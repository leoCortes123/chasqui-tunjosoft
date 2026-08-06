'use client';

import { useActionState } from 'react';
import { guardarConfig, type Resultado } from '../acciones';
import estilos from '../../vistas.module.css';
import tabla from '../../admin.module.css';

export interface FilaConfig {
  clave: string;
  valor: string;
  tipo: string;
  descripcion: string | null;
  editable: boolean;
}


function mensaje(estado: Resultado | null): string | null {
  if (!estado) return null;
  return estado.ok ? 'Guardado' : (estado.mensaje ?? 'No se pudo');
}

export function FilaParametro({ fila }: { fila: FilaConfig }) {
  const [estado, accion, enviando] = useActionState(guardarConfig, null);

  return (
    <tr className={fila.editable ? undefined : tabla.tenue}>
      <td>
        <code>{fila.clave}</code>
      </td>
      <td>{fila.descripcion ?? '—'}</td>
      <td>
        {fila.editable ? (
          <form className={tabla.enLinea} action={accion}>
            <input type="hidden" name="clave" value={fila.clave} />
            <input
              className={tabla.compacto}
              name="valor"
              defaultValue={fila.valor}
              inputMode={fila.tipo === 'entero' ? 'numeric' : 'text'}
            />
            <button className={tabla.botonCompacto} type="submit" disabled={enviando}>
              {enviando ? '…' : 'Guardar'}
            </button>
            {estado && (
              <span className={estado.ok ? undefined : tabla.peligro}>{mensaje(estado)}</span>
            )}
          </form>
        ) : (
          <>
            {fila.valor}
            <span className={tabla.tenue}> · no editable desde el portal</span>
          </>
        )}
      </td>
    </tr>
  );
}

