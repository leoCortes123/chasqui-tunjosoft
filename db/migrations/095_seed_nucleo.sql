-- =====================================================================
-- Chasqui TunjoSoft — 095_seed_nucleo.sql
-- Lo mínimo para que el sistema arranque: configuración genérica, una sede
-- y el superadmin inicial.
--
-- Aquí no hay nada del negocio. Ni un estudio, ni una tarifa, ni un
-- horario: eso es dominio y vive en `810_seed_operativo.sql`. La sede se
-- crea sin nombre real porque el núcleo necesita que exista una —`usuario`
-- y `cita` cuelgan de ella—, no porque sepa cuál es.
-- =====================================================================

SET client_min_messages = warning;

-- `nombre_negocio` y no `nombre_clinica`: la clave se llamaba así en
-- Chasqui Assistant y era el ejemplo perfecto de fuga de vocabulario —el
-- núcleo no tiene por qué saber que un cliente es una clínica. Renombrarla
-- aquí, con el volumen todavía vacío, cuesta cero.
INSERT INTO config (clave, valor, tipo, descripcion, editable_ui) VALUES
  ('nombre_negocio',     'el negocio',     'texto',
   'Nombre con el que el asistente se refiere al negocio', true),
  ('ciudad',             'Bogotá',         'texto',
   'Ciudad de operación, cuando no hay sede con dirección', true),
  ('zona_horaria',       'America/Bogota', 'texto',
   'Zona horaria operativa del negocio', false),
  ('moneda_simbolo',     '$',              'texto',
   'Símbolo de moneda en mensajes y cotizaciones', false),
  ('moneda_nombre',      'peso colombiano (COP)', 'texto',
   'Cómo se nombra la moneda en el prompt del asistente', false),
  ('politica_datos_url', '',               'texto',
   'URL de la política de tratamiento de datos (Ley 1581 de 2012)', true)
ON CONFLICT (clave) DO NOTHING;

-- Una sede, sin datos reales. El dominio la completa; el portal la edita.
INSERT INTO sede (nombre, ciudad, direccion)
SELECT 'Sede principal', 'Bogotá', NULL
WHERE NOT EXISTS (SELECT 1 FROM sede);

-- Sin consultorios sembrados: la tabla se conserva porque `sede_id` acompaña
-- a media base y cuesta treinta líneas, pero nace vacía.

-- ---------------------------------------------------------------------
-- Superadmin inicial. El telegram_user_id llega por variable de entorno;
-- la invocación con el ID real vive en `900_superadmin.sh`.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crear_superadmin_inicial(
  p_telegram_user_id bigint,
  p_nombre text DEFAULT 'Superadministrador'
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  IF p_telegram_user_id IS NULL OR p_telegram_user_id = 0 THEN
    RAISE NOTICE 'Sin SUPERADMIN_TELEGRAM_USER_ID: no se creó el superadmin inicial.';
    RETURN NULL;
  END IF;

  SELECT id INTO v_id FROM usuario WHERE telegram_user_id = p_telegram_user_id;

  IF v_id IS NULL THEN
    INSERT INTO usuario (telegram_user_id, nombre_completo, sede_id)
    VALUES (p_telegram_user_id, p_nombre,
            (SELECT id FROM sede WHERE activa ORDER BY created_at LIMIT 1))
    RETURNING id INTO v_id;
  END IF;

  INSERT INTO usuario_rol (usuario_id, rol_codigo) VALUES (v_id, 'superadmin')
  ON CONFLICT DO NOTHING;

  PERFORM auditar('usuario', v_id::text, 'seed_superadmin', v_id, 'sistema');
  RETURN v_id;
END;
$$;
