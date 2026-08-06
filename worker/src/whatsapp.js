// ---------------------------------------------------------------------------
// Cliente mínimo de la WhatsApp Cloud API (Meta Graph).
//
// Mismo trato que `telegram.js`: sin librerías, `fetch` nativo, y el worker
// solo manda. Lo que entra lo recibe n8n por webhook y lo resuelve la base
// (`145_canal_whatsapp.sql`).
//
// Queda listo para el día que exista el número: si `WHATSAPP_TOKEN` o
// `WHATSAPP_PHONE_NUMBER_ID` faltan, `enviarTexto` devuelve
// `{ok:false, motivo:'whatsapp_sin_configurar'}` y el mensaje igual queda
// registrado en `mensaje`. Nadie se queda esperando en silencio: el panel lo
// muestra y se ve que faltaba configurarlo.
//
// Las tres diferencias con Telegram que sí importan
// -------------------------------------------------
//   1. **No hay HTML.** WhatsApp usa su propio marcado: *negrita*, _cursiva_,
//      ```código```. Todo lo que el sistema arma para Telegram viene en HTML,
//      así que aquí se traduce de vuelta a texto plano con ese marcado. Si no
//      se hiciera, el cliente vería `<b>` literal en pantalla.
//   2. **Los botones son «interactive reply buttons»**, máximo tres, y el
//      título de cada uno no puede pasar de 20 caracteres. Se recorta, no se
//      falla: un botón sin texto es peor que un botón con el texto corto.
//   3. **La ventana de 24 horas.** Fuera de ella Meta solo acepta plantillas
//      aprobadas. Un mensaje libre a alguien que lleva más de un día sin
//      escribir devuelve error 131047: se marca como no recuperable y no se
//      reintenta, porque reintentarlo no lo va a arreglar.
// ---------------------------------------------------------------------------

import { log } from './log.js';

const TOKEN = process.env.WHATSAPP_TOKEN || '';
const PHONE_ID = process.env.WHATSAPP_PHONE_NUMBER_ID || '';
const VERSION = process.env.WHATSAPP_API_VERSION || 'v21.0';
const TIMEOUT_MS = Number(process.env.WHATSAPP_TIMEOUT_MS || 15000);

export const configurado = Boolean(TOKEN && PHONE_ID);

export class WhatsAppError extends Error {
  constructor(mensaje, { codigo = null } = {}) {
    super(mensaje);
    this.name = 'WhatsAppError';
    this.codigo = codigo;
  }
}

/**
 * Del HTML que arma la base al marcado de WhatsApp.
 *
 * Se hace aquí y no antes porque la base arma UN texto para todos los
 * canales, y esa decisión es la que permite que la tarjeta de confirmación se
 * escriba una sola vez. El precio es esta función; es barato.
 */
export function aWhatsApp(html) {
  return String(html ?? '')
    .replace(/<pre>([\s\S]*?)<\/pre>/g, (_, c) => '```\n' + c.trim() + '\n```')
    .replace(/<code>([\s\S]*?)<\/code>/g, '`$1`')
    .replace(/<b>([\s\S]*?)<\/b>/g, '*$1*')
    .replace(/<strong>([\s\S]*?)<\/strong>/g, '*$1*')
    .replace(/<i>([\s\S]*?)<\/i>/g, '_$1_')
    .replace(/<em>([\s\S]*?)<\/em>/g, '_$1_')
    .replace(/<[^>]+>/g, '')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&amp;', '&');
}

async function llamar(cuerpo) {
  if (!configurado) {
    return { ok: false, motivo: 'whatsapp_sin_configurar', detalle: 'faltan WHATSAPP_TOKEN o WHATSAPP_PHONE_NUMBER_ID' };
  }

  let respuesta;
  try {
    respuesta = await fetch(`https://graph.facebook.com/${VERSION}/${PHONE_ID}/messages`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${TOKEN}`,
      },
      body: JSON.stringify(cuerpo),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (err) {
    throw new WhatsAppError(`No se pudo contactar a WhatsApp: ${err.message}`);
  }

  let datos = null;
  try {
    datos = await respuesta.json();
  } catch {
    datos = null;
  }

  if (respuesta.ok) {
    return { ok: true, resultado: datos };
  }

  const codigo = datos?.error?.code ?? respuesta.status;
  const descripcion = datos?.error?.message || `HTTP ${respuesta.status}`;

  // 131047 / 131026: fuera de la ventana de 24 h, o el número no puede
  // recibir. Reintentar no lo arregla.
  if ([131047, 131026, 131051].includes(Number(codigo))) {
    log.aviso(`WhatsApp ${codigo}: ${descripcion} (no se reintenta)`);
    return { ok: false, motivo: 'fuera_de_ventana', detalle: descripcion };
  }

  // 190: token vencido. Tampoco se arregla reintentando, y hay que enterarse.
  if (Number(codigo) === 190) {
    log.aviso(`WhatsApp 190: el token venció. Renovarlo en Meta. (${descripcion})`);
    return { ok: false, motivo: 'token_vencido', detalle: descripcion };
  }

  throw new WhatsAppError(`WhatsApp falló (${codigo}): ${descripcion}`, { codigo });
}

/**
 * Manda un texto, con hasta tres botones de respuesta.
 *
 * @param {string} para     número en formato internacional sin «+» (573001112233)
 * @param {string} texto    en HTML, tal como lo arma la base
 * @param {{t: string, d: string}[]} [botones]
 */
export function enviarTexto(para, texto, botones = []) {
  const cuerpo = aWhatsApp(texto);

  if (!botones.length) {
    return llamar({
      messaging_product: 'whatsapp',
      to: para,
      type: 'text',
      text: { preview_url: false, body: cuerpo.slice(0, 4096) },
    });
  }

  return llamar({
    messaging_product: 'whatsapp',
    to: para,
    type: 'interactive',
    interactive: {
      type: 'button',
      // 1024 es el tope del cuerpo de un mensaje interactivo, bastante menos
      // que el de un texto suelto.
      body: { text: cuerpo.slice(0, 1024) },
      action: {
        buttons: botones.slice(0, 3).map((b) => ({
          type: 'reply',
          // El id es el mismo `callback_data` de Telegram: así la base no
          // tiene que saber por dónde llegó la respuesta.
          reply: { id: String(b.d).slice(0, 256), title: String(b.t).slice(0, 20) },
        })),
      },
    },
  });
}
