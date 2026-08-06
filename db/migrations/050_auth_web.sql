-- =====================================================================
-- Chasqui TunjoSoft — 050_auth_web.sql
-- Ingreso al portal a través de Telegram. Fusión verbatim de
-- `058_auth_web.sql` y `077_portal_enlace.sql` de Chasqui Pet: son la misma
-- puerta vista desde los dos lados, y separarlas no aportaba nada.
--
-- No hay contraseñas. El personal ya está identificado por su
-- telegram_user_id y nadie se autoregistra: el portal reutiliza esa
-- identidad en vez de inventar una segunda.
--
--   1. La web crea un challenge y muestra un código de 6 dígitos.
--   2. El usuario abre el bot (deep link) y confirma que fue él.
--   3. La web canjea el challenge aprobado por un token de sesión.
--
-- El token viaja una sola vez, al canjearlo; en la base sólo queda su
-- sha256. Una copia de la tabla `sesion` no permite entrar a nadie.
--
-- Telegram sigue siendo el canal del PERSONAL. El público entra por
-- WhatsApp y no tiene sesión de portal: son dos audiencias distintas
-- (§ 040), y esta puerta es solo para la primera.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Acciones que el worker traduce a llamadas de Telegram
--
-- Vienen del módulo de turnos de Chasqui Pet, que aquí no existe. Son
-- genéricas y las necesita todo el lado del bot, así que viven con la
-- puerta que las usa.
--
-- `accion_editar` sin message_id se degrada a enviar: cuando la orden
-- llega desde un comando de texto (/sesiones, /portal) no hay mensaje que
-- editar, y Telegram recibiría un editar sin destino.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION accion_enviar(p_chat_id bigint, p_texto text,
                                         p_botones jsonb DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'tipo', 'enviar', 'chat_id', p_chat_id, 'texto', p_texto, 'botones', p_botones));
$$;

CREATE OR REPLACE FUNCTION accion_editar(p_chat_id bigint, p_mensaje_id bigint,
                                         p_texto text, p_botones jsonb DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_mensaje_id IS NULL THEN accion_enviar(p_chat_id, p_texto, p_botones)
    ELSE jsonb_strip_nulls(jsonb_build_object(
           'tipo', 'editar', 'chat_id', p_chat_id, 'message_id', p_mensaje_id,
           'texto', p_texto, 'botones', p_botones))
  END;
$$;

-- ---------------------------------------------------------------------
-- Paso 1: la web pide un challenge
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crear_challenge_web(
  p_ip inet DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_device_name text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_id uuid;
  v_codigo char(6);
BEGIN
  -- Un navegador no necesita más de 10 intentos por hora. Sin esto, el
  -- código de 6 dígitos es adivinable a fuerza de challenges.
  IF NOT consumir_rate_limit('login:ip:' || COALESCE(host(p_ip), 'desconocida'), 10, 3600) THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'rate_limit',
             'mensaje', 'Demasiados intentos. Espera unos minutos.');
  END IF;

  v_codigo := lpad((floor(random() * 1000000))::int::text, 6, '0');

  INSERT INTO auth_challenge (codigo, ip, user_agent, device_name)
  VALUES (v_codigo, p_ip, left(COALESCE(p_user_agent, ''), 300), p_device_name)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'challenge_id', v_id, 'codigo', v_codigo,
                            'expira_at', now() + interval '5 minutes');
END;
$$;

-- ---------------------------------------------------------------------
-- Paso 2: el bot aprueba o rechaza
--
-- Si ese Telegram no tiene usuario aprovisionado se deniega sin revelar
-- si el código existía (§11.1.4): para quien está afuera, un challenge
-- inventado y uno real se comportan igual.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION resolver_challenge_web(
  p_telegram_user_id bigint,
  p_challenge_id uuid,
  p_aprobar boolean
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_usuario uuid;
  c auth_challenge;
BEGIN
  IF NOT consumir_rate_limit('login:tg:' || p_telegram_user_id, 10, 3600) THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Demasiados intentos. Espera unos minutos.');
  END IF;

  v_usuario := usuario_por_telegram(p_telegram_user_id);

  SELECT * INTO c FROM auth_challenge WHERE id = p_challenge_id FOR UPDATE;

  IF NOT FOUND OR c.expira_at < now() OR c.estado <> 'pendiente' OR v_usuario IS NULL THEN
    IF FOUND AND c.estado = 'pendiente' THEN
      UPDATE auth_challenge SET intentos = intentos + 1 WHERE id = p_challenge_id;
    END IF;
    RETURN jsonb_build_object('ok', false, 'motivo', 'invalido',
             'mensaje', 'Ese intento de acceso ya no es válido. Vuelve a empezar desde el navegador.');
  END IF;

  IF NOT p_aprobar THEN
    UPDATE auth_challenge
       SET estado = 'rechazado', resuelto_at = now(), usuario_id = v_usuario
     WHERE id = p_challenge_id;
    PERFORM auditar('auth_challenge', p_challenge_id::text, 'rechazar', v_usuario, 'telegram',
                    NULL, jsonb_build_object('ip', host(c.ip)));
    RETURN jsonb_build_object('ok', true, 'aprobado', false);
  END IF;

  UPDATE auth_challenge
     SET estado = 'aprobado', usuario_id = v_usuario, resuelto_at = now()
   WHERE id = p_challenge_id;

  PERFORM auditar('auth_challenge', p_challenge_id::text, 'aprobar', v_usuario, 'telegram',
                  NULL, jsonb_build_object('ip', host(c.ip), 'user_agent', c.user_agent));

  RETURN jsonb_build_object('ok', true, 'aprobado', true, 'codigo', c.codigo);
END;
$$;

-- ---------------------------------------------------------------------
-- Paso 3: la web canjea el challenge aprobado por una sesión
--
-- El token se devuelve UNA vez y no vuelve a existir en claro: en la
-- tabla queda su sha256. Es de un solo uso (el challenge pasa a
-- 'consumido'), así que reproducir la respuesta no sirve de nada.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION emitir_sesion_web(
  p_challenge_id uuid,
  p_ip inet DEFAULT NULL,
  p_user_agent text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  c auth_challenge;
  v_token text;
  v_sesion uuid;
BEGIN
  SELECT * INTO c FROM auth_challenge WHERE id = p_challenge_id FOR UPDATE;

  IF NOT FOUND OR c.expira_at < now() THEN
    RETURN jsonb_build_object('ok', false, 'estado', 'expirado');
  END IF;

  IF c.estado <> 'aprobado' THEN
    RETURN jsonb_build_object('ok', false, 'estado', c.estado);
  END IF;

  v_token := encode(gen_random_bytes(32), 'hex');

  INSERT INTO sesion (usuario_id, token_hash, device_name, ip, user_agent)
  VALUES (c.usuario_id, encode(digest(v_token, 'sha256'), 'hex'),
          c.device_name, COALESCE(p_ip, c.ip), COALESCE(p_user_agent, c.user_agent))
  RETURNING id INTO v_sesion;

  UPDATE auth_challenge
     SET estado = 'consumido', sesion_id = v_sesion
   WHERE id = p_challenge_id;

  PERFORM auditar('sesion', v_sesion::text, 'iniciar', c.usuario_id, 'web', NULL,
                  jsonb_build_object('ip', host(COALESCE(p_ip, c.ip))));

  -- §11.1: cada inicio de sesión nuevo se avisa por Telegram. Que el
  -- dueño de la cuenta se entere es la mitad del control.
  PERFORM encolar_tarea('notificar_inicio_sesion',
            jsonb_build_object('sesion_id', v_sesion), 5, 'sesion_' || v_sesion::text);

  RETURN jsonb_build_object('ok', true, 'token', v_token, 'sesion_id', v_sesion,
                            'usuario', perfil_telegram(
                              (SELECT telegram_user_id FROM usuario WHERE id = c.usuario_id)));
END;
$$;

CREATE OR REPLACE FUNCTION estado_challenge_web(p_challenge_id uuid)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN expira_at < now() AND estado = 'pendiente' THEN 'expirado' ELSE estado END
    FROM auth_challenge WHERE id = p_challenge_id;
$$;

-- ---------------------------------------------------------------------
-- Uso de la sesión
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sesion_por_token(p_token text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  s sesion;
BEGIN
  IF p_token IS NULL OR length(p_token) < 32 THEN
    RETURN NULL;
  END IF;

  SELECT * INTO s FROM sesion
   WHERE token_hash = encode(digest(p_token, 'sha256'), 'hex')
     AND NOT revocada AND expires_at > now();

  IF NOT FOUND THEN RETURN NULL; END IF;

  -- last_seen_at se usa para la lista de sesiones activas del §11.1. No
  -- merece un UPDATE por cada request: basta con un minuto de resolución.
  IF s.last_seen_at < now() - interval '1 minute' THEN
    UPDATE sesion SET last_seen_at = now() WHERE id = s.id;
  END IF;

  RETURN jsonb_build_object(
    'sesion_id', s.id,
    'usuario_id', s.usuario_id,
    'nombre', (SELECT nombre_completo FROM usuario WHERE id = s.usuario_id),
    'sede_id', (SELECT sede_id FROM usuario WHERE id = s.usuario_id),
    'permisos', COALESCE((SELECT jsonb_agg(permiso_codigo ORDER BY permiso_codigo)
                            FROM v_usuario_permiso WHERE usuario_id = s.usuario_id), '[]'::jsonb));
END;
$$;

CREATE OR REPLACE FUNCTION cerrar_sesion_web(p_token text)
RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  UPDATE sesion SET revocada = true, revocada_at = now()
   WHERE token_hash = encode(digest(COALESCE(p_token, ''), 'sha256'), 'hex')
     AND NOT revocada
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN RETURN false; END IF;
  PERFORM auditar('sesion', v_id::text, 'cerrar', NULL, 'web');
  RETURN true;
END;
$$;

-- Sesiones activas de un usuario, para el comando /sesiones del bot y la
-- vista del portal.
CREATE OR REPLACE FUNCTION sesiones_activas(p_usuario_id uuid)
RETURNS TABLE (sesion_id uuid, dispositivo text, ip inet, iniciada timestamptz, vista timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT id, COALESCE(device_name, left(COALESCE(user_agent, 'Navegador'), 40)),
         ip, created_at, last_seen_at
    FROM sesion
   WHERE usuario_id = p_usuario_id AND NOT revocada AND expires_at > now()
   ORDER BY last_seen_at DESC;
$$;

CREATE OR REPLACE FUNCTION revocar_sesiones_usuario(p_actor_id uuid, p_usuario_id uuid)
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  IF p_actor_id <> p_usuario_id THEN
    PERFORM exigir_permiso(p_actor_id, 'usuarios.gestionar');
  END IF;

  UPDATE sesion SET revocada = true, revocada_at = now(), revocada_por = p_actor_id
   WHERE usuario_id = p_usuario_id AND NOT revocada;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  PERFORM auditar('usuario', p_usuario_id::text, 'revocar_sesiones', p_actor_id, 'web',
                  NULL, jsonb_build_object('sesiones', v_n));
  RETURN v_n;
END;
$$;

-- ---------------------------------------------------------------------
-- El lado del bot: deep link, confirmación y /sesiones
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_auth_tarjeta(p_challenge_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE c auth_challenge;
BEGIN
  SELECT * INTO c FROM auth_challenge WHERE id = p_challenge_id;

  IF NOT FOUND OR c.estado <> 'pendiente' OR c.expira_at < now() THEN
    RETURN jsonb_build_object('texto',
      '⌛ Ese intento de acceso ya no es válido.' || E'\n' ||
      'Vuelve a la pantalla de ingreso del portal y empieza de nuevo.',
      'botones', '[]'::jsonb);
  END IF;

  RETURN jsonb_build_object('texto',
    format('🔐 <b>Ingreso al portal</b>%sCódigo: <b>%s</b>%s🕒 %s%s🌐 %s%s💻 %s%s%s',
           E'\n', c.codigo, E'\n',
           to_char(c.created_at AT TIME ZONE 'America/Bogota', 'HH12:MI am'), E'\n',
           COALESCE(host(c.ip), 'origen desconocido'), E'\n',
           esc(COALESCE(c.device_name, left(COALESCE(c.user_agent, 'Navegador'), 60))), E'\n\n',
           'Confirma sólo si ese código es el que estás viendo en la pantalla.'),
    'botones', jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '✅ Sí, soy yo', 'd', 'aut:si:' || c.id),
      jsonb_build_object('t', '🚫 No fui yo',  'd', 'aut:no:' || c.id))));
END;
$$;

CREATE OR REPLACE FUNCTION bot_auth_callback(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje_id bigint, p_data text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_partes text[] := string_to_array(p_data, ':');
  v_tg   bigint;
  v_r    jsonb;
  v_texto text;
  v_alerta text;
BEGIN
  IF v_partes[1] <> 'aut' THEN
    RETURN NULL;
  END IF;

  SELECT telegram_user_id INTO v_tg FROM usuario WHERE id = p_usuario_id;

  IF v_partes[2] = 'ses' THEN
    SELECT '🔐 <b>Sesiones abiertas</b>' || E'\n' ||
           COALESCE(string_agg(format('• %s · %s · vista %s',
                      esc(dispositivo), COALESCE(host(ip), '—'),
                      to_char(vista AT TIME ZONE 'America/Bogota', 'DD/MM HH12:MI am')), E'\n'),
                    'No tienes ninguna sesión abierta en el portal.')
      INTO v_texto FROM sesiones_activas(p_usuario_id);

    IF EXISTS (SELECT 1 FROM sesiones_activas(p_usuario_id)) THEN
      RETURN jsonb_build_object('alerta', NULL, 'acciones', jsonb_build_array(
        accion_editar(p_chat_id, p_mensaje_id, v_texto, jsonb_build_array(
          jsonb_build_array(jsonb_build_object('t', '🚪 Cerrar todas', 'd', 'aut:cerrar')),
          jsonb_build_array(jsonb_build_object('t', '⬅️ Menú', 'd', 'menu'))))));
    END IF;

    RETURN jsonb_build_object('alerta', NULL, 'acciones', jsonb_build_array(
      accion_editar(p_chat_id, p_mensaje_id, v_texto, jsonb_build_array(
        jsonb_build_array(jsonb_build_object('t', '⬅️ Menú', 'd', 'menu'))))));
  END IF;

  IF v_partes[2] = 'cerrar' THEN
    v_texto := format('🚪 Cerraste %s sesión(es) del portal.',
                      revocar_sesiones_usuario(p_usuario_id, p_usuario_id));
    RETURN jsonb_build_object('alerta', 'Sesiones cerradas', 'acciones', jsonb_build_array(
      accion_editar(p_chat_id, p_mensaje_id, v_texto, jsonb_build_array(
        jsonb_build_array(jsonb_build_object('t', '⬅️ Menú', 'd', 'menu'))))));
  END IF;

  v_r := resolver_challenge_web(v_tg, v_partes[3]::uuid, v_partes[2] = 'si');

  IF NOT (v_r->>'ok')::boolean THEN
    v_alerta := 'No se pudo';
    v_texto  := '⚠️ ' || esc(v_r->>'mensaje');
  ELSIF (v_r->>'aprobado')::boolean THEN
    v_alerta := 'Ingreso autorizado';
    v_texto  := '✅ <b>Listo</b>' || E'\n' ||
                'Vuelve al navegador: ya deberías estar dentro.';
  ELSE
    v_alerta := 'Intento bloqueado';
    v_texto  := '🚫 <b>Intento bloqueado</b>' || E'\n' ||
                'Nadie entró con tu usuario. Si no fuiste tú quien lo intentó, avísale al administrador.';
  END IF;

  RETURN jsonb_build_object('alerta', v_alerta, 'acciones', jsonb_build_array(
    accion_editar(p_chat_id, p_mensaje_id, v_texto, jsonb_build_array(
      jsonb_build_array(jsonb_build_object('t', '⬅️ Menú', 'd', 'menu'))))));
END;
$$;

CREATE OR REPLACE FUNCTION bot_auth_texto(
  p_usuario_id uuid, p_chat_id bigint, p_texto text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_arg text;
  v_id  uuid;
  v_vista jsonb;
BEGIN
  IF p_texto IN ('/sesiones', 'sesiones') THEN
    RETURN bot_auth_callback(p_usuario_id, p_chat_id, NULL, 'aut:ses', p_sede_id);
  END IF;

  IF p_texto NOT LIKE '/start web-%' THEN
    RETURN NULL;
  END IF;

  v_arg := substring(p_texto FROM 12);
  BEGIN
    v_id := v_arg::uuid;
  EXCEPTION WHEN others THEN
    v_id := NULL;
  END;

  IF v_id IS NULL THEN
    RETURN jsonb_build_object('acciones', jsonb_build_array(accion_enviar(p_chat_id,
      '⌛ Ese enlace de ingreso no es válido. Vuelve a empezar desde el navegador.')));
  END IF;

  v_vista := bot_auth_tarjeta(v_id);
  RETURN jsonb_build_object('acciones', jsonb_build_array(
    accion_enviar(p_chat_id, v_vista->>'texto', v_vista->'botones')));
END;
$$;

-- Dirección del portal tal como la ve el personal. El bot arma el enlace
-- con esto: la base no conoce WEB_PUBLIC_URL, que es del contenedor web.
INSERT INTO config (clave, valor, tipo, descripcion, editable_ui) VALUES
  ('portal_url', 'http://localhost:3200', 'texto',
   'Dirección del portal, para el enlace de ingreso que manda el bot', true)
ON CONFLICT (clave) DO NOTHING;

-- ---------------------------------------------------------------------
-- Enlace de un solo uso, pedido desde el chat
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crear_enlace_portal(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_id     uuid;
  v_activo boolean;
  v_expira timestamptz;
BEGIN
  SELECT activo INTO v_activo FROM usuario WHERE id = p_usuario_id;
  IF NOT COALESCE(v_activo, false) THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_usuario',
             'mensaje', 'Tu usuario no está habilitado para el portal.');
  END IF;

  -- Cada enlace es una sesión potencial. Cinco por hora alcanzan de sobra
  -- para el uso real y ponen techo a un chat secuestrado.
  IF NOT consumir_rate_limit('portal:enlace:' || p_usuario_id::text, 5, 3600) THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'rate_limit',
             'mensaje', 'Pediste varios enlaces seguidos. Espera unos minutos.');
  END IF;

  -- Los enlaces anteriores que sigan vivos se anulan: si uno se filtró en
  -- el chat, pedir otro tiene que ser suficiente para dejarlo inservible.
  UPDATE auth_challenge
     SET estado = 'expirado', resuelto_at = now()
   WHERE usuario_id = p_usuario_id
     AND estado = 'aprobado'
     AND device_name = 'Enlace desde Telegram'
     AND expira_at > now();

  INSERT INTO auth_challenge (codigo, estado, usuario_id, device_name, resuelto_at)
  VALUES (lpad((floor(random() * 1000000))::int::text, 6, '0'),
          'aprobado', p_usuario_id, 'Enlace desde Telegram', now())
  RETURNING id, expira_at INTO v_id, v_expira;

  PERFORM auditar('auth_challenge', v_id::text, 'crear_enlace', p_usuario_id, 'telegram',
                  NULL, jsonb_build_object('canal', 'enlace_telegram'));

  RETURN jsonb_build_object(
    'ok', true,
    'url', rtrim(config_txt('portal_url', 'http://localhost:3200'), '/')
           || '/entrar/enlace/' || v_id::text,
    'expira_at', v_expira);
END;
$$;

-- ---------------------------------------------------------------------
-- El lado del bot
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_por_menu(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_array(jsonb_build_array(
           jsonb_build_object('t', '🖥️ Entrar al portal', 'd', 'por:enlace')));
$$;

CREATE OR REPLACE FUNCTION bot_por_callback(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje_id bigint, p_data text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_r     jsonb;
  v_texto text;
  v_alerta text;
BEGIN
  IF p_data <> 'por:enlace' THEN
    RETURN NULL;
  END IF;

  v_r := crear_enlace_portal(p_usuario_id);

  IF NOT (v_r->>'ok')::boolean THEN
    v_alerta := 'No se pudo';
    v_texto  := '⚠️ ' || esc(v_r->>'mensaje');
  ELSE
    v_alerta := 'Enlace listo';
    -- El enlace va como texto plano, sin <a>: en el computador se copia, y
    -- que se vea a dónde lleva es parte de poder desconfiar de él.
    v_texto := '🖥️ <b>Entrar al portal</b>' || E'\n\n' ||
               esc(v_r->>'url') || E'\n\n' ||
               '⏳ Sirve <b>una sola vez</b> y por <b>5 minutos</b>.' || E'\n' ||
               'Si lo abres aquí entras desde el celular; para entrar en el ' ||
               'computador de la clínica, cópialo allá.' || E'\n' ||
               'No se lo pases a nadie: quien lo abra entra con tu usuario.';
  END IF;

  RETURN jsonb_build_object('alerta', v_alerta, 'acciones', jsonb_build_array(
    accion_editar(p_chat_id, p_mensaje_id, v_texto, jsonb_build_array(
      jsonb_build_array(jsonb_build_object('t', '⬅️ Menú', 'd', 'menu'))))));
END;
$$;

CREATE OR REPLACE FUNCTION bot_por_texto(
  p_usuario_id uuid, p_chat_id bigint, p_texto text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  IF p_texto NOT IN ('/portal', 'portal') THEN
    RETURN NULL;
  END IF;
  RETURN bot_por_callback(p_usuario_id, p_chat_id, NULL, 'por:enlace', p_sede_id);
END;
$$;

-- ---------------------------------------------------------------------
-- Despachadores del bot de Telegram
--
-- En Chasqui Pet este bloque encadenaba seis módulos —turnos, inventario,
-- cobro, compras, clínico, portal—. Aquí quedan dos, y a propósito: el bot
-- de Telegram de este proyecto sirve para entrar al portal y confirmar el
-- ingreso, nada más. La atención al público vive en WhatsApp, y el motor
-- que la atiende es `040_asistente.sql`, no un árbol de botones.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_modulo_callback(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje_id bigint, p_data text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT COALESCE(
    bot_por_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_auth_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id));
$$;

CREATE OR REPLACE FUNCTION bot_modulo_texto(
  p_usuario_id uuid, p_chat_id bigint, p_texto text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT COALESCE(
    bot_auth_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_por_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id));
$$;

CREATE OR REPLACE FUNCTION bot_menu_extra(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT bot_por_menu(p_usuario_id);
$$;

CREATE OR REPLACE FUNCTION bot_texto_ayuda(p_usuario_id uuid)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT '<b>Comandos</b>' || E'\n' ||
         '/portal — enlace para entrar al portal' || E'\n' ||
         '/sesiones — sesiones abiertas en el portal' || E'\n' ||
         '/ayuda — esta ayuda';
$$;
