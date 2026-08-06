-- =====================================================================
-- Chasqui TunjoSoft — 145_canal_whatsapp.sql
-- El enrutador del webhook de WhatsApp (Meta Cloud API).
--
-- Es el gemelo de `140_canal_telegram.sql`, y que se parezcan tanto es el
-- argumento: **el canal es una columna, no un sistema.** Lo que se enseña
-- hoy por Telegram es exactamente lo que va a hacer por WhatsApp; aquí solo
-- cambia la forma del sobre.
--
-- Queda listo y no arranca solo. Falta el número, y hasta que exista:
--   · el workflow `02-whatsapp-webhook.json` está en el repositorio pero no
--     se activa,
--   · el worker devuelve `whatsapp_sin_configurar` al intentar enviar y el
--     mensaje igual queda registrado.
--
-- Nada de esto rompe Telegram. Son dos filas distintas de `conversacion`.
--
-- Las tres diferencias con Telegram
-- ---------------------------------
--   1. La identidad es el celular (`wa_id`), no un id de bot. Por eso aquí
--      se usa `contacto_asegurar`, que ya normaliza números, en vez de
--      `contacto_asegurar_telegram`.
--   2. No hay `update_id` global: la idempotencia va por el `id` del mensaje,
--      y de eso ya se encarga `mensaje_registrar` con su `id_externo`.
--   3. Los botones vuelven como un mensaje de tipo `interactive` cuyo
--      `button_reply.id` es el mismo `callback_data` que usa Telegram. Por
--      eso la rama `ia:ok:` / `ia:no:` es idéntica: se escribió una vez.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- El enrutador
--
-- Recibe el `body` completo del webhook de Meta y devuelve `{acciones: []}`
-- con el mismo contrato que Telegram: n8n traduce, la base decide.
--
-- Meta entrega los eventos anidados en entry[].changes[].value, y en un
-- mismo POST pueden venir varios. Se recorren todos: quedarse con el primero
-- pierde mensajes cuando llegan dos seguidos.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_manejar_whatsapp(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_entry     jsonb;
  v_change    jsonb;
  v_msg       jsonb;
  v_valor     jsonb;
  v_wa_id     text;
  v_nombre    text;
  v_texto     text;
  v_id_ext    text;
  v_tipo      text;
  v_data      text;
  v_contacto  uuid;
  v_conv      uuid;
  v_r         jsonb;
  v_acciones  jsonb := '[]'::jsonb;
  v_rutas     jsonb := '[]'::jsonb;
BEGIN
  FOR v_entry IN SELECT jsonb_array_elements(COALESCE(p_payload->'entry', '[]'::jsonb))
  LOOP
    FOR v_change IN SELECT jsonb_array_elements(COALESCE(v_entry->'changes', '[]'::jsonb))
    LOOP
      v_valor := v_change->'value';

      -- Los acuses de entrega (`statuses`) llegan por el mismo webhook y son
      -- la mayoría del tráfico. No son conversación: se ignoran sin ruido.
      CONTINUE WHEN NOT (v_valor ? 'messages');

      FOR v_msg IN SELECT jsonb_array_elements(v_valor->'messages')
      LOOP
        v_wa_id  := v_msg->>'from';
        v_id_ext := 'wa-' || (v_msg->>'id');
        v_tipo   := v_msg->>'type';

        -- El nombre del perfil viene en `contacts`, no en el mensaje.
        v_nombre := (SELECT c->'profile'->>'name'
                       FROM jsonb_array_elements(COALESCE(v_valor->'contacts', '[]'::jsonb)) c
                      WHERE c->>'wa_id' = v_wa_id
                      LIMIT 1);

        CONTINUE WHEN v_wa_id IS NULL;

        v_contacto := contacto_asegurar(v_wa_id, NULLIF(trim(COALESCE(v_nombre, '')), ''));
        v_conv     := conversacion_asegurar(v_contacto, 'whatsapp', v_wa_id);

        -- ---------------------------------------------------------
        -- Botones
        -- ---------------------------------------------------------
        IF v_tipo = 'interactive' THEN
          v_data := COALESCE(v_msg->'interactive'->'button_reply'->>'id',
                             v_msg->'interactive'->'list_reply'->>'id');

          IF v_data LIKE 'ia:ok:%' OR v_data LIKE 'ia:no:%' THEN
            IF v_data LIKE 'ia:no:%' THEN
              PERFORM ia_cancelar(substring(v_data FROM 7)::uuid, v_contacto);
              v_texto := '✖️ Listo, no hice nada.';
            ELSE
              v_r := ia_confirmar(substring(v_data FROM 7)::uuid, v_contacto);
              v_texto := CASE WHEN COALESCE((v_r->>'ok')::boolean, false)
                              THEN '✅ ' || COALESCE(esc(v_r->>'mensaje'), 'Hecho.')
                              ELSE '⚠️ ' || COALESCE(esc(v_r->>'mensaje'), 'No se pudo.') END;
            END IF;

            PERFORM asistente_responder(v_conv, v_texto);

            -- WhatsApp no tiene «editar mensaje»: el resultado se manda como
            -- un mensaje nuevo. Es la única diferencia visible de las dos
            -- ramas, y no cambia nada de lo que ocurrió en la base.
            v_acciones := v_acciones || jsonb_build_object(
              'tipo', 'enviar', 'para', v_wa_id, 'texto', v_texto);
            CONTINUE;
          END IF;

          -- Un botón que no reconocemos: se trata como si hubiera escrito su
          -- título. Es lo que la persona cree que hizo.
          v_texto := COALESCE(v_msg->'interactive'->'button_reply'->>'title',
                              v_msg->'interactive'->'list_reply'->>'title');
        ELSE
          v_texto := v_msg->'text'->>'body';
        END IF;

        -- ---------------------------------------------------------
        -- Audio, imagen, documento: se registra y se dice la verdad.
        -- ---------------------------------------------------------
        IF v_texto IS NULL THEN
          PERFORM mensaje_registrar(v_conv, 'entrante', NULL,
                                    COALESCE(v_tipo, 'desconocido'), v_msg, v_id_ext);

          v_acciones := v_acciones || jsonb_build_object(
            'tipo', 'enviar', 'para', v_wa_id,
            'texto', 'Todavía no puedo escuchar notas de voz ni abrir archivos. '
                     '¿Me lo escribes? O escribe ASESOR y te atiende una persona.');
          CONTINUE;
        END IF;

        -- Todo lo demás entra por la misma puerta que Telegram. La respuesta
        -- la manda el worker, no este webhook: por eso aquí no se devuelve
        -- ninguna acción y por eso contesta en milisegundos.
        v_r := asistente_recibir(v_conv, v_texto, v_id_ext, 'texto', v_msg);

        -- Salvo que la base ya tenga la respuesta lista (el aviso de rate
        -- limit es el caso).
        IF v_r ? 'texto' AND (v_r->>'motivo') = 'rate_limit' THEN
          v_acciones := v_acciones || jsonb_build_object(
            'tipo', 'enviar', 'para', v_wa_id, 'texto', v_r->>'texto');
        END IF;

        v_rutas := v_rutas || to_jsonb(COALESCE(v_r->>'motivo', 'encolado'));
      END LOOP;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('acciones', v_acciones, 'rutas', v_rutas);
END;
$$;
