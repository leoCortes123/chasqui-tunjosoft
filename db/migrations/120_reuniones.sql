-- =====================================================================
-- Chasqui TunjoSoft — 120_reuniones.sql
-- La agenda: reuniones con prospectos.
--
-- Es `120_agenda.sql` del vertical veterinario reducido a lo que aquí hace
-- falta. La mecánica es idéntica —generar horas candidatas, descartar las
-- ocupadas, y dejar que un `EXCLUDE` de la tabla sea quien decide de
-- verdad— y esa mecánica se conserva palabra por palabra donde importa.
--
-- Lo que se cayó: equipos, modalidades, preparación, ayuno, tarifa por día
-- festivo. Aquí hay una sola persona atendiendo y una reunión no cuesta.
--
-- Lo que se conserva y no es negociable:
--
--   · **El cupo lo decide la base, no la lectura.** `horarios_reunion` no
--     reserva nada. Entre que el prospecto lee las opciones y toca el botón
--     pueden pasar minutos, y en esos minutos el cupo se puede ir. El
--     `EXCLUDE` rechaza el segundo; la función devuelve un error legible y
--     el asistente ofrece otras dos horas.
--   · **La hora la copia el modelo, no la escribe.** `horarios_reunion`
--     devuelve `inicia_at` en ISO y la herramienta exige ese valor exacto.
--     Un modelo que convierte husos horarios agenda a las 3 de la mañana.
--
-- Que el prospecto agende por aquí la reunión en la que se le va a vender
-- este mismo asistente es la demostración entera. No hay que explicarla.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Qué tipos de reunión existen
-- ---------------------------------------------------------------------
CREATE TABLE tipo_reunion (
  codigo       text PRIMARY KEY,
  nombre       text NOT NULL,
  descripcion  text,
  duracion_min int NOT NULL DEFAULT 30 CHECK (duracion_min BETWEEN 15 AND 240),
  modalidad    text NOT NULL DEFAULT 'virtual'
                 CHECK (modalidad IN ('virtual', 'presencial', 'telefonica')),
  -- El enlace de la videollamada. Vacío = se manda después por el chat, y el
  -- asistente lo dice así en vez de inventarse una sala.
  enlace       text,
  orden        int NOT NULL DEFAULT 100,
  activo       boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER tipo_reunion_touch BEFORE UPDATE ON tipo_reunion
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();


-- ---------------------------------------------------------------------
-- Cuándo se puede agendar
--
-- Franjas por día de la semana, en hora de Bogotá. 0 = domingo.
-- ---------------------------------------------------------------------
CREATE TABLE franja_agenda (
  id          bigserial PRIMARY KEY,
  dia_semana  int  NOT NULL CHECK (dia_semana BETWEEN 0 AND 6),
  hora_desde  time NOT NULL,
  hora_hasta  time NOT NULL,
  activa      boolean NOT NULL DEFAULT true,
  CHECK (hora_hasta > hora_desde)
);

-- Vacaciones, viajes, el día que hay otra cosa. Un bloqueo gana siempre
-- sobre una franja.
CREATE TABLE bloqueo_agenda (
  id          bigserial PRIMARY KEY,
  desde_at    timestamptz NOT NULL,
  hasta_at    timestamptz NOT NULL,
  motivo      text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (hasta_at > desde_at)
);

CREATE INDEX idx_bloqueo_agenda_rango ON bloqueo_agenda (desde_at, hasta_at);


-- ---------------------------------------------------------------------
-- La reunión
-- ---------------------------------------------------------------------
CREATE TABLE reunion (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo_codigo     text NOT NULL REFERENCES tipo_reunion(codigo),
  contacto_id     uuid REFERENCES contacto(id) ON DELETE SET NULL,
  prospecto_id    uuid REFERENCES prospecto(id) ON DELETE SET NULL,
  conversacion_id uuid REFERENCES conversacion(id) ON DELETE SET NULL,

  inicia_at       timestamptz NOT NULL,
  termina_at      timestamptz NOT NULL,

  con_quien       text NOT NULL,     -- el nombre de la persona
  negocio         text,              -- el nombre del negocio
  correo          text,
  celular         text,
  motivo          text,

  estado          text NOT NULL DEFAULT 'agendada'
                    CHECK (estado IN ('agendada', 'confirmada', 'cumplida',
                                      'cancelada', 'no_asistio')),
  cancelada_motivo text,

  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CHECK (termina_at > inicia_at),

  -- La reja de verdad. Dos reuniones no pueden solaparse, y no importa quién
  -- llegó primero a la pantalla: importa quién llegó primero a la tabla.
  CONSTRAINT reunion_sin_choque EXCLUDE USING gist (
    tstzrange(inicia_at, termina_at) WITH &&
  ) WHERE (estado IN ('agendada', 'confirmada'))
);

CREATE INDEX idx_reunion_contacto ON reunion (contacto_id, inicia_at DESC);
CREATE INDEX idx_reunion_proximas ON reunion (inicia_at)
  WHERE estado IN ('agendada', 'confirmada');

CREATE TRIGGER reunion_touch BEFORE UPDATE ON reunion
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();


INSERT INTO config (clave, valor, tipo, descripcion, editable_ui) VALUES
  ('agenda_anticipacion_horas', '3', 'entero',
   'Cuántas horas antes, como mínimo, se puede agendar una reunión', true),
  ('agenda_horizonte_dias', '21', 'entero',
   'Hasta cuántos días adelante se ofrecen horas', true)
ON CONFLICT (clave) DO NOTHING;


-- ---------------------------------------------------------------------
-- Las horas libres
--
-- Genera las candidatas y descarta lo que choca. No reserva: es una lectura.
-- El paso es la duración del propio tipo de reunión.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION horarios_reunion(
  p_codigo text,
  p_desde  date DEFAULT NULL,
  p_dias   int  DEFAULT 7)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  t        tipo_reunion%ROWTYPE;
  v_desde  date;
  v_dias   int;
  v_minimo timestamptz;
  v_libres jsonb := '[]'::jsonb;
  d        date;
  f        record;
  v_at     timestamptz;
  v_fin    timestamptz;
BEGIN
  SELECT * INTO t FROM tipo_reunion WHERE codigo = p_codigo AND activo;
  IF t.codigo IS NULL THEN
    RETURN jsonb_build_object('ok', false,
      'error', 'No existe ese tipo de reunión. Usa listar_servicios o pregunta '
               'con naturalidad qué quiere conversar.');
  END IF;

  v_desde  := GREATEST(COALESCE(p_desde, hoy_bogota()), hoy_bogota());
  v_dias   := LEAST(GREATEST(COALESCE(p_dias, 7), 1),
                    config_int('agenda_horizonte_dias', 21));
  v_minimo := now() + make_interval(hours => config_int('agenda_anticipacion_horas', 3));

  d := v_desde;
  WHILE d <= v_desde + v_dias LOOP
    FOR f IN SELECT hora_desde, hora_hasta FROM franja_agenda
              WHERE activa AND dia_semana = EXTRACT(dow FROM d)::int
              ORDER BY hora_desde
    LOOP
      v_at := (d + f.hora_desde) AT TIME ZONE 'America/Bogota';

      WHILE (v_at + make_interval(mins => t.duracion_min))
              <= ((d + f.hora_hasta) AT TIME ZONE 'America/Bogota') LOOP
        v_fin := v_at + make_interval(mins => t.duracion_min);

        IF v_at >= v_minimo
           AND NOT EXISTS (SELECT 1 FROM reunion r
                            WHERE r.estado IN ('agendada', 'confirmada')
                              AND tstzrange(r.inicia_at, r.termina_at)
                                  && tstzrange(v_at, v_fin))
           AND NOT EXISTS (SELECT 1 FROM bloqueo_agenda b
                            WHERE tstzrange(b.desde_at, b.hasta_at)
                                  && tstzrange(v_at, v_fin))
        THEN
          v_libres := v_libres || jsonb_build_object(
            'inicia_at', to_char(v_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
            'cuando',    fecha_es(v_at) || ' a las ' || hora_es(v_at));
        END IF;

        v_at := v_fin;
      END LOOP;
    END LOOP;

    d := d + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'datos', jsonb_build_object(
      'reunion',      t.nombre,
      'duracion_min', t.duracion_min,
      'modalidad',    t.modalidad,
      -- Se corta en 12: la lista entera no se le ofrece a nadie, y mandarla
      -- completa solo invita al modelo a recitarla.
      'libres',       (SELECT COALESCE(jsonb_agg(x), '[]'::jsonb)
                         FROM (SELECT x FROM jsonb_array_elements(v_libres) x LIMIT 12) s),
      'nota', CASE WHEN jsonb_array_length(v_libres) = 0
                   THEN 'No hay horas libres en ese rango. Ofrece mirar más adelante.'
                   ELSE 'Ofrece DOS o TRES, nunca la lista entera. Copia inicia_at exacto.' END));
END;
$$;


-- ---------------------------------------------------------------------
-- Agendar
--
-- Engancha o crea el prospecto: una reunión pedida por el chat tiene que
-- aparecer en el pipeline sin que nadie la transcriba. Ese es el punto.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION agendar_reunion(
  p_contacto_id     uuid,
  p_codigo          text,
  p_inicia_at       timestamptz,
  p_con_quien       text,
  p_negocio         text DEFAULT NULL,
  p_correo          text DEFAULT NULL,
  p_celular         text DEFAULT NULL,
  p_motivo          text DEFAULT NULL,
  p_conversacion_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  t            tipo_reunion%ROWTYPE;
  v_prospecto  uuid;
  v_id         uuid;
  v_fin        timestamptz;
BEGIN
  SELECT * INTO t FROM tipo_reunion WHERE codigo = p_codigo AND activo;
  IF t.codigo IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese tipo de reunión no existe.');
  END IF;

  IF NULLIF(trim(COALESCE(p_con_quien, '')), '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Falta el nombre de la persona.');
  END IF;

  IF p_inicia_at < now() THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa hora ya pasó.');
  END IF;

  v_fin := p_inicia_at + make_interval(mins => t.duracion_min);

  IF EXISTS (SELECT 1 FROM bloqueo_agenda b
              WHERE tstzrange(b.desde_at, b.hasta_at) && tstzrange(p_inicia_at, v_fin)) THEN
    RETURN jsonb_build_object('ok', false,
      'mensaje', 'Esa hora quedó bloqueada. Ofrécele otras con horarios_reunion.');
  END IF;

  -- El prospecto, si se sabe de qué negocio se trata.
  IF NULLIF(trim(COALESCE(p_negocio, '')), '') IS NOT NULL THEN
    SELECT id INTO v_prospecto FROM prospecto
     WHERE normalizar(nombre) = normalizar(p_negocio);

    IF v_prospecto IS NULL THEN
      INSERT INTO prospecto (nombre, estado, origen, contacto_id,
                             contacto_nombre, contacto_correo, contacto_celular)
      VALUES (trim(p_negocio), 'reunion', 'agendó por el asistente', p_contacto_id,
              p_con_quien, NULLIF(p_correo, ''), NULLIF(p_celular, ''))
      RETURNING id INTO v_prospecto;
    ELSE
      UPDATE prospecto
         SET estado          = CASE WHEN estado IN ('ganado', 'perdido', 'descartado')
                                    THEN estado ELSE 'reunion' END,
             contacto_id     = COALESCE(contacto_id, p_contacto_id),
             contacto_nombre = COALESCE(contacto_nombre, p_con_quien),
             contacto_correo = COALESCE(contacto_correo, NULLIF(p_correo, '')),
             contacto_celular= COALESCE(contacto_celular, NULLIF(p_celular, ''))
       WHERE id = v_prospecto;
    END IF;
  ELSE
    -- Sin nombre de negocio: si el contacto ya está en el pipeline, se usa.
    SELECT id INTO v_prospecto FROM prospecto
     WHERE contacto_id = p_contacto_id LIMIT 1;
  END IF;

  BEGIN
    INSERT INTO reunion (tipo_codigo, contacto_id, prospecto_id, conversacion_id,
                         inicia_at, termina_at, con_quien, negocio, correo,
                         celular, motivo)
    VALUES (t.codigo, p_contacto_id, v_prospecto, p_conversacion_id,
            p_inicia_at, v_fin, trim(p_con_quien), NULLIF(p_negocio, ''),
            NULLIF(p_correo, ''), NULLIF(p_celular, ''), NULLIF(p_motivo, ''))
    RETURNING id INTO v_id;
  EXCEPTION WHEN exclusion_violation THEN
    -- Alguien tomó el cupo entre la propuesta y el botón. Pasa, y el mensaje
    -- está escrito para que el modelo sepa qué hacer con él.
    RETURN jsonb_build_object('ok', false,
      'mensaje', 'Justo se ocupó esa hora. Discúlpate en una línea y ofrécele '
                 'otras dos con horarios_reunion.');
  END;

  IF v_prospecto IS NOT NULL THEN
    INSERT INTO interaccion (prospecto_id, tipo, resumen, resultado)
    VALUES (v_prospecto, 'chat',
            'Agendó ' || t.nombre || ' para ' || fecha_es(p_inicia_at)
              || ' a las ' || hora_es(p_inicia_at) || '.',
            NULLIF(p_motivo, ''));
  END IF;

  PERFORM auditar('reunion', v_id::text, 'agendar', NULL, 'sistema',
                  NULL, jsonb_build_object('cuando', p_inicia_at,
                                           'con', p_con_quien,
                                           'negocio', p_negocio));

  RETURN jsonb_build_object('ok', true, 'reunion_id', v_id,
    'mensaje', 'Listo, quedó agendada para ' || fecha_es(p_inicia_at)
               || ' a las ' || hora_es(p_inicia_at) || '.'
               || CASE WHEN NULLIF(t.enlace, '') IS NOT NULL
                       THEN ' El enlace es ' || t.enlace
                       ELSE ' Te mando el enlace por aquí mismo antes de la reunión.' END);
END;
$$;


CREATE OR REPLACE FUNCTION cancelar_reunion(p_id uuid, p_motivo text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE r reunion%ROWTYPE;
BEGIN
  SELECT * INTO r FROM reunion WHERE id = p_id;

  IF r.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa reunión no existe.');
  END IF;
  IF r.estado NOT IN ('agendada', 'confirmada') THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa reunión ya no estaba activa.');
  END IF;

  UPDATE reunion SET estado = 'cancelada', cancelada_motivo = NULLIF(p_motivo, '')
   WHERE id = p_id;

  IF r.prospecto_id IS NOT NULL THEN
    INSERT INTO interaccion (prospecto_id, tipo, resumen, resultado)
    VALUES (r.prospecto_id, 'chat', 'Canceló la reunión.', NULLIF(p_motivo, ''));
  END IF;

  PERFORM auditar('reunion', p_id::text, 'cancelar', NULL, 'sistema',
                  NULL, jsonb_build_object('motivo', p_motivo));

  RETURN jsonb_build_object('ok', true, 'mensaje', 'Cancelada.');
END;
$$;


CREATE OR REPLACE FUNCTION reagendar_reunion(p_id uuid, p_inicia_at timestamptz)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  r     reunion%ROWTYPE;
  t     tipo_reunion%ROWTYPE;
  v_fin timestamptz;
BEGIN
  SELECT * INTO r FROM reunion WHERE id = p_id;
  IF r.id IS NULL OR r.estado NOT IN ('agendada', 'confirmada') THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa reunión no está activa.');
  END IF;

  SELECT * INTO t FROM tipo_reunion WHERE codigo = r.tipo_codigo;
  v_fin := p_inicia_at + make_interval(mins => t.duracion_min);

  IF p_inicia_at < now() THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa hora ya pasó.');
  END IF;

  BEGIN
    UPDATE reunion SET inicia_at = p_inicia_at, termina_at = v_fin WHERE id = p_id;
  EXCEPTION WHEN exclusion_violation THEN
    RETURN jsonb_build_object('ok', false,
      'mensaje', 'Esa hora ya está ocupada. Ofrécele otras con horarios_reunion.');
  END;

  IF r.prospecto_id IS NOT NULL THEN
    INSERT INTO interaccion (prospecto_id, tipo, resumen)
    VALUES (r.prospecto_id, 'chat',
            'Movió la reunión a ' || fecha_es(p_inicia_at) || ' a las ' || hora_es(p_inicia_at) || '.');
  END IF;

  PERFORM auditar('reunion', p_id::text, 'reagendar', NULL, 'sistema',
                  NULL, jsonb_build_object('cuando', p_inicia_at));

  RETURN jsonb_build_object('ok', true,
    'mensaje', 'Movida para ' || fecha_es(p_inicia_at) || ' a las ' || hora_es(p_inicia_at) || '.');
END;
$$;


-- Las reuniones de quien está escribiendo. Van al prompt, no a una
-- herramienta: alguien a quien le preguntan «¿tenías algo agendado?»
-- después de haberlo agendado por este mismo chat sabe que habla con una
-- máquina.
CREATE OR REPLACE FUNCTION reuniones_del_contacto(
  p_contacto_id uuid, p_incluir_pasadas boolean DEFAULT false)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'reunion_id', r.id,
           'que',        t.nombre,
           'cuando',     fecha_es(r.inicia_at) || ' a las ' || hora_es(r.inicia_at),
           'inicia_at',  to_char(r.inicia_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
           'modalidad',  t.modalidad,
           'enlace',     NULLIF(t.enlace, ''),
           'estado',     r.estado) ORDER BY r.inicia_at), '[]'::jsonb)
    FROM reunion r JOIN tipo_reunion t ON t.codigo = r.tipo_codigo
   WHERE r.contacto_id = p_contacto_id
     AND (p_incluir_pasadas OR (r.inicia_at >= now() AND r.estado IN ('agendada', 'confirmada')));
$$;
