-- =====================================================================
-- Chasqui TunjoSoft — 130_salidas.sql
-- Lo que no puede depender de que el modelo se acuerde.
--
-- Es el patrón de `130_triaje.sql` del vertical veterinario, sin las filas
-- clínicas. El patrón —y esto es lo que se lleva de vuelta a Assistant
-- cuando esté probado— tiene tres partes y ninguna es opcional:
--
--   1. **La detección ocurre con un SELECT, antes de que el modelo vea el
--      mensaje.** Probado en la fase 1 de Assistant: ante un caso grave el
--      modelo respondió impecable, dijo que escalaba… y no escaló. Un límite
--      que depende de que el modelo llame una herramienta es un límite que se
--      pierde el día que se distrae.
--   2. **La respuesta es texto literal de una tabla**, recitado sin
--      reescribir. Un texto fijo se puede revisar y aprobar; una redacción
--      distinta cada vez, no.
--   3. **Corta el turno.** No se encola nada al modelo. Si el mensaje traía
--      además otra consulta, se pierde y la persona la repite: es un costo
--      real y aceptado.
--
-- Qué se recita aquí, en una agencia
-- ----------------------------------
-- Allá eran urgencias médicas. Aquí son **las promesas**. `METODO.md`, anexo
-- «lo que no se promete», es una lista de cinco cosas que un vendedor
-- entusiasmado dice sin querer y que después no se pueden cumplir: la
-- primera posición en Google, plazos, aparecer en ChatGPT, comprar enlaces,
-- volumen de ventas.
--
-- Un modelo entrenado para sonar servicial dice que sí. Cuesta un contrato
-- y la reputación, y frente a un prospecto que está evaluando comprarnos un
-- asistente, que el nuestro prometa de más es la peor demostración posible.
-- Por eso la respuesta a «¿me garantizan el primer lugar?» es una fila, no
-- una generación.
--
-- La asimetría es la misma que allá: sobra un falso positivo —se recita una
-- aclaración que quizá no hacía falta— y no puede faltar ninguno.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Las respuestas literales
-- ---------------------------------------------------------------------
CREATE TABLE respuesta_literal (
  codigo       text PRIMARY KEY,
  nombre       text NOT NULL,
  -- Lo que el bot dice, palabra por palabra. Se escribe para leerse en un
  -- celular: frases cortas, y lo que NO se promete antes de lo que sí.
  texto        text NOT NULL,
  -- Mayor = gana cuando un mensaje dispara varias.
  prioridad    int  NOT NULL DEFAULT 50,
  -- true = además le pasa el chat a una persona. Casi nunca: aclarar qué no
  -- se promete es parte de la conversación, no un motivo para interrumpirla.
  escala       boolean NOT NULL DEFAULT false,
  aprobada_por text,
  aprobada_at  timestamptz,
  fuente       text,
  activa       boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER respuesta_literal_touch BEFORE UPDATE ON respuesta_literal
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- Los términos que la disparan. Normalizados —sin tildes, minúsculas—
-- porque la gente escribe como escribe. Varias filas por respuesta.
CREATE TABLE termino_literal (
  termino  text PRIMARY KEY,
  codigo   text NOT NULL REFERENCES respuesta_literal(codigo) ON DELETE CASCADE,
  activo   boolean NOT NULL DEFAULT true
);

CREATE INDEX idx_termino_literal_codigo ON termino_literal (codigo);

-- La vista que dice qué falta firmar. En el vertical veterinario esto lo
-- firmaba un médico; aquí lo firma quien responde por lo que se promete.
CREATE OR REPLACE VIEW v_literal_sin_aprobar AS
  SELECT codigo, nombre, fuente, created_at
    FROM respuesta_literal
   WHERE activa AND aprobada_por IS NULL
   ORDER BY prioridad DESC, codigo;


-- ---------------------------------------------------------------------
-- La detección
--
-- El término se busca entre bordes de palabra para que «garantia» no salte
-- dentro de otra palabra.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION detectar_literal(p_texto text)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_txt text := normalizar(COALESCE(p_texto, ''));
  c     record;
BEGIN
  IF v_txt = '' THEN RETURN NULL; END IF;

  SELECT rl.codigo, rl.nombre, rl.texto, rl.escala, t.termino
    INTO c
    FROM termino_literal t
    JOIN respuesta_literal rl ON rl.codigo = t.codigo
   WHERE t.activo AND rl.activa
     AND v_txt ~ ('(^|[^a-z0-9])' || t.termino || '([^a-z0-9]|$)')
   ORDER BY rl.prioridad DESC, length(t.termino) DESC
   LIMIT 1;

  IF c.codigo IS NULL THEN RETURN NULL; END IF;

  RETURN jsonb_build_object(
    'codigo', c.codigo, 'nombre', c.nombre,
    'termino', c.termino, 'texto', c.texto, 'escala', c.escala);
END;
$$;


-- ---------------------------------------------------------------------
-- «ASESOR»: la salida a humano
--
-- No pasa por el modelo, por la misma razón de siempre. Las frases tienen
-- que ser inequívocas: la primera versión de Assistant incluía «humano» y
-- «persona real», y con eso «¿eres una persona real o un bot?» escalaba el
-- chat en vez de responderse.
-- ---------------------------------------------------------------------
INSERT INTO config (clave, valor, tipo, descripcion, editable_ui) VALUES
  ('palabras_asesor',
   'asesor,operador,quiero hablar con alguien,hablar con una persona,'
   'con un humano,con una persona,pasame con alguien,pasame con una persona,'
   'necesito hablar con alguien,atencion humana,hablar con el dueno,'
   'hablar con leonardo',
   'texto', 'Frases que hacen que el bot entregue el chat a una persona, separadas por coma', true),

  ('texto_es_bot',
   'Soy un asistente virtual, no una persona. Te lo digo de una porque '
   'preguntaste directo.' || E'\n\n' ||
   'De hecho soy el mismo producto del que estamos hablando: esto que estás '
   'usando es lo que hacemos. Los precios y los horarios que te doy salen del '
   'sistema, no me los invento.' || E'\n\n' ||
   'Si prefieres hablar con una persona, escribe ASESOR y te paso.' || E'\n\n' ||
   '¿Seguimos?',
   'texto', 'Lo que responde el bot cuando le preguntan de frente si es un bot', true),

  ('frases_es_bot',
   'eres un bot,eres bot,sos un bot,un bot,eres una maquina,eres un robot,'
   'eres una ia,eres un programa,eres un algoritmo,eres una persona real,'
   'eres real,eres humano,eres una persona o un bot,persona o un bot,'
   'hablo con un bot,hablo con una maquina,hablo con un robot,'
   'hablo con una persona real,esto es un bot,esto es un robot,'
   'estoy hablando con un bot,eres un contestador,eres automatico',
   'texto', 'Frases que hacen que el bot admita que es un bot, separadas por coma', true)
ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor;

CREATE OR REPLACE FUNCTION frase_en_config(p_texto text, p_clave text)
RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_txt text := normalizar(COALESCE(p_texto, ''));
  p     text;
BEGIN
  IF v_txt = '' THEN RETURN false; END IF;

  FOREACH p IN ARRAY string_to_array(normalizar(config_txt(p_clave, '')), ',') LOOP
    p := trim(p);
    IF p <> '' AND v_txt ~ ('(^|[^a-z0-9])' || p || '([^a-z0-9]|$)') THEN
      RETURN true;
    END IF;
  END LOOP;

  RETURN false;
END;
$$;

CREATE OR REPLACE FUNCTION pide_asesor(p_texto text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT frase_en_config(p_texto, 'palabras_asesor');
$$;

CREATE OR REPLACE FUNCTION pregunta_si_es_bot(p_texto text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT frase_en_config(p_texto, 'frases_es_bot');
$$;


-- ---------------------------------------------------------------------
-- El enganche: se reemplaza `asistente_recibir` de 040_asistente.sql
--
-- Es el mismo cuerpo con un bloque nuevo delante, y va ANTES de todo lo
-- demás: antes del rate limit y antes de mirar si la IA está encendida. Lo
-- que se promete o no se promete no lo puede decidir un límite de mensajes
-- por hora ni una API caída.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION asistente_recibir(
  p_conversacion_id uuid,
  p_texto text,
  p_id_externo text DEFAULT NULL,
  p_tipo text DEFAULT 'texto',
  p_payload jsonb DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  c         conversacion%ROWTYPE;
  v_msg_id  bigint;
  v_literal jsonb;
  v_texto   text;
BEGIN
  SELECT * INTO c FROM conversacion WHERE id = p_conversacion_id;
  IF c.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa conversación no existe.');
  END IF;

  -- Idempotencia: el canal reintenta. Si este mensaje ya se registró, se
  -- descarta entero.
  v_msg_id := mensaje_registrar(p_conversacion_id, 'entrante', p_texto,
                                p_tipo, p_payload, p_id_externo);
  IF v_msg_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'duplicado', true, 'responde', false);
  END IF;

  -- ---------------------------------------------------------------
  -- Respuestas literales. Lo primero, siempre.
  -- ---------------------------------------------------------------
  v_literal := detectar_literal(p_texto);

  IF v_literal IS NOT NULL AND NOT c.atendida_por_humano THEN
    v_texto := v_literal->>'texto';

    IF COALESCE((v_literal->>'escala')::boolean, false) THEN
      PERFORM escalar_a_humano(p_conversacion_id,
                               'respuesta literal: ' || (v_literal->>'nombre'));
    END IF;

    -- El texto sale por la cola y no por `asistente_responder`: en Telegram y
    -- WhatsApp hay que hablar con una API, y eso no cabe en el segundo que el
    -- webhook tiene para contestar. Prioridad 20, la más alta que se usa.
    PERFORM encolar_tarea('enviar_texto',
      jsonb_build_object('conversacion_id', p_conversacion_id, 'texto', v_texto),
      20, NULL, 0, 5);

    -- En la memoria del modelo sí queda: si la conversación sigue, tiene que
    -- saber que esto ya se dijo y no contradecirlo.
    PERFORM ia_registrar(p_conversacion_id, 'user', to_jsonb(p_texto));
    PERFORM ia_registrar(p_conversacion_id, 'assistant', to_jsonb(v_texto));

    RETURN jsonb_build_object('ok', true, 'responde', false, 'motivo', 'respuesta_literal',
                              'literal', v_literal->>'codigo', 'texto', v_texto);
  END IF;

  -- ---------------------------------------------------------------
  -- «ASESOR». Pedir una persona no puede depender de que el modelo
  -- entienda que se la están pidiendo.
  -- ---------------------------------------------------------------
  IF pide_asesor(p_texto) AND NOT c.atendida_por_humano THEN
    PERFORM escalar_a_humano(p_conversacion_id, 'pidió hablar con una persona');
    v_texto := 'Listo, ya le avisé a una persona del equipo. Te escribe por este '
               'mismo chat en un momento.';
    PERFORM encolar_tarea('enviar_texto',
      jsonb_build_object('conversacion_id', p_conversacion_id, 'texto', v_texto),
      20, NULL, 0, 5);
    PERFORM ia_registrar(p_conversacion_id, 'assistant', to_jsonb(v_texto));
    RETURN jsonb_build_object('ok', true, 'responde', false, 'motivo', 'pidio_asesor');
  END IF;

  -- ---------------------------------------------------------------
  -- «¿Eres un bot?». La misma reja, por la misma razón, y aquí más que en
  -- ningún otro vertical: quien pregunta está evaluando comprar un bot.
  -- Mentirle es perder la venta y merecerlo.
  --
  -- En Assistant el prompt lo pedía desde el principio y el modelo contestó
  -- «soy una persona real, tranquilo» dos de cada tres veces. No es un
  -- descuido del prompt: la instrucción compite con otras veinte sobre sonar
  -- natural, y sonar natural es justo lo que empuja hacia la mentira.
  -- ---------------------------------------------------------------
  IF pregunta_si_es_bot(p_texto) AND NOT c.atendida_por_humano THEN
    v_texto := config_txt('texto_es_bot');

    PERFORM encolar_tarea('enviar_texto',
      jsonb_build_object('conversacion_id', p_conversacion_id, 'texto', v_texto),
      20, NULL, 0, 5);
    PERFORM ia_registrar(p_conversacion_id, 'user', to_jsonb(p_texto));
    PERFORM ia_registrar(p_conversacion_id, 'assistant', to_jsonb(v_texto));

    RETURN jsonb_build_object('ok', true, 'responde', false,
                              'motivo', 'pregunta_si_es_bot', 'texto', v_texto);
  END IF;

  -- El hilo está en manos de una persona: se guarda lo que dijo el cliente
  -- para que el panel lo muestre, y el bot se queda callado.
  IF NOT bot_responde(p_conversacion_id) THEN
    RETURN jsonb_build_object('ok', true, 'responde', false,
                              'motivo', 'atendida_por_humano');
  END IF;

  IF NOT ia_disponible(c.contacto_id) THEN
    RETURN jsonb_build_object('ok', true, 'responde', false, 'motivo', 'ia_apagada');
  END IF;

  -- Un chat secuestrado no puede quemar la cuenta del modelo en una noche.
  IF NOT consumir_rate_limit('ia:' || c.contacto_id::text,
                             config_int('ia_limite_hora', 60), 3600) THEN
    RETURN jsonb_build_object('ok', true, 'responde', false, 'motivo', 'rate_limit',
      'texto', 'Hemos hablado mucho en la última hora. Dame un momento, '
               'o escribe ASESOR si necesitas atención inmediata.');
  END IF;

  PERFORM ia_registrar(p_conversacion_id, 'user', to_jsonb(p_texto));

  PERFORM encolar_tarea('chasqui_responder',
    jsonb_build_object('conversacion_id', p_conversacion_id,
                       'contacto_id', c.contacto_id,
                       'canal', c.canal),
    5,          -- prioridad alta: hay alguien esperando frente al teléfono
    NULL, 0, 2  -- 2 intentos: si el modelo falla dos veces, mejor avisar que insistir
  );

  RETURN jsonb_build_object('ok', true, 'responde', true, 'mensaje_id', v_msg_id);
END;
$$;


-- ---------------------------------------------------------------------
-- La última reja: la herramienta para escalar
--
-- La primera es la lista de términos; la segunda, «ASESOR». Esta es para lo
-- que ninguna de las dos vio.
--
-- **Por qué no pide confirmación**, siendo que cambia estado y la regla del
-- proyecto es que escribir se confirma con un botón: esa regla protege a la
-- persona de una acción que no pidió. Pasarle el chat a un humano no le hace
-- daño a nadie, y esperar un toque de botón para hacerlo sí. La excepción es
-- esta y ninguna más.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION h_pedir_asesor(
  p_contacto_id uuid, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_conv uuid;
BEGIN
  -- El hilo abierto de este contacto: la herramienta no recibe el id de la
  -- conversación porque el modelo no tiene por qué manejarlo, ni por qué
  -- poder escalar el hilo de otro.
  SELECT id INTO v_conv
    FROM conversacion
   WHERE contacto_id = p_contacto_id AND estado = 'abierta'
   ORDER BY ultima_actividad_at DESC
   LIMIT 1;

  IF v_conv IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No hay una conversación abierta.');
  END IF;

  PERFORM escalar_a_humano(
    v_conv, COALESCE(NULLIF(trim(p_args->>'motivo'), ''), 'el asistente pidió ayuda'));

  RETURN jsonb_build_object('ok', true, 'datos', jsonb_build_object(
    'escalada', true,
    'nota', 'Ya se le avisó a una persona. Dile en una sola frase que ya '
            'avisaste y que le escriben por este chat. No preguntes nada más.'));
END;
$$;

INSERT INTO ia_herramienta (nombre, audiencia, escribe, critica, orden,
                            fn_leer, descripcion, esquema) VALUES
('pedir_asesor', 'publica', false, false, 5, 'h_pedir_asesor',
 'Le pasa la conversación a una persona del equipo. Úsala en cuanto veas '
 'cualquiera de estas cosas: te piden un dato que no tienes y que importa; '
 'quieren negociar el precio o el alcance; el proyecto se sale de lo que '
 'vendemos; la persona está molesta o insiste en algo que ya le dijiste que '
 'no puedes; o pide hablar con alguien. Ante la duda, úsala. '
 'NO preguntes «¿quieres que te pase con un asesor?» — llámala y avísale que '
 'ya lo hiciste. '
 'Después de usarla, dilo en una frase corta y no sigas preguntando cosas.',
 '{"type":"object","properties":{"motivo":{"type":"string","description":"Por qué escalas, en pocas palabras y en español. Lo lee el equipo, no el cliente."}},"required":["motivo"]}'::jsonb)
ON CONFLICT (nombre) DO UPDATE
  SET audiencia = EXCLUDED.audiencia, escribe = EXCLUDED.escribe,
      fn_leer = EXCLUDED.fn_leer,
      descripcion = EXCLUDED.descripcion, esquema = EXCLUDED.esquema,
      orden = EXCLUDED.orden;
