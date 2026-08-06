// ---------------------------------------------------------------------------
// alertar_personal — payload {conversacion_id, motivo}
//
// La encola `escalar_a_humano` (db/migrations/030_actor.sql) cada vez que un
// hilo pasa a manos de una persona: una urgencia, alguien que escribió
// ASESOR, o el asistente que no pudo responder.
//
// El panel muestra el hilo en rojo, pero nadie tiene el panel abierto a las
// tres de la mañana. Por eso la alerta sale por Telegram al personal que
// puede atender: el aviso va a donde la persona ya está mirando.
//
// Quién recibe es una consulta de permisos, no una lista en el código: se le
// avisa a quien tenga `conversaciones.atender` y haya usado el bot alguna vez
// (sin chat_id no hay a dónde escribir). Cambiar a quién se le avisa es un
// cambio de permisos, no un despliegue.
// ---------------------------------------------------------------------------

import { enviarMensaje } from '../telegram.js';

export const tipo = 'alertar_personal';

export async function manejar({ payload }, { db, log }) {
  const conversacionId = payload?.conversacion_id;
  if (!conversacionId) throw new Error('payload sin conversacion_id');

  const { rows: cRows } = await db.query(
    `SELECT c.canal, c.motivo_escalamiento, c.intencion,
            ct.celular, COALESCE(u.nombre_completo, ct.nombre) AS nombre,
            (SELECT m.texto FROM mensaje m
              WHERE m.conversacion_id = c.id AND m.direccion = 'entrante'
              ORDER BY m.id DESC LIMIT 1) AS ultimo
       FROM conversacion c
       JOIN contacto ct ON ct.id = c.contacto_id
       LEFT JOIN usuario u ON u.id = ct.usuario_id
      WHERE c.id = $1`,
    [conversacionId],
  );
  const c = cRows[0];
  if (!c) throw new Error(`la conversación ${conversacionId} no existe`);

  const { rows: destinos } = await db.query(
    `SELECT u.telegram_chat_id AS chat_id, u.nombre_completo AS nombre
       FROM usuario u
       JOIN v_usuario_permiso p ON p.usuario_id = u.id
      WHERE p.permiso_codigo = 'conversaciones.atender'
        AND u.activo AND u.telegram_chat_id IS NOT NULL`,
  );

  if (destinos.length === 0) {
    // No es un fallo de la tarea: es una clínica sin nadie habilitado para
    // atender el chat. Se deja dicho en el log y se completa, porque
    // reintentar cinco veces no va a crear un usuario.
    log.aviso(
      `conversación ${conversacionId} escalada y nadie tiene 'conversaciones.atender' ` +
        'con Telegram vinculado: la alerta se queda en el panel',
    );
    return { avisados: 0, motivo: 'sin_destinatarios' };
  }

  const texto =
    '🚨 <b>Un chat necesita a una persona</b>\n' +
    `${c.nombre ?? 'Alguien'}${c.celular ? ` · ${c.celular}` : ''} (${c.canal})\n` +
    `Motivo: ${payload.motivo ?? c.motivo_escalamiento ?? 'sin especificar'}\n` +
    (c.ultimo ? `\nÚltimo mensaje:\n«${c.ultimo}»` : '');

  const envios = await Promise.allSettled(
    destinos.map((d) => enviarMensaje(Number(d.chat_id), texto)),
  );

  const entregados = envios.filter((e) => e.status === 'fulfilled' && e.value.ok).length;

  // Si no llegó a nadie, se lanza: la cola reintenta con backoff. Un
  // escalamiento que nadie recibió es exactamente lo que no puede quedarse
  // callado.
  if (entregados === 0) {
    throw new Error(`no se pudo avisar a ninguno de los ${destinos.length} destinatarios`);
  }

  return { avisados: entregados, de: destinos.length };
}
