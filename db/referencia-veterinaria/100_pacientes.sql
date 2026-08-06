-- =====================================================================
-- Chasqui TunjoSoft — 100_pacientes.sql
-- Tutores y pacientes. Lo que una cita necesita para colgar de algo.
--
-- Aquí vive el antiduplicado de historia clínica, que Abanimal declara por
-- escrito como problema en su propio formulario de contacto. No es una
-- mejora: es requisito.
--
-- El antiduplicado son DOS reglas, y las dos las hace la base:
--
--   1. El celular normalizado a E.164 es la llave del tutor. «311 234 5678»,
--      «3112345678» y «+57 311 2345678» son la misma persona. Quien
--      normaliza es `normalizar_celular` (030_actor.sql), la misma función
--      que usa el canal, para que no haya dos criterios de igualdad.
--
--   2. Dentro de un tutor, el nombre del paciente sin tildes y en minúscula
--      es único. «Luna», «luna» y «LUNA» del mismo dueño son la misma
--      perrita. Es un índice, no un `IF EXISTS` en código: dos mensajes
--      simultáneos no pueden crear dos Lunas.
--
-- Lo que NO se hace: fusionar automáticamente dos tutores que se parecen.
-- Si el mismo señor escribe desde dos celulares, quedan dos fichas y las
-- une una persona desde el portal. Fusionar historias clínicas por
-- parecido de nombre es peor que tener dos.
-- =====================================================================

SET client_min_messages = warning;

-- `unaccent` es STABLE, no IMMUTABLE, porque en teoría alguien podría
-- cambiarle el diccionario en caliente; por eso Postgres no la deja entrar
-- en un índice. Fijando el diccionario de forma explícita el resultado sí
-- es constante, y este envoltorio lo declara.
CREATE OR REPLACE FUNCTION sin_tildes(txt text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT unaccent('unaccent'::regdictionary, txt);
$$;

-- ---------------------------------------------------------------------
-- El tutor
--
-- No es lo mismo que `contacto` (030_actor.sql). `contacto` es «un número
-- que escribió»; `dueno` es «una persona con pacientes». Un contacto puede
-- no tener ficha —el que solo preguntó el horario— y una ficha puede no
-- tener contacto —la que abrió la recepcionista por teléfono—.
-- ---------------------------------------------------------------------
CREATE TABLE dueno (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre       text NOT NULL,
  celular      text,                       -- E.164, normalizado al insertar
  correo       text,
  documento    text,
  direccion    text,
  notas        text,
  activo       boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- Regla 1 del antiduplicado. Parcial porque la ficha abierta por teléfono
-- puede no traer celular todavía.
CREATE UNIQUE INDEX idx_dueno_celular
  ON dueno (celular) WHERE celular IS NOT NULL;

-- Para que la recepcionista encuentre «Rodriguez» escribiendo «rodrigez».
CREATE INDEX idx_dueno_nombre_trgm ON dueno USING gin (nombre gin_trgm_ops);

CREATE TRIGGER dueno_touch BEFORE UPDATE ON dueno
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- El puente entre «un número que escribe» y «una persona con pacientes».
-- Va en `contacto` y no en `dueno` porque un tutor puede escribir desde el
-- celular y desde el fijo de la casa: varios contactos, una ficha.
ALTER TABLE contacto
  ADD COLUMN dueno_id uuid REFERENCES dueno(id) ON DELETE SET NULL;

CREATE INDEX idx_contacto_dueno ON contacto (dueno_id) WHERE dueno_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- El paciente
-- ---------------------------------------------------------------------
CREATE TABLE paciente (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dueno_id      uuid NOT NULL REFERENCES dueno(id) ON DELETE CASCADE,
  nombre        text NOT NULL,
  especie       text NOT NULL DEFAULT 'canino'
                  CHECK (especie IN ('canino','felino','silvestre','otro')),
  raza          text,
  sexo          text CHECK (sexo IN ('macho','hembra')),
  esterilizado  boolean,
  fecha_nac     date,
  -- Aproximado y en años, para cuando el tutor dice «tiene como 7». La
  -- fecha exacta casi nunca la saben, y pedirla frena la conversación.
  edad_aprox    numeric(4,1),
  peso_kg       numeric(6,2),
  notas         text,
  activo        boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- Regla 2 del antiduplicado.
CREATE UNIQUE INDEX idx_paciente_unico
  ON paciente (dueno_id, lower(sin_tildes(nombre)));

CREATE INDEX idx_paciente_dueno ON paciente (dueno_id);
CREATE INDEX idx_paciente_nombre_trgm ON paciente USING gin (nombre gin_trgm_ops);

CREATE TRIGGER paciente_touch BEFORE UPDATE ON paciente
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ---------------------------------------------------------------------
-- Asegurar el tutor
--
-- «Asegurar» y no «crear»: la llama el asistente en medio de una
-- conversación y tiene que ser idempotente. Si el señor ya está, devuelve
-- el que hay y le completa lo que le falte; nunca pisa un dato bueno con
-- uno nuevo vacío.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dueno_asegurar(
  p_nombre      text,
  p_celular     text DEFAULT NULL,
  p_contacto_id uuid DEFAULT NULL,
  p_correo      text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_cel   text := normalizar_celular(p_celular);
  v_id    uuid;
  v_nuevo boolean := false;
BEGIN
  IF COALESCE(trim(p_nombre), '') = '' THEN
    RAISE EXCEPTION 'Falta el nombre del tutor.';
  END IF;

  -- Si no vino celular pero sí el contacto que escribe, se usa el suyo: es
  -- el mismo número por el que llegó el mensaje.
  IF v_cel IS NULL AND p_contacto_id IS NOT NULL THEN
    SELECT celular INTO v_cel FROM contacto WHERE id = p_contacto_id;
  END IF;

  -- Camino corto: este contacto ya tiene ficha.
  IF p_contacto_id IS NOT NULL THEN
    SELECT dueno_id INTO v_id FROM contacto WHERE id = p_contacto_id;
  END IF;

  IF v_id IS NULL AND v_cel IS NOT NULL THEN
    SELECT id INTO v_id FROM dueno WHERE celular = v_cel;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO dueno (nombre, celular, correo)
    VALUES (trim(p_nombre), v_cel, NULLIF(trim(p_correo), ''))
    ON CONFLICT (celular) WHERE celular IS NOT NULL DO UPDATE
      SET nombre = CASE WHEN dueno.nombre IS NULL OR dueno.nombre = ''
                        THEN EXCLUDED.nombre ELSE dueno.nombre END
    RETURNING id INTO v_id;
    v_nuevo := true;
  ELSE
    -- Completar huecos, nunca sobrescribir.
    UPDATE dueno
       SET correo  = COALESCE(correo, NULLIF(trim(p_correo), '')),
           celular = COALESCE(celular, v_cel)
     WHERE id = v_id;
  END IF;

  IF p_contacto_id IS NOT NULL THEN
    UPDATE contacto SET dueno_id = v_id
     WHERE id = p_contacto_id AND dueno_id IS DISTINCT FROM v_id;
  END IF;

  IF v_nuevo THEN
    PERFORM auditar('dueno', v_id::text, 'crear', NULL, 'sistema', NULL,
                    jsonb_build_object('nombre', trim(p_nombre), 'celular', v_cel));
  END IF;

  RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------
-- Asegurar el paciente
--
-- El `ON CONFLICT` sobre el índice de unicidad es el antiduplicado de
-- verdad: dos mensajes que lleguen al tiempo pidiendo cita para «Luna» no
-- crean dos Lunas, porque quien decide es el índice y no un `SELECT`
-- previo que puede quedar viejo entre la lectura y la escritura.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION paciente_asegurar(
  p_dueno_id uuid,
  p_nombre   text,
  p_especie  text DEFAULT 'canino',
  p_raza     text DEFAULT NULL,
  p_sexo     text DEFAULT NULL,
  p_edad     numeric DEFAULT NULL,
  p_peso     numeric DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_id      uuid;
  v_especie text := lower(COALESCE(NULLIF(trim(p_especie), ''), 'canino'));
BEGIN
  IF COALESCE(trim(p_nombre), '') = '' THEN
    RAISE EXCEPTION 'Falta el nombre del paciente.';
  END IF;

  -- El tutor dice «perro» y «gato», no «canino» y «felino».
  v_especie := CASE
    WHEN v_especie IN ('perro','perra','canino','can') THEN 'canino'
    WHEN v_especie IN ('gato','gata','felino')         THEN 'felino'
    WHEN v_especie IN ('silvestre','exotico','exótico','no convencional') THEN 'silvestre'
    ELSE 'otro'
  END;

  INSERT INTO paciente (dueno_id, nombre, especie, raza, sexo, edad_aprox, peso_kg)
  VALUES (p_dueno_id, trim(p_nombre), v_especie,
          NULLIF(trim(p_raza), ''), NULLIF(trim(p_sexo), ''), p_edad, p_peso)
  ON CONFLICT (dueno_id, lower(sin_tildes(nombre))) DO UPDATE
    SET raza       = COALESCE(paciente.raza, EXCLUDED.raza),
        sexo       = COALESCE(paciente.sexo, EXCLUDED.sexo),
        edad_aprox = COALESCE(EXCLUDED.edad_aprox, paciente.edad_aprox),
        peso_kg    = COALESCE(EXCLUDED.peso_kg, paciente.peso_kg),
        -- La especie sí se corrige: si estaba en el valor por defecto y
        -- ahora sabemos que es un gato, era un dato supuesto, no uno dado.
        especie    = CASE WHEN paciente.especie = 'canino' AND EXCLUDED.especie <> 'canino'
                          THEN EXCLUDED.especie ELSE paciente.especie END,
        activo     = true
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------
-- Los pacientes de quien está escribiendo
--
-- La usa el asistente para no volver a preguntar lo que ya sabe. Que a un
-- tutor conocido le vuelvan a pedir el nombre de su perro en cada chat es
-- exactamente la sensación de estar hablando con una máquina.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pacientes_del_contacto(p_contacto_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'paciente_id', p.id,
           'nombre',      p.nombre,
           'especie',     p.especie,
           'raza',        p.raza,
           'sexo',        p.sexo,
           'edad',        p.edad_aprox,
           'peso_kg',     p.peso_kg) ORDER BY p.created_at), '[]'::jsonb)
    FROM contacto c
    JOIN paciente p ON p.dueno_id = c.dueno_id AND p.activo
   WHERE c.id = p_contacto_id;
$$;

-- Lo que el portal necesita para revisar duplicados a mano: tutores
-- distintos con nombres parecidos. No fusiona nada, solo los pone juntos
-- para que una persona mire.
CREATE OR REPLACE VIEW v_dueno_posible_duplicado AS
  SELECT a.id AS dueno_a, a.nombre AS nombre_a, a.celular AS celular_a,
         b.id AS dueno_b, b.nombre AS nombre_b, b.celular AS celular_b,
         similarity(a.nombre, b.nombre) AS parecido
    FROM dueno a
    JOIN dueno b ON b.id > a.id AND similarity(a.nombre, b.nombre) > 0.6
   WHERE a.activo AND b.activo
   ORDER BY 7 DESC;
