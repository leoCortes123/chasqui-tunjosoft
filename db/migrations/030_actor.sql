-- =====================================================================
-- Chasqui TunjoSoft — 030_actor.sql
-- Contacto, conversación y mensaje: quién habla, por dónde y qué se dijo.
--
-- Por qué existe este archivo
-- ---------------------------
-- Chasqui Pet atendía solo a personal interno: todo pivotaba sobre una fila
-- en `usuario`, con rol y permisos. Este bot atiende al PÚBLICO — un número
-- de WhatsApp desconocido, sin usuario, sin rol y sin permisos.
--
-- La generalización es el **actor**: el interlocutor de una conversación,
-- sea un contacto anónimo o un miembro del personal. Todo actor tiene fila
-- en `contacto`; el interno además apunta a `usuario`. El catálogo de
-- herramientas se filtra por AUDIENCIA (pública / interna), y `tiene_permiso`
-- sigue aplicando — pero solo sobre el actor interno.
--
-- El principio heredado no cambia: los permisos son datos. Se le agrega un
-- eje, no se reemplaza.
--
-- El canal es una columna, no una tabla: `whatsapp`, `telegram`, `simulador`.
-- El simulador del portal no es un caso especial que haya que mantener en
-- sincronía aparte — es un canal más sobre el mismo motor.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Normalización del celular
--
-- Es la mitad del antiduplicado de historia clínica, y por eso vive en el
-- núcleo y no en el dominio: el mismo número escrito «315 418 4245»,
-- «+573154184245» y «57 315 4184245» tiene que colisionar contra el mismo
-- índice único, no crear tres contactos.
--
-- Devuelve E.164. Si no logra reconocer un celular colombiano devuelve solo
-- los dígitos: es preferible un contacto con un número raro a perder el
-- mensaje de alguien.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION normalizar_celular(p_texto text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  d text := regexp_replace(COALESCE(p_texto, ''), '\D', '', 'g');
BEGIN
  IF d = '' THEN RETURN NULL; END IF;

  -- 0057…, 057… → 57…
  d := regexp_replace(d, '^0+', '');

  -- 10 dígitos que empiezan por 3: celular colombiano sin indicativo.
  IF d ~ '^3\d{9}$' THEN
    RETURN '+57' || d;
  END IF;

  -- 12 dígitos con indicativo de Colombia.
  IF d ~ '^573\d{9}$' THEN
    RETURN '+' || d;
  END IF;

  -- Fijo de Bogotá a 10 dígitos (601…) o cualquier otro: se conserva tal cual.
  IF d ~ '^57\d{10}$' THEN
    RETURN '+' || d;
  END IF;

  RETURN '+' || d;
END;
$$;

-- ---------------------------------------------------------------------
-- Contacto: la identidad externa
--
-- Un contacto puede o no tener `usuario_id`. Con él es personal interno y
-- se le aplican permisos; sin él es público y solo ve el catálogo abierto.
-- ---------------------------------------------------------------------
CREATE TABLE contacto (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  celular     text,
  nombre      text,
  usuario_id  uuid REFERENCES usuario(id) ON DELETE SET NULL,
  bloqueado   boolean NOT NULL DEFAULT false,
  notas       text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- El índice único es sobre el celular ya normalizado. Sin esto el
-- antiduplicado no existe.
CREATE UNIQUE INDEX idx_contacto_celular ON contacto (celular) WHERE celular IS NOT NULL;
CREATE INDEX idx_contacto_usuario ON contacto (usuario_id) WHERE usuario_id IS NOT NULL;

CREATE TRIGGER contacto_touch BEFORE UPDATE ON contacto
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- Busca o crea. El celular entra sin normalizar: normalizarlo es
-- responsabilidad de esta función, no de quien la llama.
CREATE OR REPLACE FUNCTION contacto_asegurar(
  p_celular text, p_nombre text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_cel text := normalizar_celular(p_celular);
  v_id  uuid;
BEGIN
  IF v_cel IS NULL THEN
    RAISE EXCEPTION 'No se puede crear un contacto sin celular';
  END IF;

  INSERT INTO contacto (celular, nombre)
  VALUES (v_cel, NULLIF(trim(COALESCE(p_nombre, '')), ''))
  -- El predicado se repite porque el índice es parcial: sin él, Postgres no
  -- reconoce cuál es el índice del ON CONFLICT.
  ON CONFLICT (celular) WHERE celular IS NOT NULL DO UPDATE
    -- El nombre que trae el canal solo llena el vacío; no pisa el que ya
    -- se confirmó con la persona.
    SET nombre = COALESCE(contacto.nombre, EXCLUDED.nombre)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- El actor, resuelto de una vez: es lo que necesitan todas las funciones
-- del asistente para decidir qué puede ver y qué puede hacer.
CREATE OR REPLACE FUNCTION actor(p_contacto_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
           'contacto_id', c.id,
           'usuario_id',  c.usuario_id,
           'es_interno',  c.usuario_id IS NOT NULL AND COALESCE(u.activo, false),
           'nombre',      COALESCE(u.nombre_completo, c.nombre),
           'celular',     c.celular,
           'bloqueado',   c.bloqueado)
    FROM contacto c
    LEFT JOIN usuario u ON u.id = c.usuario_id
   WHERE c.id = p_contacto_id;
$$;

-- El usuario interno detrás del contacto, o NULL si es público.
-- Devolver NULL y no fallar es deliberado: `tiene_permiso(NULL, …)` es
-- false, que es exactamente lo que debe pasar con un desconocido.
CREATE OR REPLACE FUNCTION actor_usuario(p_contacto_id uuid)
RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT u.id
    FROM contacto c JOIN usuario u ON u.id = c.usuario_id AND u.activo
   WHERE c.id = p_contacto_id;
$$;

-- ---------------------------------------------------------------------
-- Conversación: un hilo por contacto y canal
--
-- `atendida_por_humano` es la regla de oro del proyecto: mientras esté
-- activa el bot NO responde en ese hilo. Se levanta con «ASESOR» o por
-- escalamiento de urgencia, y solo la baja una persona desde el panel.
-- ---------------------------------------------------------------------
CREATE TABLE conversacion (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contacto_id         uuid NOT NULL REFERENCES contacto(id) ON DELETE CASCADE,
  canal               text NOT NULL
                        CHECK (canal IN ('whatsapp','telegram','simulador')),
  -- Identificador del hilo en el canal: el wa_id de WhatsApp, el chat_id de
  -- Telegram. Texto porque no todos los canales usan enteros.
  chat_externo_id     text,
  estado              text NOT NULL DEFAULT 'abierta'
                        CHECK (estado IN ('abierta','cerrada')),
  intencion           text,      -- 'urgencia','cita','precios','ubicacion','remision',…
  atendida_por_humano boolean NOT NULL DEFAULT false,
  humano_desde_at     timestamptz,
  motivo_escalamiento text,
  ultima_actividad_at timestamptz NOT NULL DEFAULT now(),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

-- Un solo hilo abierto por contacto y canal. Dos hilos abiertos a la vez
-- son dos bots contestándole a la misma persona.
CREATE UNIQUE INDEX idx_conversacion_abierta
  ON conversacion (contacto_id, canal) WHERE estado = 'abierta';
CREATE INDEX idx_conversacion_actividad ON conversacion (ultima_actividad_at DESC);
CREATE INDEX idx_conversacion_humano ON conversacion (atendida_por_humano)
  WHERE atendida_por_humano;

CREATE TRIGGER conversacion_touch BEFORE UPDATE ON conversacion
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TABLE mensaje (
  id              bigserial PRIMARY KEY,
  conversacion_id uuid NOT NULL REFERENCES conversacion(id) ON DELETE CASCADE,
  direccion       text NOT NULL CHECK (direccion IN ('entrante','saliente')),
  tipo            text NOT NULL DEFAULT 'texto'
                    CHECK (tipo IN ('texto','audio','imagen','documento','boton','plantilla')),
  texto           text,
  -- Payload crudo del canal, tal cual llegó. Es lo que permite auditar qué
  -- dijo el bot y por qué, que es lo que se muestra en el panel.
  payload         jsonb,
  -- Identificador del mensaje en el canal. El índice único es la
  -- idempotencia del webhook: Meta reintenta, y sin esto se duplican
  -- respuestas y tareas.
  id_externo      text,
  enviado_por     uuid REFERENCES usuario(id),  -- no nulo = lo escribió una persona
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_mensaje_externo ON mensaje (id_externo)
  WHERE id_externo IS NOT NULL;
CREATE INDEX idx_mensaje_conversacion ON mensaje (conversacion_id, id);

-- Abre o recupera el hilo del contacto en ese canal, y de paso registra el
-- identificador externo si cambió (Telegram lo cambia si borran el chat).
CREATE OR REPLACE FUNCTION conversacion_asegurar(
  p_contacto_id uuid, p_canal text, p_chat_externo_id text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id
    FROM conversacion
   WHERE contacto_id = p_contacto_id AND canal = p_canal AND estado = 'abierta';

  IF v_id IS NULL THEN
    INSERT INTO conversacion (contacto_id, canal, chat_externo_id)
    VALUES (p_contacto_id, p_canal, p_chat_externo_id)
    RETURNING id INTO v_id;
  ELSE
    UPDATE conversacion
       SET chat_externo_id = COALESCE(p_chat_externo_id, chat_externo_id),
           ultima_actividad_at = now()
     WHERE id = v_id;
  END IF;

  RETURN v_id;
END;
$$;

-- Punto de entrada del canal: de un celular a un hilo listo para conversar.
-- Devuelve todo lo que el webhook necesita sin una segunda consulta.
CREATE OR REPLACE FUNCTION conversacion_entrante(
  p_canal text,
  p_celular text,
  p_nombre text DEFAULT NULL,
  p_chat_externo_id text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_contacto uuid := contacto_asegurar(p_celular, p_nombre);
  v_conv     uuid := conversacion_asegurar(v_contacto, p_canal, p_chat_externo_id);
  c          conversacion%ROWTYPE;
BEGIN
  SELECT * INTO c FROM conversacion WHERE id = v_conv;

  RETURN jsonb_build_object(
    'conversacion_id',     v_conv,
    'contacto_id',         v_contacto,
    'actor',               actor(v_contacto),
    'atendida_por_humano', c.atendida_por_humano,
    'intencion',           c.intencion);
END;
$$;

-- Registra un mensaje. Devuelve NULL si el id externo ya se había visto:
-- quien llama debe descartar el update sin procesarlo.
CREATE OR REPLACE FUNCTION mensaje_registrar(
  p_conversacion_id uuid,
  p_direccion text,
  p_texto text,
  p_tipo text DEFAULT 'texto',
  p_payload jsonb DEFAULT NULL,
  p_id_externo text DEFAULT NULL,
  p_enviado_por uuid DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE v_id bigint;
BEGIN
  INSERT INTO mensaje (conversacion_id, direccion, tipo, texto, payload, id_externo, enviado_por)
  VALUES (p_conversacion_id, p_direccion, p_tipo, p_texto, p_payload,
          NULLIF(p_id_externo, ''), p_enviado_por)
  ON CONFLICT (id_externo) WHERE id_externo IS NOT NULL DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NOT NULL THEN
    UPDATE conversacion SET ultima_actividad_at = now() WHERE id = p_conversacion_id;
  END IF;

  RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------
-- Traspaso a humano y vuelta
--
-- Siempre hay salida a humano. El bot se calla en ese hilo hasta que una
-- persona lo devuelva: nunca se desactiva solo por tiempo, porque un hilo
-- que el bot retoma sin que nadie lo decida es exactamente la sorpresa que
-- no puede pasar con un cliente enojado o una urgencia.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION escalar_a_humano(
  p_conversacion_id uuid,
  p_motivo text,
  p_intencion text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE c conversacion%ROWTYPE;
BEGIN
  UPDATE conversacion
     SET atendida_por_humano = true,
         humano_desde_at = COALESCE(humano_desde_at, now()),
         motivo_escalamiento = p_motivo,
         intencion = COALESCE(p_intencion, intencion),
         ultima_actividad_at = now()
   WHERE id = p_conversacion_id
  RETURNING * INTO c;

  IF c.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa conversación no existe.');
  END IF;

  PERFORM auditar('conversacion', p_conversacion_id::text, 'escalar', NULL, c.canal,
                  NULL, jsonb_build_object('motivo', p_motivo, 'intencion', c.intencion));

  -- El personal se entera por la cola, no por el panel abierto por
  -- casualidad. La clave de unicidad evita diez alertas del mismo hilo.
  PERFORM encolar_tarea('alertar_personal',
    jsonb_build_object('conversacion_id', p_conversacion_id, 'motivo', p_motivo),
    10, 'escalar_' || p_conversacion_id::text, 0, 3);

  RETURN jsonb_build_object('ok', true, 'conversacion_id', p_conversacion_id,
                            'motivo', p_motivo);
END;
$$;

CREATE OR REPLACE FUNCTION devolver_al_bot(p_conversacion_id uuid, p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM exigir_permiso(p_usuario_id, 'conversaciones.atender');

  UPDATE conversacion
     SET atendida_por_humano = false,
         humano_desde_at = NULL,
         motivo_escalamiento = NULL,
         ultima_actividad_at = now()
   WHERE id = p_conversacion_id;

  PERFORM auditar('conversacion', p_conversacion_id::text, 'devolver_al_bot',
                  p_usuario_id, 'web');

  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ¿Debe responder el bot en este hilo? Una sola pregunta, un solo lugar
-- donde cambiarla.
CREATE OR REPLACE FUNCTION bot_responde(p_conversacion_id uuid)
RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1
      FROM conversacion c JOIN contacto ct ON ct.id = c.contacto_id
     WHERE c.id = p_conversacion_id
       AND c.estado = 'abierta'
       AND NOT c.atendida_por_humano
       AND NOT ct.bloqueado
  );
$$;

-- ---------------------------------------------------------------------
-- Lo que ve el panel (§ PROPUESTA 3.10)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_conversacion_activa AS
  SELECT c.id                AS conversacion_id,
         c.canal,
         c.intencion,
         c.atendida_por_humano,
         c.motivo_escalamiento,
         c.humano_desde_at,
         c.ultima_actividad_at,
         ct.id               AS contacto_id,
         ct.celular,
         COALESCE(u.nombre_completo, ct.nombre) AS nombre,
         (SELECT m.texto FROM mensaje m
           WHERE m.conversacion_id = c.id ORDER BY m.id DESC LIMIT 1) AS ultimo_mensaje,
         (SELECT count(*) FROM mensaje m WHERE m.conversacion_id = c.id) AS mensajes
    FROM conversacion c
    JOIN contacto ct ON ct.id = c.contacto_id
    LEFT JOIN usuario u ON u.id = ct.usuario_id
   WHERE c.estado = 'abierta'
   ORDER BY c.atendida_por_humano DESC, c.ultima_actividad_at DESC;
