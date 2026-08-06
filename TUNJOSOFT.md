# Chasqui TunjoSoft — plan de la copia

Qué copiar de `chasqui_assistant` al repositorio nuevo `chasqui_tunjoSoft`,
qué dejar afuera y qué hay que renombrar para que los dos sistemas convivan
sin pisarse.

**Motivo.** El demo de Chasqui Assistant está corriendo a la espera de que
Abanimal lo pruebe y no se puede intervenir. TunjoSoft es la copia donde sí se
trabaja: es el asistente propio de la agencia —para no ser casa de herrero—,
ayuda en el acercamiento a clientes y **es el demo que se muestra**.

Beneficio secundario, y no es menor: es el lugar seguro para hacer los tres
arreglos de genericidad pendientes (prompt a la base, `ia_contexto` por
catálogo, `nucleo/` compartido). Se hacen aquí, se prueban aquí, y cuando
Abanimal responda se llevan a Assistant ya probados. El segundo vertical se
construye contra un cliente real: nosotros.

---

## 1. Lo que NO se puede hacer

Cuatro cosas rompen el demo de Abanimal. Ninguna es reversible sola.

1. **No reutilizar el token del bot de Telegram.** Es el riesgo número uno. Un
   token tiene un solo webhook registrado; el servicio `registrador` de
   TunjoSoft lo re-apuntaría a sí mismo y el bot de Abanimal dejaría de
   responder sin mensaje de error. **Bot nuevo en @BotFather, token nuevo.**
2. **No reutilizar los nombres de volumen.** `chasqui_assistant_pgdata`,
   `_n8ndata` y `_caddydata` quedan intactos. Los nuevos llevan
   `chasqui_tunjosoft_`.
3. **No reutilizar puertos.** Ver la tabla de la sección 4.
4. **Nunca `docker compose down` en `chasqui_assistant`.** Regla ya vigente,
   se repite porque durante la copia se está trabajando en la carpeta de al
   lado y es fácil equivocarse de terminal.

Y de siempre: **no tocar los volúmenes `chasquipet_*`.**

---

## 2. Qué se copia

```bash
# Desde /mnt/datos/Programacion
cp -a chasqui_assistant chasqui_tunjoSoft
cd chasqui_tunjoSoft
rm -rf .git referencia backups docs .env
git init
```

Se copia todo y se poda, en vez de copiar selectivamente: el sistema está
entrelazado y armarlo por piezas produce una base que no arranca. Ese fue el
razonamiento cuando se creó Assistant desde chasquiPet y sigue siendo válido.

### Se borra después de copiar

| Qué | Por qué |
|---|---|
| `.git/` | Historia de otro producto. Repositorio nuevo desde cero. |
| `referencia/` | Es material de consulta de chasquiPet, no se compila ni se edita. Si se necesita, está en su sitio. |
| `backups/` | 416 KB de respaldos de la base de Abanimal. No tienen nada que hacer aquí. |
| `.env` | **Contiene secretos en uso.** Se regenera desde `.env.example`. Todas las claves nuevas. |
| `docs/` | Casi todo es de Abanimal. Ver excepciones abajo. |

### De `docs/` se rescatan tres

| Archivo | Qué hacer |
|---|---|
| `METODO.md` | Copiar tal cual. Es el método de trabajo con clientes, no es de Abanimal. |
| `CLIENTES.md` | Copiar tal cual. **Este es el insumo del asistente comercial.** |
| `SEO-AUDITORIA.md` | Copiar como plantilla, con los datos de Abanimal borrados. |

`PROPUESTA.md`, `PLAN.md`, `SEO-PROPUESTA-COMERCIAL.md`,
`conversacion-real-abanimal.md` y `propuesta-web/` se quedan donde están.

`scripts/auditar.sh` sí se copia: es la herramienta de calificación de
prospectos y su lugar natural es aquí.

---

## 3. Migraciones: qué sobrevive

El núcleo ya está separado — se comprobó midiendo: suma unas 2.900 líneas y
contiene **10 menciones veterinarias en total**.

### Se copian sin tocar (el núcleo)

| Archivo | Líneas | Qué aporta |
|---|---:|---|
| `000_n8n_db.sh` | — | Base y usuario de n8n |
| `010_base.sql` | 403 | `config`, `sede`, auditoría, `tarea_async`, rate limit |
| `020_identidad.sql` | 314 | Usuarios, roles, permisos, sesiones, estado conversacional |
| `030_actor.sql` | 387 | `contacto`, `conversacion`, `mensaje`, escalar a humano |
| `040_asistente.sql` | 627 | El motor: catálogo, acciones pendientes, confirmación |
| `050_auth_web.sql` | 567 | Ingreso al portal por Telegram |
| `060_admin.sql` | 398 | Administración |
| `070_mantenimiento.sql` | 102 | Poda y jobs |
| `090_seed_roles.sql` | 93 | Permisos y roles — **se siembran antes que cualquier catálogo** |
| `095_seed_nucleo.sql` | 65 | Config genérica, una sede, superadmin |
| `140_canal_telegram.sql` | 220 | El canal |
| `900_grants.sql` | 97 | Roles de base de datos |
| `900_superadmin.sh` | — | Contraseñas de roles |

Único ajuste en el núcleo: en `095_seed_nucleo.sql` la clave de configuración
se llama `nombre_clinica`. Renombrarla a `nombre_negocio` aquí — es el momento
barato de hacerlo y es exactamente el tipo de fuga de vocabulario que después
cuesta.

### Se borran (dominio veterinario)

| Archivo | Líneas | Destino |
|---|---:|---|
| `100_pacientes.sql` | 267 | Fuera |
| `110_estudios.sql` | 427 | Fuera |
| `120_agenda.sql` | 739 | **Revisar antes de borrar.** Agendar reuniones con prospectos es la misma mecánica que agendar estudios; puede que se rescate el 70 %. |
| `130_triaje.sql` | 820 | **No borrar sin extraer el patrón.** La estructura —detectar por `SELECT` antes del modelo y recitar una instrucción literal aprobada— es genérica y vale oro. Las filas veterinarias sí se van. |
| `150_herramientas.sql` | 416 | Se reescribe entero |
| `810_seed_operativo.sql` | 197 | Se reescribe entero (datos de TunjoSoft) |

---

## 4. Renombrado

Hay **123 apariciones** de `chasqui_assistant` / `chasqui-assistant` en 23
archivos fuera de `docs/`, `.git`, `node_modules` y `referencia`:

```
CLAUDE.md                          n8n/workflows/01-telegram-webhook.json
README.md                          n8n/workflows/04-job-mantenimiento.json
.env.example                       scripts/backup.sh
docker-compose.yml                 scripts/configurar-bot.sh
db/migrations/000_n8n_db.sh        scripts/importar-n8n.sh
db/migrations/900_grants.sql       scripts/probar-chat.sh
db/migrations/900_superadmin.sh    scripts/registrar-publico.sh
web/package.json                   scripts/restaurar.sh
web/package-lock.json              web/src/lib/db.ts
web/README.md                      web/src/lib/sesion.ts
worker/package.json                worker/package-lock.json
worker/src/index.js
```

Sustitución mecánica `chasqui_assistant` → `chasqui_tunjosoft` y
`chasqui-assistant` → `chasqui-tunjosoft`, y después revisar a mano
`docker-compose.yml` y `.env.example`, que son los dos donde un descuido choca
con el sistema vivo.

> Nota sobre minúsculas: el repositorio se llama `chasqui_tunjoSoft` como pidió
> el usuario, pero **nombres de volumen, base de datos, roles de Postgres,
> contenedores y red van en minúscula** (`chasqui_tunjosoft`). Docker y
> Postgres tratan mal las mayúsculas y no vale la pena averiguar cómo.

### Puertos

| | Chasqui (n8n) | Chasqui Pet | Assistant | **TunjoSoft** |
|---|---|---|---|---|
| Postgres | 5432 | 5433 | 5434 | **5435** |
| n8n | 5678 | 5679 | 5680 | **5681** |
| Portal | — | 3100 | 3200 | **3300** |
| Proxy | — | 8081 | 8082 | **8083** |

### Identificadores a cambiar

- `name:` del compose → `chasqui_tunjosoft`
- Red → `chasqui_tunjosoft`
- `container_name` de los 8 servicios → `chasqui-tunjosoft-*`
- Imágenes → `chasqui-tunjosoft/worker`, `chasqui-tunjosoft/web`
- Volúmenes → `chasqui_tunjosoft_pgdata`, `_n8ndata`, `_caddydata`
- Roles de Postgres → `chasqui_tunjosoft_app`, `chasqui_tunjosoft_lectura`
- `TELEGRAM_WEBHOOK_PATH` → `chasqui-tunjosoft-telegram`

### Secretos: todos nuevos

`POSTGRES_PASSWORD`, `APP_DB_PASSWORD`, `READONLY_DB_PASSWORD`,
`N8N_DB_PASSWORD`, `N8N_BASIC_AUTH_PASSWORD`, `N8N_ENCRYPTION_KEY`,
`SESSION_SECRET` — `openssl rand` para cada uno. **`TELEGRAM_BOT_TOKEN`: bot
nuevo, obligatorio.** `SUPERADMIN_TELEGRAM_USER_ID` sí es el mismo, es la
misma persona.

`DEEPSEEK_API_KEY` puede ser la misma cuenta, pero conviene una llave aparte
para poder separar el costo del demo del costo del cliente.

---

## 5. El dominio nuevo

Aquí está lo que hay que diseñar en la sesión siguiente. TunjoSoft tiene dos
caras y conviene no confundirlas.

### Cara interna — el asistente personal (por Telegram)

Habla con el equipo. Lo que necesita saber:

- **Prospectos**: el pipeline de `CLIENTES.md` convertido en tablas. Estado,
  peldaño, resultado de la prueba de WhatsApp, próxima acción, fecha.
- **Auditorías**: resultado de `auditar.sh` guardado por sitio y por fecha, para
  poder comparar antes y después — que es justo lo que exige la fase 4 del
  método.
- **Seguimientos**: la agenda de contactos pendientes. Lo que hoy se olvida.
- **Propuestas**: qué se mandó, a quién, cuándo, por cuánto, y en qué quedó.

Herramientas candidatas (`ia_herramienta`): `listar_prospectos`,
`estado_prospecto`, `registrar_contacto`, `agendar_seguimiento`,
`resultado_auditoria`, `proximas_acciones`. Las de escritura dejan propuesta y
se confirman con botón, igual que siempre.

### Cara pública — el demo comercial

Es lo que ve un prospecto. Responde por el negocio de la agencia: qué se hace,
qué incluye cada etapa, cuánto cuesta, y agenda una reunión. Tres reglas que
vienen del producto y aquí importan más que nunca:

- **Ningún precio sale de la memoria del modelo.** Las etapas A–E y la
  operación mensual son filas, no texto del prompt.
- **Suena como persona pero no miente sobre serlo.** Si preguntan si es un bot,
  lo dice. Frente a un prospecto que está evaluando comprar un bot, mentir es
  la peor demostración posible.
- **Siempre hay salida a humano.**

Que el prospecto **use** el asistente para agendar la reunión en la que se le
va a vender el asistente es la demostración. No hace falta explicarla.

### Los tres arreglos de genericidad

Se hacen aquí porque aquí se pueden hacer:

1. Sacar el prompt de `worker/src/tareas/chasqui_responder.js:60` —hoy dice
   literalmente «una clínica veterinaria en Colombia»— y llevarlo a `config`,
   partido en identidad, giro, límites y tono.
2. `ia_contexto` compuesta desde un catálogo de fuentes, en vez de las claves
   fijas `clinica`, `pacientes`, `citas`, `'peso colombiano (COP)'`.
3. Que `150_herramientas` **extienda** el motor en vez de reemplazar cinco de
   sus funciones con `CREATE OR REPLACE`.

Si TunjoSoft arranca con estos tres hechos, queda probado que el motor sirve
para cualquier giro. Y eso deja de ser una promesa de venta para volverse un
hecho verificable.

---

## 6. Orden de trabajo sugerido

1. Copiar, podar, `git init`.
2. Renombrar los 123 literales; revisar compose y `.env` a mano.
3. Borrar el dominio veterinario; conservar `130_triaje` y `120_agenda` en un
   lado para extraerles el patrón.
4. Bot nuevo, secretos nuevos, levantar con el volumen vacío y verificar que
   arranca sin errores **antes** de escribir una línea de dominio.
5. Confirmar que Assistant sigue vivo y respondiendo. Es el paso que se olvida.
6. Los tres arreglos de genericidad.
7. Diseñar el dominio: prospectos, auditorías, seguimientos, propuestas.
8. Catálogo de herramientas y seed de TunjoSoft.

Los pasos 1 a 5 son mecánicos y se pueden hacer de corrido. Del 6 en adelante
hay decisiones de diseño y conviene tomarlas despacio: lo que se decida ahí es
la forma que va a tener el producto genérico.
