-- =====================================================================
-- Chasqui TunjoSoft — 900_grants.sql
-- Roles de base de datos y append-only real.
--
-- La aplicación (n8n, worker, portal) se conecta como `chasqui_tunjosoft_app`,
-- que NO es superusuario ni dueño de las tablas. Sobre `evento_auditoria` no
-- tiene UPDATE ni DELETE: la corrección se hace con un registro inverso, no
-- editando el original. Que la app no pueda borrar la auditoría es lo que
-- hace que la auditoría sirva de algo.
--
-- Corre de último a propósito: los GRANT sobre ALL TABLES tienen que
-- alcanzar también a las tablas del dominio, que nacen en las migraciones
-- 100–150.
-- =====================================================================

SET client_min_messages = warning;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'chasqui_tunjosoft_app') THEN
    -- La contraseña se fija desde docker-compose (ver .env). Aquí sólo el rol.
    CREATE ROLE chasqui_tunjosoft_app LOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'chasqui_tunjosoft_lectura') THEN
    CREATE ROLE chasqui_tunjosoft_lectura LOGIN;   -- reportes / BI, sólo lectura
  END IF;
END $$;

DO $$
BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO chasqui_tunjosoft_app, chasqui_tunjosoft_lectura',
                 current_database());
END $$;

GRANT USAGE ON SCHEMA public TO chasqui_tunjosoft_app, chasqui_tunjosoft_lectura;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO chasqui_tunjosoft_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO chasqui_tunjosoft_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO chasqui_tunjosoft_app;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO chasqui_tunjosoft_lectura;

-- ---------------------------------------------------------------------
-- Append-only: sólo INSERT y SELECT. Sin UPDATE, sin DELETE, sin TRUNCATE.
--
-- `evento_auditoria` por lo de siempre. `mensaje` se le suma aquí y es
-- propio de este proyecto: lo que el bot le dijo a un cliente no se edita
-- después. Si el bot se equivocó, la corrección es otro mensaje —igual que
-- en el chat real—, no reescribir lo que ya se leyó del otro lado.
--
-- Las que aún no existen en esta etapa del proyecto se ignoran sin fallar.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  t text;
  tablas text[] := ARRAY['evento_auditoria', 'mensaje'];
BEGIN
  FOREACH t IN ARRAY tablas LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      EXECUTE format('REVOKE UPDATE, DELETE, TRUNCATE ON %I FROM chasqui_tunjosoft_app', t);
      EXECUTE format('GRANT SELECT, INSERT ON %I TO chasqui_tunjosoft_app', t);
      EXECUTE format('REVOKE ALL ON %I FROM chasqui_tunjosoft_lectura', t);
      EXECUTE format('GRANT SELECT ON %I TO chasqui_tunjosoft_lectura', t);
    END IF;
  END LOOP;
END $$;

-- El registro de updates de Telegram sí se actualiza (marcar procesado),
-- pero nunca se borra desde la app: la retención la maneja un job.
REVOKE DELETE, TRUNCATE ON telegram_update FROM chasqui_tunjosoft_app;

-- Las funciones que auditan o escriben en tablas append-only corren como
-- SECURITY DEFINER cuando necesitan más privilegio que el llamador.
-- `auditar` es el caso claro: la app no puede escribir directo pero sí a
-- través de ella.
ALTER FUNCTION auditar(text, text, text, uuid, text, jsonb, jsonb, text) SECURITY DEFINER;

-- `mensaje_registrar` es la única puerta de escritura a `mensaje`, sobre la
-- que la app perdió el UPDATE que necesita el ON CONFLICT. Como en
-- `auditar`: la puerta es concreta y no hay otra.
ALTER FUNCTION mensaje_registrar(uuid, text, text, text, jsonb, text, uuid) SECURITY DEFINER;

-- La purga diaria borra de `telegram_update`, sobre la que la aplicación no
-- tiene DELETE. Puede hacerlo por esta puerta concreta y por ninguna otra:
-- la función no recibe parámetros, así que no hay nada que manipular desde
-- fuera para que borre otra cosa.
ALTER FUNCTION mantenimiento_diario() SECURITY DEFINER;

-- Nuevas tablas y funciones creadas después heredan estos permisos.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO chasqui_tunjosoft_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO chasqui_tunjosoft_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO chasqui_tunjosoft_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO chasqui_tunjosoft_lectura;
