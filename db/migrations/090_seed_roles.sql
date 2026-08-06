-- =====================================================================
-- Chasqui TunjoSoft — 090_seed_roles.sql
-- Roles y permisos como datos. Cambiar quién puede hacer qué es un UPDATE,
-- no un despliegue.
--
-- Por qué va aquí y no al final
-- -----------------------------
-- El catálogo de herramientas (`150_herramientas.sql`) tiene una FK a
-- `permiso`. Desde un volumen vacío, sembrar los permisos después aborta la
-- inicialización en la primera herramienta con permiso, y todo lo que viene
-- detrás —grants, superadmin, seeds— no llega a correr.
--
-- La regla que sale de ahí: **los permisos se siembran antes que cualquier
-- catálogo que los referencie.** Por eso este archivo es 090 y el catálogo
-- del dominio es 150.
--
-- Sobre el tamaño de la lista: TunjoSoft es una agencia de una persona, así
-- que hoy los cuatro roles los ocupa la misma. Se dejan igual porque el
-- sistema es el demo del producto — un prospecto que entra al portal tiene
-- que ver cómo se reparte el trabajo en SU negocio, no en el nuestro.
-- =====================================================================

SET client_min_messages = warning;

INSERT INTO rol (codigo, nombre, descripcion, nivel, sistema) VALUES
  ('superadmin', 'Superadministrador',
   'Acceso técnico total, configuración del sistema, auditoría y tareas fallidas.', 100, true),
  ('admin',      'Administrador',
   'Administra el negocio: usuarios, catálogo de servicios, precios, agenda y reportes.', 80, true),
  ('comercial',  'Comercial',
   'Trabaja el pipeline: prospectos, seguimientos, propuestas y reuniones.', 60, true),
  ('atencion',   'Atención',
   'Atiende el chat y agenda reuniones. No cambia precios ni ve reportes de dinero.', 40, true)
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO permiso (codigo, modulo, descripcion) VALUES
  -- Conversaciones: el canal de atención. `conversaciones.atender` la usa el
  -- worker para saber a quién avisarle cuando un chat se escala: si nadie la
  -- tiene, el escalamiento no llega a ninguna parte.
  ('conversaciones.ver',      'canal',      'Ver las conversaciones activas y su historial'),
  ('conversaciones.atender',  'canal',      'Escribir en un hilo y devolvérselo al bot'),
  -- Pipeline comercial
  ('prospectos.ver',          'comercial',  'Ver el pipeline, el estado de cada prospecto y su historia'),
  ('prospectos.gestionar',    'comercial',  'Crear prospectos, registrar contactos y mover su estado'),
  ('propuestas.gestionar',    'comercial',  'Registrar propuestas enviadas y su resultado'),
  ('auditorias.ver',          'comercial',  'Consultar las auditorías técnicas de sitios de prospectos'),
  -- Agenda
  ('agenda.ver',              'agenda',     'Ver la agenda de reuniones y seguimientos'),
  ('agenda.gestionar',        'agenda',     'Agendar, reagendar y cancelar reuniones'),
  ('agenda.disponibilidad',   'agenda',     'Definir las franjas en que se pueden agendar reuniones'),
  ('catalogo.editar',         'agenda',     'Crear y editar servicios y sus precios'),
  -- Reportes y administración
  ('reportes.operativos',     'reportes',   'Reportes de pipeline, conversaciones y reuniones'),
  ('reportes.financieros',    'reportes',   'Reportes de propuestas, valores y cierre'),
  ('usuarios.gestionar',      'admin',      'Crear usuarios, asignar roles y permisos'),
  ('config.editar',           'admin',      'Editar configuración operativa, sedes y parámetros del asistente'),
  ('auditoria.ver',           'admin',      'Consultar la auditoría'),
  ('sistema.operar',          'admin',      'Bandeja de tareas fallidas, backups y salud del sistema')
ON CONFLICT (codigo) DO NOTHING;

-- superadmin: todo.
INSERT INTO rol_permiso (rol_codigo, permiso_codigo)
SELECT 'superadmin', codigo FROM permiso
ON CONFLICT DO NOTHING;

-- admin: todo excepto la operación técnica del sistema.
INSERT INTO rol_permiso (rol_codigo, permiso_codigo)
SELECT 'admin', codigo FROM permiso WHERE codigo <> 'sistema.operar'
ON CONFLICT DO NOTHING;

-- comercial: vive en el pipeline. Agenda y propone, no toca precios ni
-- usuarios.
INSERT INTO rol_permiso (rol_codigo, permiso_codigo) VALUES
  ('comercial', 'conversaciones.ver'),
  ('comercial', 'conversaciones.atender'),
  ('comercial', 'prospectos.ver'),
  ('comercial', 'prospectos.gestionar'),
  ('comercial', 'propuestas.gestionar'),
  ('comercial', 'auditorias.ver'),
  ('comercial', 'agenda.ver'),
  ('comercial', 'agenda.gestionar'),
  ('comercial', 'reportes.operativos'),
  ('comercial', 'reportes.financieros')
ON CONFLICT DO NOTHING;

-- atención: es quien está en el chat. Agenda y registra el contacto, y hasta
-- ahí. No ve lo que se cotizó ni mueve el estado del negocio.
INSERT INTO rol_permiso (rol_codigo, permiso_codigo) VALUES
  ('atencion', 'conversaciones.ver'),
  ('atencion', 'conversaciones.atender'),
  ('atencion', 'prospectos.ver'),
  ('atencion', 'prospectos.gestionar'),
  ('atencion', 'agenda.ver'),
  ('atencion', 'agenda.gestionar'),
  ('atencion', 'reportes.operativos')
ON CONFLICT DO NOTHING;
