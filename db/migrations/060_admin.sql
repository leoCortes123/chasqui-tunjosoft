-- =====================================================================
-- Chasqui TunjoSoft — 060_admin.sql
-- Lo que el portal necesita para administrarse: usuarios, roles, permisos,
-- configuración, auditoría, cola de tareas y salud del sistema.
--
-- Heredado de `085_admin.sql` de Chasqui Pet, sin el catálogo de
-- medicamentos, las tarifas ni el libro de movimientos de inventario: eso
-- era dominio y este archivo es núcleo. Las tarifas de estudios vuelven en
-- `110_estudios.sql`, con otras reglas.
--
-- Todo pasa por `exigir_permiso`. Que el portal esconda un botón es
-- comodidad; que la función lo rechace es la seguridad.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Rango por defecto de un listado con fechas: del primero del mes a hoy.
-- Es lo que el administrador quiere ver el 90 % de las veces que abre uno.
-- Venían de `080_reportes.sql`, que no se copió; las usa `auditoria_listado`.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rango_desde(p_desde date) RETURNS date
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(p_desde, date_trunc('month', hoy_bogota())::date);
$$;

CREATE OR REPLACE FUNCTION rango_hasta(p_hasta date) RETURNS date
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(p_hasta, hoy_bogota());
$$;

-- ---------------------------------------------------------------------
-- Usuarios, roles y permisos
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION usuarios_listado()
RETURNS TABLE (usuario_id uuid, nombre text, telegram_user_id bigint,
               telefono text, roles text[], permisos_extra text[],
               activo boolean, ultimo_acceso timestamptz, sesiones bigint)
LANGUAGE sql STABLE AS $$
  SELECT u.id, u.nombre_completo, u.telegram_user_id, u.telefono,
         COALESCE(array_agg(DISTINCT ur.rol_codigo)
                  FILTER (WHERE ur.rol_codigo IS NOT NULL), '{}'),
         COALESCE(array_agg(DISTINCT up.permiso_codigo)
                  FILTER (WHERE up.otorgado), '{}'),
         u.activo, u.ultimo_acceso_at,
         (SELECT count(*) FROM sesion s
           WHERE s.usuario_id = u.id AND NOT s.revocada AND s.expires_at > now())
    FROM usuario u
    LEFT JOIN usuario_rol ur ON ur.usuario_id = u.id
    LEFT JOIN usuario_permiso up ON up.usuario_id = u.id
   GROUP BY u.id
   ORDER BY u.activo DESC, u.nombre_completo;
$$;

CREATE OR REPLACE FUNCTION roles_disponibles()
RETURNS TABLE (codigo text, nombre text, descripcion text, nivel int, permisos bigint)
LANGUAGE sql STABLE AS $$
  SELECT r.codigo, r.nombre, r.descripcion, r.nivel,
         (SELECT count(*) FROM rol_permiso rp WHERE rp.rol_codigo = r.codigo)
    FROM rol r ORDER BY r.nivel DESC;
$$;

CREATE OR REPLACE FUNCTION permisos_disponibles()
RETURNS TABLE (codigo text, modulo text, descripcion text, roles text[])
LANGUAGE sql STABLE AS $$
  SELECT p.codigo, p.modulo, p.descripcion,
         COALESCE(array_agg(rp.rol_codigo ORDER BY rp.rol_codigo)
                  FILTER (WHERE rp.rol_codigo IS NOT NULL), '{}')
    FROM permiso p
    LEFT JOIN rol_permiso rp ON rp.permiso_codigo = p.codigo
   GROUP BY p.codigo, p.modulo, p.descripcion
   ORDER BY p.modulo, p.codigo;
$$;

CREATE OR REPLACE FUNCTION asignar_roles(
  p_actor_id uuid, p_usuario_id uuid, p_roles text[], p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_antes text[]; v_rol text;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'usuarios.gestionar');

  IF p_roles IS NULL OR array_length(p_roles, 1) IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Cada persona necesita al menos un rol.');
  END IF;

  -- El superadmin sólo lo reparte un superadmin, y nadie se quita el
  -- suyo: quedarse sin superadmin deja el sistema sin quien lo arregle.
  IF 'superadmin' = ANY (p_roles)
     AND NOT EXISTS (SELECT 1 FROM usuario_rol
                      WHERE usuario_id = p_actor_id AND rol_codigo = 'superadmin') THEN
    RETURN jsonb_build_object('ok', false, 'mensaje',
             'Sólo un superadmin puede otorgar el rol de superadmin.');
  END IF;

  IF p_actor_id = p_usuario_id AND NOT ('superadmin' = ANY (p_roles))
     AND EXISTS (SELECT 1 FROM usuario_rol
                  WHERE usuario_id = p_actor_id AND rol_codigo = 'superadmin') THEN
    RETURN jsonb_build_object('ok', false, 'mensaje',
             'No puedes quitarte a ti mismo el rol de superadmin.');
  END IF;

  SELECT array_agg(rol_codigo ORDER BY rol_codigo) INTO v_antes
    FROM usuario_rol WHERE usuario_id = p_usuario_id;

  DELETE FROM usuario_rol WHERE usuario_id = p_usuario_id AND NOT (rol_codigo = ANY (p_roles));

  FOREACH v_rol IN ARRAY p_roles LOOP
    INSERT INTO usuario_rol (usuario_id, rol_codigo, asignado_por)
    VALUES (p_usuario_id, v_rol, p_actor_id)
    ON CONFLICT DO NOTHING;
  END LOOP;

  PERFORM auditar('usuario', p_usuario_id::text, 'asignar_roles', p_actor_id, p_canal,
                  jsonb_build_object('roles', to_jsonb(v_antes)),
                  jsonb_build_object('roles', to_jsonb(p_roles)));

  RETURN jsonb_build_object('ok', true, 'roles', to_jsonb(p_roles));
END;
$$;

-- La excepción individual de §4: el auxiliar al que el admin le habilita
-- descuentos o entradas de inventario, sin inventar un rol nuevo.
CREATE OR REPLACE FUNCTION ajustar_permiso_usuario(
  p_actor_id uuid, p_usuario_id uuid, p_permiso text,
  p_otorgado boolean, p_motivo text DEFAULT NULL, p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'usuarios.gestionar');

  IF NOT EXISTS (SELECT 1 FROM permiso WHERE codigo = p_permiso) THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese permiso no existe.');
  END IF;

  INSERT INTO usuario_permiso (usuario_id, permiso_codigo, otorgado, motivo, asignado_por)
  VALUES (p_usuario_id, p_permiso, p_otorgado, NULLIF(trim(COALESCE(p_motivo,'')), ''), p_actor_id)
  ON CONFLICT (usuario_id, permiso_codigo) DO UPDATE
    SET otorgado = EXCLUDED.otorgado,
        motivo = EXCLUDED.motivo,
        asignado_por = EXCLUDED.asignado_por;

  PERFORM auditar('usuario', p_usuario_id::text,
                  CASE WHEN p_otorgado THEN 'otorgar_permiso' ELSE 'revocar_permiso' END,
                  p_actor_id, p_canal, NULL,
                  jsonb_build_object('permiso', p_permiso), p_motivo);

  RETURN jsonb_build_object('ok', true);
END;
$$;

-- Devuelve la excepción a lo que diga el rol: quitar la fila, no poner
-- otra que diga lo contrario.
CREATE OR REPLACE FUNCTION limpiar_permiso_usuario(
  p_actor_id uuid, p_usuario_id uuid, p_permiso text, p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'usuarios.gestionar');

  DELETE FROM usuario_permiso
   WHERE usuario_id = p_usuario_id AND permiso_codigo = p_permiso;

  PERFORM auditar('usuario', p_usuario_id::text, 'limpiar_permiso', p_actor_id, p_canal,
                  NULL, jsonb_build_object('permiso', p_permiso));
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION reactivar_usuario(
  p_actor_id uuid, p_usuario_id uuid, p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'usuarios.gestionar');
  UPDATE usuario SET activo = true WHERE id = p_usuario_id;
  PERFORM auditar('usuario', p_usuario_id::text, 'reactivar', p_actor_id, p_canal);
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ---------------------------------------------------------------------
-- Configuración operativa (§11.2)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION config_listado()
RETURNS TABLE (clave text, valor text, tipo text, descripcion text, editable boolean)
LANGUAGE sql STABLE AS $$
  SELECT clave, valor, tipo, descripcion, editable_ui
    FROM config ORDER BY editable_ui DESC, clave;
$$;

CREATE OR REPLACE FUNCTION guardar_config(
  p_actor_id uuid, p_clave text, p_valor text, p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_tipo text; v_antes text; v_editable boolean;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'config.editar');

  SELECT tipo, valor, editable_ui INTO v_tipo, v_antes, v_editable
    FROM config WHERE clave = p_clave FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa clave de configuración no existe.');
  END IF;

  -- Lo no editable —la zona horaria, el símbolo de moneda— cambia el
  -- comportamiento de todo el sistema y no se toca desde una pantalla.
  IF NOT v_editable THEN
    RETURN jsonb_build_object('ok', false, 'mensaje',
             'Esa clave no se edita desde el portal.');
  END IF;

  IF v_tipo = 'entero' AND p_valor !~ '^-?[0-9]+$' THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese valor tiene que ser un número entero.');
  END IF;
  IF v_tipo = 'booleano' AND lower(p_valor) NOT IN ('true','false') THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese valor tiene que ser verdadero o falso.');
  END IF;

  UPDATE config SET valor = p_valor WHERE clave = p_clave;

  PERFORM auditar('config', p_clave, 'editar', p_actor_id, p_canal,
                  jsonb_build_object('valor', v_antes),
                  jsonb_build_object('valor', p_valor));

  RETURN jsonb_build_object('ok', true, 'clave', p_clave, 'valor', p_valor);
END;
$$;

-- Tarifas: lo que cobra la clínica. Se edita aquí y el bot lo ofrece sin
-- desplegar nada.
CREATE OR REPLACE FUNCTION guardar_consultorio(
  p_actor_id uuid, p_consultorio_id uuid, p_nombre text,
  p_orden int DEFAULT NULL, p_activo boolean DEFAULT NULL,
  p_sede_id uuid DEFAULT NULL, p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_id uuid := p_consultorio_id;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'config.editar');

  IF v_id IS NULL THEN
    INSERT INTO consultorio (sede_id, nombre, orden)
    VALUES (COALESCE(p_sede_id, (SELECT id FROM sede WHERE activa ORDER BY created_at LIMIT 1)),
            trim(p_nombre), COALESCE(p_orden, 99))
    RETURNING id INTO v_id;
  ELSE
    UPDATE consultorio
       SET nombre = COALESCE(NULLIF(trim(p_nombre), ''), nombre),
           orden  = COALESCE(p_orden, orden),
           activo = COALESCE(p_activo, activo)
     WHERE id = v_id;
  END IF;

  PERFORM auditar('consultorio', v_id::text, 'guardar', p_actor_id, p_canal);
  RETURN jsonb_build_object('ok', true, 'consultorio_id', v_id);
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ya hay un consultorio con ese nombre.');
END;
$$;

-- ---------------------------------------------------------------------
-- Auditoría y libro de movimientos (§11.2)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria_listado(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL,
  p_entidad text DEFAULT NULL, p_usuario_id uuid DEFAULT NULL,
  p_limite int DEFAULT 200
)
RETURNS TABLE (id bigint, cuando timestamptz, entidad text, entidad_id text,
               accion text, usuario text, canal text, detalle text,
               antes jsonb, despues jsonb)
LANGUAGE sql STABLE AS $$
  SELECT e.id, e.created_at, e.entidad, e.entidad_id, e.accion,
         COALESCE(u.nombre_completo, '—'), e.canal, e.detalle,
         e.datos_antes, e.datos_despues
    FROM evento_auditoria e
    LEFT JOIN usuario u ON u.id = e.usuario_id
   WHERE (e.created_at AT TIME ZONE 'America/Bogota')::date
         BETWEEN rango_desde(p_desde) AND rango_hasta(p_hasta)
     AND (p_entidad IS NULL OR p_entidad = '' OR e.entidad = p_entidad)
     AND (p_usuario_id IS NULL OR e.usuario_id = p_usuario_id)
   ORDER BY e.created_at DESC
   LIMIT GREATEST(p_limite, 1);
$$;

CREATE OR REPLACE FUNCTION auditoria_entidades()
RETURNS TABLE (entidad text, eventos bigint)
LANGUAGE sql STABLE AS $$
  SELECT entidad, count(*) FROM evento_auditoria
   GROUP BY entidad ORDER BY count(*) DESC;
$$;
-- ---------------------------------------------------------------------
-- Bandeja de tareas fallidas (§2.2.4)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tareas_listado(p_estado text DEFAULT 'fallida', p_limite int DEFAULT 100)
RETURNS TABLE (id bigint, tipo text, estado text, intentos int, max_intentos int,
               proxima_ejecucion timestamptz, ultimo_error text,
               payload jsonb, created_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT t.id, t.tipo, t.estado, t.intentos, t.max_intentos,
         t.proxima_ejecucion, t.ultimo_error, t.payload, t.created_at
    FROM tarea_async t
   WHERE p_estado IS NULL OR p_estado = '' OR t.estado = p_estado
   ORDER BY t.created_at DESC
   LIMIT GREATEST(p_limite, 1);
$$;

CREATE OR REPLACE FUNCTION resumen_tareas()
RETURNS TABLE (estado text, tareas bigint, mas_antigua timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT estado, count(*), min(created_at) FROM tarea_async
   GROUP BY estado ORDER BY count(*) DESC;
$$;

-- Reintentar es devolver la tarea a la cola con el contador a cero. No se
-- edita el payload: si estaba mal, la tarea se descarta y el hecho se
-- vuelve a provocar desde donde salió.
CREATE OR REPLACE FUNCTION reintentar_tarea(p_actor_id uuid, p_tarea_id bigint)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_estado text;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'sistema.operar');

  SELECT estado INTO v_estado FROM tarea_async WHERE id = p_tarea_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa tarea ya no está.');
  END IF;
  IF v_estado = 'procesando' THEN
    RETURN jsonb_build_object('ok', false, 'mensaje',
             'Esa tarea la tiene un worker ahora mismo.');
  END IF;

  UPDATE tarea_async
     SET estado = 'pendiente', intentos = 0, proxima_ejecucion = now(), ultimo_error = NULL
   WHERE id = p_tarea_id;

  PERFORM auditar('tarea_async', p_tarea_id::text, 'reintentar', p_actor_id, 'web');
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION descartar_tarea(
  p_actor_id uuid, p_tarea_id bigint, p_motivo text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'sistema.operar');

  UPDATE tarea_async
     SET estado = 'completada', completada_at = now(),
         resultado = jsonb_build_object('descartada', true, 'motivo', p_motivo)
   WHERE id = p_tarea_id AND estado <> 'procesando';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'No se pudo descartar esa tarea.');
  END IF;

  PERFORM auditar('tarea_async', p_tarea_id::text, 'descartar', p_actor_id, 'web',
                  NULL, NULL, p_motivo);
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ---------------------------------------------------------------------
-- Salud del sistema, para el /health del portal y la vista de operación
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION salud_sistema()
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'hora', now(),
    'fecha_operativa', hoy_bogota(),
    'tareas', jsonb_build_object(
      'pendientes',  (SELECT count(*) FROM tarea_async WHERE estado = 'pendiente'),
      'procesando',  (SELECT count(*) FROM tarea_async WHERE estado = 'procesando'),
      'fallidas',    (SELECT count(*) FROM tarea_async WHERE estado = 'fallida'),
      -- Una tarea pendiente muy vieja significa que el worker no está
      -- corriendo, aunque el contenedor diga que sí.
      'atraso_seg',  COALESCE((SELECT round(extract(epoch FROM (now() - min(proxima_ejecucion))))
                                 FROM tarea_async
                                WHERE estado = 'pendiente' AND proxima_ejecucion < now()), 0)),
    'telegram', jsonb_build_object(
      'ultimo_update', (SELECT max(recibido_at) FROM telegram_update),
      'sin_procesar',  (SELECT count(*) FROM telegram_update
                         WHERE NOT procesado AND recibido_at > now() - interval '1 day')),
    'sesiones_activas', (SELECT count(*) FROM sesion
                          WHERE NOT revocada AND expires_at > now()),
    -- El pulso propio de este proyecto: si hay hilos esperando a una persona,
    -- el sistema está sano pero la operación no.
    'conversaciones', jsonb_build_object(
      'abiertas',  (SELECT count(*) FROM conversacion WHERE estado = 'abierta'),
      'con_humano', (SELECT count(*) FROM conversacion
                      WHERE estado = 'abierta' AND atendida_por_humano)));
$$;
