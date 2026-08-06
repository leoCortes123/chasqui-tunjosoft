-- =====================================================================
-- Chasqui TunjoSoft — 070_mantenimiento.sql
-- La limpieza diaria. Heredado de `088_mantenimiento.sql` de Chasqui Pet.
--
-- Cuatro tablas crecen para siempre si nadie las poda, y ninguna aporta
-- nada pasadas unas semanas:
--
--   · `telegram_update` guarda cada update recibido para descartar los
--     repetidos. Telegram reintenta durante horas, no durante meses.
--   · `conversacion_estado` guarda flujos a medias, con su propio
--     `expira_at`. Lo vencido no lo lee nadie.
--   · `auth_challenge` guarda intentos de ingreso al portal, TTL de cinco
--     minutos.
--   · `ia_accion_pendiente` guarda propuestas que nadie confirmó. Una
--     propuesta sin resolver a los diez minutos ya no se puede ejecutar.
--
-- Lo que NO se purga nunca:
--
--   · `evento_auditoria` — el registro de lo que pasó. Su valor está
--     justamente en que nadie, ni un job, pueda quitarle filas.
--   · `mensaje` — lo que de verdad se dijo por el canal. Es la prueba de
--     qué contestó el bot, y la conversación completa por paciente es parte
--     de lo que se le ofrece a la clínica. `ia_mensaje` sí se poda: esa es
--     solo la memoria de trabajo del modelo, y `ia_historial` ya la corta
--     al leer.
--
-- La función es SECURITY DEFINER (se marca en 900_grants.sql) porque la
-- aplicación no tiene DELETE sobre `telegram_update`: puede purgar a través
-- de esta puerta concreta y por ninguna otra.
-- =====================================================================

SET client_min_messages = warning;

INSERT INTO config (clave, valor, tipo, descripcion, editable_ui) VALUES
  ('retencion_updates_dias', '7',  'entero',
   'Días que se conservan los updates de Telegram recibidos, para descartar repetidos', true),
  ('retencion_tareas_dias',  '30', 'entero',
   'Días que se conservan las tareas ya completadas de la cola', true),
  ('retencion_memoria_dias', '90', 'entero',
   'Días que se conserva la memoria de conversación del asistente', true)
ON CONFLICT (clave) DO NOTHING;

CREATE OR REPLACE FUNCTION mantenimiento_diario()
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_updates int;
  v_estados int;
  v_challenges int;
  v_tareas int;
  v_sesiones int;
  v_propuestas int;
  v_memoria int;
BEGIN
  DELETE FROM telegram_update
   WHERE recibido_at < now() - make_interval(days => config_int('retencion_updates_dias', 7));
  GET DIAGNOSTICS v_updates = ROW_COUNT;

  DELETE FROM conversacion_estado WHERE expira_at < now() - interval '1 day';
  GET DIAGNOSTICS v_estados = ROW_COUNT;

  DELETE FROM auth_challenge WHERE expira_at < now() - interval '1 day';
  GET DIAGNOSTICS v_challenges = ROW_COUNT;

  DELETE FROM tarea_async
   WHERE estado = 'completada'
     AND completada_at < now() - make_interval(days => config_int('retencion_tareas_dias', 30));
  GET DIAGNOSTICS v_tareas = ROW_COUNT;

  -- Las propuestas vencidas se marcan expiradas antes de borrarlas: entre
  -- las dos cosas hay un día en el que el panel todavía puede explicar por
  -- qué una acción no se ejecutó.
  UPDATE ia_accion_pendiente
     SET estado = 'expirada', resuelta_at = now()
   WHERE estado = 'pendiente' AND expira_at < now();

  DELETE FROM ia_accion_pendiente
   WHERE estado <> 'pendiente' AND created_at < now() - interval '30 days';
  GET DIAGNOSTICS v_propuestas = ROW_COUNT;

  DELETE FROM ia_mensaje
   WHERE created_at < now() - make_interval(days => config_int('retencion_memoria_dias', 90));
  GET DIAGNOSTICS v_memoria = ROW_COUNT;

  -- Las sesiones vencidas se marcan revocadas, no se borran: la lista de
  -- «dónde estuvo abierta mi sesión» es justamente lo que hace útil la
  -- notificación de ingreso.
  UPDATE sesion SET revocada = true, revocada_at = now()
   WHERE NOT revocada AND expires_at < now();
  GET DIAGNOSTICS v_sesiones = ROW_COUNT;

  RETURN jsonb_build_object(
    'fecha', hoy_bogota(),
    'updates_purgados', v_updates,
    'conversaciones_purgadas', v_estados,
    'challenges_purgados', v_challenges,
    'tareas_purgadas', v_tareas,
    'propuestas_purgadas', v_propuestas,
    'memoria_purgada', v_memoria,
    'sesiones_vencidas', v_sesiones);
END;
$$;
