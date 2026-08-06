# Chasqui TunjoSoft

El asistente conversacional de la agencia. Dos caras del mismo bot, en el mismo
chat:

- **Pública — el demo comercial.** Responde por TunjoSoft: qué hacemos, qué
  incluye cada etapa, cuánto cuesta, y agenda la reunión de diagnóstico. Que el
  prospecto **use** el asistente para agendar la reunión en la que se le va a
  vender el asistente es la demostración. No hace falta explicarla.
- **Interna — el asistente propio.** El pipeline comercial por Telegram:
  prospectos, seguimientos, propuestas y auditorías de sitios. Es lo que hoy se
  olvida, y para no ser casa de herrero.

Lo que ve cada quien lo decide la columna `audiencia` del catálogo de
herramientas. No son dos sistemas.

---

## De dónde viene

Copia de **Chasqui Assistant** (`../chasqui_assistant`), el demo de Abanimal
Clínica Veterinaria. Se copió el sistema completo y funcionando en vez de armar
un esqueleto a mano, porque las migraciones se referencian de forma cruzada y
extraer «solo lo reutilizable» produce una base que no arranca.

**El demo de Abanimal sigue vivo esperando respuesta del cliente y no se
toca**: bot distinto, token distinto, puertos y volúmenes distintos. El detalle
de qué se copió, qué se podó y qué no se podía romper está en
[`TUNJOSOFT.md`](TUNJOSOFT.md).

`db/referencia-veterinaria/` guarda las migraciones del vertical anterior. **No
se ejecutan**: no están en `db/migrations/`. Ver su `LEEME.md`.

---

## Estado

**El sistema levanta desde cero sin errores y el asistente responde por los dos
lados.** Falta el número de WhatsApp y las vistas del pipeline en el portal.

### Los tres arreglos de genericidad — hechos

Se hicieron aquí porque aquí se podían hacer, y quedaron probados contra un
giro que no es veterinario, que era justamente la prueba:

1. **El prompt salió del código.** El worker ya no sabe a qué se dedica el
   negocio. Son cuatro filas de `config` editables desde el portal:
   `prompt_identidad`, `prompt_giro`, `prompt_limites`, `prompt_tono`.
2. **`ia_contexto` se compone desde un catálogo de fuentes**
   (`ia_contexto_fuente`), y cada fuente redacta su propia línea del prompt,
   incluida la del caso vacío.
3. **El dominio extiende el motor en vez de reemplazarlo.** El catálogo guarda
   el nombre de la función que ejecuta cada herramienta (`fn_leer`,
   `fn_escribir`, `fn_resumen`, `fn_validar`) y el núcleo despacha. Agregar una
   herramienta es un `INSERT`.

Con eso, «el motor sirve para cualquier giro» deja de ser una promesa de venta
y pasa a ser un hecho verificable.

### Qué hay hoy

| Migración | Qué aporta |
|---|---|
| `010_base.sql` | `config`, sedes, auditoría, cola `tarea_async`, rate limit, fechas en `America/Bogota` |
| `020_identidad.sql` | Usuarios, roles y permisos **como datos** |
| `030_actor.sql` | Contacto, conversación y mensaje: atender a un desconocido, no solo a personal con sesión |
| `040_asistente.sql` | El motor: catálogo por **audiencia**, confirmación obligatoria para escribir, contexto por fuentes |
| `050_auth_web.sql` | Ingreso al portal sin contraseñas, con enlace de un solo uso |
| `060_admin.sql` | Usuarios, config, auditoría, cola de tareas y salud |
| `070_mantenimiento.sql` | La poda diaria de lo que crece para siempre |
| `090_seed_roles.sql` | Roles y permisos del negocio |
| `100_comercial.sql` | Servicios y precios: las etapas A–E y la operación mensual, **en filas** |
| `110_prospectos.sql` | Prospectos, interacciones, seguimientos, propuestas y auditorías de sitios |
| `120_reuniones.sql` | La agenda, con `EXCLUDE` contra el doble cupo |
| `130_salidas.sql` | Respuestas literales, «ASESOR» y «¿eres un bot?», **antes del modelo** |
| `140`/`145` | Los canales: Telegram y WhatsApp |
| `150_herramientas.sql` | El catálogo de herramientas y sus funciones |
| `810_seed_operativo.sql` | Los datos de TunjoSoft y el pipeline de `docs/CLIENTES.md` |
| `900_grants.sql` | Roles de BD con **append-only real** sobre auditoría y mensajes |

### Qué falta

El número de WhatsApp (todo lo demás del canal ya está escrito, ver abajo), las
vistas del pipeline en el portal, y los datos de contacto de la agencia —que
están vacíos **a propósito**: el bot dice que no los tiene en vez de
inventarlos.

---

## Puertos

Cuatro sistemas conviven en la misma máquina:

| | Chasqui (n8n) | Chasqui Pet | Assistant | **TunjoSoft** |
|---|---|---|---|---|
| Postgres | 5432 | 5433 | 5434 | **5435** |
| n8n | 5678 | 5679 | 5680 | **5681** |
| Portal web | — | 3100 | 3200 | **3300** |
| Proxy | — | 8081 | 8082 | **8083** |

---

## Arrancar

```bash
cp .env.example .env      # y editar: claves, token del bot, superadmin
docker compose up -d      # el perfil "local" ya viene puesto en .env
bash scripts/importar-n8n.sh
bash scripts/configurar-bot.sh
```

La base solo corre `db/migrations/` la **primera** vez, con el volumen
`chasqui_tunjosoft_pgdata` vacío. Para rehacer el esquema durante el desarrollo
hay que borrar ese volumen — **verificando el nombre**, no el de Assistant ni el
de Chasqui Pet.

Para probar un cambio de esquema sin tocar el volumen ni recrear contenedores,
un Postgres desechable con las migraciones montadas alcanza:

```bash
docker run --rm -d --name prueba-esquema \
  -e POSTGRES_USER=chasqui_tunjosoft -e POSTGRES_PASSWORD=prueba \
  -e POSTGRES_DB=chasqui_tunjosoft -e APP_DB_PASSWORD=x \
  -e N8N_DB_NAME=n8n -e N8N_DB_USER=n8n -e N8N_DB_PASSWORD=x \
  -v "$PWD/db/migrations:/docker-entrypoint-initdb.d:ro" postgres:16-alpine
docker logs prueba-esquema 2>&1 | grep ERROR
```

**Sin `DEEPSEEK_API_KEY` el asistente no responde**: escala la conversación a
una persona y lo dice. Es el comportamiento correcto, no un error.

---

## Probar el asistente

```bash
bash scripts/probar-chat.sh "hola, que hacen ustedes?"
bash scripts/probar-chat.sh "cuanto vale el asistente?"
bash scripts/probar-chat.sh "me garantizan el primer lugar en google?"
bash scripts/probar-chat.sh "eres un bot?"
```

Entra por la misma puerta que el canal real (`asistente_recibir`), así que lo
que se ve es lo que vería un prospecto. El segundo argumento es el celular: con
el mismo número la conversación continúa, con uno distinto empieza de cero.

Se invoca con `bash` porque el repositorio vive en NTFS y no admite el bit de
ejecución.

La línea del final dice por dónde salió la respuesta:

| ruta | significa |
|---|---|
| `respuesta_literal` | la recitó la base, sin pasar por el modelo |
| `pregunta_si_es_bot` | preguntaron de frente y se les dijo |
| `pidio_asesor` | dijo «ASESOR» |
| `al modelo` | respondió el modelo |
| `rate_limit` | superó el tope de mensajes por hora |

Por Telegram, el bot es **@TunjoSoftBot**. Ese enlace es el que se le manda a
un prospecto.

### Lo que vale la pena mirar, porque lo decide la base y no el modelo

- **Los precios.** Están en `servicio`, y `cotizar_servicio` devuelve
  `como_decirlo` junto al valor para que la instrucción viaje pegada al dato.
  El modelo no dice una cifra sin llamarla.
- **Lo que no existe no se ofrece.** El contestador telefónico con voz está
  cotizado en una propuesta y no está construido: `disponible = false` lo saca
  del catálogo que ve el asistente sin borrar su historia.
- **Las promesas se recitan.** «¿Me garantizan el primer lugar?» no lo contesta
  el modelo: lo contesta una fila aprobada, detectada con un `SELECT` antes de
  gastar una llamada a la API. Es el anexo «lo que no se promete» de
  `docs/METODO.md` hecho sistema.
- **La agenda no se sobreagenda.** Es un `EXCLUDE` sobre `reunion`, no una
  consulta previa: dos conversaciones simultáneas no pueden tomar la misma hora.
- **El prospecto entra solo al pipeline.** Quien agenda por el chat queda en
  `prospecto` con su interacción registrada, sin que nadie lo transcriba.

```sql
SELECT jsonb_pretty(listar_servicios());
SELECT jsonb_pretty(horarios_reunion('diagnostico'));
SELECT jsonb_pretty(proximas_acciones());
SELECT * FROM v_literal_sin_aprobar;   -- textos que falta firmar
```

Para empezar de cero con todos los hilos:

```sql
DELETE FROM ia_mensaje; DELETE FROM mensaje;
DELETE FROM conversacion; DELETE FROM contacto; DELETE FROM tarea_async;
```

---

## WhatsApp

Está construido y esperando el número:

- `db/migrations/145_canal_whatsapp.sql` — el enrutador del webhook, gemelo del
  de Telegram. Que se parezcan tanto es el argumento: **el canal es una
  columna, no un sistema.**
- `worker/src/whatsapp.js` — el envío por la Cloud API, con la traducción del
  HTML al marcado de WhatsApp y el manejo de la ventana de 24 horas.
- `n8n/workflows/02-whatsapp-webhook.json` — la entrada. **Nace desactivado a
  propósito**: un webhook a medio configurar recibe mensajes de Meta y los
  pierde en silencio.

Mientras `WHATSAPP_TOKEN` esté vacío no pasa nada malo: el canal queda
inactivo, el worker responde `whatsapp_sin_configurar` y el mensaje igual queda
registrado. Los cinco pasos para encenderlo están comentados en `.env.example`,
sección 5b.

---

## Auditar un sitio

```bash
bash scripts/auditar.sh https://sitio.com
bash scripts/auditar.sh --guardar https://sitio.com     # además, a la base
```

Con `--guardar` la corrida queda fechada en `auditoria_sitio` y enganchada al
prospecto si la URL coincide con la suya. Es lo que después permite comparar el
antes y el después —la fase 4 del método—, y lo que lee la herramienta interna
`resultado_auditoria`.

---

## Estructura

```
db/migrations/             esquema, funciones, permisos y seeds (se ejecutan en orden)
db/referencia-veterinaria/ el vertical anterior, NO se ejecuta
n8n/workflows/             webhooks y jobs versionados
worker/                    cola de tareas asíncronas (Node)
web/                       portal (Next.js)
proxy/                     Caddyfile
scripts/                   respaldo, restauración, n8n, webhook, auditoría, chat de prueba
docs/                      método, pipeline y plantilla de auditoría
```

---

## Documentos

- [`TUNJOSOFT.md`](TUNJOSOFT.md) — por qué existe este repositorio y qué no se puede romper
- [`docs/METODO.md`](docs/METODO.md) — el proceso con un cliente, fases 0 a 5, y el anexo «lo que no se promete»
- [`docs/CLIENTES.md`](docs/CLIENTES.md) — el pipeline real. Es el insumo del asistente interno
- [`docs/SEO-AUDITORIA.md`](docs/SEO-AUDITORIA.md) — plantilla de auditoría
- [`CLAUDE.md`](CLAUDE.md) — principios y reglas de operación
