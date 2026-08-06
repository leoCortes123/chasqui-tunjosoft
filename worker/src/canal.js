// ---------------------------------------------------------------------------
// Salida por canal.
//
// El canal es una columna en `conversacion`, no un sistema aparte (ver
// db/migrations/030_actor.sql). Esta capa es la contraparte de esa decisión:
// quien responde no sabe por dónde está hablando, solo pide "manda esto a
// esta conversación".
//
// Hoy hay tres canales:
//
//   telegram   — el que se puede enseñar hoy, sin pedirle permiso a nadie.
//   whatsapp   — Meta Cloud API. El transporte está escrito y probado contra
//                la API; lo que falta es el número. Sin `WHATSAPP_TOKEN` el
//                envío devuelve `whatsapp_sin_configurar` y el mensaje igual
//                queda registrado, que es como se descubre que faltaba esto
//                en vez de que alguien se quede esperando en silencio.
//   simulador  — el chat del portal. No sale a internet: el mensaje queda en
//                la tabla `mensaje` y el portal lo lee de ahí. Por eso no
//                necesita transporte propio, y por eso es el respaldo si la
//                red falla en la reunión.
//
// Todo lo que se manda queda registrado con `asistente_responder`, incluido
// lo del simulador: un canal que no deja rastro en la misma tabla que los
// demás sería un canal que hay que mantener aparte.
// ---------------------------------------------------------------------------

import { enviarMensaje, teclado } from './telegram.js';
import { enviarTexto } from './whatsapp.js';

/** Pasa la respuesta del modelo al HTML que entiende el canal. */
export function formatear(texto, { limite = 3900 } = {}) {
  let t = escapar(texto);

  // Encabezados markdown: ni Telegram ni WhatsApp los tienen. Se vuelven
  // negrita.
  t = t.replace(/^\s{0,3}#{1,6}\s+(.+)$/gm, '<b>$1</b>');

  // Bloques y trozos de código antes que nada: adentro no se toca. Se
  // apartan detrás de un centinela de control (U+0000), que no puede venir en
  // el texto del modelo. Con un marcador visible tipo " 3 " se confundiría
  // con las cifras de una respuesta llena de precios, y el reemplazo final
  // destrozaría la respuesta.
  const codigos = [];
  const apartar = (html) => `\u0000${codigos.push(html) - 1}\u0000`;
  t = t.replace(/```[a-z]*\n?([\s\S]*?)```/g, (_, c) => apartar(`<pre>${c.trim()}</pre>`));
  t = t.replace(/`([^`\n]+)`/g, (_, c) => apartar(`<code>${c}</code>`));

  t = t.replace(/\*\*\*(.+?)\*\*\*/g, '<b><i>$1</i></b>');
  t = t.replace(/\*\*(.+?)\*\*/g, '<b>$1</b>');
  t = t.replace(/(^|[\s(])\*([^*\n]+)\*(?=[\s).,;:!?]|$)/g, '$1<i>$2</i>');
  // El guión bajo se deja fuera a propósito: abundan los códigos de estudio
  // con guiones bajos, y volverlos cursiva a media palabra rompe más de lo
  // que arregla.

  t = t.replace(/^(\s*)[-*]\s+/gm, '$1• ');
  t = t.replace(/\u0000(\d+)\u0000/g, (_, i) => codigos[Number(i)]);

  return t.length > limite ? `${t.slice(0, limite)}…` : t;
}

function escapar(valor) {
  return String(valor ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

/**
 * Manda un texto por el canal de la conversación y lo deja registrado.
 *
 * `conversacion` = { id, canal, chat_externo_id }
 * `botones`      = [{ t, d }] tal como los arma la base; opcional.
 * `markdown`     = true si el texto viene del modelo y hay que traducirlo.
 *
 * Lo que se ENVÍA se formatea; lo que se REGISTRA no. Los dos son el mismo
 * mensaje, pero el registro es también la memoria del modelo, y un modelo
 * que se lee a sí mismo escribiendo `<b>` empieza a escribir `<b>` a mano
 * en el turno siguiente — y entonces `formatear` se lo escapa y el cliente
 * ve `&lt;b&gt;` en pantalla. Pasó. Por eso el HTML no entra a la historia.
 *
 * Las respuestas que arma la base (la cartilla de una urgencia, la tarjeta
 * de confirmación) ya vienen en HTML y no llevan `markdown`: formatearlas
 * las escaparía dos veces.
 */
export async function responder(db, conversacion, texto, botones = [], { markdown = false } = {}) {
  const { id, canal, chat_externo_id: externo } = conversacion;
  const salida = markdown ? formatear(texto) : texto;
  let envio = { ok: true, motivo: null };

  if (canal === 'telegram') {
    envio = await enviarMensaje(Number(externo), salida, {
      reply_markup: botones.length
        ? teclado([botones.map((b) => ({ texto: b.t, dato: b.d }))])
        : undefined,
    });
  } else if (canal === 'whatsapp') {
    // `chat_externo_id` guarda el `wa_id`: el número en formato internacional
    // sin «+», que es como lo entrega Meta y como lo pide de vuelta.
    envio = await enviarTexto(String(externo), salida, botones);
  }
  // 'simulador' no tiene transporte: el registro de abajo ES el envío.

  const { rows } = await db.query('SELECT asistente_responder($1, $2, $3) AS id', [
    id,
    texto,
    JSON.stringify({ botones, envio }),
  ]);

  return { ...envio, mensaje_id: rows[0]?.id ?? null };
}
