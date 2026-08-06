# Clientes y prospectos

Estado del embudo comercial a **6 de agosto de 2026**. Este documento existe
para poder retomar la planeación de marketing en una sesión aparte sin volver
a levantar el contexto desde cero.

Documentos hermanos:

- `docs/METODO.md` — el proceso técnico completo por cliente (fases 0 a 5)
- `docs/SEO-AUDITORIA.md` — la auditoría de Abanimal, plantilla de todas las demás
- `docs/SEO-PROPUESTA-COMERCIAL.md` — la propuesta enviada, con la lista de precios
- `scripts/auditar.sh` — la herramienta que produce la tabla de calificación

---

## 1. Qué se vende

Dos productos, un mismo núcleo. Ver el análisis de producto para el detalle
técnico; lo que importa aquí es la escalera comercial.

| Etapa | Qué es | Precio | Estado del producto |
|---|---|---:|---|
| A | Corrección técnica del portal + schema + GBP | $2.400.000 | **Listo**, se puede vender hoy |
| B | Arquitectura de contenido y territorio | $8.500.000 | Listo, es trabajo manual |
| C | Piloto del asistente (se abona íntegro a D) | $1.800.000 | Depende de terminar el dominio |
| D | Asistente en producción | $12.000.000 – 18.000.000 | **En construcción** |
| — | Canal adicional | $2.500.000 | Depende de D |
| — | Contestador telefónico con voz | $4.500.000 – 6.500.000 | **No existe.** Está en la lista de precios sin producto detrás |
| E | Gestión interna (Chasqui Gestión) | $3.500.000 – 6.000.000 | Existe como chasquiPet, falta generalizar |
| — | Operación mensual | $950.000 – 1.500.000 /mes | Es el ancla de ingreso recurrente |

**Riesgo abierto:** el contestador con voz ya está cotizado en la propuesta de
Abanimal. Si lo aceptan, hay que construirlo. No ofrecerlo en propuestas
nuevas hasta tenerlo.

---

## 2. Cliente activo

### Abanimal Clínica Veterinaria — Bogotá (Kennedy)

Centro de referencia nacional en imágenes diagnósticas. Propuesta enviada el
**5 de agosto de 2026**, sin respuesta al momento de escribir esto.

- **Qué se le mandó:** auditoría SEO completa (12 hallazgos) + acceso al demo
  del asistente.
- **La tesis de venta:** «nadie los encuentra, y al que los encuentra se le
  acaba la paciencia esperando respuesta».
- **Evidencia dura disponible:** conversación real archivada en
  `docs/conversacion-real-abanimal.md` — es la prueba más fuerte que existe
  en todo el material y la única fuente de un precio conocido.
- **Aritmética presentada:** ~5.000 ecografías/año × $172.000 ≈ $860M/año;
  recuperar el 5 % ≈ $43M/año.
- **Hallazgo más citable:** la página del director tiene **una sola frase
  indexable**.
- **Datos sembrados en `810_seed_operativo.sql`** salieron de fuentes públicas.
  Hay que hacérselos confirmar antes de cualquier demo en vivo. Un horario
  desactualizado en boca del bot es peor que no tenerlo.

**Siguiente acción pendiente:** seguimiento. Definir cuándo y con qué excusa
(lo natural: un dato nuevo, no un «¿ya lo vio?»).

---

## 3. La escalera de prospectos

Corrección estratégica tomada el 6 de agosto: **no empezar por los clientes
grandes.** Primero clientes pequeños para pulir el proceso y producir casos
mostrables; los grandes después, cuando haya con qué respaldar la promesa.

| Peldaño | Perfil | Qué se le vende | Para qué sirve |
|---|---|---|---|
| **1 — ahora (3 a 5 clientes)** | 1–2 sedes, 100–400 reseñas, sitio roto, WhatsApp atendido a mano | Etapa A → asistente básico | Pulir el proceso y **producir números publicables** |
| **2 — en 6 meses** | Red de 3–10 sedes, especialistas de referencia | Portal + asistente + módulos | Ingreso serio, mensualidad real |
| **3 — en 12–18 meses** | Cuentas ya automatizadas (tipo Malo Dental) | Desplazamiento, con voz e integración | Solo con portafolio y contestadora funcionando |

### La prueba de calificación, antes de invertir una hora

Escribirle al WhatsApp del prospecto **en día hábil y en horario de oficina**,
y repetir un domingo o a las 10 de la noche.

- Contesta un bot → **se descarta** (peldaño 3, no ahora).
- Contesta una persona en 10 minutos con un formulario copiado y pegado →
  **es cliente**.
- No contesta hasta el otro día → es cliente, y ya tienes la evidencia.

Esto invierte la prospección: no se busca el negocio más grande, se busca el
negocio con **la peor puerta de entrada y el mejor servicio detrás**. Son
cosas distintas y la segunda es la que compra.

### Señales de descalificación

1. **Las reseñas critican la calidad técnica**, no la atención. Ese negocio
   tiene un problema que ningún portal ni ningún bot arregla.
2. **Ya automatizó.** Si responde un bot decente y además hay llamada de
   seguimiento cuando uno abandona la conversación, ese cliente ya tiene
   proveedor, con histórico y con relación. Es venta de desplazamiento y
   cuesta cinco veces más.
3. **El ticket no permite decidir $2M sin comité.** Si hay comité, el ciclo
   de venta se mide en meses y no lo aguantas todavía.

---

## 4. Prospectos auditados

20 sitios de Bogotá auditados con `scripts/auditar.sh` el 6 de agosto de 2026.

> **Estado de los datos.** La parte técnica (idioma, meta, H1, alt, schema,
> palabras indexables, stack) es medición directa sobre el HTML crudo y es
> confiable. **La parte de reseñas NO está verificada**: Google Maps no es
> recuperable de forma fiable por búsqueda web, y lo que se obtuvo salió de
> agregadores y resultados de búsqueda. Hay que confirmarlas a mano antes de
> citarlas en cualquier propuesta. Para regenerar la tabla técnica:
>
> ```bash
> ./scripts/auditar.sh https://sitio1.com https://sitio2.com ...
> ```

### Peldaño 1 — calificados, empezar aquí

Falla técnica confirmada. **Falta aplicarles la prueba de WhatsApp** antes de
escribir una sola línea de propuesta.

- Orthovet
- Vetovet
- CPVet
- Dogtor
- Animalandia
- Betel
- Normandía

### Ya correctos técnicamente — solo asistente

No tiene sentido venderles etapa A. Entrada distinta: el problema de atención,
no el de visibilidad.

- Dover
- Clínica Protectora de Animales
- Cliniderma
- VetLevel

### Peldaño 3 — aplazados

- **Malo Dental.** Tiene bot **y** llamada de recuperación al abandonar la
  conversación: embudo diseñado por alguien que sabe. Punto interesante: su
  SEO **sí** está roto (36 de 36 imágenes sin `alt`, sin H1, sin schema), lo
  que revela que su proveedor es de automatización comercial, no de
  posicionamiento. Es un flanco real, pero entrar por SEO donde ya hay
  proveedor de bot es competir por el mismo presupuesto desde la posición
  débil. Revisar en 12 meses, con portafolio.
- **Vetas.** Red de varias sedes; ticket y ciclo de venta por encima del
  peldaño 1.

### No auditables

Excluidos, no reportados como prospectos:

- `reprotec.com.co` — HTTP 000 (timeout / TLS)
- `fertividacolombia.com` — HTTP 000
- `o4odontologia.com` — 404
- `clinisurveterinaria.com` — cuerpo vacío (114 bytes)

---

## 5. Reglas que no se negocian

De `docs/METODO.md`, anexo «lo que no se promete»:

- **No se promete la posición #1.** Google no vende ese lugar y quien lo
  prometa está mintiendo. Se promete legibilidad y visibilidad medible.
- **No se prometen plazos de Google.** Lo técnico se ve en semanas; el
  contenido, en 3 a 6 meses.
- **No se garantiza aparecer en ChatGPT.**
- **No se compran reseñas ni enlaces.** Nunca.
- **No se garantiza volumen de ventas.**

Marco legal (Ley 1581 de 2012, habeas data; multas SIC hasta 2.000 SMMLV):

- No comprar bases de datos.
- No enviar WhatsApp masivos.
- No usar números de celular personales para prospectar.
- Publicar política de tratamiento de datos **antes** de guardar contactos en
  un CRM.

**Sobre el precio:** no cobrar barato por ser pequeño el cliente. El error del
primer año es descontar para cerrar y quedar anclado. Se cobra la etapa A
completa y se descuenta a cambio de **caso de estudio con nombre, números
publicables y testimonio grabado** — eso vale más que el descuento y es lo que
habilita el peldaño 3.

---

## 6. Pendientes para la sesión de marketing

1. Aplicar la prueba de WhatsApp a los siete del peldaño 1 y ordenarlos por
   resultado.
2. Verificar a mano las reseñas de Google Maps de esos siete.
3. Definir el guion de primer contacto: por dónde se entra (¿correo al dueño?
   ¿WhatsApp? ¿visita?) y con qué se abre.
4. Decidir el activo de entrada: ¿se manda la auditoría completa gratis, como
   con Abanimal, o solo el hallazgo más fuerte?
5. Definir el seguimiento a Abanimal.
6. Decidir si se abre una página de ventas por vertical o una sola genérica.
7. Definir qué se considera «caso de estudio publicable» y pedir el permiso
   por escrito desde el contrato, no después.
