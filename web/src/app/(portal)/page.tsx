import type { Metadata } from 'next';
import Link from 'next/link';
import { consultarUna } from '@/lib/db';
import { exigirSesion, puede } from '@/lib/sesion';
import { fecha, numero } from '@/lib/formato';
import estilos from './vistas.module.css';
import tabla from './admin.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Panel — Chasqui TunjoSoft',
  robots: { index: false, follow: false },
};

interface Salud {
  fecha_operativa: string;
  tareas: { pendientes: number; procesando: number; fallidas: number; atraso_seg: number };
  sesiones_activas: number;
  conversaciones: { abiertas: number; con_humano: number };
}

/**
 * La portada del portal. Hoy muestra el pulso del sistema: cuántos hilos hay
 * abiertos, cuántos esperando a una persona y si la cola de tareas va al día.
 *
 * La agenda del día, las conversaciones activas y los cupos liberados —lo que
 * de verdad va a ver la operadora— llegan en la fase 4. Se deja este panel
 * mínimo en vez de una página vacía porque «hay hilos esperando a un humano»
 * es la única cifra que ya se puede medir y que ya importa.
 */
export default async function PaginaPanel() {
  const sesion = await exigirSesion('/');

  const fila = await consultarUna<{ s: Salud }>('SELECT salud_sistema() AS s');
  const s = fila?.s;

  if (!s) {
    return <p className={estilos.vacio}>No se pudo leer el estado del sistema.</p>;
  }

  const atrasoAlto = Number(s.tareas.atraso_seg) > 120;

  return (
    <>
      <h1 className={estilos.titulo}>Hoy, {fecha(s.fecha_operativa)}</h1>
      <p className={estilos.subtitulo}>Lo que está pasando ahora mismo en el canal.</p>

      <section>
        <h2 className={estilos.titulo}>Conversaciones</h2>
        <div className={tabla.indicadores}>
          <Indicador valor={numero(s.conversaciones.abiertas)} etiqueta="Abiertas" />
          <Indicador
            valor={numero(s.conversaciones.con_humano)}
            etiqueta="Esperando a una persona"
            tono={s.conversaciones.con_humano > 0 ? 'alerta' : undefined}
          />
        </div>
      </section>

      <section className={tabla.seccion}>
        <h2 className={estilos.titulo}>Cola de tareas</h2>
        <div className={tabla.indicadores}>
          <Indicador valor={numero(s.tareas.pendientes)} etiqueta="Pendientes" />
          <Indicador valor={numero(s.tareas.procesando)} etiqueta="En proceso" />
          <Indicador
            valor={numero(s.tareas.fallidas)}
            etiqueta="Fallidas"
            tono={s.tareas.fallidas > 0 ? 'grave' : undefined}
          />
          <Indicador
            valor={`${numero(s.tareas.atraso_seg)} s`}
            etiqueta="Atraso"
            // Un atraso alto significa que el worker no está corriendo, aunque
            // el contenedor diga que sí.
            tono={atrasoAlto ? 'alerta' : 'bien'}
          />
        </div>
      </section>

      {puede(sesion, 'sistema.operar') && s.tareas.fallidas > 0 && (
        <section className={tabla.seccion}>
          <h2 className={estilos.titulo}>Pendientes</h2>
          <div className={tabla.tarjetas}>
            <Link className={tabla.tarjeta} href="/admin/tareas">
              <span className={tabla.tarjetaTitulo}>
                {numero(s.tareas.fallidas)} tarea(s) fallida(s)
              </span>
              <span className={tabla.tarjetaDetalle}>
                Respuestas y avisos que no se pudieron entregar.
              </span>
            </Link>
          </div>
        </section>
      )}
    </>
  );
}

function Indicador({
  valor,
  etiqueta,
  tono,
}: {
  valor: string;
  etiqueta: string;
  tono?: 'alerta' | 'grave' | 'bien';
}) {
  return (
    <div className={`${tabla.indicador} ${tono ? tabla[tono] : ''}`}>
      <span className={tabla.indicadorValor}>{valor}</span>
      <span className={tabla.indicadorEtiqueta}>{etiqueta}</span>
    </div>
  );
}
