-- =====================================================================
-- Chasqui TunjoSoft — 110_prospectos.sql
-- El pipeline comercial: a quién le estamos vendiendo y en qué va.
--
-- Es `docs/CLIENTES.md` convertido en tablas. No para reemplazar el
-- documento —el documento explica por qué se decidió cada cosa y eso no cabe
-- en una fila— sino porque lo que hoy se olvida es la parte operativa: a
-- quién había que volver a escribirle el jueves.
--
-- Las cuatro cosas que guarda, y por qué cada una:
--
--   `prospecto`       — el estado. Sin esto, «¿en qué quedamos con Vetovet?»
--                       se responde buscando en un chat de WhatsApp.
--   `interaccion`     — lo que se habló y cuándo. Es la memoria del vendedor.
--   `seguimiento`     — lo que hay que hacer y para cuándo. Es lo único que
--                       de verdad se pierde hoy.
--   `propuesta`       — qué se mandó, por cuánto y en qué quedó. Es lo que
--                       después responde «¿cuánto le cotizamos?».
--   `auditoria_sitio` — la salida de `scripts/auditar.sh`, fechada. La fase 4
--                       del método exige comparar antes y después: sin
--                       guardar el antes, no hay después.
--
-- Marco legal (Ley 1581 de 2012). Estas tablas guardan datos de contacto de
-- personas. Lo que dice `CLIENTES.md` §5 aplica al esquema, no solo a la
-- conducta: no se cargan bases compradas, y la política de tratamiento de
-- datos (`config.politica_datos_url`) se publica ANTES de guardar el primer
-- contacto. `origen` existe para poder demostrar de dónde salió cada dato.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- El prospecto
-- ---------------------------------------------------------------------
CREATE TABLE prospecto (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre        text NOT NULL,
  sitio         text,
  ciudad        text,
  sector        text,             -- «veterinaria», «odontología», …

  -- El peldaño de la escalera de `CLIENTES.md` §3. No es una prioridad: es
  -- una decisión de secuencia. El 3 no se trabaja aunque parezca jugoso.
  peldano       int CHECK (peldano BETWEEN 1 AND 3),

  estado        text NOT NULL DEFAULT 'nuevo'
                  CHECK (estado IN ('nuevo', 'calificando', 'calificado',
                                    'contactado', 'reunion', 'propuesta',
                                    'ganado', 'perdido', 'descartado')),
  -- Obligatorio de hecho, no de esquema: un descarte sin motivo se repite a
  -- los seis meses porque nadie recuerda por qué se descartó.
  motivo        text,

  -- La persona. Una sola: el método dice identificar a quien decide, y
  -- guardar cinco contactos de una empresa donde decide el dueño es ruido.
  contacto_nombre  text,
  contacto_cargo   text,
  contacto_celular text,
  contacto_correo  text,
  -- De dónde salió el dato. Ley 1581: hay que poder decirlo.
  origen           text,

  -- La prueba de cliente incógnito (método, fase 0). Es el dato más
  -- persuasivo de toda la propuesta y cuesta un mensaje.
  prueba_at        timestamptz,
  prueba_resultado text CHECK (prueba_resultado IN
                     ('bot', 'persona_rapida', 'persona_lenta', 'sin_respuesta')),
  prueba_minutos   int,
  prueba_nota      text,

  -- Si el prospecto escribió al asistente, aquí queda enganchado su chat.
  -- Es lo que permite que «el que pidió la reunión por el demo» y «el que
  -- está en el pipeline» sean la misma fila.
  contacto_id   uuid REFERENCES contacto(id) ON DELETE SET NULL,

  notas         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- Un prospecto por nombre. El índice es sobre el nombre normalizado porque
-- «Orthovet», «orthovet» y «OrthoVet» son el mismo negocio y duplicarlo
-- rompe justo lo que esta tabla viene a arreglar.
CREATE UNIQUE INDEX idx_prospecto_nombre ON prospecto (normalizar(nombre));
CREATE INDEX idx_prospecto_estado ON prospecto (estado, peldano);
CREATE INDEX idx_prospecto_contacto ON prospecto (contacto_id) WHERE contacto_id IS NOT NULL;

CREATE TRIGGER prospecto_touch BEFORE UPDATE ON prospecto
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();


-- ---------------------------------------------------------------------
-- Lo que se habló
-- ---------------------------------------------------------------------
CREATE TABLE interaccion (
  id           bigserial PRIMARY KEY,
  prospecto_id uuid NOT NULL REFERENCES prospecto(id) ON DELETE CASCADE,
  tipo         text NOT NULL DEFAULT 'otro'
                 CHECK (tipo IN ('llamada', 'whatsapp', 'correo', 'reunion',
                                 'chat', 'visita', 'otro')),
  resumen      text NOT NULL,
  resultado    text,
  usuario_id   uuid REFERENCES usuario(id) ON DELETE SET NULL,
  ocurrio_at   timestamptz NOT NULL DEFAULT now(),
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_interaccion_prospecto ON interaccion (prospecto_id, ocurrio_at DESC);


-- ---------------------------------------------------------------------
-- Lo que hay que hacer
--
-- La tabla más importante del archivo. Todo lo demás documenta el pasado;
-- esta es la única que evita perder un negocio por olvido.
-- ---------------------------------------------------------------------
CREATE TABLE seguimiento (
  id           bigserial PRIMARY KEY,
  prospecto_id uuid NOT NULL REFERENCES prospecto(id) ON DELETE CASCADE,
  que          text NOT NULL,
  -- Con excusa, no «¿ya lo vio?». `CLIENTES.md` lo deja anotado como la
  -- lección del seguimiento a Abanimal: lo natural es un dato nuevo.
  excusa       text,
  para_fecha   date NOT NULL,
  hecho        boolean NOT NULL DEFAULT false,
  hecho_at     timestamptz,
  usuario_id   uuid REFERENCES usuario(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_seguimiento_pendiente ON seguimiento (para_fecha) WHERE NOT hecho;
CREATE INDEX idx_seguimiento_prospecto ON seguimiento (prospecto_id, para_fecha DESC);


-- ---------------------------------------------------------------------
-- Lo que se mandó
-- ---------------------------------------------------------------------
CREATE TABLE propuesta (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  prospecto_id uuid NOT NULL REFERENCES prospecto(id) ON DELETE CASCADE,
  enviada_at   timestamptz NOT NULL DEFAULT now(),
  -- Los códigos de `servicio`, no texto libre: así el valor de la propuesta
  -- se puede contrastar contra el catálogo del día en que se mandó.
  servicios    text[] NOT NULL DEFAULT '{}',
  valor        numeric(12,2),
  estado       text NOT NULL DEFAULT 'enviada'
                 CHECK (estado IN ('enviada', 'en_revision', 'aceptada',
                                   'rechazada', 'vencida')),
  vence_at     date,
  resultado    text,
  usuario_id   uuid REFERENCES usuario(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_propuesta_prospecto ON propuesta (prospecto_id, enviada_at DESC);

CREATE TRIGGER propuesta_touch BEFORE UPDATE ON propuesta
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();


-- ---------------------------------------------------------------------
-- La auditoría técnica del sitio
--
-- La produce `scripts/auditar.sh` sobre el HTML crudo. Se guarda fechada
-- porque la fase 4 del método vive de comparar contra la línea base: sin el
-- «antes» archivado el día cero, el «después» no demuestra nada.
--
-- `hallazgos` es jsonb y no columnas porque el script cambia y las columnas
-- no: hoy mide idioma, meta, H1, alt, schema y palabras indexables; mañana
-- medirá otra cosa y esta tabla no debería enterarse.
-- ---------------------------------------------------------------------
CREATE TABLE auditoria_sitio (
  id           bigserial PRIMARY KEY,
  prospecto_id uuid REFERENCES prospecto(id) ON DELETE SET NULL,
  url          text NOT NULL,
  corrida_at   timestamptz NOT NULL DEFAULT now(),
  http_estado  int,
  puntaje      int,            -- 0–100, como lo calcula el script
  hallazgos    jsonb NOT NULL DEFAULT '{}'::jsonb,
  resumen      text,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_auditoria_sitio_url ON auditoria_sitio (url, corrida_at DESC);
CREATE INDEX idx_auditoria_sitio_prospecto ON auditoria_sitio (prospecto_id, corrida_at DESC);


-- =====================================================================
-- Funciones de negocio
--
-- Las mismas que va a usar el portal. Las herramientas del asistente
-- (150_herramientas.sql) no hacen otra cosa que llamarlas.
-- =====================================================================

-- Busca un prospecto por nombre parcial. El asistente recibe «cómo va
-- ortovet» y hay que dar con la fila sin exigirle un UUID a nadie.
CREATE OR REPLACE FUNCTION prospecto_por_nombre(p_texto text)
RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT id FROM prospecto
   WHERE normalizar(nombre) LIKE '%' || normalizar(COALESCE(p_texto, '')) || '%'
   ORDER BY length(nombre)
   LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION prospecto_ficha(p_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'prospecto_id', p.id,
    'nombre',    p.nombre,
    'sitio',     p.sitio,
    'ciudad',    p.ciudad,
    'sector',    p.sector,
    'peldano',   p.peldano,
    'estado',    p.estado,
    'motivo',    p.motivo,
    'contacto',  jsonb_build_object('nombre',  p.contacto_nombre,
                                    'cargo',   p.contacto_cargo,
                                    'celular', p.contacto_celular,
                                    'correo',  p.contacto_correo),
    'prueba_whatsapp', CASE WHEN p.prueba_at IS NULL THEN NULL ELSE
      jsonb_build_object('cuando',    to_char(p.prueba_at AT TIME ZONE 'America/Bogota', 'YYYY-MM-DD'),
                         'resultado', p.prueba_resultado,
                         'minutos',   p.prueba_minutos,
                         'nota',      p.prueba_nota) END,
    'notas',     p.notas,
    'ultimas_interacciones', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                 'cuando',    to_char(i.ocurrio_at AT TIME ZONE 'America/Bogota', 'YYYY-MM-DD'),
                 'tipo',      i.tipo,
                 'resumen',   i.resumen,
                 'resultado', i.resultado) ORDER BY i.ocurrio_at DESC)
          FROM (SELECT * FROM interaccion WHERE prospecto_id = p.id
                 ORDER BY ocurrio_at DESC LIMIT 5) i), '[]'::jsonb),
    'seguimientos_pendientes', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                 'seguimiento_id', s.id,
                 'que',    s.que,
                 'excusa', s.excusa,
                 'para',   s.para_fecha,
                 'vencido', s.para_fecha < hoy_bogota()) ORDER BY s.para_fecha)
          FROM seguimiento s WHERE s.prospecto_id = p.id AND NOT s.hecho), '[]'::jsonb),
    'propuestas', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                 'enviada',   to_char(pr.enviada_at AT TIME ZONE 'America/Bogota', 'YYYY-MM-DD'),
                 'servicios', pr.servicios,
                 'valor',     pr.valor,
                 'estado',    pr.estado,
                 'resultado', pr.resultado) ORDER BY pr.enviada_at DESC)
          FROM propuesta pr WHERE pr.prospecto_id = p.id), '[]'::jsonb),
    'ultima_auditoria', (
        SELECT jsonb_build_object(
                 'cuando',  to_char(a.corrida_at AT TIME ZONE 'America/Bogota', 'YYYY-MM-DD'),
                 'url',     a.url,
                 'puntaje', a.puntaje,
                 'resumen', a.resumen,
                 'hallazgos', a.hallazgos)
          FROM auditoria_sitio a WHERE a.prospecto_id = p.id
         ORDER BY a.corrida_at DESC LIMIT 1))
  FROM prospecto p WHERE p.id = p_id;
$$;

CREATE OR REPLACE FUNCTION listar_prospectos(
  p_estado text DEFAULT NULL, p_peldano int DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'orden'), '[]'::jsonb) FROM (
    SELECT jsonb_build_object(
      'prospecto_id', p.id,
      'nombre',   p.nombre,
      'estado',   p.estado,
      'peldano',  p.peldano,
      'sitio',    p.sitio,
      'prueba',   p.prueba_resultado,
      'ultimo_contacto', (SELECT to_char(max(i.ocurrio_at) AT TIME ZONE 'America/Bogota', 'YYYY-MM-DD')
                            FROM interaccion i WHERE i.prospecto_id = p.id),
      'pendientes', (SELECT count(*) FROM seguimiento s
                      WHERE s.prospecto_id = p.id AND NOT s.hecho),
      'orden', lpad(COALESCE(p.peldano, 9)::text, 1, '0') || '-' || normalizar(p.nombre)) AS x
      FROM prospecto p
     WHERE (p_estado  IS NULL OR p.estado = p_estado)
       AND (p_peldano IS NULL OR p.peldano = p_peldano)
       -- Los descartados no aparecen salvo que se pidan por estado: si
       -- aparecieran siempre, la lista dejaría de leerse a los dos meses.
       AND (p_estado IS NOT NULL OR p.estado <> 'descartado')) t;
$$;

-- Lo que hay que hacer. Junta seguimientos vencidos y de los próximos días
-- con los prospectos que llevan demasiado tiempo sin que nadie los toque.
CREATE OR REPLACE FUNCTION proximas_acciones(p_dias int DEFAULT 7)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'hoy', hoy_bogota(),
    'seguimientos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'seguimiento_id', s.id,
               'prospecto',   p.nombre,
               'prospecto_id', p.id,
               'que',         s.que,
               'excusa',      s.excusa,
               'para',        s.para_fecha,
               'vencido',     s.para_fecha < hoy_bogota()) ORDER BY s.para_fecha)
        FROM seguimiento s JOIN prospecto p ON p.id = s.prospecto_id
       WHERE NOT s.hecho
         AND s.para_fecha <= hoy_bogota() + GREATEST(COALESCE(p_dias, 7), 0)), '[]'::jsonb),
    -- Un prospecto en conversación al que nadie escribe hace tres semanas
    -- está perdido y todavía no lo sabe. Es exactamente lo que hoy no se ve.
    --
    -- El GROUP BY va en una subconsulta y no aquí: `jsonb_agg` de algo que
    -- ya contiene `max()` es anidar agregados, y Postgres lo rechaza.
    'sin_movimiento', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'prospecto',         t.nombre,
               'prospecto_id',      t.id,
               'estado',            t.estado,
               'dias_sin_contacto', t.dias) ORDER BY t.dias DESC)
        FROM (SELECT p.id, p.nombre, p.estado,
                     (hoy_bogota() - COALESCE(max(i.ocurrio_at)::date,
                                              p.created_at::date)) AS dias
                FROM prospecto p
                LEFT JOIN interaccion i ON i.prospecto_id = p.id
               WHERE p.estado IN ('contactado', 'reunion', 'propuesta')
               GROUP BY p.id, p.nombre, p.estado, p.created_at
              HAVING (hoy_bogota() - COALESCE(max(i.ocurrio_at)::date,
                                              p.created_at::date)) >= 14) t
      ), '[]'::jsonb));
$$;

-- --- Escrituras -------------------------------------------------------
--
-- Devuelven jsonb con `ok` y `mensaje`, como todas las funciones de negocio
-- del proyecto: ese jsonb es lo que la conversación le muestra a la persona
-- después de que toca el botón.

CREATE OR REPLACE FUNCTION registrar_contacto(
  p_prospecto_id uuid,
  p_tipo         text,
  p_resumen      text,
  p_resultado    text DEFAULT NULL,
  p_usuario_id   uuid DEFAULT NULL,
  p_nuevo_estado text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_nombre text;
  v_id     bigint;
BEGIN
  SELECT nombre INTO v_nombre FROM prospecto WHERE id = p_prospecto_id;
  IF v_nombre IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese prospecto no existe.');
  END IF;

  INSERT INTO interaccion (prospecto_id, tipo, resumen, resultado, usuario_id)
  VALUES (p_prospecto_id, COALESCE(NULLIF(p_tipo, ''), 'otro'),
          p_resumen, NULLIF(p_resultado, ''), p_usuario_id)
  RETURNING id INTO v_id;

  IF NULLIF(p_nuevo_estado, '') IS NOT NULL THEN
    UPDATE prospecto SET estado = p_nuevo_estado WHERE id = p_prospecto_id;
  END IF;

  PERFORM auditar('interaccion', v_id::text, 'crear', p_usuario_id, 'sistema',
                  NULL, jsonb_build_object('prospecto', v_nombre, 'tipo', p_tipo));

  RETURN jsonb_build_object('ok', true, 'interaccion_id', v_id,
    'mensaje', 'Queda registrado el contacto con ' || v_nombre || '.');
END;
$$;

CREATE OR REPLACE FUNCTION agendar_seguimiento(
  p_prospecto_id uuid,
  p_que          text,
  p_para_fecha   date,
  p_excusa       text DEFAULT NULL,
  p_usuario_id   uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_nombre text;
  v_id     bigint;
BEGIN
  SELECT nombre INTO v_nombre FROM prospecto WHERE id = p_prospecto_id;
  IF v_nombre IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese prospecto no existe.');
  END IF;

  IF p_para_fecha < hoy_bogota() THEN
    RETURN jsonb_build_object('ok', false,
      'mensaje', 'Esa fecha ya pasó. Escoge una de hoy en adelante.');
  END IF;

  INSERT INTO seguimiento (prospecto_id, que, excusa, para_fecha, usuario_id)
  VALUES (p_prospecto_id, p_que, NULLIF(p_excusa, ''), p_para_fecha, p_usuario_id)
  RETURNING id INTO v_id;

  PERFORM auditar('seguimiento', v_id::text, 'crear', p_usuario_id, 'sistema',
                  NULL, jsonb_build_object('prospecto', v_nombre, 'para', p_para_fecha));

  RETURN jsonb_build_object('ok', true, 'seguimiento_id', v_id,
    'mensaje', 'Listo: ' || v_nombre || ' el ' || fecha_es(p_para_fecha::timestamptz) || '.');
END;
$$;

CREATE OR REPLACE FUNCTION cerrar_seguimiento(
  p_id bigint, p_usuario_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE seguimiento SET hecho = true, hecho_at = now()
   WHERE id = p_id AND NOT hecho;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false,
      'mensaje', 'Ese seguimiento no existe o ya estaba hecho.');
  END IF;

  PERFORM auditar('seguimiento', p_id::text, 'cerrar', p_usuario_id, 'sistema');
  RETURN jsonb_build_object('ok', true, 'mensaje', 'Marcado como hecho.');
END;
$$;

-- Alta de prospecto desde el chat público: alguien escribió al demo y dejó
-- sus datos. Es el puente entre las dos caras del sistema, y la
-- demostración entera cabe en esta función — el prospecto usa el asistente
-- que le queremos vender para entrar él mismo al pipeline.
CREATE OR REPLACE FUNCTION registrar_interes(
  p_contacto_id uuid,
  p_negocio     text,
  p_sitio       text DEFAULT NULL,
  p_ciudad      text DEFAULT NULL,
  p_sector      text DEFAULT NULL,
  p_necesita    text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_id     uuid;
  v_nombre text;
BEGIN
  IF NULLIF(trim(COALESCE(p_negocio, '')), '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Falta el nombre del negocio.');
  END IF;

  SELECT nombre INTO v_nombre FROM contacto WHERE id = p_contacto_id;

  SELECT id INTO v_id FROM prospecto WHERE normalizar(nombre) = normalizar(p_negocio);

  IF v_id IS NULL THEN
    INSERT INTO prospecto (nombre, sitio, ciudad, sector, estado, origen,
                           contacto_id, contacto_nombre, notas)
    VALUES (trim(p_negocio), NULLIF(p_sitio, ''), NULLIF(p_ciudad, ''),
            NULLIF(p_sector, ''), 'contactado',
            'escribió al asistente', p_contacto_id, v_nombre, NULLIF(p_necesita, ''))
    RETURNING id INTO v_id;
  ELSE
    -- Ya existía —lo teníamos en la lista y ahora escribió solo, que es la
    -- mejor noticia posible. Se engancha el chat y se conserva lo demás.
    UPDATE prospecto
       SET contacto_id     = COALESCE(contacto_id, p_contacto_id),
           contacto_nombre = COALESCE(contacto_nombre, v_nombre),
           sitio           = COALESCE(sitio, NULLIF(p_sitio, '')),
           estado          = CASE WHEN estado IN ('nuevo', 'calificando', 'calificado')
                                  THEN 'contactado' ELSE estado END
     WHERE id = v_id;
  END IF;

  INSERT INTO interaccion (prospecto_id, tipo, resumen, resultado)
  VALUES (v_id, 'chat',
          'Escribió al asistente de TunjoSoft.',
          NULLIF(p_necesita, ''));

  PERFORM auditar('prospecto', v_id::text, 'registrar_interes', NULL, 'sistema',
                  NULL, jsonb_build_object('negocio', p_negocio));

  RETURN jsonb_build_object('ok', true, 'prospecto_id', v_id,
    'mensaje', 'Gracias, ya quedaron tus datos. Te escribimos por este mismo chat.');
END;
$$;

-- La auditoría de un sitio, la última que haya. `scripts/auditar.sh` la
-- inserta; esto solo la lee.
CREATE OR REPLACE FUNCTION resultado_auditoria(p_texto text)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v jsonb;
BEGIN
  SELECT jsonb_build_object(
           'url',       a.url,
           'prospecto', p.nombre,
           'cuando',    to_char(a.corrida_at AT TIME ZONE 'America/Bogota', 'YYYY-MM-DD'),
           'puntaje',   a.puntaje,
           'resumen',   a.resumen,
           'hallazgos', a.hallazgos,
           -- La comparación contra la corrida anterior es el entregable de
           -- la fase 4. Se calcula aquí porque es donde están las dos filas.
           'anterior', (SELECT jsonb_build_object(
                                 'cuando',  to_char(b.corrida_at AT TIME ZONE 'America/Bogota', 'YYYY-MM-DD'),
                                 'puntaje', b.puntaje)
                          FROM auditoria_sitio b
                         WHERE b.url = a.url AND b.corrida_at < a.corrida_at
                         ORDER BY b.corrida_at DESC LIMIT 1))
    INTO v
    FROM auditoria_sitio a
    LEFT JOIN prospecto p ON p.id = a.prospecto_id
   WHERE a.url ILIKE '%' || COALESCE(p_texto, '') || '%'
      OR normalizar(COALESCE(p.nombre, '')) LIKE '%' || normalizar(COALESCE(p_texto, '')) || '%'
   ORDER BY a.corrida_at DESC
   LIMIT 1;

  IF v IS NULL THEN
    RETURN jsonb_build_object('ok', false,
      'error', 'No hay auditorías guardadas para eso. Se corren con scripts/auditar.sh.');
  END IF;

  RETURN jsonb_build_object('ok', true, 'datos', v);
END;
$$;
