# Chasqui TunjoSoft

El asistente propio de la agencia, y el demo que se le muestra a un prospecto.
Dos caras del mismo bot:

- **Pública** — responde por TunjoSoft: qué hacemos, cuánto vale, y agenda la
  reunión de diagnóstico. Que el prospecto **use** el asistente para agendar la
  reunión en la que se le va a vender el asistente es la demostración entera.
- **Interna** — el pipeline comercial por Telegram: prospectos, seguimientos,
  propuestas y auditorías. Es lo que hoy se olvida.

Es el mismo bot y el mismo chat. Lo que ve cada quien lo decide `audiencia` en
`ia_herramienta`, no dos sistemas distintos.

Antes de trabajar, leer en este orden:
1. `TUNJOSOFT.md` — por qué existe este repositorio y qué no se puede romper
2. `docs/METODO.md` — el proceso de trabajo con un cliente, fases 0 a 5
3. `docs/CLIENTES.md` — el pipeline real. **Es el insumo del asistente interno**
4. `README.md` — puertos, estructura, cómo arranca

---

## Origen

Copia de `../chasqui_assistant` (demo de Abanimal), podada y renombrada. Se
copió el sistema completo porque las migraciones se referencian de forma
cruzada y extraer «solo lo reutilizable» produce una base que no arranca.

**El demo de Abanimal está vivo, esperando respuesta del cliente, y no se
toca.** Bot distinto, volúmenes distintos, puertos distintos. Nunca
`docker compose down` en `../chasqui_assistant`, y nunca tocar los volúmenes
`chasqui_assistant_*` ni `chasquipet_*`.

`db/referencia-veterinaria/` guarda las migraciones del vertical anterior. **No
se ejecutan** —no están en `db/migrations/`— y están ahí por dos patrones que
valía la pena conservar: ver su `LEEME.md`.

---

## Lo que se arregló aquí, y es lo que se lleva de vuelta

Los tres arreglos de genericidad que no se podían hacer en Assistant sin
arriesgar su demo. Están hechos y probados contra un vertical que no es
veterinario, que era justamente la prueba:

1. **El prompt salió del código.** `worker/src/tareas/chasqui_responder.js` ya
   no sabe a qué se dedica el negocio. Son cuatro filas de `config`:
   `prompt_identidad`, `prompt_giro`, `prompt_limites`, `prompt_tono`.
   Identidad y giro cambian con cada cliente; límites y tono casi nunca, y son
   los que sostienen el producto.
2. **`ia_contexto` se compone desde un catálogo.** `ia_contexto_fuente`
   registra funciones `f(contacto, sede) → {valor, linea}`. Cada fuente
   **redacta su propia línea del prompt**, incluida la del caso vacío, porque
   quien conoce el dato es quien sabe cómo decirlo. Se acabaron las claves
   fijas `clinica`, `pacientes`, `citas`.
3. **El dominio extiende el motor, no lo reemplaza.** `ia_herramienta` tiene
   `fn_leer`, `fn_escribir`, `fn_resumen` y `fn_validar`: el nombre de la
   función que ejecuta cada herramienta. El núcleo despacha. Agregar una
   herramienta es un `INSERT`, y ya no puede borrar otra sin avisar — que es
   como se perdió más de una vez la rama de `pedir_asesor`.

---

## Principios heredados — se respetan

- **La base de datos es la fuente única de verdad.** El comportamiento vive en
  filas y funciones de Postgres, no en código de n8n ni del worker.
- **Los permisos son datos**, nunca constantes en código.
- **El asistente no escribe SQL.** Catálogo cerrado de herramientas que llaman
  a las mismas funciones que usan los botones y el portal.
- **Leer se hace solo; escribir se confirma con un botón.** Toda herramienta
  con `escribe = true` deja una propuesta y la dispara la persona. **La regla
  no se relaja porque del otro lado haya un prospecto y no un empleado.**
- **Append-only real** sobre auditoría y `mensaje`: la aplicación no tiene
  `DELETE`. Se corrige con un registro inverso.
- **El webhook responde en menos de un segundo.** Todo lo lento va a
  `tarea_async` y lo procesa el worker.
- **Todo en español**: tablas, funciones, variables, comentarios y mensajes.

## Principios propios de este proyecto

- **Ningún precio sale de la memoria del modelo.** Las etapas A–E y la
  operación mensual son filas de `servicio`; siempre `cotizar_servicio`, que
  devuelve `como_decirlo` junto al valor para que la instrucción viaje pegada
  al dato.
- **Lo que no existe no se ofrece.** `servicio.disponible = false` saca un
  servicio de `listar_servicios` sin borrarlo. Hoy lo usa el contestador
  telefónico con voz, que está cotizado en una propuesta y **no existe**. Que
  el sistema lo impida vale más que la nota en un documento que alguien
  recordará.
- **Las promesas se recitan, no se generan.** `respuesta_literal` +
  `termino_literal`, detectadas con un `SELECT` en `asistente_recibir`
  **antes** de que el modelo vea el mensaje. Es el anexo «lo que no se
  promete» de `METODO.md` convertido en filas: la primera posición en Google,
  los plazos, ChatGPT, comprar enlaces o reseñas, bases de datos. Un modelo
  entrenado para sonar servicial dice que sí, y eso cuesta un contrato.
  `v_literal_sin_aprobar` lista las que falta firmar.
- **Suena como persona, pero no miente sobre serlo.** Si le preguntan de frente
  si es un bot, lo dice — y aquí más que en ningún otro vertical, porque quien
  pregunta está evaluando comprar un bot. Lo ataja la base, no el prompt: en
  Assistant, pedido en el prompt, el modelo mintió dos de cada tres veces.
- **Siempre hay salida a humano.** «ASESOR» en cualquier momento; el bot se
  calla en ese hilo hasta que la persona lo devuelva.
- **Un campo vacío en el contexto es una invitación a alucinar.** Con la sede
  sin sembrar, el modelo inventó dirección y horario completos. Cada fuente de
  contexto necesita su rama de «no lo tengo». Por eso la dirección y el
  teléfono de la agencia están vacíos a propósito y el bot lo dice.
- **El cupo lo decide la base, no la lectura.** `horarios_reunion` no reserva
  nada; el `EXCLUDE` de `reunion` rechaza el segundo que llegue y la función
  devuelve un error escrito para que el modelo sepa qué hacer con él.
- **Ley 1581 de 2012.** No se cargan bases compradas ni se mandan mensajes
  masivos. `prospecto.origen` existe para poder demostrar de dónde salió cada
  dato, y la política de tratamiento se publica antes de guardar contactos.

---

## Puertos

Conviven cuatro sistemas en la misma máquina:

| | Chasqui (n8n) | Chasqui Pet | Assistant | **este** |
|---|---|---|---|---|
| Postgres | 5432 | 5433 | 5434 | **5435** |
| n8n | 5678 | 5679 | 5680 | **5681** |
| Portal | — | 3100 | 3200 | **3300** |
| Proxy | — | 8081 | 8082 | **8083** |

Volúmenes: `chasqui_tunjosoft_pgdata`, `_n8ndata`, `_caddydata`. **Nunca tocar
`chasqui_assistant_*` ni `chasquipet_*`: esos sistemas están en manos de
clientes esperando.**

---

## Estructura de las migraciones

| | |
|---|---|
| `000`–`095` | Núcleo. No sabe de qué giro es el negocio |
| `090_seed_roles` | Permisos. **Antes que cualquier catálogo que los referencie** |
| `100_comercial` | Servicios y precios |
| `110_prospectos` | Pipeline: prospectos, interacciones, seguimientos, propuestas, auditorías |
| `120_reuniones` | Agenda |
| `130_salidas` | Respuestas literales, «ASESOR», «¿eres un bot?» |
| `140`/`145` | Canales: Telegram y WhatsApp |
| `150_herramientas` | El catálogo y sus funciones. **Extiende, no reemplaza** |
| `810_seed_operativo` | Los datos de TunjoSoft |
| `900_*` | Grants y contraseñas de rol |

---

## Reglas de operación

- «Sube los servicios» significa `docker compose up -d`. Nunca `down`, nunca
  recrear contenedores, salvo pedido explícito.
- `db/migrations/` solo corre con el volumen vacío. Para rehacer el esquema en
  desarrollo hay que borrar `chasqui_tunjosoft_pgdata` — **verificar el nombre
  antes de borrar nada.**
- Después de tocar un JSON de `n8n/workflows/`: `bash scripts/importar-n8n.sh`.
  Respeta `"active": false` — hoy el webhook de WhatsApp nace apagado.
- Para conversar sin gastar un mensaje real: `bash scripts/probar-chat.sh "..."`.
  Entra por la misma puerta que el canal real.
