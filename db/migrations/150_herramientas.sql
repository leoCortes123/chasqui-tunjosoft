-- =====================================================================
-- Chasqui TunjoSoft — 150_herramientas.sql
-- El catálogo de herramientas del dominio.
--
-- Aquí está el tercer arreglo de genericidad, y se nota por lo que este
-- archivo NO hace: no reemplaza ni una función del núcleo. Antes había que
-- hacer `CREATE OR REPLACE` de `ia_leer`, `ia_escribir`, `ia_resumen_accion`,
-- `ia_validar_accion` e `ia_contexto` —copiando a mano las ramas que ya
-- existían, porque reemplazar las pierde— y así se perdió más de una vez la
-- rama de `pedir_asesor`, que no falla en voz alta: simplemente el asistente
-- deja de poder escalar.
--
-- Ahora cada herramienta declara en el catálogo qué función la ejecuta, y el
-- núcleo despacha. Agregar una herramienta es un INSERT. Dos módulos de
-- dominio pueden convivir sin pisarse.
--
-- Convención de nombres: `h_` para lo que ejecuta una herramienta, `f_ctx_`
-- para lo que aporta contexto. Ninguna de las dos cosas tiene lógica de
-- negocio propia — llaman a las funciones de 100, 110 y 120, que son las
-- mismas que usará el portal.
--
-- Las dos caras del sistema, en una sola tabla:
--
--   audiencia 'publica' — el demo comercial. Lo que ve un prospecto.
--   audiencia 'interna' — el asistente propio de la agencia, por Telegram.
--                         Sujeto además a `permiso`.
--
-- Y son el mismo bot, en el mismo chat. Quien escribe con su Telegram
-- aprovisionado como usuario ve las dos; cualquier otro ve solo las
-- públicas. Eso ya lo resuelve `ia_herramientas` en el núcleo.
-- =====================================================================

SET client_min_messages = warning;

-- =====================================================================
-- 1. Herramientas públicas — el demo comercial
-- =====================================================================

CREATE OR REPLACE FUNCTION h_listar_servicios(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT listar_servicios(NULLIF(p_args->>'texto', ''));
$$;

CREATE OR REPLACE FUNCTION h_cotizar_servicio(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT cotizar_servicio(p_args->>'codigo');
$$;

CREATE OR REPLACE FUNCTION h_informacion_empresa(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'negocio',       config_txt('nombre_negocio', 'TunjoSoft'),
    'que_hacemos',   config_txt('empresa_que_hacemos', ''),
    'ciudad',        config_txt('ciudad', 'Bogotá'),
    'sitio',         config_txt('empresa_sitio', ''),
    'correo',        config_txt('empresa_correo', ''),
    'whatsapp',      config_txt('empresa_whatsapp', ''),
    'horario',       config_txt('empresa_horario', ''),
    'politica_datos', config_txt('politica_datos_url', ''),
    'sobre_el_negocio', NULLIF(config_txt('ia_sobre_el_negocio', ''), ''));
$$;

CREATE OR REPLACE FUNCTION h_horarios_reunion(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT horarios_reunion(
           COALESCE(NULLIF(p_args->>'codigo', ''), 'diagnostico'),
           NULLIF(p_args->>'fecha', '')::date,
           COALESCE(NULLIF(p_args->>'dias', '')::int, 7));
$$;

CREATE OR REPLACE FUNCTION h_mis_reuniones(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'reuniones', reuniones_del_contacto(
                   p_contacto_id,
                   COALESCE((p_args->>'incluir_pasadas')::boolean, false)));
$$;


-- --- Escrituras públicas ---------------------------------------------
--
-- No las ejecuta el modelo: dejan propuesta y esperan el botón. La regla no
-- se relaja porque del otro lado haya un prospecto y no un empleado.

CREATE OR REPLACE FUNCTION h_esc_agendar_reunion(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_conv uuid;
BEGIN
  SELECT id INTO v_conv FROM conversacion
   WHERE contacto_id = p_contacto_id AND estado = 'abierta'
   ORDER BY ultima_actividad_at DESC LIMIT 1;

  RETURN agendar_reunion(
    p_contacto_id,
    COALESCE(NULLIF(p_args->>'codigo', ''), 'diagnostico'),
    (p_args->>'inicia_at')::timestamptz,
    p_args->>'con_quien',
    NULLIF(p_args->>'negocio', ''),
    NULLIF(p_args->>'correo', ''),
    NULLIF(p_args->>'celular', ''),
    NULLIF(p_args->>'motivo', ''),
    v_conv);
END;
$$;

CREATE OR REPLACE FUNCTION h_val_agendar_reunion(p_args jsonb)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NULLIF(trim(COALESCE(p_args->>'con_quien', '')), '') IS NULL THEN
    RETURN 'Falta el nombre de la persona. Pregúntaselo con naturalidad antes de proponer la reunión.';
  END IF;

  IF p_args->>'inicia_at' IS NULL THEN
    RETURN 'Falta la fecha y la hora. Ofrécele opciones con horarios_reunion y copia inicia_at exacto.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM tipo_reunion
                  WHERE codigo = COALESCE(NULLIF(p_args->>'codigo', ''), 'diagnostico')
                    AND activo) THEN
    RETURN 'Ese tipo de reunión no existe. Omite el código para usar el que va por defecto.';
  END IF;

  RETURN NULL;
END;
$$;

-- La tarjeta. Se arma en SQL, con los datos de la base y no con lo que el
-- modelo crea recordar: si él la redactara, un día diría una hora distinta
-- de la que se va a guardar y la persona confirmaría esa.
CREATE OR REPLACE FUNCTION h_res_agendar_reunion(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
  t    tipo_reunion%ROWTYPE;
  v_at timestamptz := (p_args->>'inicia_at')::timestamptz;
  v    text;
BEGIN
  SELECT * INTO t FROM tipo_reunion
   WHERE codigo = COALESCE(NULLIF(p_args->>'codigo', ''), 'diagnostico');

  v := 'Confirmemos:' || E'\n\n'
    || '🗓️ ' || esc(t.nombre) || E'\n'
    || '📅 ' || fecha_es(v_at) || ' a las ' || hora_es(v_at) || E'\n'
    || '⏱️ ' || t.duracion_min || ' minutos' || E'\n'
    || '👤 ' || esc(p_args->>'con_quien')
    || CASE WHEN NULLIF(p_args->>'negocio', '') IS NOT NULL
            THEN ' — ' || esc(p_args->>'negocio') ELSE '' END;

  IF t.modalidad = 'virtual' THEN
    v := v || E'\n' || '💻 ' ||
         COALESCE(NULLIF(esc(t.enlace), ''), 'videollamada; te mando el enlace por aquí');
  END IF;

  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION h_esc_cancelar_reunion(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT cancelar_reunion((p_args->>'reunion_id')::uuid, NULLIF(p_args->>'motivo', ''));
$$;

CREATE OR REPLACE FUNCTION h_esc_reagendar_reunion(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT reagendar_reunion((p_args->>'reunion_id')::uuid,
                           (p_args->>'inicia_at')::timestamptz);
$$;

-- El `::uuid` revienta con cualquier cosa que no sea un identificador, y el
-- modelo manda lo que recuerda. Aquí «no parece un uuid» y «no existe» son
-- el mismo caso y la misma respuesta.
CREATE OR REPLACE FUNCTION h_val_reunion_existente(p_args jsonb)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF COALESCE(p_args->>'reunion_id', '')
       !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     OR NOT EXISTS (SELECT 1 FROM reunion WHERE id = (p_args->>'reunion_id')::uuid) THEN
    RETURN 'Esa reunión no existe. Mira cuáles tiene con mis_reuniones y usa el identificador que devuelva.';
  END IF;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION h_res_cancelar_reunion(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT 'Voy a cancelar ' || esc(t.nombre) || ' del ' || fecha_es(r.inicia_at)
      || ' a las ' || hora_es(r.inicia_at) || '.'
    FROM reunion r JOIN tipo_reunion t ON t.codigo = r.tipo_codigo
   WHERE r.id = (p_args->>'reunion_id')::uuid;
$$;

CREATE OR REPLACE FUNCTION h_res_reagendar_reunion(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT 'Voy a mover ' || esc(t.nombre) || E'\n'
      || 'de: ' || fecha_es(r.inicia_at) || ' a las ' || hora_es(r.inicia_at) || E'\n'
      || 'a: '  || fecha_es((p_args->>'inicia_at')::timestamptz)
                || ' a las ' || hora_es((p_args->>'inicia_at')::timestamptz)
    FROM reunion r JOIN tipo_reunion t ON t.codigo = r.tipo_codigo
   WHERE r.id = (p_args->>'reunion_id')::uuid;
$$;

-- Dejar los datos sin agendar nada. Es la salida para quien no quiere
-- comprometerse a una hora todavía, y sin ella esa conversación se pierde.
CREATE OR REPLACE FUNCTION h_esc_dejar_datos(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT registrar_interes(
           p_contacto_id,
           p_args->>'negocio',
           NULLIF(p_args->>'sitio', ''),
           NULLIF(p_args->>'ciudad', ''),
           NULLIF(p_args->>'sector', ''),
           NULLIF(p_args->>'necesita', ''));
$$;

CREATE OR REPLACE FUNCTION h_val_dejar_datos(p_args jsonb)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN NULLIF(trim(COALESCE(p_args->>'negocio', '')), '') IS NULL
              THEN 'Falta el nombre del negocio. Pregúntaselo antes.'
              ELSE NULL END;
$$;

CREATE OR REPLACE FUNCTION h_res_dejar_datos(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT 'Guardo tus datos para escribirte:' || E'\n\n'
      || '🏢 ' || esc(p_args->>'negocio')
      || CASE WHEN NULLIF(p_args->>'sitio', '') IS NOT NULL
              THEN E'\n' || '🌐 ' || esc(p_args->>'sitio') ELSE '' END
      || CASE WHEN NULLIF(p_args->>'necesita', '') IS NOT NULL
              THEN E'\n' || '📝 ' || esc(p_args->>'necesita') ELSE '' END
      || E'\n\n' || 'Los usamos solo para contactarte por este tema.';
$$;


-- =====================================================================
-- 2. Herramientas internas — el asistente propio de la agencia
-- =====================================================================

CREATE OR REPLACE FUNCTION h_listar_prospectos(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('prospectos',
    listar_prospectos(NULLIF(p_args->>'estado', ''),
                      NULLIF(p_args->>'peldano', '')::int));
$$;

CREATE OR REPLACE FUNCTION h_estado_prospecto(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_id uuid := prospecto_por_nombre(p_args->>'nombre');
BEGIN
  IF v_id IS NULL THEN
    RETURN jsonb_build_object('ok', false,
      'error', 'No hay ningún prospecto con ese nombre. Mira la lista con listar_prospectos.');
  END IF;
  RETURN jsonb_build_object('ok', true, 'datos', prospecto_ficha(v_id));
END;
$$;

CREATE OR REPLACE FUNCTION h_proximas_acciones(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT proximas_acciones(COALESCE(NULLIF(p_args->>'dias', '')::int, 7));
$$;

CREATE OR REPLACE FUNCTION h_resultado_auditoria(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT resultado_auditoria(COALESCE(p_args->>'sitio', p_args->>'nombre', ''));
$$;

CREATE OR REPLACE FUNCTION h_esc_registrar_contacto(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT registrar_contacto(
           prospecto_por_nombre(p_args->>'prospecto'),
           COALESCE(NULLIF(p_args->>'tipo', ''), 'otro'),
           p_args->>'resumen',
           NULLIF(p_args->>'resultado', ''),
           actor_usuario(p_contacto_id),
           NULLIF(p_args->>'nuevo_estado', ''));
$$;

CREATE OR REPLACE FUNCTION h_val_prospecto(p_args jsonb)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN prospecto_por_nombre(p_args->>'prospecto') IS NULL
      THEN 'No hay ningún prospecto con ese nombre. Búscalo con listar_prospectos y usa el nombre tal como aparezca.'
    ELSE NULL END;
$$;

CREATE OR REPLACE FUNCTION h_res_registrar_contacto(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT 'Registro el contacto:' || E'\n\n'
      || '🏢 ' || esc((SELECT nombre FROM prospecto
                        WHERE id = prospecto_por_nombre(p_args->>'prospecto'))) || E'\n'
      || '📞 ' || esc(COALESCE(NULLIF(p_args->>'tipo', ''), 'otro')) || E'\n'
      || '📝 ' || esc(p_args->>'resumen')
      || CASE WHEN NULLIF(p_args->>'nuevo_estado', '') IS NOT NULL
              THEN E'\n' || '➡️ pasa a: ' || esc(p_args->>'nuevo_estado') ELSE '' END;
$$;

CREATE OR REPLACE FUNCTION h_esc_agendar_seguimiento(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT agendar_seguimiento(
           prospecto_por_nombre(p_args->>'prospecto'),
           p_args->>'que',
           (p_args->>'para_fecha')::date,
           NULLIF(p_args->>'excusa', ''),
           actor_usuario(p_contacto_id));
$$;

CREATE OR REPLACE FUNCTION h_val_agendar_seguimiento(p_args jsonb)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF prospecto_por_nombre(p_args->>'prospecto') IS NULL THEN
    RETURN 'No hay ningún prospecto con ese nombre. Búscalo con listar_prospectos.';
  END IF;
  IF NULLIF(p_args->>'para_fecha', '') IS NULL THEN
    RETURN 'Falta la fecha. Pregúntale para cuándo, o propón una tú.';
  END IF;
  IF NULLIF(trim(COALESCE(p_args->>'que', '')), '') IS NULL THEN
    RETURN 'Falta qué hay que hacer. «Escribirle» no sirve: qué se le dice y con qué excusa.';
  END IF;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION h_res_agendar_seguimiento(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT 'Agendo el seguimiento:' || E'\n\n'
      || '🏢 ' || esc((SELECT nombre FROM prospecto
                        WHERE id = prospecto_por_nombre(p_args->>'prospecto'))) || E'\n'
      || '📅 ' || fecha_es(((p_args->>'para_fecha')::date)::timestamptz) || E'\n'
      || '✅ ' || esc(p_args->>'que')
      || CASE WHEN NULLIF(p_args->>'excusa', '') IS NOT NULL
              THEN E'\n' || '💡 con qué excusa: ' || esc(p_args->>'excusa') ELSE '' END;
$$;

CREATE OR REPLACE FUNCTION h_esc_cerrar_seguimiento(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT cerrar_seguimiento((p_args->>'seguimiento_id')::bigint,
                            actor_usuario(p_contacto_id));
$$;

CREATE OR REPLACE FUNCTION h_res_cerrar_seguimiento(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT 'Marco como hecho: ' || esc(COALESCE(
           (SELECT s.que || ' (' || p.nombre || ')'
              FROM seguimiento s JOIN prospecto p ON p.id = s.prospecto_id
             WHERE s.id = (p_args->>'seguimiento_id')::bigint),
           'ese seguimiento'));
$$;


-- =====================================================================
-- 3. El catálogo
--
-- Lo que el modelo ve. La descripción es la documentación de la herramienta
-- y es lo único que le dice cuándo usarla: se escribe con el mismo cuidado
-- que el prompt, y en imperativo.
-- =====================================================================

INSERT INTO ia_herramienta
  (nombre, audiencia, permiso, escribe, critica, orden,
   fn_leer, fn_escribir, fn_resumen, fn_validar, descripcion, esquema) VALUES

-- --- Públicas ---------------------------------------------------------
('listar_servicios', 'publica', NULL, false, false, 10,
 'h_listar_servicios', NULL, NULL, NULL,
 'Lo que hacemos, por etapas, con qué es cada una y cuánto vale. Úsala cuando '
 'pregunten qué hacen, si hacen tal cosa, o cuando no sepas con qué código '
 'cotizar. Sin texto devuelve todo; con texto filtra (por ejemplo "asistente", '
 '"seo", "portal"). Los códigos que devuelve son los que necesita '
 'cotizar_servicio.',
 '{"type":"object","properties":{"texto":{"type":"string","description":"Palabra para filtrar. Omitir para ver todo."}}}'::jsonb),

('cotizar_servicio', 'publica', NULL, false, false, 20,
 'h_cotizar_servicio', NULL, NULL, NULL,
 'El precio de un servicio, con qué incluye y cuánto dura. SIEMPRE úsala antes '
 'de decir una cifra: los valores están en el sistema y tu memoria no es una '
 'fuente. Nunca los inventes, redondees ni promedies. Devuelve el campo '
 '"como_decirlo": obedécelo tal cual.',
 '{"type":"object","properties":{"codigo":{"type":"string","description":"Código del servicio, de listar_servicios"}},"required":["codigo"]}'::jsonb),

('informacion_empresa', 'publica', NULL, false, false, 30,
 'h_informacion_empresa', NULL, NULL, NULL,
 'Datos de la agencia: qué hacemos, dónde estamos, cómo contactarnos, horario '
 'y política de datos. Úsala cuando pregunten quiénes somos, dónde quedamos o '
 'cómo los contactan por fuera del chat.',
 '{"type":"object","properties":{}}'::jsonb),

('horarios_reunion', 'publica', NULL, false, false, 40,
 'h_horarios_reunion', NULL, NULL, NULL,
 'Las horas libres de verdad para una reunión. SIEMPRE úsala antes de proponer '
 'un día o una hora: la agenda está en la base y tú no la tienes. Nunca digas '
 '"tenemos disponible el jueves" sin haberla llamado. Si piden un día concreto, '
 'mándalo en fecha; si dicen "esta semana" o no dicen nada, omítela. Ofrece DOS '
 'o TRES de las que devuelva, no la lista entera.',
 '{"type":"object","properties":{"codigo":{"type":"string","description":"Tipo de reunión. Omitir para la de diagnóstico, que es la normal."},"fecha":{"type":"string","description":"Día desde el que buscar, AAAA-MM-DD. Omitir para desde hoy."},"dias":{"type":"integer","description":"Cuántos días mirar. Por defecto 7."}}}'::jsonb),

('mis_reuniones', 'publica', NULL, false, false, 50,
 'h_mis_reuniones', NULL, NULL, NULL,
 'Las reuniones que ya tiene quien te escribe, con su hora y su enlace. Úsala '
 'cuando pregunten "¿a qué hora era?" o antes de mover o cancelar algo, para '
 'saber de cuál hablan.',
 '{"type":"object","properties":{"incluir_pasadas":{"type":"boolean","description":"true para ver también las viejas. Por defecto false."}}}'::jsonb),

('agendar_reunion', 'publica', NULL, true, true, 60,
 NULL, 'h_esc_agendar_reunion', 'h_res_agendar_reunion', 'h_val_agendar_reunion',
 'Agenda la reunión. Llámala cuando la persona ya escogió una hora concreta de '
 'las que le ofreciste. La hora va en inicia_at, copiada EXACTA del campo '
 '"inicia_at" que devolvió horarios_reunion: no la escribas de memoria ni la '
 'conviertas. Necesitas su nombre; el del negocio y el correo pídelos con '
 'naturalidad, no como formulario. No queda agendada al llamarla: a la persona '
 'le sale un botón de confirmar. No digas "ya quedó" hasta que lo toque.',
 '{"type":"object","properties":{"inicia_at":{"type":"string","description":"Hora exacta tal como la devolvió horarios_reunion"},"con_quien":{"type":"string","description":"Nombre de la persona"},"negocio":{"type":"string","description":"Nombre del negocio o empresa"},"correo":{"type":"string"},"celular":{"type":"string"},"motivo":{"type":"string","description":"Qué quiere resolver, en sus palabras"},"codigo":{"type":"string","description":"Tipo de reunión. Omitir para la normal."}},"required":["inicia_at","con_quien"]}'::jsonb),

('cancelar_reunion', 'publica', NULL, true, true, 70,
 NULL, 'h_esc_cancelar_reunion', 'h_res_cancelar_reunion', 'h_val_reunion_existente',
 'Cancela una reunión que ya existe. Necesita el reunion_id, que sale de '
 'mis_reuniones: nunca lo inventes. Antes de cancelar, ofrece moverla.',
 '{"type":"object","properties":{"reunion_id":{"type":"string","description":"Identificador, de mis_reuniones"},"motivo":{"type":"string","description":"Lo que dijo la persona"}},"required":["reunion_id"]}'::jsonb),

('reagendar_reunion', 'publica', NULL, true, true, 80,
 NULL, 'h_esc_reagendar_reunion', 'h_res_reagendar_reunion', 'h_val_reunion_existente',
 'Mueve una reunión a otra hora. Necesita el reunion_id de mis_reuniones y una '
 'hora nueva sacada de horarios_reunion.',
 '{"type":"object","properties":{"reunion_id":{"type":"string","description":"Identificador, de mis_reuniones"},"inicia_at":{"type":"string","description":"Hora nueva, copiada de horarios_reunion"}},"required":["reunion_id","inicia_at"]}'::jsonb),

('dejar_datos', 'publica', NULL, true, false, 90,
 NULL, 'h_esc_dejar_datos', 'h_res_dejar_datos', 'h_val_dejar_datos',
 'Guarda los datos de quien escribe para que el equipo lo contacte. Úsala '
 'cuando haya interés pero no quieran comprometerse a una hora todavía, o '
 'cuando pidan que les escriban después. Necesitas el nombre del negocio; el '
 'sitio web y qué necesita, si los da. No la uses para agendar: para eso está '
 'agendar_reunion.',
 '{"type":"object","properties":{"negocio":{"type":"string","description":"Nombre del negocio"},"sitio":{"type":"string","description":"Su página web, si la tiene"},"ciudad":{"type":"string"},"sector":{"type":"string","description":"A qué se dedica"},"necesita":{"type":"string","description":"Qué quiere resolver, en sus palabras"}},"required":["negocio"]}'::jsonb),

-- --- Internas ---------------------------------------------------------
('listar_prospectos', 'interna', 'prospectos.ver', false, false, 110,
 'h_listar_prospectos', NULL, NULL, NULL,
 'El pipeline: quién está en cada estado, en qué peldaño y cuántos '
 'seguimientos pendientes tiene. Sin filtros trae todo menos los descartados.',
 '{"type":"object","properties":{"estado":{"type":"string","description":"nuevo, calificando, calificado, contactado, reunion, propuesta, ganado, perdido o descartado"},"peldano":{"type":"integer","description":"1, 2 o 3"}}}'::jsonb),

('estado_prospecto', 'interna', 'prospectos.ver', false, false, 120,
 'h_estado_prospecto', NULL, NULL, NULL,
 'La ficha completa de un prospecto: estado, contacto, prueba de WhatsApp, '
 'últimas conversaciones, seguimientos pendientes, propuestas y la última '
 'auditoría de su sitio. Úsala cuando pregunten "¿cómo va X?" o antes de '
 'registrar algo, para no repetir lo que ya está.',
 '{"type":"object","properties":{"nombre":{"type":"string","description":"Nombre del prospecto, aunque sea parcial"}},"required":["nombre"]}'::jsonb),

('proximas_acciones', 'interna', 'prospectos.ver', false, false, 130,
 'h_proximas_acciones', NULL, NULL, NULL,
 'Qué hay que hacer: los seguimientos vencidos y los de los próximos días, más '
 'los prospectos que llevan dos semanas o más sin que nadie los toque. Úsala '
 'cuando pregunten qué toca hoy, qué está pendiente o con quién hay que hablar. '
 'Responde con lo vencido primero y no recites la lista entera: di cuántos hay '
 'y nombra los tres más urgentes.',
 '{"type":"object","properties":{"dias":{"type":"integer","description":"Horizonte en días. Por defecto 7."}}}'::jsonb),

('resultado_auditoria', 'interna', 'auditorias.ver', false, false, 140,
 'h_resultado_auditoria', NULL, NULL, NULL,
 'La última auditoría técnica guardada de un sitio, con sus hallazgos y, si '
 'hay, la corrida anterior para comparar. Úsala cuando pregunten cómo está el '
 'sitio de alguien o si mejoró.',
 '{"type":"object","properties":{"sitio":{"type":"string","description":"URL o parte de ella"},"nombre":{"type":"string","description":"Nombre del prospecto, si no sabes la URL"}}}'::jsonb),

('registrar_contacto', 'interna', 'prospectos.gestionar', true, false, 150,
 NULL, 'h_esc_registrar_contacto', 'h_res_registrar_contacto', 'h_val_prospecto',
 'Deja anotado que se habló con un prospecto: por dónde, qué se dijo y en qué '
 'quedó. Si la conversación movió el negocio, manda también nuevo_estado. Sale '
 'con botón de confirmar.',
 '{"type":"object","properties":{"prospecto":{"type":"string","description":"Nombre del prospecto"},"tipo":{"type":"string","description":"llamada, whatsapp, correo, reunion, chat, visita u otro"},"resumen":{"type":"string","description":"Qué se habló, en dos líneas"},"resultado":{"type":"string","description":"En qué quedó"},"nuevo_estado":{"type":"string","description":"Solo si el estado cambió"}},"required":["prospecto","resumen"]}'::jsonb),

('agendar_seguimiento', 'interna', 'prospectos.gestionar', true, false, 160,
 NULL, 'h_esc_agendar_seguimiento', 'h_res_agendar_seguimiento', 'h_val_agendar_seguimiento',
 'Deja pendiente volver a hablarle a alguien, con fecha. Es lo que hoy se '
 'olvida, así que ofrécelo tú cuando una conversación quede en el aire. Pide '
 'la excusa concreta —un dato nuevo, no un "¿ya lo viste?"— porque un '
 'seguimiento sin excusa no se hace. Sale con botón de confirmar.',
 '{"type":"object","properties":{"prospecto":{"type":"string","description":"Nombre del prospecto"},"que":{"type":"string","description":"Qué hay que hacer, concreto"},"para_fecha":{"type":"string","description":"Fecha AAAA-MM-DD"},"excusa":{"type":"string","description":"Con qué se le vuelve a escribir"}},"required":["prospecto","que","para_fecha"]}'::jsonb),

('cerrar_seguimiento', 'interna', 'prospectos.gestionar', true, false, 170,
 NULL, 'h_esc_cerrar_seguimiento', 'h_res_cerrar_seguimiento', NULL,
 'Marca un seguimiento como hecho. El seguimiento_id sale de '
 'proximas_acciones o de estado_prospecto.',
 '{"type":"object","properties":{"seguimiento_id":{"type":"integer","description":"Identificador del seguimiento"}},"required":["seguimiento_id"]}'::jsonb)

ON CONFLICT (nombre) DO UPDATE
  SET audiencia = EXCLUDED.audiencia, permiso = EXCLUDED.permiso,
      escribe = EXCLUDED.escribe, critica = EXCLUDED.critica,
      fn_leer = EXCLUDED.fn_leer, fn_escribir = EXCLUDED.fn_escribir,
      fn_resumen = EXCLUDED.fn_resumen, fn_validar = EXCLUDED.fn_validar,
      descripcion = EXCLUDED.descripcion, esquema = EXCLUDED.esquema,
      orden = EXCLUDED.orden;


-- =====================================================================
-- 4. Las fuentes de contexto
--
-- Lo que va en el prompt de cada turno sin que el modelo tenga que acordarse
-- de pedirlo. La regla para decidir qué va aquí y qué va en una herramienta:
-- **si hay que acordarse de llamarla, algún día no se llama.** Todo lo que
-- delata a una máquina cuando falta —preguntar dos veces lo mismo, no saber
-- que la reunión ya se agendó— va aquí.
--
-- Cada fuente redacta su propia línea, incluida la del caso vacío. Un dato
-- ausente se declara ausente: callarlo deja un hueco, y el modelo rellena
-- los huecos.
-- =====================================================================

CREATE OR REPLACE FUNCTION f_ctx_reuniones(p_contacto_id uuid, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v jsonb := reuniones_del_contacto(p_contacto_id, false);
BEGIN
  IF jsonb_array_length(v) = 0 THEN
    RETURN jsonb_build_object('valor', v, 'linea', '- No tiene ninguna reunión agendada.');
  END IF;

  RETURN jsonb_build_object('valor', v, 'linea',
    '- Reuniones ya agendadas: ' ||
    (SELECT string_agg((r->>'que') || ', ' || (r->>'cuando')
                       || ' (reunion_id ' || (r->>'reunion_id') || ')', ' | ')
       FROM jsonb_array_elements(v) r) ||
    '. Están confirmadas: si pregunta, existen.');
END;
$$;

-- Quién es, si ya lo conocemos. Un prospecto al que le volvemos a preguntar
-- el nombre de su negocio en cada conversación sabe perfectamente que está
-- hablando con una máquina.
CREATE OR REPLACE FUNCTION f_ctx_prospecto(p_contacto_id uuid, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE p prospecto%ROWTYPE;
BEGIN
  SELECT * INTO p FROM prospecto WHERE contacto_id = p_contacto_id
   ORDER BY updated_at DESC LIMIT 1;

  IF p.id IS NULL THEN RETURN NULL; END IF;

  RETURN jsonb_build_object(
    'valor', jsonb_build_object('nombre', p.nombre, 'estado', p.estado),
    'linea', '- Ya sabes que escribe por ' || p.nombre
             || COALESCE(', en ' || p.ciudad, '')
             || '. No vuelvas a preguntar el nombre del negocio.');
END;
$$;

-- --- Solo para el equipo ---------------------------------------------

CREATE OR REPLACE FUNCTION f_ctx_agenda_hoy(p_contacto_id uuid, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'que', t.nombre, 'con', r.con_quien, 'negocio', r.negocio,
           'cuando', hora_es(r.inicia_at)) ORDER BY r.inicia_at), '[]'::jsonb)
    INTO v
    FROM reunion r JOIN tipo_reunion t ON t.codigo = r.tipo_codigo
   WHERE r.estado IN ('agendada', 'confirmada')
     AND (r.inicia_at AT TIME ZONE 'America/Bogota')::date = hoy_bogota();

  IF jsonb_array_length(v) = 0 THEN
    RETURN jsonb_build_object('valor', v, 'linea', '- Hoy no hay reuniones agendadas.');
  END IF;

  RETURN jsonb_build_object('valor', v, 'linea',
    '- Reuniones de hoy: ' ||
    (SELECT string_agg((x->>'cuando') || ' ' || (x->>'que') || ' con ' || (x->>'con')
                       || COALESCE(' (' || (x->>'negocio') || ')', ''), '; ')
       FROM jsonb_array_elements(v) x) || '.');
END;
$$;

CREATE OR REPLACE FUNCTION f_ctx_pipeline(p_contacto_id uuid, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_vencidos int;
  v_hoy      int;
  v_activos  int;
BEGIN
  SELECT count(*) FILTER (WHERE para_fecha <  hoy_bogota()),
         count(*) FILTER (WHERE para_fecha =  hoy_bogota())
    INTO v_vencidos, v_hoy
    FROM seguimiento WHERE NOT hecho;

  SELECT count(*) INTO v_activos FROM prospecto
   WHERE estado IN ('calificado', 'contactado', 'reunion', 'propuesta');

  RETURN jsonb_build_object(
    'valor', jsonb_build_object('vencidos', v_vencidos, 'hoy', v_hoy, 'activos', v_activos),
    'linea', '- Pipeline: ' || v_activos || ' prospectos activos, '
             || v_hoy || ' seguimientos para hoy y ' || v_vencidos || ' vencidos.'
             || CASE WHEN v_vencidos > 0
                     THEN ' Los vencidos son lo primero que hay que mencionar.'
                     ELSE '' END);
END;
$$;

INSERT INTO ia_contexto_fuente (clave, fn, orden, solo_personal, descripcion) VALUES
  ('reuniones', 'f_ctx_reuniones',  10, false,
   'Las reuniones ya agendadas de quien escribe'),
  ('prospecto', 'f_ctx_prospecto',  20, false,
   'El negocio de quien escribe, si ya está en el pipeline'),
  ('agenda_hoy','f_ctx_agenda_hoy', 30, true,
   'Las reuniones de hoy, para el equipo'),
  ('pipeline',  'f_ctx_pipeline',   40, true,
   'Cuántos seguimientos hay pendientes y cuántos vencidos')
ON CONFLICT (clave) DO UPDATE
  SET fn = EXCLUDED.fn, orden = EXCLUDED.orden,
      solo_personal = EXCLUDED.solo_personal, descripcion = EXCLUDED.descripcion;
