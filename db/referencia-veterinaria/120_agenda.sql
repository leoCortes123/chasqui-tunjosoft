-- =====================================================================
-- Chasqui TunjoSoft — 120_agenda.sql
-- La agenda: recursos, horarios, bloqueos y citas.
--
-- La regla que manda todo este archivo: **el tomógrafo es uno solo**. No
-- se puede sobreagendar, y eso no lo puede garantizar el código de una
-- aplicación que consulta y después inserta —entre las dos cosas cabe otra
-- conversación—. Lo garantiza un `EXCLUDE` de Postgres: dos citas del
-- mismo recurso con horarios que se cruzan no entran a la tabla. Punto.
-- Si el asistente lo intenta, la base lo rechaza y él tiene que ofrecer
-- otra hora.
--
-- Es el mismo principio de todo el sistema: lo que no puede fallar no se
-- le pide al modelo, ni al worker. Se le pide a la base.
--
-- Los horarios sembrados aquí son un SUPUESTO de trabajo (imagen con cita,
-- de lunes a sábado y medio domingo). La clínica atiende urgencias 24/7,
-- que es otra cosa y no pasa por aquí: una urgencia se llega sin cita.
-- Antes de mostrarle esto a Abanimal hay que hacerles confirmar la franja
-- real de cada equipo. `v_horario_por_confirmar` los lista.
-- =====================================================================

SET client_min_messages = warning;

-- Para el EXCLUDE: cruza un uuid (igualdad) con un rango (solapamiento) en
-- el mismo índice. Sin esto no se puede pedir «mismo recurso Y horas que
-- se cruzan».
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ---------------------------------------------------------------------
-- Los recursos
--
-- Un recurso es lo que se agota: el tomógrafo, el ecógrafo, la sala de
-- rayos. `estudio.equipo` (110) ya apuntaba a esto sin tabla; aquí se le
-- da cuerpo.
--
-- `capacidad` existe porque no todo se agota de a uno: si mañana compran
-- un segundo ecógrafo, es `capacidad = 2` y no una tabla nueva.
-- ---------------------------------------------------------------------
CREATE TABLE recurso (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo     text UNIQUE NOT NULL,           -- coincide con estudio.equipo
  nombre     text NOT NULL,
  sede_id    uuid REFERENCES sede(id),
  capacidad  int  NOT NULL DEFAULT 1 CHECK (capacidad >= 1),
  activo     boolean NOT NULL DEFAULT true,
  orden      int  NOT NULL DEFAULT 100,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER recurso_touch BEFORE UPDATE ON recurso
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ---------------------------------------------------------------------
-- Cuándo atiende cada recurso
--
-- `dia_semana` sigue a `EXTRACT(dow)`: 0 domingo … 6 sábado.
-- ---------------------------------------------------------------------
CREATE TABLE horario_recurso (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recurso_id  uuid NOT NULL REFERENCES recurso(id) ON DELETE CASCADE,
  dia_semana  int  NOT NULL CHECK (dia_semana BETWEEN 0 AND 6),
  hora_desde  time NOT NULL,
  hora_hasta  time NOT NULL,
  -- true = un horario supuesto por nosotros, sin confirmar por la clínica.
  -- Igual que `tarifa.estimado`: lo que no nos consta se marca, no se
  -- disimula.
  supuesto    boolean NOT NULL DEFAULT true,
  CHECK (hora_hasta > hora_desde),
  UNIQUE (recurso_id, dia_semana, hora_desde)
);

-- ---------------------------------------------------------------------
-- Bloqueos: mantenimiento, capacitación, el día que no hay radiólogo
-- ---------------------------------------------------------------------
CREATE TABLE bloqueo_agenda (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- NULL = bloquea toda la clínica (un 25 de diciembre, por ejemplo).
  recurso_id uuid REFERENCES recurso(id) ON DELETE CASCADE,
  desde_at   timestamptz NOT NULL,
  hasta_at   timestamptz NOT NULL,
  motivo     text NOT NULL,
  creado_por uuid REFERENCES usuario(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (hasta_at > desde_at)
);

CREATE INDEX idx_bloqueo_rango ON bloqueo_agenda (desde_at, hasta_at);

-- ---------------------------------------------------------------------
-- La cita
--
-- `franja` es una columna generada y no dos timestamps sueltos porque el
-- `EXCLUDE` necesita un rango. Que sea generada evita el error de
-- actualizar la hora de inicio y olvidar la de fin.
-- ---------------------------------------------------------------------
CREATE TABLE cita (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  paciente_id     uuid NOT NULL REFERENCES paciente(id) ON DELETE CASCADE,
  estudio_id      uuid NOT NULL REFERENCES estudio(id),
  recurso_id      uuid NOT NULL REFERENCES recurso(id),
  sede_id         uuid REFERENCES sede(id),

  inicia_at       timestamptz NOT NULL,
  termina_at      timestamptz NOT NULL,
  franja          tstzrange GENERATED ALWAYS AS
                    (tstzrange(inicia_at, termina_at, '[)')) STORED,

  estado          text NOT NULL DEFAULT 'confirmada'
                    CHECK (estado IN ('confirmada','cancelada','atendida','no_asistio')),

  -- Quién y por dónde. Sirve para mandarle el recordatorio de ayuno por el
  -- mismo chat por el que pidió la cita.
  contacto_id     uuid REFERENCES contacto(id) ON DELETE SET NULL,
  conversacion_id uuid REFERENCES conversacion(id) ON DELETE SET NULL,
  creada_por      uuid REFERENCES usuario(id),

  -- El valor que se le dijo al tutor, congelado. Si la tarifa cambia
  -- mañana, la cita de mañana sigue valiendo lo que se prometió hoy.
  valor           numeric(12,2),
  valor_estimado  boolean NOT NULL DEFAULT true,

  -- Desde cuándo no puede comer. Se calcula al agendar, con la preparación
  -- del estudio, y es lo que dice el recordatorio.
  ayuno_desde_at  timestamptz,

  motivo          text,          -- «la remite el Dr. Pérez por vómito crónico»
  notas           text,
  cancelada_por   text,
  motivo_cancelacion text,

  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CHECK (termina_at > inicia_at),

  -- ⚠️ El corazón del archivo. Dos citas vivas del mismo recurso no pueden
  -- cruzarse. Las canceladas y las que no asistieron sí liberan el cupo.
  CONSTRAINT cita_sin_cruce EXCLUDE USING gist (
    recurso_id WITH =,
    franja     WITH &&
  ) WHERE (estado IN ('confirmada','atendida'))
);

CREATE INDEX idx_cita_inicia   ON cita (inicia_at);
CREATE INDEX idx_cita_paciente ON cita (paciente_id, inicia_at DESC);
CREATE INDEX idx_cita_contacto ON cita (contacto_id, inicia_at DESC);
CREATE INDEX idx_cita_agenda   ON cita (recurso_id, inicia_at)
  WHERE estado IN ('confirmada','atendida');

CREATE TRIGGER cita_touch BEFORE UPDATE ON cita
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- Cuando el cupo del recurso es el que se agota, no se puede tener a
-- alguien esperando en la nada: la lista de espera es la respuesta honesta
-- a «no hay nada esa semana».
CREATE TABLE lista_espera (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  paciente_id  uuid REFERENCES paciente(id) ON DELETE CASCADE,
  contacto_id  uuid REFERENCES contacto(id) ON DELETE CASCADE,
  estudio_id   uuid NOT NULL REFERENCES estudio(id),
  desde_fecha  date NOT NULL DEFAULT hoy_bogota(),
  hasta_fecha  date,
  nota         text,
  estado       text NOT NULL DEFAULT 'esperando'
                 CHECK (estado IN ('esperando','avisado','agendado','vencido')),
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_espera_abierta ON lista_espera (estudio_id, desde_fecha)
  WHERE estado = 'esperando';

-- ---------------------------------------------------------------------
-- Semilla de recursos y horarios
--
-- Los códigos salen de `estudio.equipo` (110_estudios.sql). Si mañana se
-- agrega un estudio con un equipo nuevo, hay que agregarlo aquí también:
-- `v_estudio_sin_recurso` lo delata.
-- ---------------------------------------------------------------------
INSERT INTO recurso (codigo, nombre, capacidad, orden, sede_id)
SELECT v.codigo, v.nombre, v.capacidad, v.orden, s.id
  FROM (VALUES
    ('ecografo_1', 'Ecógrafo',            1, 10),
    ('tac',        'Tomógrafo',           1, 20),
    ('rayos_x',    'Sala de radiología',  1, 30),
    ('endoscopio', 'Endoscopio',          1, 40),
    ('consultorio','Consultorio',         3, 50)
  ) AS v(codigo, nombre, capacidad, orden)
  CROSS JOIN LATERAL (SELECT id FROM sede ORDER BY created_at LIMIT 1) s
ON CONFLICT (codigo) DO NOTHING;

-- Los estudios sin equipo (consulta general, especialista, segunda
-- opinión) se atienden en consultorio, que sí tiene más de un cupo.
UPDATE estudio SET equipo = 'consultorio' WHERE equipo IS NULL;

-- Horario supuesto: lunes a sábado de 8 a 18, domingo de 9 a 13.
-- Todo marcado `supuesto = true` a la espera de que la clínica confirme.
INSERT INTO horario_recurso (recurso_id, dia_semana, hora_desde, hora_hasta, supuesto)
SELECT r.id, d.dia, d.desde, d.hasta, true
  FROM recurso r
  CROSS JOIN (VALUES
    (1, '08:00'::time, '18:00'::time), (2, '08:00', '18:00'),
    (3, '08:00', '18:00'),             (4, '08:00', '18:00'),
    (5, '08:00', '18:00'),             (6, '08:00', '18:00'),
    (0, '09:00', '13:00')
  ) AS d(dia, desde, hasta)
ON CONFLICT DO NOTHING;

CREATE OR REPLACE VIEW v_horario_por_confirmar AS
  SELECT r.nombre AS recurso, h.dia_semana, h.hora_desde, h.hora_hasta
    FROM horario_recurso h JOIN recurso r ON r.id = h.recurso_id
   WHERE h.supuesto
   ORDER BY r.orden, h.dia_semana;

CREATE OR REPLACE VIEW v_estudio_sin_recurso AS
  SELECT e.codigo, e.nombre, e.equipo
    FROM estudio e
   WHERE e.activo
     AND NOT EXISTS (SELECT 1 FROM recurso r WHERE r.codigo = e.equipo AND r.activo);

-- ---------------------------------------------------------------------
-- Decir una fecha como la diría una persona
--
-- «el jueves 6 de agosto a las 9:00 am», no «2026-08-06T09:00:00-05:00».
-- Va en SQL y no en el prompt porque esta cadena entra en la tarjeta de
-- confirmación, y la tarjeta no la redacta el modelo.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fecha_es(p_at timestamptz)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT (ARRAY['domingo','lunes','martes','miércoles','jueves','viernes','sábado'])
           [EXTRACT(dow FROM p_at AT TIME ZONE 'America/Bogota')::int + 1]
      || ' ' || EXTRACT(day FROM p_at AT TIME ZONE 'America/Bogota')::int
      || ' de ' ||
         (ARRAY['enero','febrero','marzo','abril','mayo','junio','julio',
                'agosto','septiembre','octubre','noviembre','diciembre'])
           [EXTRACT(month FROM p_at AT TIME ZONE 'America/Bogota')::int];
$$;

CREATE OR REPLACE FUNCTION hora_es(p_at timestamptz)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT trim(to_char(p_at AT TIME ZONE 'America/Bogota', 'FMHH12:MI'))
      || CASE WHEN to_char(p_at AT TIME ZONE 'America/Bogota', 'AM') = 'AM'
              THEN ' am' ELSE ' pm' END;
$$;

-- ---------------------------------------------------------------------
-- El ayuno, dicho como se lo diría una persona
--
-- La resta pura sale de lugar más de la mitad de las veces: una cita a las
-- 9 de la mañana con 8 horas de ayuno da la 1:00 am, y nadie le da de comer
-- al perro a la una de la madrugada. Un tutor que lee «desde la 1:00 am»
-- entiende «puedo darle comida a medianoche», que es justo lo contrario de
-- lo que hay que entender.
--
-- Cuando el límite cae de madrugada se adelanta a las 9:00 pm del día
-- anterior: es la hora real en que uno deja de darle comida, y adelantar un
-- ayuno nunca daña un estudio. Redondear para el otro lado sí.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ayuno_limite(p_cita_at timestamptz, p_horas int)
RETURNS timestamptz
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_horas IS NULL OR p_horas <= 0 THEN NULL
    WHEN EXTRACT(hour FROM (p_cita_at - make_interval(hours => p_horas))
                 AT TIME ZONE 'America/Bogota') < 7
      THEN date_trunc('day', (p_cita_at - make_interval(hours => p_horas))
                             AT TIME ZONE 'America/Bogota')
           AT TIME ZONE 'America/Bogota' - interval '3 hours'   -- 9:00 pm del día anterior
    ELSE p_cita_at - make_interval(hours => p_horas)
  END;
$$;

CREATE OR REPLACE FUNCTION ayuno_texto(p_cita_at timestamptz, p_horas int)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN ayuno_limite(p_cita_at, p_horas) IS NULL THEN NULL
    ELSE 'sin comida ni agua desde las ' || hora_es(ayuno_limite(p_cita_at, p_horas))
         || CASE WHEN (ayuno_limite(p_cita_at, p_horas) AT TIME ZONE 'America/Bogota')::date
                    = (p_cita_at AT TIME ZONE 'America/Bogota')::date
                 THEN ' del mismo día'
                 ELSE ' del ' || fecha_es(ayuno_limite(p_cita_at, p_horas)) END
  END;
$$;

-- ---------------------------------------------------------------------
-- Horarios disponibles
--
-- Genera las horas candidatas de un día y descarta las que chocan con una
-- cita viva o con un bloqueo. No reserva nada: es una lectura, y entre
-- que se lee y se agenda alguien más puede tomar el cupo. Por eso quien
-- decide de verdad es el `EXCLUDE` de la tabla, no esta función.
--
-- El paso es la duración del propio estudio: un TAC de 60 minutos ofrece
-- 8:00, 9:00, 10:00…; una ecografía de 45, 8:00, 8:45, 9:30…
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION horarios_disponibles(
  p_codigo  text,
  p_fecha   date DEFAULT NULL,
  p_dias    int  DEFAULT 7,
  p_limite  int  DEFAULT 12)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  e        estudio%ROWTYPE;
  r        recurso%ROWTYPE;
  v_desde  date := COALESCE(p_fecha, hoy_bogota());
  v_dias   int  := GREATEST(1, LEAST(COALESCE(p_dias, 7), 30));
  v_libres jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO e FROM estudio WHERE codigo = p_codigo AND activo;
  IF e.id IS NULL THEN
    RAISE EXCEPTION 'No existe el estudio %. Usa listar_estudios.', p_codigo;
  END IF;

  SELECT * INTO r FROM recurso WHERE codigo = e.equipo AND activo;
  IF r.id IS NULL THEN
    RAISE EXCEPTION 'El estudio % no tiene equipo asignado en la agenda.', p_codigo;
  END IF;

  -- Si piden un día que ya pasó, se empieza por hoy en vez de devolver
  -- vacío: casi siempre es alguien que escribió mal el año.
  IF v_desde < hoy_bogota() THEN
    v_desde := hoy_bogota();
  END IF;

  WITH dias AS (
    SELECT (v_desde + i)::date AS dia
      FROM generate_series(0, v_dias - 1) AS i
  ),
  -- Todos los comienzos posibles de cada día, según el horario del recurso.
  candidatos AS (
    SELECT (d.dia + h.hora_desde) AT TIME ZONE 'America/Bogota'
             + make_interval(mins => e.duracion_min * paso.n) AS inicia_at
      FROM dias d
      JOIN horario_recurso h
        ON h.recurso_id = r.id
       AND h.dia_semana = EXTRACT(dow FROM d.dia)::int
      CROSS JOIN LATERAL generate_series(
        0,
        GREATEST(0, (EXTRACT(epoch FROM (h.hora_hasta - h.hora_desde)) / 60
                     / e.duracion_min)::int - 1)
      ) AS paso(n)
  ),
  con_fin AS (
    SELECT inicia_at, inicia_at + make_interval(mins => e.duracion_min) AS termina_at
      FROM candidatos
     -- Nadie agenda para dentro de diez minutos: hay que llegar a la clínica.
     WHERE inicia_at > now() + interval '2 hours'
  )
  SELECT COALESCE(jsonb_agg(x ORDER BY x.inicia_at), '[]'::jsonb)
    INTO v_libres
    FROM (
      SELECT c.inicia_at, c.termina_at
        FROM con_fin c
       WHERE (
               SELECT count(*) FROM cita ct
                WHERE ct.recurso_id = r.id
                  AND ct.estado IN ('confirmada','atendida')
                  AND ct.franja && tstzrange(c.inicia_at, c.termina_at, '[)')
             ) < r.capacidad
         AND NOT EXISTS (
               SELECT 1 FROM bloqueo_agenda b
                WHERE (b.recurso_id = r.id OR b.recurso_id IS NULL)
                  AND tstzrange(b.desde_at, b.hasta_at, '[)')
                      && tstzrange(c.inicia_at, c.termina_at, '[)')
             )
       ORDER BY c.inicia_at
       LIMIT GREATEST(1, LEAST(COALESCE(p_limite, 12), 40))
    ) AS x;

  RETURN jsonb_build_object(
    'estudio',      e.nombre,
    'codigo',       e.codigo,
    'duracion_min', e.duracion_min,
    'equipo',       r.nombre,
    'desde',        v_desde,
    -- El precio va PEGADO a cada hora, y no aparte, porque cambia con el
    -- día: el mismo estudio vale distinto un viernes festivo que el jueves
    -- anterior. Con el precio en otro campo, el modelo cotiza una vez, la
    -- conversación se mueve al domingo y él sigue repitiendo la cifra del
    -- lunes. Aquí no puede: cada hora trae la suya.
    'horarios',     (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'inicia_at', s->>'inicia_at',
               'cuando',    fecha_es((s->>'inicia_at')::timestamptz)
                            || ' a las ' || hora_es((s->>'inicia_at')::timestamptz),
               'valor',     t.q->>'valor_texto',
               -- Sin esto el modelo cubre la espalda solo y agrega «de
               -- referencia» a un precio que sí está confirmado. Hedge
               -- gratis: el cliente oye duda donde no la hay.
               'precio_confirmado', t.q->'precio_confirmado',
               'es_domingo_o_festivo', t.q->'es_domingo_o_festivo',
               'festivo',   t.q->>'festivo')
             ORDER BY s->>'inicia_at'), '[]'::jsonb)
        FROM jsonb_array_elements(v_libres) AS s
        CROSS JOIN LATERAL (
          SELECT cotizar_estudio(
                   e.codigo,
                   ((s->>'inicia_at')::timestamptz AT TIME ZONE 'America/Bogota')::date) AS q
        ) t),
    'como_decirlo',
      CASE WHEN jsonb_array_length(v_libres) = 0
        THEN 'No hay cupo en esos días. Dilo, ofrece buscar más adelante o '
             'anotarlo en lista de espera, y no inventes una hora.'
        ELSE 'Ofrece DOS o TRES opciones concretas, no la lista entera, y '
             'pregunta cuál le sirve. Usa el texto de "cuando" tal cual; '
             'para agendar manda el "inicia_at" exacto. Si vuelves a decir un '
             'precio, usa el "valor" de la hora que estés ofreciendo, no el '
             'que dijiste antes: cambia según el día. Cuando alguna hora caiga '
             'en domingo o festivo, dilo y di por qué cuesta distinto. Si '
             '"precio_confirmado" es true, NO digas «de referencia» ni «puede '
             'variar»: es el precio, dilo con seguridad.'
      END);
END;
$$;

-- ---------------------------------------------------------------------
-- Agendar
--
-- Hace todo el trámite de una vez: asegura el tutor, asegura el paciente,
-- congela el precio, calcula el ayuno, guarda la cita y programa los
-- recordatorios. Se llama una sola vez y con lo que el tutor ya dijo en la
-- conversación; no hay un formulario de seis pasos.
--
-- Es `escribe = true`: el modelo la propone, la persona toca el botón.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION agendar_cita(
  p_contacto_id     uuid,
  p_codigo          text,
  p_inicia_at       timestamptz,
  p_paciente        text,
  p_tutor           text    DEFAULT NULL,
  p_especie         text    DEFAULT 'canino',
  p_raza            text    DEFAULT NULL,
  p_edad            numeric DEFAULT NULL,
  p_motivo          text    DEFAULT NULL,
  p_conversacion_id uuid    DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  e            estudio%ROWTYPE;
  r            recurso%ROWTYPE;
  prep         preparacion%ROWTYPE;
  v_dueno      uuid;
  v_paciente   uuid;
  v_cita       uuid;
  v_termina    timestamptz;
  v_tarifa     jsonb;
  v_ayuno      timestamptz;
  v_tutor      text := NULLIF(trim(p_tutor), '');
  v_sede       uuid;
  v_aviso_seg  int;
  v_recordar   timestamptz;
BEGIN
  IF p_inicia_at IS NULL THEN
    RAISE EXCEPTION 'Falta la hora de la cita.';
  END IF;

  SELECT * INTO e FROM estudio WHERE codigo = p_codigo AND activo;
  IF e.id IS NULL THEN
    RAISE EXCEPTION 'No existe el estudio %. Usa listar_estudios.', p_codigo;
  END IF;

  SELECT * INTO r FROM recurso WHERE codigo = e.equipo AND activo;
  IF r.id IS NULL THEN
    RAISE EXCEPTION 'El estudio % no tiene equipo en la agenda.', p_codigo;
  END IF;

  IF p_inicia_at < now() THEN
    RAISE EXCEPTION 'Esa hora ya pasó. Ofrece horarios con horarios_disponibles.';
  END IF;

  v_termina := p_inicia_at + make_interval(mins => e.duracion_min);

  -- Que la hora caiga dentro del horario del equipo. Sin esto se puede
  -- agendar un TAC a las tres de la mañana y el EXCLUDE lo dejaría pasar,
  -- porque no choca con nada.
  IF NOT EXISTS (
    SELECT 1 FROM horario_recurso h
     WHERE h.recurso_id = r.id
       AND h.dia_semana = EXTRACT(dow FROM p_inicia_at AT TIME ZONE 'America/Bogota')::int
       AND (p_inicia_at AT TIME ZONE 'America/Bogota')::time >= h.hora_desde
       AND (v_termina   AT TIME ZONE 'America/Bogota')::time <= h.hora_hasta
  ) THEN
    RAISE EXCEPTION 'A esa hora no se atiende ese estudio. Usa horarios_disponibles y ofrece una de las que devuelva.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM bloqueo_agenda b
     WHERE (b.recurso_id = r.id OR b.recurso_id IS NULL)
       AND tstzrange(b.desde_at, b.hasta_at, '[)') && tstzrange(p_inicia_at, v_termina, '[)')
  ) THEN
    RAISE EXCEPTION 'Ese horario está bloqueado. Ofrece otro con horarios_disponibles.';
  END IF;

  -- Tutor y paciente. Si no dieron nombre del tutor, se usa el del
  -- contacto: es el nombre con el que llegó por WhatsApp.
  IF v_tutor IS NULL THEN
    SELECT nombre INTO v_tutor FROM contacto WHERE id = p_contacto_id;
  END IF;

  v_dueno := dueno_asegurar(COALESCE(v_tutor, 'Sin nombre'), NULL, p_contacto_id);
  v_paciente := paciente_asegurar(v_dueno, p_paciente, p_especie, p_raza, NULL, p_edad);

  -- El precio del día de la cita, no el de hoy: si cae en domingo, vale lo
  -- del domingo. Se congela en la fila.
  v_tarifa := cotizar_estudio(e.codigo, (p_inicia_at AT TIME ZONE 'America/Bogota')::date);

  SELECT * INTO prep FROM preparacion WHERE estudio_id = e.id;
  v_ayuno := ayuno_limite(p_inicia_at, prep.ayuno_horas);

  SELECT id INTO v_sede FROM sede ORDER BY created_at LIMIT 1;

  BEGIN
    INSERT INTO cita (paciente_id, estudio_id, recurso_id, sede_id,
                      inicia_at, termina_at, contacto_id, conversacion_id,
                      valor, valor_estimado, ayuno_desde_at, motivo)
    VALUES (v_paciente, e.id, r.id, v_sede,
            p_inicia_at, v_termina, p_contacto_id, p_conversacion_id,
            (v_tarifa->>'valor')::numeric,
            NOT COALESCE((v_tarifa->>'precio_confirmado')::boolean, false),
            v_ayuno, NULLIF(trim(p_motivo), ''))
    RETURNING id INTO v_cita;
  EXCEPTION WHEN exclusion_violation THEN
    -- Alguien tomó el cupo entre que se ofreció y se confirmó. Es la
    -- carrera que el EXCLUDE existe para atrapar.
    RETURN jsonb_build_object('ok', false,
      'mensaje', 'Ese horario lo acaban de tomar. Discúlpate y ofrece otro con horarios_disponibles.');
  END;

  -- Recordatorios. El del ayuno es clínico: si el paciente come, se pierde
  -- el estudio y el cupo. Se programa con el retraso de la cola, así que
  -- si el worker está caído se manda al volver, no se pierde.
  IF v_ayuno IS NOT NULL AND p_conversacion_id IS NOT NULL THEN
    v_aviso_seg := EXTRACT(epoch FROM (v_ayuno - interval '1 hour' - now()))::int;
    IF v_aviso_seg > 60 THEN
      PERFORM encolar_tarea('enviar_texto',
        jsonb_build_object(
          'conversacion_id', p_conversacion_id,
          'texto', format(
            'Recordatorio de %s: %s tiene %s el %s a las %s. Importante: %s. Si come, el estudio no sirve y toca repetirlo otro día.',
            config_txt('nombre_clinica', 'la clínica'),
            p_paciente, e.nombre, fecha_es(p_inicia_at), hora_es(p_inicia_at),
            ayuno_texto(p_inicia_at, prep.ayuno_horas))),
        10, 'ayuno:' || v_cita::text, v_aviso_seg);
    END IF;
  END IF;

  -- El del día, tres horas antes. Con el tope de las 7 am: tres horas antes
  -- de una cita a las 8 es un mensaje a las cinco de la mañana, y un chat
  -- que suena de madrugada se silencia para siempre.
  IF p_conversacion_id IS NOT NULL THEN
    v_recordar := p_inicia_at - interval '3 hours';
    IF EXTRACT(hour FROM v_recordar AT TIME ZONE 'America/Bogota') < 7 THEN
      v_recordar := date_trunc('day', p_inicia_at AT TIME ZONE 'America/Bogota')
                    AT TIME ZONE 'America/Bogota' + interval '7 hours';
    END IF;
    v_aviso_seg := EXTRACT(epoch FROM (v_recordar - now()))::int;
    IF v_aviso_seg > 60 THEN
      PERFORM encolar_tarea('enviar_texto',
        jsonb_build_object(
          'conversacion_id', p_conversacion_id,
          'texto', format('Hoy a las %s te esperamos con %s para %s. Llega 10 minutos antes. Dirección: %s',
                          hora_es(p_inicia_at), p_paciente, e.nombre,
                          config_txt('clinica_direccion', ''))),
        10, 'recordatorio:' || v_cita::text, v_aviso_seg);
    END IF;
  END IF;

  PERFORM auditar('cita', v_cita::text, 'crear', NULL, 'sistema', NULL,
                  jsonb_build_object('estudio', e.codigo, 'inicia_at', p_inicia_at,
                                     'paciente', p_paciente, 'contacto_id', p_contacto_id));

  RETURN jsonb_build_object(
    'ok', true,
    'cita_id',  v_cita,
    'estudio',  e.nombre,
    'paciente', p_paciente,
    'cuando',   fecha_es(p_inicia_at) || ' a las ' || hora_es(p_inicia_at),
    'valor',    pesos((v_tarifa->>'valor')::numeric),
    'ayuno', ayuno_texto(p_inicia_at, prep.ayuno_horas),
    'preparacion', prep.texto,
    'direccion', config_txt('clinica_direccion', ''),
    'mensaje', 'La cita quedó agendada.');
END;
$$;

-- ---------------------------------------------------------------------
-- Cancelar y reagendar
--
-- Cancelar no borra: cambia el estado. Append-only también aquí — el cupo
-- que se liberó y a qué hora se liberó es justo lo que uno quiere saber
-- cuando algo sale mal.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cancelar_cita(
  p_cita_id uuid, p_motivo text DEFAULT NULL, p_por text DEFAULT 'tutor')
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE c cita%ROWTYPE;
BEGIN
  SELECT * INTO c FROM cita WHERE id = p_cita_id FOR UPDATE;
  IF c.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa cita no existe.');
  END IF;
  IF c.estado <> 'confirmada' THEN
    RETURN jsonb_build_object('ok', false,
      'mensaje', format('Esa cita ya está %s.', c.estado));
  END IF;

  UPDATE cita SET estado = 'cancelada', cancelada_por = p_por,
                  motivo_cancelacion = NULLIF(trim(p_motivo), '')
   WHERE id = p_cita_id;

  -- Los recordatorios de una cita cancelada no se mandan.
  DELETE FROM tarea_async
   WHERE clave_unicidad IN ('ayuno:' || p_cita_id::text,
                            'recordatorio:' || p_cita_id::text)
     AND estado = 'pendiente';

  PERFORM auditar('cita', p_cita_id::text, 'cancelar', NULL, 'sistema',
                  jsonb_build_object('estado', c.estado),
                  jsonb_build_object('estado', 'cancelada', 'motivo', p_motivo));

  RETURN jsonb_build_object('ok', true, 'mensaje', 'La cita quedó cancelada.',
    'liberado', fecha_es(c.inicia_at) || ' a las ' || hora_es(c.inicia_at));
END;
$$;

CREATE OR REPLACE FUNCTION reagendar_cita(p_cita_id uuid, p_inicia_at timestamptz)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  c         cita%ROWTYPE;
  e         estudio%ROWTYPE;
  v_termina timestamptz;
  v_ayuno   timestamptz;
  v_horas   int;
  v_tarifa  jsonb;
BEGIN
  SELECT * INTO c FROM cita WHERE id = p_cita_id FOR UPDATE;
  IF c.id IS NULL OR c.estado <> 'confirmada' THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa cita no se puede mover.');
  END IF;

  SELECT * INTO e FROM estudio WHERE id = c.estudio_id;
  v_termina := p_inicia_at + make_interval(mins => e.duracion_min);

  SELECT ayuno_horas INTO v_horas FROM preparacion WHERE estudio_id = e.id;
  v_ayuno := ayuno_limite(p_inicia_at, v_horas);

  IF NOT EXISTS (
    SELECT 1 FROM horario_recurso h
     WHERE h.recurso_id = c.recurso_id
       AND h.dia_semana = EXTRACT(dow FROM p_inicia_at AT TIME ZONE 'America/Bogota')::int
       AND (p_inicia_at AT TIME ZONE 'America/Bogota')::time >= h.hora_desde
       AND (v_termina   AT TIME ZONE 'America/Bogota')::time <= h.hora_hasta
  ) THEN
    RETURN jsonb_build_object('ok', false,
      'mensaje', 'A esa hora no se atiende. Ofrece otra con horarios_disponibles.');
  END IF;

  -- Mover la cita mueve el precio. Un viernes festivo vale más que el
  -- sábado siguiente, y una cita que se mueve conservando la tarifa vieja
  -- cobra de menos o de más en la caja el día que llegan.
  v_tarifa := cotizar_estudio(e.codigo, (p_inicia_at AT TIME ZONE 'America/Bogota')::date);

  BEGIN
    UPDATE cita SET inicia_at = p_inicia_at, termina_at = v_termina,
                    ayuno_desde_at = v_ayuno,
                    valor = (v_tarifa->>'valor')::numeric,
                    valor_estimado = NOT COALESCE((v_tarifa->>'precio_confirmado')::boolean, false)
     WHERE id = p_cita_id;
  EXCEPTION WHEN exclusion_violation THEN
    RETURN jsonb_build_object('ok', false,
      'mensaje', 'Ese horario ya está tomado. Ofrece otro.');
  END;

  -- Los avisos viejos apuntaban a la hora vieja.
  DELETE FROM tarea_async
   WHERE clave_unicidad IN ('ayuno:' || p_cita_id::text,
                            'recordatorio:' || p_cita_id::text)
     AND estado = 'pendiente';

  PERFORM auditar('cita', p_cita_id::text, 'reagendar', NULL, 'sistema',
                  jsonb_build_object('inicia_at', c.inicia_at),
                  jsonb_build_object('inicia_at', p_inicia_at));

  RETURN jsonb_build_object('ok', true,
    'mensaje', 'La cita quedó movida.',
    'cuando', fecha_es(p_inicia_at) || ' a las ' || hora_es(p_inicia_at),
    'valor',  pesos((v_tarifa->>'valor')::numeric),
    'ayuno',  ayuno_texto(p_inicia_at, v_horas));
END;
$$;

-- ---------------------------------------------------------------------
-- Las citas de quien está escribiendo
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION citas_del_contacto(
  p_contacto_id uuid, p_incluir_pasadas boolean DEFAULT false)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'cita_id',  c.id,
           'estudio',  e.nombre,
           'codigo',   e.codigo,
           'paciente', p.nombre,
           'cuando',   fecha_es(c.inicia_at) || ' a las ' || hora_es(c.inicia_at),
           'inicia_at', c.inicia_at,
           'estado',   c.estado,
           'valor',    pesos(c.valor),
           'ayuno', CASE WHEN c.ayuno_desde_at IS NULL THEN NULL
                         ELSE 'sin comida ni agua desde las ' || hora_es(c.ayuno_desde_at)
                              || ' del ' || fecha_es(c.ayuno_desde_at) END)
         ORDER BY c.inicia_at), '[]'::jsonb)
    FROM cita c
    JOIN estudio  e ON e.id = c.estudio_id
    JOIN paciente p ON p.id = c.paciente_id
    LEFT JOIN contacto ct ON ct.id = p_contacto_id
   WHERE (c.contacto_id = p_contacto_id
          OR (ct.dueno_id IS NOT NULL AND p.dueno_id = ct.dueno_id))
     AND (p_incluir_pasadas OR (c.inicia_at > now() AND c.estado = 'confirmada'));
$$;

-- La agenda del día, para el portal y para el personal.
CREATE OR REPLACE VIEW v_agenda_hoy AS
  SELECT c.id, c.inicia_at, hora_es(c.inicia_at) AS hora, e.nombre AS estudio,
         p.nombre AS paciente, p.especie, d.nombre AS tutor, d.celular,
         r.nombre AS equipo, c.estado, c.valor, c.motivo
    FROM cita c
    JOIN estudio  e ON e.id = c.estudio_id
    JOIN paciente p ON p.id = c.paciente_id
    JOIN dueno    d ON d.id = p.dueno_id
    JOIN recurso  r ON r.id = c.recurso_id
   WHERE (c.inicia_at AT TIME ZONE 'America/Bogota')::date = hoy_bogota()
   ORDER BY c.inicia_at;
