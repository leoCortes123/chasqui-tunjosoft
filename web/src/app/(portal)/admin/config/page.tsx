import type { Metadata } from 'next';
import Link from 'next/link';
import { consultar } from '@/lib/db';
import { exigirPermiso } from '@/lib/sesion';
import { FilaParametro, type FilaConfig } from './formularios';
import estilos from '../../vistas.module.css';
import tabla from '../../admin.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Configuración — Chasqui TunjoSoft',
  robots: { index: false, follow: false },
};

interface Consultorio {
  id: string;
  nombre: string;
  activo: boolean;
  orden: number;
}

/**
 * Configuración operativa (§11.2). Todo lo de aquí son filas de tablas
 * que el sistema lee en caliente: cambiar el nombre de la clínica o los
 * parámetros del asistente no exige desplegar nada ni reiniciar el bot.
 *
 * Las tarifas de estudios tienen su propia vista en la fase 2: la regla de
 * precio depende del día (L–S vs. domingos y festivos) y no cabe en una
 * tabla de clave/valor.
 */
export default async function PaginaConfig() {
  await exigirPermiso('config.editar', '/admin/config');

  const [parametros, consultorios] = await Promise.all([
    consultar<FilaConfig>('SELECT * FROM config_listado()'),
    consultar<Consultorio>(
      'SELECT id, nombre, activo, orden FROM consultorio ORDER BY orden, nombre',
    ),
  ]);

  return (
    <>
      <p className={tabla.migaja}>
        <Link href="/admin">← Administración</Link>
      </p>
      <h1 className={estilos.titulo}>Configuración</h1>
      <p className={estilos.subtitulo}>
        El bot y el portal leen esto en caliente. No hace falta reiniciar nada.
      </p>

      <section>
        <h2 className={estilos.titulo}>Parámetros</h2>
        <div className={tabla.desplazable}>
          <table className={tabla.tabla}>
            <thead>
              <tr>
                <th>Clave</th>
                <th>Para qué sirve</th>
                <th>Valor</th>
              </tr>
            </thead>
            <tbody>
              {parametros.map((p) => (
                <FilaParametro key={p.clave} fila={p} />
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section className={tabla.seccion}>
        <h2 className={estilos.titulo}>Consultorios</h2>
        <ul className={estilos.lista}>
          {consultorios.map((c) => (
            <li key={c.id} className={estilos.fila}>
              <span className={estilos.emoji}>🚪</span>
              <span className={estilos.filaTexto}>
                <span className={estilos.filaNombre}>{c.nombre}</span>
                <span className={estilos.filaDetalle}>orden {c.orden}</span>
              </span>
              <span className={`${estilos.etiqueta} ${c.activo ? estilos.firmada : estilos.anulada}`}>
                {c.activo ? 'activo' : 'inactivo'}
              </span>
            </li>
          ))}
        </ul>
      </section>
    </>
  );
}
