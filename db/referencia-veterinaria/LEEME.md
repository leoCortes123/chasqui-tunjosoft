# Migraciones del dominio veterinario — no se ejecutan

Vienen de `chasqui_assistant` (Abanimal). No están en `db/migrations/`, así que
Postgres nunca las corre. Se conservan por dos razones concretas:

- `130_triaje.sql` — el patrón que vale oro: detectar por `SELECT` **antes**
  de que el modelo vea el mensaje y recitar una instrucción literal aprobada.
  En TunjoSoft ese patrón vive en `db/migrations/130_salidas.sql`, sin las
  filas clínicas.
- `120_agenda.sql` — la mecánica de cupos y disponibilidad. Agendar una
  reunión con un prospecto es lo mismo con menos reglas; `120_reuniones.sql`
  es su versión reducida.

El resto (`100_pacientes`, `110_estudios`, `150_herramientas`,
`810_seed_operativo`) queda solo como referencia de estilo. Si algún día
estorban, se borran sin consecuencias.
