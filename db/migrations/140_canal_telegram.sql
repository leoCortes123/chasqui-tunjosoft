-- =====================================================================
-- Chasqui TunjoSoft — 140_canal_telegram.sql
-- El enrutador del webhook de Telegram.
--
-- Telegram es el canal que se puede enseñar HOY: no depende de que Meta
-- apruebe un número. El demo real va por WhatsApp (fase 3), pero el motor es
-- el mismo y el canal es una columna, así que lo que se vea aquí es
-- exactamente lo que se verá allá.
--
-- Un chat de Telegram puede ser dos cosas distintas y esta función es la que
-- decide cuál:
--
--   · Personal de la clínica — tiene fila en `usuario` con ese
--     telegram_user_id. Usa el bot para entrar al portal y confirmar su
--     ingreso. Eso lo atiende `050_auth_web.sql`, con sus botones.
--   · Cualquier otra persona — es un cliente. Su mensaje entra por
--     `asistente_recibir`, igual que si hubiera escrito por WhatsApp.
--
-- El personal también puede conversar con el asistente: si escribe algo que
-- no es un comando del portal, cae al asistente como todos, pero con su
-- `usuario_id` colgado del contacto, así que ve además las herramientas
-- internas. Ese es el eje `actor` de 030 funcionando de verdad.
--
-- Devuelve `{acciones: [...]}` en el formato que traduce el workflow de n8n:
-- `enviar`, `editar` y `responder_callback`. La base decide qué se manda; n8n
-- solo cambia de formato.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Un contacto se identifica por celular (WhatsApp) o por su id de Telegram.
--
-- Telegram no entrega el número: entrega un id numérico. Sin esta columna, un
-- cliente que escribe por Telegram no tendría cómo existir en `contacto`, que
-- es donde vive todo lo demás.
-- ---------------------------------------------------------------------
ALTER TABLE contacto ADD COLUMN IF NOT EXISTS telegram_user_id bigint;

CREATE UNIQUE INDEX IF NOT EXISTS idx_contacto_telegram
  ON contacto (telegram_user_id) WHERE telegram_user_id IS NOT NULL;

CREATE OR REPLACE FUNCTION contacto_asegurar_telegram(
  p_telegram_user_id bigint, p_nombre text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_id      uuid;
  v_usuario uuid := usuario_por_telegram(p_telegram_user_id);
BEGIN
  IF p_telegram_user_id IS NULL THEN
    RAISE EXCEPTION 'No se puede crear un contacto sin telegram_user_id';
  END IF;

  INSERT INTO contacto (telegram_user_id, nombre, usuario_id)
  VALUES (p_telegram_user_id, NULLIF(trim(COALESCE(p_nombre, '')), ''), v_usuario)
  ON CONFLICT (telegram_user_id) WHERE telegram_user_id IS NOT NULL DO UPDATE
    -- El vínculo con `usuario` se refresca en cada mensaje: si a alguien lo
    -- aprovisionan como personal después de haber escrito como cliente, su
    -- siguiente mensaje ya lo trata como personal.
    SET nombre     = COALESCE(contacto.nombre, EXCLUDED.nombre),
        usuario_id = COALESCE(EXCLUDED.usuario_id, contacto.usuario_id)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------
-- El enrutador
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_manejar_update(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_msg        jsonb;
  v_cb         jsonb  := p_payload->'callback_query';
  v_tg_user    bigint;
  v_chat_id    bigint;
  v_texto      text;
  v_mensaje_id bigint;
  v_data       text;
  v_nombre     text;
  v_usuario    uuid;
  v_contacto   uuid;
  v_conv       uuid;
  v_r          jsonb;
  v_acciones   jsonb := '[]'::jsonb;
BEGIN
  v_msg := COALESCE(v_cb->'message', p_payload->'message', p_payload->'edited_message');

  v_tg_user := COALESCE((v_cb->'from'->>'id')::bigint,
                        (p_payload->'message'->'from'->>'id')::bigint,
                        (p_payload->'edited_message'->'from'->>'id')::bigint);
  v_chat_id := (v_msg->'chat'->>'id')::bigint;

  IF v_tg_user IS NULL OR v_chat_id IS NULL THEN
    RETURN jsonb_build_object('acciones', '[]'::jsonb, 'motivo', 'update_sin_origen');
  END IF;

  v_nombre := trim(COALESCE(v_cb->'from'->>'first_name',
                            p_payload->'message'->'from'->>'first_name', '') || ' ' ||
                   COALESCE(v_cb->'from'->>'last_name',
                            p_payload->'message'->'from'->>'last_name', ''));

  v_usuario  := usuario_por_telegram(v_tg_user);
  v_contacto := contacto_asegurar_telegram(v_tg_user, v_nombre);
  v_conv     := conversacion_asegurar(v_contacto, 'telegram', v_chat_id::text);

  -- Al personal se le refresca el chat_id: cambia si borran la conversación,
  -- y es a donde llegan las alertas de escalamiento.
  IF v_usuario IS NOT NULL THEN
    PERFORM vincular_chat_usuario(v_tg_user, v_chat_id);
  END IF;

  -- ---------------------------------------------------------------
  -- Botones
  -- ---------------------------------------------------------------
  IF v_cb IS NOT NULL THEN
    v_data       := v_cb->>'data';
    v_mensaje_id := (v_msg->>'message_id')::bigint;

    -- Confirmar o cancelar una propuesta del asistente. Va primero porque es
    -- la que puede tocar cualquiera, personal o cliente.
    IF v_data LIKE 'ia:ok:%' OR v_data LIKE 'ia:no:%' THEN
      IF v_data LIKE 'ia:no:%' THEN
        PERFORM ia_cancelar(substring(v_data FROM 7)::uuid, v_contacto);
        v_texto := '✖️ Listo, no hice nada.';
      ELSE
        v_r := ia_confirmar(substring(v_data FROM 7)::uuid, v_contacto);
        v_texto := CASE WHEN COALESCE((v_r->>'ok')::boolean, false)
                        THEN '✅ Hecho.'
                        ELSE '⚠️ ' || COALESCE(esc(v_r->>'mensaje'), 'No se pudo.') END;
      END IF;

      PERFORM asistente_responder(v_conv, v_texto);

      RETURN jsonb_build_object('acciones', jsonb_build_array(
        jsonb_build_object('tipo', 'responder_callback',
                           'callback_query_id', v_cb->>'id'),
        accion_editar(v_chat_id, v_mensaje_id, v_texto)));
    END IF;

    -- Los botones del portal son solo del personal.
    IF v_usuario IS NOT NULL THEN
      v_r := bot_modulo_callback(v_usuario, v_chat_id, v_mensaje_id, v_data, NULL);
      IF v_r IS NOT NULL THEN
        RETURN jsonb_build_object('acciones',
          jsonb_build_array(jsonb_build_object(
            'tipo', 'responder_callback',
            'callback_query_id', v_cb->>'id',
            'texto', v_r->>'alerta')) || COALESCE(v_r->'acciones', '[]'::jsonb));
      END IF;
    END IF;

    RETURN jsonb_build_object('acciones', jsonb_build_array(
      jsonb_build_object('tipo', 'responder_callback',
                         'callback_query_id', v_cb->>'id')));
  END IF;

  -- ---------------------------------------------------------------
  -- Texto
  -- ---------------------------------------------------------------
  v_texto := COALESCE(p_payload->'message'->>'text',
                      p_payload->'edited_message'->>'text',
                      p_payload->'message'->>'caption');

  -- Nota de voz, foto o documento: se registra para que el panel lo muestre y
  -- se avisa con honestidad. La transcripción de audio es de la fase 3, y
  -- callarse aquí sería peor que decirlo.
  IF v_texto IS NULL THEN
    IF p_payload->'message' ? 'voice' OR p_payload->'message' ? 'audio' THEN
      PERFORM mensaje_registrar(v_conv, 'entrante', NULL, 'audio', p_payload,
                                'tg-' || (p_payload->>'update_id'));
      RETURN jsonb_build_object('acciones', jsonb_build_array(accion_enviar(v_chat_id,
        'Todavía no puedo escuchar notas de voz. ¿Me lo escribes? '
        'O escribe ASESOR y te atiende una persona.')));
    END IF;
    RETURN jsonb_build_object('acciones', '[]'::jsonb, 'motivo', 'sin_texto');
  END IF;

  -- Comandos del portal: solo personal, y solo los suyos. Si `bot_modulo_texto`
  -- no lo reclama, el mensaje sigue de largo hacia el asistente.
  IF v_usuario IS NOT NULL THEN
    v_r := bot_modulo_texto(v_usuario, v_chat_id, v_texto, NULL);
    IF v_r IS NOT NULL THEN
      RETURN jsonb_build_object('acciones', COALESCE(v_r->'acciones', '[]'::jsonb));
    END IF;
  END IF;

  -- `/start` no existe en WhatsApp: allá la gente abre el chat y escribe
  -- «hola». Telegram obliga a tocar un botón que manda ese comando, y el
  -- servicio se vende para WhatsApp, así que aquí se traduce en vez de
  -- responder con un menú de capacidades.
  --
  -- Un mostrador no le lee a nadie la lista de servicios cuando entra: uno
  -- saluda, le devuelven el saludo y preguntan en qué le sirven. Eso es lo
  -- que hace esta línea — el «hola» se lo pasa al asistente y contesta como
  -- contestaría a cualquier saludo, con el mismo tono y sin guion aparte.
  IF v_texto IN ('/start', '/ayuda', '/help') THEN
    v_texto := 'Hola';
  END IF;

  -- Todo lo demás: es una conversación. Entra por la misma puerta que
  -- WhatsApp. La respuesta la manda el worker, no este webhook — por eso aquí
  -- no se devuelve ninguna acción y por eso el webhook contesta en
  -- milisegundos.
  v_r := asistente_recibir(v_conv, v_texto, 'tg-' || (p_payload->>'update_id'),
                           'texto', p_payload);

  -- Salvo que la base ya tenga la respuesta lista y no haga falta esperar a
  -- nadie: el aviso de rate limit es el caso.
  IF v_r ? 'texto' AND (v_r->>'motivo') = 'rate_limit' THEN
    RETURN jsonb_build_object('acciones',
      jsonb_build_array(accion_enviar(v_chat_id, v_r->>'texto')));
  END IF;

  RETURN jsonb_build_object('acciones', '[]'::jsonb, 'ruta', v_r->>'motivo');
END;
$$;
