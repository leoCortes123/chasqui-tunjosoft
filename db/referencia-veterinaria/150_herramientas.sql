-- =====================================================================
-- Chasqui TunjoSoft — 150_herramientas.sql
-- El catálogo de herramientas del dominio.
--
-- Llena el `CASE` que el núcleo (040) dejó vacío. Cada herramienta llama a
-- las MISMAS funciones que usarían un botón o el portal: el asistente no
-- tiene una vía privilegiada a la base, tiene una lista cerrada.
--
-- ⚠️ Este archivo REEMPLAZA `ia_leer`, que `130_triaje.sql` ya había
-- reemplazado para agregar `pedir_asesor`. Esa rama se conserva aquí. Si se
-- pierde, el asistente se queda sin su tercera reja para escalar y nada
-- falla en voz alta — que es la peor forma de romper algo.
-- =====================================================================

SET client_min_messages = warning;

INSERT INTO ia_herramienta (nombre, audiencia, permiso, escribe, critica, orden, descripcion, esquema) VALUES

('listar_estudios', 'publica', NULL, false, false, 10,
 'Los estudios y servicios que hacemos, con qué es cada uno y cuánto dura. '
 'Úsala cuando pregunten qué hacen, si hacen tal estudio, o cuando no sepas '
 'con qué código cotizar. Sin texto devuelve el catálogo completo; con texto '
 'busca (por ejemplo "ecografia", "corazon", "tac"). Los códigos que devuelve '
 'son los que necesita cotizar_estudio.',
 '{"type":"object","properties":{"texto":{"type":"string","description":"Palabra para filtrar. Omitir para ver todo."}}}'::jsonb),

('cotizar_estudio', 'publica', NULL, false, false, 20,
 'El precio de un estudio para una fecha, con su preparación. SIEMPRE úsala '
 'antes de decir un precio: la tarifa cambia los domingos y festivos y el '
 'calendario de festivos colombianos está en la base, no en tu memoria. '
 'Nunca inventes ni redondees un valor. Devuelve también el campo '
 '"como_decirlo": obedécelo, dice si el precio está confirmado o es de '
 'referencia. Si no te dan fecha, cotiza para hoy.',
 '{"type":"object","properties":{"codigo":{"type":"string","description":"Código del estudio, de listar_estudios"},"fecha":{"type":"string","description":"Fecha AAAA-MM-DD. Omitir para hoy."}},"required":["codigo"]}'::jsonb),

('informacion_clinica', 'publica', NULL, false, false, 30,
 'Datos de la clínica: dirección, teléfonos, horarios, servicios y equipo '
 'médico. Úsala cuando pregunten dónde quedan, cómo llegar, a qué hora '
 'atienden, si abren domingos o quién los atiende. Trae el enlace de mapa.',
 '{"type":"object","properties":{}}'::jsonb),

('preparacion_estudio', 'publica', NULL, false, false, 40,
 'Cómo hay que preparar al paciente para un estudio: ayuno, sedación, qué '
 'traer. Úsala cuando pregunten «¿tiene que venir en ayunas?» o cuando ya '
 'quedó una cita y quieras recordárselo.',
 '{"type":"object","properties":{"codigo":{"type":"string","description":"Código del estudio"}},"required":["codigo"]}'::jsonb),

('horarios_disponibles', 'publica', NULL, false, false, 50,
 'Las horas libres de verdad para un estudio. SIEMPRE úsala antes de '
 'proponer un día o una hora: la agenda está en la base y tú no la tienes. '
 'Nunca digas «tenemos disponible el jueves» sin haberla llamado. Si te '
 'piden un día concreto, manda ese día en fecha; si dicen «esta semana» o no '
 'dicen nada, omítela. Devuelve cada hora con su texto en "cuando": ofrece '
 'DOS o TRES, no la lista entera.',
 '{"type":"object","properties":{"codigo":{"type":"string","description":"Código del estudio, de listar_estudios"},"fecha":{"type":"string","description":"Día desde el que buscar, AAAA-MM-DD. Omitir para desde hoy."},"dias":{"type":"integer","description":"Cuántos días mirar. Por defecto 7."}},"required":["codigo"]}'::jsonb),

('mis_citas', 'publica', NULL, false, false, 60,
 'Las citas que ya tiene quien te está escribiendo, con su paciente, su hora '
 'y su ayuno. Úsala cuando pregunten «¿a qué hora era mi cita?», «¿tengo '
 'algo agendado?», o antes de cancelar o mover algo, para saber de qué cita '
 'hablan.',
 '{"type":"object","properties":{"incluir_pasadas":{"type":"boolean","description":"true para ver también las citas viejas. Por defecto false."}}}'::jsonb),

-- --- Escritura: el modelo propone, la persona toca el botón --------------
('agendar_cita', 'publica', NULL, true, true, 70,
 'Agenda la cita. Llámala cuando la persona ya eligió una hora concreta de '
 'las que le ofreciste. La hora va en inicia_at, copiada EXACTA del campo '
 '"inicia_at" que devolvió horarios_disponibles: no la escribas de memoria '
 'ni la conviertas. Necesitas el nombre del paciente; si no lo sabes, '
 'pregúntalo antes en la conversación, con naturalidad, no como formulario. '
 'No queda agendada al llamarla: le sale un botón de confirmar a la persona. '
 'No digas «ya quedó» hasta que confirme.',
 '{"type":"object","properties":{"codigo":{"type":"string","description":"Código del estudio"},"inicia_at":{"type":"string","description":"Hora exacta tal como la devolvió horarios_disponibles"},"paciente":{"type":"string","description":"Nombre de la mascota"},"tutor":{"type":"string","description":"Nombre de la persona. Omitir si ya lo sabes por el contexto."},"especie":{"type":"string","description":"perro, gato, silvestre u otro"},"raza":{"type":"string"},"edad":{"type":"number","description":"Años, aproximada"},"motivo":{"type":"string","description":"Por qué le mandaron el estudio, o quién lo remite"}},"required":["codigo","inicia_at","paciente"]}'::jsonb),

('cancelar_cita', 'publica', NULL, true, true, 80,
 'Cancela una cita que ya existe. Necesita el cita_id, que sale de '
 'mis_citas: nunca lo inventes. También sale con botón de confirmar. Antes '
 'de cancelar, ofrece moverla a otra hora: un cupo que se libera y nadie '
 'ocupa lo pierden los dos.',
 '{"type":"object","properties":{"cita_id":{"type":"string","description":"Identificador de la cita, de mis_citas"},"motivo":{"type":"string","description":"Lo que dijo la persona"}},"required":["cita_id"]}'::jsonb),

('reagendar_cita', 'publica', NULL, true, true, 90,
 'Mueve una cita existente a otra hora. Necesita el cita_id de mis_citas y '
 'una hora nueva sacada de horarios_disponibles. Sale con botón de '
 'confirmar.',
 '{"type":"object","properties":{"cita_id":{"type":"string","description":"Identificador de la cita, de mis_citas"},"inicia_at":{"type":"string","description":"Hora nueva, copiada de horarios_disponibles"}},"required":["cita_id","inicia_at"]}'::jsonb)

ON CONFLICT (nombre) DO UPDATE
  SET audiencia = EXCLUDED.audiencia, permiso = EXCLUDED.permiso,
      escribe = EXCLUDED.escribe, critica = EXCLUDED.critica,
      descripcion = EXCLUDED.descripcion, esquema = EXCLUDED.esquema,
      orden = EXCLUDED.orden;

-- ---------------------------------------------------------------------
-- Ejecución de las herramientas de lectura
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_leer(
  p_contacto_id uuid, p_sede_id uuid, p_nombre text, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v      jsonb;
  v_conv uuid;
BEGIN
  CASE p_nombre

    -- Viene de 130_triaje.sql. No se toca: es la última reja del triaje.
    WHEN 'pedir_asesor' THEN
      SELECT id INTO v_conv
        FROM conversacion
       WHERE contacto_id = p_contacto_id AND estado = 'abierta'
       ORDER BY ultima_actividad_at DESC
       LIMIT 1;

      IF v_conv IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'No hay una conversación abierta.');
      END IF;

      PERFORM escalar_a_humano(
        v_conv,
        COALESCE(NULLIF(trim(p_args->>'motivo'), ''), 'el asistente pidió ayuda'));

      RETURN jsonb_build_object('ok', true, 'datos', jsonb_build_object(
        'escalada', true,
        'nota', 'Ya se le avisó a una persona. Dile en una sola frase que ya '
                'avisaste y que le escriben por este chat. No preguntes nada más.'));

    WHEN 'listar_estudios' THEN
      v := listar_estudios(NULLIF(p_args->>'texto', ''));

    WHEN 'cotizar_estudio' THEN
      v := cotizar_estudio(p_args->>'codigo', NULLIF(p_args->>'fecha', '')::date);

    WHEN 'horarios_disponibles' THEN
      v := horarios_disponibles(
             p_args->>'codigo',
             NULLIF(p_args->>'fecha', '')::date,
             COALESCE(NULLIF(p_args->>'dias', '')::int, 7));

    WHEN 'mis_citas' THEN
      v := jsonb_build_object(
             'citas', citas_del_contacto(
                        p_contacto_id,
                        COALESCE((p_args->>'incluir_pasadas')::boolean, false)),
             'pacientes', pacientes_del_contacto(p_contacto_id));

    WHEN 'preparacion_estudio' THEN
      SELECT jsonb_build_object(
               'estudio', e.nombre,
               'preparacion', p.texto,
               'ayuno_horas', p.ayuno_horas,
               'duracion_min', e.duracion_min)
        INTO v
        FROM estudio e LEFT JOIN preparacion p ON p.estudio_id = e.id
       WHERE e.codigo = p_args->>'codigo' AND e.activo;

      IF v IS NULL THEN
        RETURN jsonb_build_object('ok', false,
          'error', 'No existe ese estudio. Usa listar_estudios.');
      END IF;

    WHEN 'informacion_clinica' THEN
      v := jsonb_build_object(
        'clinica',   config_txt('nombre_clinica', 'la clínica'),
        'direccion', config_txt('clinica_direccion', ''),
        'mapa',      config_txt('clinica_mapa_url', ''),
        'horario',   config_txt('clinica_horario', ''),
        'telefonos', jsonb_build_object(
          'principal',           config_txt('clinica_telefono_principal', ''),
          'alterno',             config_txt('clinica_telefono_alterno', ''),
          'whatsapp_imagenes',   config_txt('clinica_whatsapp_imagenes', ''),
          'whatsapp_consulta',   config_txt('clinica_whatsapp_consulta', ''),
          'whatsapp_hospital',   config_txt('clinica_whatsapp_hospital', '')),
        'correo_informes', config_txt('clinica_correo_imagenes', ''),
        'modalidades', (SELECT COALESCE(jsonb_agg(DISTINCT modalidad), '[]'::jsonb)
                          FROM estudio WHERE activo),
        'sobre_el_negocio', NULLIF(config_txt('ia_sobre_el_negocio', ''), ''));

    ELSE
      RETURN jsonb_build_object('ok', false,
        'error', format('La herramienta %s no existe.', p_nombre));
  END CASE;

  RETURN jsonb_build_object('ok', true, 'datos', COALESCE(v, 'null'::jsonb));
END;
$$;


-- ---------------------------------------------------------------------
-- Qué se revisa antes de armar la tarjeta
--
-- El modelo escribe los argumentos, y los códigos de estudio son justo el
-- tipo de dato que rellena de memoria: pidió `ECO-ABD` cuando el catálogo
-- dice `eco_abdominal`. Con el código malo, `agendar_cita` habría fallado
-- —lo valida— pero recién al confirmar, y la tarjeta ya se habría mostrado
-- con el estudio en blanco y $0.
--
-- Se revisa la existencia y poco más: la hora libre, el horario del equipo y
-- los bloqueos se miran al confirmar, porque cambian mientras la persona lee.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_validar_accion(p_nombre text, p_args jsonb)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_codigo text := p_args->>'codigo';
  v_cita   text := p_args->>'cita_id';
BEGIN
  -- El `::uuid` de más abajo se traga un identificador de verdad y revienta
  -- con cualquier otra cosa. El modelo manda lo que recuerda, así que aquí
  -- «no parece un uuid» y «no existe» son el mismo caso y la misma respuesta.
  IF p_nombre IN ('cancelar_cita', 'reagendar_cita')
     AND COALESCE(v_cita, '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RETURN 'Esa cita no existe. Mira cuáles tiene con mis_citas y usa el identificador que devuelva.';
  END IF;

  CASE p_nombre

    WHEN 'agendar_cita' THEN
      IF NULLIF(trim(COALESCE(p_args->>'paciente', '')), '') IS NULL THEN
        RETURN 'Falta el nombre del paciente. Pregúntaselo antes de proponer la cita.';
      END IF;

      IF p_args->>'inicia_at' IS NULL THEN
        RETURN 'Falta la fecha y hora. Ofrécele horarios con horarios_disponibles.';
      END IF;

      IF NOT EXISTS (SELECT 1 FROM estudio WHERE codigo = v_codigo AND activo) THEN
        RETURN format(
          'No existe el estudio «%s». Los códigos salen de listar_estudios, no te '
          'los inventes: llámala, escoge el que corresponda y vuelve a proponer.',
          COALESCE(v_codigo, '(vacío)'));
      END IF;

      RETURN NULL;

    WHEN 'cancelar_cita' THEN
      IF NOT EXISTS (SELECT 1 FROM cita WHERE id = (p_args->>'cita_id')::uuid) THEN
        RETURN 'Esa cita no existe. Mira cuáles tiene con mis_citas.';
      END IF;
      RETURN NULL;

    WHEN 'reagendar_cita' THEN
      IF NOT EXISTS (SELECT 1 FROM cita WHERE id = (p_args->>'cita_id')::uuid) THEN
        RETURN 'Esa cita no existe. Mira cuáles tiene con mis_citas.';
      END IF;
      IF p_args->>'inicia_at' IS NULL THEN
        RETURN 'Falta la hora nueva. Ofrécele horarios con horarios_disponibles.';
      END IF;
      RETURN NULL;

    ELSE
      RETURN NULL;
  END CASE;
END;
$$;


-- ---------------------------------------------------------------------
-- La tarjeta de confirmación
--
-- Se arma aquí, en SQL, con los datos frescos de la base. El modelo no la
-- redacta ni la ve: si él escribiera la tarjeta, un día diría «$150.000» en
-- una cita de $172.000 y la persona confirmaría eso.
--
-- Va con `esc()` porque el canal la manda con `parse_mode: HTML` y un
-- paciente que se llame «Tom & Jerry» no puede romper el mensaje.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_resumen_accion(
  p_contacto_id uuid, p_sede_id uuid, p_nombre text, p_args jsonb)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
  e        estudio%ROWTYPE;
  c        cita%ROWTYPE;
  v_at     timestamptz;
  v_tarifa jsonb;
  v_horas  int;
  v        text;
BEGIN
  CASE p_nombre

    WHEN 'agendar_cita' THEN
      SELECT * INTO e FROM estudio WHERE codigo = p_args->>'codigo';
      v_at := (p_args->>'inicia_at')::timestamptz;
      v_tarifa := cotizar_estudio(p_args->>'codigo',
                                  (v_at AT TIME ZONE 'America/Bogota')::date);
      SELECT ayuno_horas INTO v_horas FROM preparacion WHERE estudio_id = e.id;

      v := 'Confirmemos:' || E'\n\n'
        || '🐾 ' || esc(p_args->>'paciente') || E'\n'
        || '🔬 ' || esc(e.nombre) || E'\n'
        || '📅 ' || fecha_es(v_at) || ' a las ' || hora_es(v_at) || E'\n'
        || '💵 ' || pesos((v_tarifa->>'valor')::numeric)
        || CASE WHEN COALESCE((v_tarifa->>'precio_confirmado')::boolean, false)
                THEN '' ELSE ' (valor de referencia)' END || E'\n'
        || '📍 ' || esc(config_txt('clinica_direccion', ''));

      IF ayuno_texto(v_at, v_horas) IS NOT NULL THEN
        v := v || E'\n\n' || '⚠️ Ayuno de ' || v_horas || ' horas: '
               || ayuno_texto(v_at, v_horas) || '.';
      END IF;

      RETURN v;

    WHEN 'cancelar_cita' THEN
      SELECT * INTO c FROM cita WHERE id = (p_args->>'cita_id')::uuid;
      IF c.id IS NULL THEN RETURN 'Cancelar una cita que ya no existe.'; END IF;
      SELECT * INTO e FROM estudio WHERE id = c.estudio_id;
      RETURN 'Voy a cancelar ' || esc(e.nombre) || ' del '
          || fecha_es(c.inicia_at) || ' a las ' || hora_es(c.inicia_at) || '.';

    WHEN 'reagendar_cita' THEN
      SELECT * INTO c FROM cita WHERE id = (p_args->>'cita_id')::uuid;
      IF c.id IS NULL THEN RETURN 'Mover una cita que ya no existe.'; END IF;
      SELECT * INTO e FROM estudio WHERE id = c.estudio_id;
      v_at := (p_args->>'inicia_at')::timestamptz;
      RETURN 'Voy a mover ' || esc(e.nombre) || E'\n'
          || 'de: ' || fecha_es(c.inicia_at) || ' a las ' || hora_es(c.inicia_at) || E'\n'
          || 'a: '  || fecha_es(v_at)        || ' a las ' || hora_es(v_at);

    ELSE
      RETURN 'Acción: ' || esc(p_nombre);
  END CASE;
END;
$$;


-- ---------------------------------------------------------------------
-- Ejecución de las herramientas de ESCRITURA
--
-- No la llama el modelo: la llama `ia_confirmar` después del botón. Es el
-- único camino por el que una conversación cambia algo en la base.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_escribir(
  p_contacto_id uuid, p_sede_id uuid, p_nombre text, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_conv uuid;
BEGIN
  SELECT id INTO v_conv
    FROM conversacion
   WHERE contacto_id = p_contacto_id AND estado = 'abierta'
   ORDER BY ultima_actividad_at DESC
   LIMIT 1;

  CASE p_nombre

    WHEN 'agendar_cita' THEN
      RETURN agendar_cita(
        p_contacto_id,
        p_args->>'codigo',
        (p_args->>'inicia_at')::timestamptz,
        p_args->>'paciente',
        NULLIF(p_args->>'tutor', ''),
        COALESCE(NULLIF(p_args->>'especie', ''), 'canino'),
        NULLIF(p_args->>'raza', ''),
        NULLIF(p_args->>'edad', '')::numeric,
        NULLIF(p_args->>'motivo', ''),
        v_conv);

    WHEN 'cancelar_cita' THEN
      RETURN cancelar_cita((p_args->>'cita_id')::uuid,
                           NULLIF(p_args->>'motivo', ''), 'tutor');

    WHEN 'reagendar_cita' THEN
      RETURN reagendar_cita((p_args->>'cita_id')::uuid,
                            (p_args->>'inicia_at')::timestamptz);

    ELSE
      RETURN jsonb_build_object('ok', false,
        'mensaje', format('La herramienta %s no existe.', p_nombre));
  END CASE;
END;
$$;


-- ---------------------------------------------------------------------
-- El contexto, con lo que ya sabemos de quien escribe
--
-- Un tutor conocido al que le vuelven a preguntar cómo se llama su perro en
-- cada conversación sabe perfectamente que está hablando con una máquina.
-- Por eso los pacientes y las citas van en el prompt y no en una
-- herramienta: si hay que acordarse de llamarla, algún día no se llama.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_contexto(p_contacto_id uuid, p_sede_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  a      jsonb := actor(p_contacto_id);
  v_sede record;
BEGIN
  SELECT nombre, direccion, telefono, ciudad INTO v_sede
    FROM sede
   WHERE (p_sede_id IS NULL AND activa) OR id = p_sede_id
   ORDER BY created_at
   LIMIT 1;

  RETURN jsonb_build_object(
    'clinica',        config_txt('nombre_clinica', 'la clínica'),
    'interlocutor',   COALESCE(a->>'nombre', 'alguien que escribe por primera vez'),
    'es_personal',    COALESCE((a->>'es_interno')::boolean, false),
    'roles',          COALESCE((SELECT jsonb_agg(rol_codigo)
                                  FROM usuario_rol
                                 WHERE usuario_id = actor_usuario(p_contacto_id)), '[]'::jsonb),
    'sede',           v_sede.nombre,
    'direccion',      v_sede.direccion,
    'telefono',       v_sede.telefono,
    'ciudad',         v_sede.ciudad,
    'fecha_hoy',      hoy_bogota(),
    'hora_local',     to_char(ahora_bogota(), 'HH24:MI'),
    'moneda',         'peso colombiano (COP)',
    'pacientes',      pacientes_del_contacto(p_contacto_id),
    'citas',          citas_del_contacto(p_contacto_id),
    'sobre_el_negocio', NULLIF(config_txt('ia_sobre_el_negocio', ''), ''));
END;
$$;
