// ---------------------------------------------------------------------------
// enviar_texto — payload {conversacion_id, texto}
//
// Manda por el canal un texto que armó la base. Existe porque hay respuestas
// que NO las escribe el modelo: la cartilla de una urgencia, el aviso de que
// ya se llamó a una persona, los recordatorios de ayuno de la fase 3.
//
// En el simulador, registrar el mensaje ES enviarlo. En Telegram y WhatsApp
// no: hay que hablar con una API, y eso es I/O lento que no cabe en el
// segundo que el webhook tiene para responder. Por eso pasa por la cola, y
// por eso la base encola en vez de escribir directo.
//
// El registro en `mensaje` lo hace `responder()`, no la base: si lo hicieran
// los dos, el panel mostraría cada respuesta dos veces.
// ---------------------------------------------------------------------------

import { responder } from '../canal.js';

export const tipo = 'enviar_texto';

export async function manejar({ payload }, { db, log }) {
  const conversacionId = payload?.conversacion_id;
  const texto = payload?.texto;

  if (!conversacionId || !texto) throw new Error('payload sin conversacion_id o texto');

  const { rows } = await db.query(
    'SELECT id, canal, chat_externo_id FROM conversacion WHERE id = $1',
    [conversacionId],
  );
  const conversacion = rows[0];
  if (!conversacion) throw new Error(`la conversación ${conversacionId} no existe`);

  const r = await responder(db, conversacion, texto, payload.botones ?? []);

  log.info(
    `conversación ${conversacionId} · texto de la base → ` +
      (r.ok ? 'enviado' : `no enviado (${r.motivo})`),
  );

  return { enviado: r.ok, motivo: r.motivo ?? null, mensaje_id: r.mensaje_id };
}
