-- =====================================================================
-- Chasqui TunjoSoft — 100_comercial.sql
-- El catálogo de lo que vende la agencia, con sus precios.
--
-- Por qué es una tabla y no un párrafo del prompt
-- -----------------------------------------------
-- Porque un precio en el prompt es un precio que el modelo puede redondear,
-- confundir de etapa o promediar entre dos rangos. Y aquí el interlocutor es
-- alguien que está evaluando comprarnos un asistente: si el nuestro se
-- equivoca en su propio precio, la demostración terminó.
--
-- Regla del producto, sin excepciones: **ningún valor sale de la memoria del
-- modelo.** Las etapas A–E y la operación mensual son filas; el asistente
-- llama a `cotizar_servicio` o no dice cifras.
--
-- La columna que más importa
-- --------------------------
-- `disponible`. `CLIENTES.md` deja anotado el riesgo: el contestador
-- telefónico con voz está cotizado en una propuesta y **no existe**. Un
-- servicio con `disponible = false` sigue en la tabla —se cotizó, hay
-- historia— pero `listar_servicios` no lo devuelve y el asistente no puede
-- ofrecerlo. Es la diferencia entre una nota en un documento que alguien
-- recordará y un dato que el sistema hace cumplir.
-- =====================================================================

SET client_min_messages = warning;

CREATE TABLE servicio (
  codigo        text PRIMARY KEY,
  nombre        text NOT NULL,
  -- 'etapa'       — un peldaño de la escalera A–E, se vende una vez
  -- 'recurrente'  — mensualidad
  -- 'complemento' — se suma a una etapa, no se vende solo
  categoria     text NOT NULL DEFAULT 'etapa'
                  CHECK (categoria IN ('etapa', 'recurrente', 'complemento')),
  -- La letra de la escalera, cuando la tiene. Ordena la conversación mucho
  -- mejor que el código: «vamos por la A» se entiende sin explicar nada.
  etapa         text,
  resumen       text NOT NULL,   -- una frase: qué es. La lee el modelo.
  incluye       text,            -- qué entrega, en viñetas cortas
  -- Rango, no precio. Casi todo lo que se vende aquí es un rango honesto, y
  -- decir un rango es más creíble que decir una cifra exacta que después
  -- cambia. Si min = max, se presenta como valor único.
  valor_min     numeric(12,2),
  valor_max     numeric(12,2),
  unidad        text NOT NULL DEFAULT 'proyecto'
                  CHECK (unidad IN ('proyecto', 'mes')),
  duracion      text,            -- «30 días», «3 a 6 meses»
  requiere      text REFERENCES servicio(codigo),  -- qué hay que tener antes
  -- Se puede vender hoy. false = existe en la tabla por historia, pero el
  -- asistente no lo ve.
  disponible    boolean NOT NULL DEFAULT true,
  -- Nota interna sobre por qué no está disponible, o qué falta. No se le
  -- muestra a nadie de afuera.
  nota_interna  text,
  orden         int NOT NULL DEFAULT 100,
  activo        boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER servicio_touch BEFORE UPDATE ON servicio
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE INDEX idx_servicio_orden ON servicio (orden) WHERE activo AND disponible;


-- ---------------------------------------------------------------------
-- Cómo se dice un precio
--
-- Se arma aquí y no en el prompt, por la misma razón que el precio: la forma
-- de presentarlo es parte del precio. «Desde $2.400.000» y «entre $12 y $18
-- millones, según el alcance» son dos promesas distintas.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION servicio_precio_texto(s servicio)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN s.valor_min IS NULL AND s.valor_max IS NULL THEN 'se cotiza según el alcance'
    WHEN s.valor_max IS NULL OR s.valor_max = s.valor_min THEN
      pesos(s.valor_min) || CASE WHEN s.unidad = 'mes' THEN ' al mes' ELSE '' END
    ELSE
      'entre ' || pesos(s.valor_min) || ' y ' || pesos(s.valor_max)
      || CASE WHEN s.unidad = 'mes' THEN ' al mes' ELSE '' END
      || ', según el alcance'
  END;
$$;


-- ---------------------------------------------------------------------
-- Las dos herramientas de catálogo, como funciones de negocio
--
-- Devuelven jsonb porque las va a leer el modelo, pero no son «funciones de
-- IA»: el portal las usará igual. El asistente no tiene una vía privilegiada
-- a la base, tiene la misma que todos.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION listar_servicios(p_texto text DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'codigo',   s.codigo,
           'nombre',   s.nombre,
           'etapa',    s.etapa,
           'que_es',   s.resumen,
           'duracion', s.duracion,
           'precio',   servicio_precio_texto(s),
           'requiere', s.requiere) ORDER BY s.orden), '[]'::jsonb)
    FROM servicio s
   WHERE s.activo AND s.disponible
     AND (p_texto IS NULL
          OR normalizar(s.nombre)  LIKE '%' || normalizar(p_texto) || '%'
          OR normalizar(s.resumen) LIKE '%' || normalizar(p_texto) || '%'
          OR normalizar(COALESCE(s.incluye, '')) LIKE '%' || normalizar(p_texto) || '%'
          OR normalizar(s.codigo)  LIKE '%' || normalizar(p_texto) || '%');
$$;

CREATE OR REPLACE FUNCTION cotizar_servicio(p_codigo text)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE s servicio%ROWTYPE;
BEGIN
  SELECT * INTO s FROM servicio WHERE codigo = p_codigo AND activo AND disponible;

  IF s.codigo IS NULL THEN
    RETURN jsonb_build_object('ok', false,
      'error', format('No existe un servicio con código «%s», o no está a la venta. '
                      'Usa listar_servicios y escoge uno de los que devuelva.',
                      COALESCE(p_codigo, '(vacío)')));
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'datos', jsonb_build_object(
      'codigo',    s.codigo,
      'nombre',    s.nombre,
      'etapa',     s.etapa,
      'que_es',    s.resumen,
      'incluye',   s.incluye,
      'duracion',  s.duracion,
      'valor_min', s.valor_min,
      'valor_max', s.valor_max,
      'precio',    servicio_precio_texto(s),
      'requiere',  s.requiere,
      -- Igual que `como_decirlo` en el vertical veterinario: la instrucción
      -- viaja pegada al dato para que no haya que acordarse de ella.
      'como_decirlo',
        'Di el precio con estas palabras: «' || servicio_precio_texto(s) || '». '
        'Es un valor de referencia hasta que haya una propuesta firmada; dilo en '
        'la misma frase, no como advertencia al final. Nunca lo redondees ni lo '
        'conviertas a otra unidad.'));
END;
$$;
