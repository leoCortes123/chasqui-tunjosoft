-- =====================================================================
-- Chasqui TunjoSoft — 110_estudios.sql
-- Catálogo de estudios, tarifas y preparación.
--
-- Por qué los precios NO están en el prompt
-- -----------------------------------------
-- Un precio en el prompt es un precio que el modelo puede redondear, mezclar
-- o actualizar mal cuando cambie. Aquí una función los calcula y el modelo
-- solo repite lo que le devuelve. La regla de tarifa de Abanimal depende del
-- día —ecografía abdominal $172.000 de lunes a sábado, $187.000 domingos y
-- festivos— y eso ya es demasiada aritmética para dejársela a un modelo.
--
-- Precio base, no precio final
-- ----------------------------
-- Cada estudio tiene un valor de referencia que el asistente SÍ entrega: un
-- cliente que pregunta cuánto vale y recibe «depende» se va a otra clínica.
-- Pero el valor final lo define el profesional según el caso —sedación, más
-- de una región, contraste, tamaño del paciente—, y eso se dice en la misma
-- frase, no en letra chica.
--
-- ⚠️ ORIGEN DE LAS CIFRAS — leer antes de mostrar esto a un cliente
--
-- Solo UN precio está confirmado: la ecografía abdominal, que aparece en la
-- conversación real de agosto de 2026 con la línea 315 418 4245
-- (`docs/conversacion-real-abanimal.md`).
--
-- Todos los demás son ESTIMACIONES, marcadas con `estimado = true`. Se
-- calcularon a partir de las tarifas públicas de la Clínica Veterinaria de la
-- Universidad de La Salle (ecografía $150.000, radiografía primera vista
-- $74.000, vista adicional $34.000), escaladas por la misma proporción que
-- separa esa ecografía de la de Abanimal (×1,15), y ajustadas por
-- complejidad. Sirven para que el demo funcione; NO sirven para cotizarle a
-- un cliente real.
--
-- `SELECT * FROM v_tarifa_por_confirmar;` lista lo que falta confirmar. Con
-- la lista de precios real de Abanimal, esto son quince UPDATE y se acabó.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Festivos de Colombia (Ley 51 de 1983, con los lunes trasladados)
--
-- Sin esta tabla la cotización se equivoca: un domingo y un festivo cuestan
-- lo mismo, y adivinar cuál lunes es festivo no es algo que se le pida a un
-- modelo de lenguaje.
-- ---------------------------------------------------------------------
CREATE TABLE festivo_colombia (
  fecha  date PRIMARY KEY,
  nombre text NOT NULL
);

INSERT INTO festivo_colombia (fecha, nombre) VALUES
  -- 2026
  ('2026-01-01', 'Año Nuevo'),
  ('2026-01-12', 'Reyes Magos'),
  ('2026-03-23', 'San José'),
  ('2026-04-02', 'Jueves Santo'),
  ('2026-04-03', 'Viernes Santo'),
  ('2026-05-01', 'Día del Trabajo'),
  ('2026-05-18', 'Ascensión'),
  ('2026-06-08', 'Corpus Christi'),
  ('2026-06-15', 'Sagrado Corazón'),
  ('2026-06-29', 'San Pedro y San Pablo'),
  ('2026-07-20', 'Día de la Independencia'),
  ('2026-08-07', 'Batalla de Boyacá'),
  ('2026-08-17', 'Asunción de la Virgen'),
  ('2026-10-12', 'Día de la Raza'),
  ('2026-11-02', 'Todos los Santos'),
  ('2026-11-16', 'Independencia de Cartagena'),
  ('2026-12-08', 'Inmaculada Concepción'),
  ('2026-12-25', 'Navidad'),
  -- 2027
  ('2027-01-01', 'Año Nuevo'),
  ('2027-01-11', 'Reyes Magos'),
  ('2027-03-22', 'San José'),
  ('2027-03-25', 'Jueves Santo'),
  ('2027-03-26', 'Viernes Santo'),
  ('2027-05-01', 'Día del Trabajo'),
  ('2027-05-10', 'Ascensión'),
  ('2027-05-31', 'Corpus Christi'),
  ('2027-06-07', 'Sagrado Corazón'),
  ('2027-07-05', 'San Pedro y San Pablo'),
  ('2027-07-20', 'Día de la Independencia'),
  ('2027-08-07', 'Batalla de Boyacá'),
  ('2027-08-16', 'Asunción de la Virgen'),
  ('2027-10-18', 'Día de la Raza'),
  ('2027-11-01', 'Todos los Santos'),
  ('2027-11-15', 'Independencia de Cartagena'),
  ('2027-12-08', 'Inmaculada Concepción'),
  ('2027-12-25', 'Navidad');

-- 'domingo_festivo' o 'lunes_sabado'. Es el eje de la regla de tarifa.
CREATE OR REPLACE FUNCTION tipo_dia(p_fecha date DEFAULT NULL)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN extract(isodow FROM COALESCE(p_fecha, hoy_bogota())) = 7
      OR EXISTS (SELECT 1 FROM festivo_colombia
                  WHERE fecha = COALESCE(p_fecha, hoy_bogota()))
    THEN 'domingo_festivo'
    ELSE 'lunes_sabado'
  END;
$$;

-- ---------------------------------------------------------------------
-- El catálogo
-- ---------------------------------------------------------------------
CREATE TABLE estudio (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo            text UNIQUE NOT NULL,
  nombre            text NOT NULL,
  modalidad         text NOT NULL
                      CHECK (modalidad IN ('ecografia','tomografia','radiologia',
                                           'endoscopia','intervencionismo','consulta',
                                           'laboratorio')),
  -- Lo que el asistente dice cuando preguntan «¿y eso para qué es?».
  descripcion       text,
  duracion_min      int  NOT NULL DEFAULT 30,
  requiere_cita     boolean NOT NULL DEFAULT true,
  -- El TAC es uno solo y no se puede sobreagendar. Se usa en la agenda.
  equipo            text,
  activo            boolean NOT NULL DEFAULT true,
  orden             int  NOT NULL DEFAULT 100,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER estudio_touch BEFORE UPDATE ON estudio
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TABLE tarifa (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  estudio_id   uuid NOT NULL REFERENCES estudio(id) ON DELETE CASCADE,
  tipo_dia     text NOT NULL CHECK (tipo_dia IN ('lunes_sabado','domingo_festivo')),
  valor        numeric(12,2) NOT NULL CHECK (valor >= 0),
  -- true = cifra derivada de referencias del mercado, no confirmada por la
  -- clínica. El asistente lo dice, y el portal lo muestra en la lista de
  -- pendientes. Un precio inventado que se presenta como firme es la peor
  -- forma de perder un cliente.
  estimado     boolean NOT NULL DEFAULT true,
  vigente_desde date NOT NULL DEFAULT hoy_bogota(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (estudio_id, tipo_dia)
);

CREATE TRIGGER tarifa_touch BEFORE UPDATE ON tarifa
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- Reglas de preparación. La primera y más importante: el ayuno.
CREATE TABLE preparacion (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  estudio_id  uuid NOT NULL REFERENCES estudio(id) ON DELETE CASCADE,
  -- Lo que se le dice al tutor, literal. Igual que las urgencias: es
  -- información clínica y no la redacta el modelo.
  texto       text NOT NULL,
  ayuno_horas int,
  -- Horas antes de la cita a las que se manda el recordatorio. El aviso de
  -- las 8 pm de la noche anterior no es opcional: si el paciente rompe el
  -- ayuno se pierde el estudio y el cupo.
  aviso_horas_antes int DEFAULT 12,
  UNIQUE (estudio_id)
);

-- ---------------------------------------------------------------------
-- Los estudios
-- ---------------------------------------------------------------------
INSERT INTO estudio (codigo, nombre, modalidad, duracion_min, equipo, orden, descripcion) VALUES
('eco_abdominal', 'Ecografía abdominal', 'ecografia', 45, 'ecografo_1', 10,
 'Revisa hígado, bazo, riñones, vejiga, intestino y demás órganos del abdomen. Es el estudio con el que se empieza cuando hay vómito, diarrea, pérdida de peso, problemas para orinar o dolor abdominal.'),

('eco_gestacional', 'Ecografía gestacional', 'ecografia', 30, 'ecografo_1', 20,
 'Confirma preñez, cuenta fetos y revisa que estén vivos y bien. Se puede hacer desde los 25 días.'),

('eco_doppler', 'Ecografía Doppler vascular', 'ecografia', 60, 'ecografo_1', 30,
 'Mira cómo circula la sangre por un vaso o un órgano. Se usa para trombos, shunts hepáticos y masas con mucha vascularización.'),

('ecocardiograma', 'Ecocardiografía', 'ecografia', 60, 'ecografo_1', 40,
 'Ecografía del corazón: mide cámaras, válvulas y qué tan bien bombea. Es el estudio de un soplo, una tos crónica o un paciente que se cansa.'),

('eco_cervical', 'Ecografía de cuello', 'ecografia', 30, 'ecografo_1', 50,
 'Tiroides, paratiroides, ganglios y masas del cuello.'),

('eco_musculo', 'Ecografía musculoesquelética', 'ecografia', 45, 'ecografo_1', 60,
 'Tendones, músculos y articulaciones. Útil en cojeras que no se explican con radiografía.'),

('eco_toracica', 'Ecografía torácica', 'ecografia', 45, 'ecografo_1', 70,
 'Tórax fuera del corazón: líquido, masas y pleura.'),

('rx_simple', 'Radiografía (una proyección)', 'radiologia', 20, 'rayos_x', 100,
 'Placa digital de una región. Huesos, tórax o abdomen. Casi siempre se toman dos proyecciones para ver bien.'),

('rx_dos', 'Radiografía (dos proyecciones)', 'radiologia', 30, 'rayos_x', 110,
 'Lo habitual: dos vistas de la misma región, que es lo que permite interpretar de verdad.'),

('rx_contraste', 'Radiografía de contraste', 'radiologia', 60, 'rayos_x', 120,
 'Con medio de contraste, para ver esófago, estómago, intestino o vías urinarias. Toma varias placas a lo largo de un rato.'),

('rx_dental', 'Radiología dental', 'radiologia', 30, 'rayos_x', 130,
 'Placas de piezas dentales y sus raíces. Requiere sedación.'),

('tac_simple', 'Tomografía (TAC) simple', 'tomografia', 45, 'tac', 200,
 'Cortes finos de una región, en tres dimensiones. Ve lo que la radiografía no: fracturas complejas, oído, nariz, columna, tórax detallado. Requiere sedación o anestesia.'),

('tac_contraste', 'Tomografía (TAC) con contraste', 'tomografia', 75, 'tac', 210,
 'TAC con medio de contraste endovenoso, para masas, vasos y estadificación de tumores. Requiere sedación o anestesia.'),

('endoscopia_dx', 'Endoscopia diagnóstica', 'endoscopia', 60, 'endoscopio', 300,
 'Cámara flexible para ver por dentro esófago, estómago o vías respiratorias, y tomar biopsias. Requiere anestesia.'),

('endoscopia_tx', 'Endoscopia terapéutica', 'endoscopia', 90, 'endoscopio', 310,
 'La misma vía, para sacar un cuerpo extraño sin abrir. Requiere anestesia.'),

('puncion_eco', 'Punción guiada por ecografía', 'intervencionismo', 45, 'ecografo_1', 400,
 'Toma de muestra de un órgano o una masa con aguja fina, guiada en tiempo real. Evita una cirugía para llegar al diagnóstico.'),

('biopsia_tac', 'Biopsia guiada por tomografía', 'intervencionismo', 90, 'tac', 410,
 'Muestra de una lesión profunda, guiada por TAC. Requiere anestesia.'),

('consulta_general', 'Consulta general', 'consulta', 30, NULL, 500,
 'Valoración con el médico. Es por donde se empieza cuando no se sabe todavía qué estudio hace falta.'),

('consulta_especialista', 'Consulta con especialista', 'consulta', 45, NULL, 510,
 'Valoración con medicina interna, cirugía u oncología, según el caso.'),

('segunda_opinion', 'Segunda opinión de imágenes', 'consulta', 30, NULL, 520,
 'Lectura por parte de nuestros radiólogos de un estudio hecho en otro lado. No hay que traer al paciente.');

-- ---------------------------------------------------------------------
-- Las tarifas
--
-- La regla: domingos y festivos, recargo. Solo la ecografía abdominal tiene
-- las dos cifras confirmadas; en el resto el recargo se aplicó con la misma
-- proporción ($187.000 / $172.000 ≈ 1,087).
-- ---------------------------------------------------------------------
INSERT INTO tarifa (estudio_id, tipo_dia, valor, estimado)
SELECT e.id, v.tipo_dia, v.valor, v.estimado
  FROM (VALUES
    -- El único confirmado, y por eso el único con estimado = false.
    ('eco_abdominal',         'lunes_sabado',    172000, false),
    ('eco_abdominal',         'domingo_festivo', 187000, false),

    ('eco_gestacional',       'lunes_sabado',    120000, true),
    ('eco_gestacional',       'domingo_festivo', 130000, true),
    ('eco_doppler',           'lunes_sabado',    230000, true),
    ('eco_doppler',           'domingo_festivo', 250000, true),
    ('ecocardiograma',        'lunes_sabado',    250000, true),
    ('ecocardiograma',        'domingo_festivo', 272000, true),
    ('eco_cervical',          'lunes_sabado',    140000, true),
    ('eco_cervical',          'domingo_festivo', 152000, true),
    ('eco_musculo',           'lunes_sabado',    160000, true),
    ('eco_musculo',           'domingo_festivo', 174000, true),
    ('eco_toracica',          'lunes_sabado',    170000, true),
    ('eco_toracica',          'domingo_festivo', 185000, true),

    ('rx_simple',             'lunes_sabado',     85000, true),
    ('rx_simple',             'domingo_festivo',  92000, true),
    ('rx_dos',                'lunes_sabado',    125000, true),
    ('rx_dos',                'domingo_festivo', 136000, true),
    ('rx_contraste',          'lunes_sabado',    260000, true),
    ('rx_contraste',          'domingo_festivo', 283000, true),
    ('rx_dental',             'lunes_sabado',    190000, true),
    ('rx_dental',             'domingo_festivo', 207000, true),

    ('tac_simple',            'lunes_sabado',    650000, true),
    ('tac_simple',            'domingo_festivo', 707000, true),
    ('tac_contraste',         'lunes_sabado',    850000, true),
    ('tac_contraste',         'domingo_festivo', 924000, true),

    ('endoscopia_dx',         'lunes_sabado',    520000, true),
    ('endoscopia_dx',         'domingo_festivo', 565000, true),
    ('endoscopia_tx',         'lunes_sabado',    780000, true),
    ('endoscopia_tx',         'domingo_festivo', 848000, true),

    ('puncion_eco',           'lunes_sabado',    240000, true),
    ('puncion_eco',           'domingo_festivo', 261000, true),
    ('biopsia_tac',           'lunes_sabado',    920000, true),
    ('biopsia_tac',           'domingo_festivo', 1000000, true),

    ('consulta_general',      'lunes_sabado',     85000, true),
    ('consulta_general',      'domingo_festivo',  95000, true),
    ('consulta_especialista', 'lunes_sabado',    130000, true),
    ('consulta_especialista', 'domingo_festivo', 141000, true),
    ('segunda_opinion',       'lunes_sabado',    120000, true),
    ('segunda_opinion',       'domingo_festivo', 130000, true)
  ) AS v(codigo, tipo_dia, valor, estimado)
  JOIN estudio e ON e.codigo = v.codigo;

-- Lo que falta que confirme la clínica.
CREATE OR REPLACE VIEW v_tarifa_por_confirmar AS
  SELECT e.codigo, e.nombre, t.tipo_dia, t.valor
    FROM tarifa t JOIN estudio e ON e.id = t.estudio_id
   WHERE t.estimado
   ORDER BY e.orden, t.tipo_dia;

-- ---------------------------------------------------------------------
-- Preparación
--
-- El ayuno es la razón de ser del recordatorio de las 8 pm: si el paciente
-- come, se pierde el estudio y se pierde el cupo.
-- ---------------------------------------------------------------------
INSERT INTO preparacion (estudio_id, texto, ayuno_horas, aviso_horas_antes)
SELECT e.id, v.texto, v.horas, v.aviso
  FROM (VALUES
    ('eco_abdominal',
     'Ayuno de 8 horas, sin comida ni líquidos. El agua tampoco: llena el estómago de gas y tapa la imagen. Si es posible, que no haga pipí en la hora antes de venir — la vejiga llena se ve mucho mejor.',
     8, 12),
    ('eco_doppler',
     'Ayuno de 8 horas, sin comida ni líquidos.', 8, 12),
    ('eco_toracica',
     'Ayuno de 8 horas, sin comida ni líquidos.', 8, 12),
    ('rx_contraste',
     'Ayuno de 12 horas. El estudio toma varias placas a lo largo de un par de horas, así que calcula tiempo.',
     12, 14),
    ('rx_dental',
     'Ayuno de 8 horas: requiere sedación.', 8, 12),
    ('tac_simple',
     'Ayuno de 8 horas: se hace con sedación o anestesia. Trae los estudios previos que tengas.',
     8, 12),
    ('tac_contraste',
     'Ayuno de 8 horas: se hace con sedación o anestesia. Si el paciente tiene problemas de riñón, avísanos antes — el contraste necesita revisión previa.',
     8, 12),
    ('endoscopia_dx',
     'Ayuno de 12 horas, sin comida ni líquidos. Se hace bajo anestesia.', 12, 14),
    ('endoscopia_tx',
     'Ayuno de 12 horas, sin comida ni líquidos. Se hace bajo anestesia.', 12, 14),
    ('puncion_eco',
     'Ayuno de 8 horas. Traer exámenes de coagulación si el médico los pidió.', 8, 12),
    ('biopsia_tac',
     'Ayuno de 8 horas: se hace bajo anestesia. Traer exámenes de coagulación.', 8, 12),
    ('ecocardiograma',
     'No requiere ayuno. Ven con tiempo: el paciente tiene que estar tranquilo para medir bien el corazón.',
     NULL, 12),
    ('eco_gestacional',
     'No requiere ayuno.', NULL, 12),
    ('eco_cervical',
     'No requiere ayuno.', NULL, 12),
    ('eco_musculo',
     'No requiere ayuno.', NULL, 12),
    ('rx_simple',
     'No requiere ayuno, salvo que el médico haya pedido sedación.', NULL, 12),
    ('rx_dos',
     'No requiere ayuno, salvo que el médico haya pedido sedación.', NULL, 12),
    ('consulta_general',
     'No requiere preparación. Trae los exámenes previos que tengas.', NULL, 12),
    ('consulta_especialista',
     'No requiere preparación. Trae la historia y los estudios previos.', NULL, 12),
    ('segunda_opinion',
     'No hay que traer al paciente. Necesitamos las imágenes y el informe del estudio original.',
     NULL, 12)
  ) AS v(codigo, texto, horas, aviso)
  JOIN estudio e ON e.codigo = v.codigo;

-- ---------------------------------------------------------------------
-- Cotizar
--
-- Devuelve todo lo que el asistente necesita para responder de una: precio
-- del día que preguntaron, si ese día tiene recargo y por qué, la
-- preparación, y si la cifra está confirmada o no.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cotizar_estudio(p_codigo text, p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  e        estudio%ROWTYPE;
  v_fecha  date := COALESCE(p_fecha, hoy_bogota());
  v_tipo   text := tipo_dia(v_fecha);
  v_tarifa tarifa%ROWTYPE;
  v_prep   preparacion%ROWTYPE;
  v_festivo text;
BEGIN
  SELECT * INTO e FROM estudio WHERE codigo = p_codigo AND activo;
  IF e.id IS NULL THEN
    RETURN jsonb_build_object('ok', false,
      'error', format('No existe un estudio con código %s. Usa listar_estudios.', p_codigo));
  END IF;

  SELECT * INTO v_tarifa FROM tarifa
   WHERE estudio_id = e.id AND tipo_dia = v_tipo;

  SELECT * INTO v_prep FROM preparacion WHERE estudio_id = e.id;
  SELECT nombre INTO v_festivo FROM festivo_colombia WHERE fecha = v_fecha;

  RETURN jsonb_build_object(
    'ok', true,
    'estudio', e.nombre,
    'codigo', e.codigo,
    'que_es', e.descripcion,
    'duracion_min', e.duracion_min,
    'fecha_consultada', v_fecha,
    'tipo_dia', v_tipo,
    'es_domingo_o_festivo', v_tipo = 'domingo_festivo',
    'festivo', v_festivo,
    'valor', v_tarifa.valor,
    'valor_texto', pesos(v_tarifa.valor),
    'precio_confirmado', NOT COALESCE(v_tarifa.estimado, true),
    -- El modelo lee esto y lo dice con sus palabras. Se le manda la
    -- instrucción junto al dato para que no se le olvide la mitad.
    'como_decirlo',
      CASE WHEN COALESCE(v_tarifa.estimado, true)
        THEN 'Da el valor como precio de referencia y aclara EN LA MISMA FRASE que '
             'el valor final lo confirma el profesional según el caso, porque puede '
             'necesitar sedación, contraste o más de una región. No lo presentes '
             'como precio cerrado.'
        ELSE 'Este precio está confirmado. Dilo con seguridad, y menciona que si el '
             'caso necesita sedación o más de una región, el médico lo ajusta.'
      END,
    'preparacion', v_prep.texto,
    'ayuno_horas', v_prep.ayuno_horas,
    'requiere_cita', e.requiere_cita);
END;
$$;

-- El catálogo, para que el modelo sepa qué códigos existen antes de cotizar.
CREATE OR REPLACE FUNCTION listar_estudios(p_texto text DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'codigo', codigo, 'nombre', nombre, 'modalidad', modalidad,
           'que_es', descripcion, 'duracion_min', duracion_min) ORDER BY orden), '[]'::jsonb)
    FROM estudio
   WHERE activo
     AND (COALESCE(p_texto, '') = ''
          OR normalizar(nombre) LIKE '%' || normalizar(p_texto) || '%'
          OR normalizar(COALESCE(descripcion, '')) LIKE '%' || normalizar(p_texto) || '%'
          OR normalizar(modalidad) LIKE '%' || normalizar(p_texto) || '%');
$$;
