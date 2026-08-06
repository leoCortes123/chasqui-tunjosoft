# Plantilla de auditoría SEO — página de un cliente

Esta es la forma del entregable de la **fase 1** de `METODO.md`, vaciada de
datos. Se copia, se rellena y se manda.

Los datos del cliente se reemplazan donde dice `{{así}}`. La auditoría real que
originó esta plantilla —la de Abanimal, con sus doce hallazgos— vive en el
repositorio de Chasqui Assistant y no se copió aquí a propósito: son datos de
un cliente en un repositorio que no es el suyo.

Lo que hay que conservar al rellenarla, porque es lo que la hace convincente:

- **Cada hallazgo es una medición, no una opinión.** Si no se puede señalar en
  el HTML crudo, no va. `scripts/auditar.sh` produce la mitad de esta tabla.
- **La simulación de agentes de IA se hace de verdad**, se guarda con fecha y
  con captura. Es la diapositiva que vende el proyecto y la línea base contra
  la que se compara a los tres meses.
- **El esfuerzo va en horas y por fases independientes.** Un cliente que puede
  comprar solo la fase 1 compra; uno al que le presentan un bloque de doce
  horas, lo piensa.
- **Nada de promesas de posición.** Ver el anexo de `METODO.md`.

---

# Propuesta de optimización SEO — {{página}}

**Sitio:** {{url}}
**Objetivo:** posicionar la página para búsquedas de {{negocio}}, sus
{{personas clave}} y sus {{servicios}}, tanto en Google como en agentes de IA
(ChatGPT, Gemini, Perplexity, Copilot).
**Fecha:** {{mes y año}}

---

## 1. Diagnóstico técnico

Una fila por hallazgo. Severidad: **Crítico** si impide que el contenido sea
leído; **Alto** si degrada cómo se lee; **Medio** si es deuda técnica.

| # | Hallazgo | Severidad | Impacto |
|---|---|---|---|
| 1 | **`lang="{{valor}}"`** en `<html>` — el sitio está en {{idioma real}} | | Google clasifica mal el idioma del sitio |
| 2 | **Open Graph locale `{{valor}}`** | | Mismo efecto en redes sociales y rich snippets |
| 3 | **Sin `<meta name="description">`** | | Google genera el snippet solo: texto genérico o de otra página |
| 4 | **Sin etiqueta H1** | | La página no declara un título jerárquico visible para crawlers |
| 5 | **{{plugin SEO}} versión {{n}}** ({{año}}) | | Qué se pierde por no actualizar |
| 6 | **Imágenes sin `alt` descriptivo**: {{n}} de {{total}} | | Google Images no indexa; lectores de pantalla no acceden; la IA no extrae contexto |
| 7 | **Sin WebP/AVIF** | | Peso de imagen y Core Web Vitals |
| 8 | **Schema markup insuficiente** — hoy solo {{tipos}} | | Faltan los que ponen al negocio en el Knowledge Graph |

---

## 2. Diagnóstico de contenido

La pregunta que ordena esta sección: **¿cuánto texto indexable tiene la página
de verdad?** El caso que más se repite es un sitio bonito cuya información está
toda dentro de imágenes — y para un crawler, esa página está vacía.

> Cita literal del único texto indexable, si es tan poco que cabe.

Tabla de lo que el negocio cree que está diciendo y no está diciendo:

| Información crítica | ¿Está en HTML? | ¿Está en schema? | ¿La ve un agente de IA? |
|---|---|---|---|
| {{dato}} | | | |
| {{dato}} | | | |

---

## 3. Diagnóstico para agentes de IA

Los agentes construyen respuestas a partir de tres fuentes:

1. **Contenido textual del HTML** — ponderan `<h1>`–`<h6>`, `<p>`, `<li>`, `<table>`.
2. **Schema markup (JSON-LD)** — fuente estructurada, y la usan con prioridad.
3. **Entidades enlazadas** — reconocen instituciones, profesiones y ubicaciones.

### Lo que responden hoy

Se corren de verdad, se pega la respuesta literal y se guarda la captura con
fecha. **Diez preguntas**, las que haría un cliente real:

**Pregunta:** _«{{pregunta}}»_

> {{respuesta literal del modelo, tal cual}}

Repetir. Si la respuesta es «no se encuentra información», esa frase es el
argumento entero: el problema no es que la página esté mal optimizada, es que
**para un crawler la página no tiene contenido.**

---

## 4. Plan de mejoras

Por fases independientes, con horas. Cada una se puede entregar sola.

### Fase 1 — Correcciones técnicas inmediatas ({{n}} h)

| Acción | Dónde | Resultado |
|---|---|---|
| Corregir `lang` | Ajustes del CMS | El contenido se trata en el idioma correcto |
| Agregar meta description (150–160 caracteres) | Plugin SEO | Snippet controlado |
| Agregar H1 visible | Editor | Jerarquía clara para crawlers |
| `loading="eager"` y `fetchpriority="high"` en la imagen hero | Editor | Mejora el LCP |

### Fase 2 — Textualizar el contenido ({{n}} h)

**Sacar de las imágenes todo lo que sea información y pasarlo a HTML**, con
marcado semántico. Cada foto se queda, pero con `alt` descriptivo y único.

```html
<h2>{{sección}}</h2>
<h3>{{nombre}}</h3>
<ul>
  <li>{{dato verificable}}</li>
  <li>{{dato verificable}}</li>
</ul>
<!-- alt="{{descripción concreta de la foto, no «imagen1»}}" -->
```

### Fase 3 — Schema markup ({{n}} h)

JSON-LD **adicional**, no en reemplazo del que ya genera el plugin. Enlazado
por `@id` entre bloques.

```json
{
  "@context": "https://schema.org",
  "@type": "{{LocalBusiness o el tipo específico del sector}}",
  "@id": "{{url}}/#negocio",
  "name": "{{negocio}}",
  "description": "{{una frase verificable}}",
  "url": "{{url}}",
  "telephone": "{{+57...}}",
  "address": {
    "@type": "PostalAddress",
    "streetAddress": "{{dirección}}",
    "addressLocality": "{{ciudad}}",
    "addressRegion": "{{región}}",
    "addressCountry": "CO"
  },
  "openingHoursSpecification": {
    "@type": "OpeningHoursSpecification",
    "dayOfWeek": ["Monday","Tuesday","Wednesday","Thursday","Friday"],
    "opens": "{{HH:MM}}",
    "closes": "{{HH:MM}}"
  }
}
```

Y un `Person` por cada profesional. **Es lo que más rinde en negocios de
referencia**: el especialista suele ser una entidad más buscada que la empresa,
y las universidades enlazadas con `sameAs` las reconoce el Knowledge Graph.

```json
{
  "@context": "https://schema.org",
  "@type": "Person",
  "@id": "{{url de su ficha}}/#{{slug}}",
  "name": "{{nombre}}",
  "jobTitle": "{{cargo}}",
  "worksFor": { "@id": "{{url}}/#negocio" },
  "alumniOf": [
    { "@type": "CollegeOrUniversity", "name": "{{universidad}}", "sameAs": "{{url oficial}}" }
  ],
  "knowsAbout": ["{{tema}}", "{{tema}}"],
  "description": "{{formación y años de experiencia, verificables}}"
}
```

Agregar `FAQPage` si se incluyen preguntas frecuentes, y el tipo de
especialidad que corresponda al sector.

### Fase 4 — Rendimiento ({{n}} h)

| Acción | Herramienta |
|---|---|
| Convertir imágenes a WebP | ShortPixel, Imagify o conversión manual |
| Verificar `srcset` | — |
| Actualizar el plugin SEO | Panel del CMS |
| Evaluar actualización del CMS y del constructor | **Con respaldo previo** |

### Fase 5 — Contenido para agentes de IA (opcional, alto impacto)

Los modelos citan párrafos que responden una pregunta completa **sin contexto
alrededor**. Cada respuesta tiene que poder leerse sola.

```html
<h2>Preguntas frecuentes</h2>
<h3>{{pregunta que la gente hace de verdad}}</h3>
<p>{{respuesta autocontenida, con cifras y fechas verificables}}</p>
```

Las preguntas salen del WhatsApp del cliente y del autocompletado de Google, no
de la imaginación.

---

## 5. Resumen de impacto esperado

Lo que se compromete, medido. Nada de posiciones.

| Métrica | Antes | Después |
|---|---|---|
| Texto indexable en la página | {{n}} palabras | {{n}} palabras |
| Imágenes con alt descriptivo | {{n}} de {{total}} | {{total}} de {{total}} |
| Tipos de schema presentes | {{n}} | {{n}} |
| Entidades enlazadas | {{n}} | {{n}} |
| Idioma declarado | {{valor}} | es-CO |
| LCP estimado | {{n}} s | {{n}} s |
| Respuestas correctas de agentes de IA | {{n}} de 10 | se mide a los 90 días |

---

## 6. Esfuerzo

| Fase | Horas |
|---|---|
| 1. Correcciones técnicas | {{n}} |
| 2. Textualizar contenido | {{n}} |
| 3. Schema markup | {{n}} |
| 4. Rendimiento | {{n}} |
| 5. FAQ (opcional) | {{n}} |
| **Total** | **{{n}}** |

Las fases son independientes y se entregan por separado. La 1 y la 2 juntas
suelen producir la mayor parte del impacto.
