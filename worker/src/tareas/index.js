// ---------------------------------------------------------------------------
// Registro de manejadores de tarea_async.
//
// Para agregar un tipo nuevo: cree src/tareas/<tipo>.js exportando
// `tipo` (string, igual al valor de tarea_async.tipo) y
// `manejar(tarea, ctx)`, e impórtelo aquí. Nada más.
//
//   tarea = { id, tipo, payload, intentos, max_intentos, ... }   (fila completa)
//   ctx   = { db, log }
//   retorno = objeto JSON que se guarda en tarea_async.resultado
//   lanzar  = la tarea se marca con fallar_tarea (backoff y reintentos los
//             decide la base, el worker no reimplementa nada de eso).
// ---------------------------------------------------------------------------

import * as notificarSuperadmin from './notificar_superadmin.js';
import * as notificarInicioSesion from './notificar_inicio_sesion.js';
import * as chasquiResponder from './chasqui_responder.js';
import * as alertarPersonal from './alertar_personal.js';
import * as enviarTexto from './enviar_texto.js';

const MODULOS = [
  notificarSuperadmin,
  notificarInicioSesion,
  chasquiResponder,
  alertarPersonal,
  enviarTexto,
];

export const manejadores = new Map(MODULOS.map((m) => [m.tipo, m.manejar]));

export const tiposConocidos = [...manejadores.keys()].sort();
