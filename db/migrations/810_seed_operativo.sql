-- =====================================================================
-- Chasqui TunjoSoft — 810_seed_operativo.sql
-- Los datos de la agencia. Esta vez el cliente somos nosotros.
--
-- Casi todo sale de `docs/CLIENTES.md` y `docs/METODO.md`, que son
-- documentos propios: los precios, la escalera de etapas, la lista de
-- prospectos y las cinco cosas que no se prometen. Cuando este archivo y
-- esos documentos digan cosas distintas, manda el documento y esta tabla
-- está desactualizada.
--
-- Lo que queda deliberadamente vacío
-- ----------------------------------
-- Dirección, teléfono, correo y sitio de la agencia. **No se inventan.** El
-- asistente está construido para decir «no lo tengo» y ofrecer pasar con una
-- persona, y eso es exactamente lo correcto mientras esos datos no existan
-- o no estén decididos. Se llenan desde `/admin/config`, sin desplegar nada.
--
-- Un dato falso en boca del bot es peor que un dato ausente, y aquí el bot
-- habla en nombre de quien vende bots.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- La sede
-- ---------------------------------------------------------------------
UPDATE sede
   SET nombre    = 'TunjoSoft',
       ciudad    = 'Bogotá'
 WHERE nombre = 'Sede principal';

-- ---------------------------------------------------------------------
-- Configuración
-- ---------------------------------------------------------------------
UPDATE config SET valor = 'TunjoSoft' WHERE clave = 'nombre_negocio';

INSERT INTO config (clave, valor, tipo, descripcion, editable_ui) VALUES
  ('empresa_que_hacemos',
   'Hacemos dos cosas y están conectadas: que a un negocio lo encuentren '
   '(portal, ficha de Google, contenido) y que a quien lo encuentra le '
   'contesten en segundos (asistente en WhatsApp).',
   'texto', 'La frase con la que el asistente explica a qué nos dedicamos', true),
  ('empresa_sitio',    '', 'texto', 'Sitio web de la agencia. Vacío = el asistente dice que no lo tiene', true),
  ('empresa_correo',   '', 'texto', 'Correo de contacto', true),
  ('empresa_whatsapp', '', 'texto', 'WhatsApp de contacto', true),
  ('empresa_horario',  'Lunes a viernes, 9:00 am a 6:00 pm', 'texto',
   'Horario en que hay una persona atendiendo', true)
ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor;


-- ---------------------------------------------------------------------
-- El prompt
--
-- Cuatro filas, no cuatrocientas líneas de JavaScript. Identidad y giro son
-- de TunjoSoft; límites y tono se dejan como los sembró el núcleo, con un
-- añadido que aquí es el corazón del producto.
-- ---------------------------------------------------------------------
UPDATE config SET valor =
'Eres quien atiende el chat de {negocio}, una agencia de {ciudad} que hace
posicionamiento web y asistentes conversacionales para negocios pequeños y
medianos.'
WHERE clave = 'prompt_identidad';

UPDATE config SET valor =
'Escribes con alguien que está evaluando si contratarnos, o que apenas está
entendiendo qué hacemos. Tu trabajo es que entienda si esto le sirve y, si le
sirve, que quede agendada una reunión de diagnóstico.

Y hay algo más, que es la mitad del asunto: **tú eres la demostración**. Lo
que la persona está evaluando es exactamente esto que está usando. Si
respondes rápido, sin formularios, sin inventar precios y agendas bien, ya
mostraste el producto. Si te enredas, ninguna explicación lo arregla. No lo
menciones: se nota solo.

Cuando alguien pregunta un precio o qué hacemos, casi siempre está a un paso
de querer conversarlo; ese paso lo propones tú. Una propuesta concreta por
mensaje, y si dicen que no, se deja la puerta abierta.'
WHERE clave = 'prompt_giro';

UPDATE config SET valor =
'No inventas. Un dato que no esté en tu contexto ni salga de una herramienta,
NO LO TIENES. Decir «déjame confirmártelo con una persona» siempre es mejor
que acertar de casualidad.
No dices un precio de memoria: SIEMPRE cotizar_servicio. Los valores están en
el sistema. Nunca los redondees ni los promedies.
No prometes resultados. Ni la primera posición en Google, ni plazos, ni
aparecer en ChatGPT, ni volumen de ventas. Si te lo piden, el sistema ya tiene
la respuesta exacta y te la va a dar; no improvises una.
No ofreces lo que no existe. Si un servicio no sale en listar_servicios, no se
vende, aunque lo hayas visto mencionado.
No te haces pasar por humano si te preguntan de frente.
NUNCA anuncias algo que no hiciste. Si escribes «te paso con una persona», «ya
le avisé al equipo» o «te agendo», tienes que haber llamado la herramienta
correspondiente EN ESTE MISMO TURNO. Decirlo sin hacerlo deja a alguien
esperando a quien nunca fue avisado, y es el peor error que puedes cometer.'
WHERE clave = 'prompt_limites';


-- ---------------------------------------------------------------------
-- Lo que el asistente sabe del negocio
--
-- Entra literal en el prompt. Escrito para que lo lea un modelo, no una
-- persona: frases cortas, hechos separados, sin adornos de folleto. Lo que
-- no esté aquí, el asistente no lo sabe — y dice que no lo sabe.
--
-- Los precios NO van aquí. Van en `servicio`, donde una función los lee.
-- ---------------------------------------------------------------------
UPDATE config SET valor =
'IDENTIDAD
TunjoSoft. Bogotá, Colombia. Agencia pequeña.
Dos frentes que se alimentan: posicionamiento (que al negocio lo encuentren) y
asistentes conversacionales (que a quien lo encuentra le contesten). El
segundo sin el primero atiende a nadie; el primero sin el segundo trae gente a
una puerta que no abre.

QUÉ HACEMOS, EN ORDEN
La escalera va por etapas y no hay que comprarlas todas. Los códigos y los
valores salen de listar_servicios y cotizar_servicio; nunca de tu memoria.
- Etapa A: dejar el portal legible. Correcciones técnicas, schema, ficha de
  Google completa, medición instalada. Es lo que compra credibilidad porque se
  ve en semanas.
- Etapa B: arquitectura de contenido. Una página por intención de búsqueda, no
  una página «Servicios» con quince párrafos.
- Etapa C: piloto del asistente. Se abona íntegro a la etapa D si sigue.
- Etapa D: el asistente en producción, sobre el sistema del negocio.
- Etapa E: gestión interna — el mismo asistente, pero hacia adentro.
- Operación mensual: informe de una página, medición contra la línea base, y
  el trabajo permanente de ficha y contenido. Es donde vive la relación.

CÓMO TRABAJAMOS
Empieza con un diagnóstico: se mira el sitio, la ficha de Google, la
competencia y —esto es lo que casi nadie hace— cuánto tarda hoy el negocio en
contestarle a un cliente. Ese número suele ser el hallazgo más incómodo y el
más útil.
Después se ejecuta por olas, cada una con algo visible: días 0–30 «que
exista», 30–90 «que responda», 90–180 «que gane».
Y se mide todos los meses, en dos columnas separadas: lo que nos
comprometemos a hacer (páginas, schema, velocidad, reseñas solicitadas) y lo
que se espera que pase (posiciones, clics, llamadas, citas). Mezclarlas es
como se pierde la confianza cuando un mes viene flojo.

LO QUE NO PROMETEMOS
Nunca la primera posición: Google no vende ese lugar y quien lo promete está
mintiendo. Nunca plazos para resultados de contenido. Nunca aparecer en
ChatGPT. No compramos enlaces ni reseñas. No garantizamos volumen de ventas.
Sí garantizamos legibilidad y visibilidad medibles, con línea base fechada
para poder comparar.

DATOS PERSONALES
Ley 1581 de 2012. No compramos bases de datos, no mandamos WhatsApp masivos y
no prospectamos a números personales. Los datos que alguien deja por este chat
se usan solo para contactarlo por este tema.

PARA QUIÉN SIRVE
Negocios de una o pocas sedes, con servicio bueno y puerta de entrada mala:
sitio roto o inexistente, y WhatsApp atendido a mano cuando alguien puede.
No sirve —y se dice— si el problema del negocio es la calidad de lo que hace:
eso no lo arregla ni un portal ni un bot.

CÓMO AGENDAS
Tú agendas. No pasas a nadie para eso.
1. horarios_reunion. Nunca propongas un día ni una hora sin haberla llamado.
2. Ofrece DOS o TRES horas concretas, no la lista entera ni «dime cuándo te
   sirve». Una pregunta abierta alarga la conversación; dos opciones la
   cierran.
3. Cuando elija, necesitas su nombre y el del negocio. Pídelos como los
   pediría una persona, no como formulario.
4. agendar_reunion. Sale un botón de confirmar. Hasta que lo toque NO está
   agendada: no digas «listo, ya quedó».
5. Si la hora se ocupó entre medio, la herramienta te lo dice. Discúlpate en
   una línea y ofrece otras dos. No lo escales.
Si no quiere comprometerse a una hora, dejar_datos y el equipo le escribe.

LO QUE NO SABES TODAVÍA
- La dirección, el teléfono y el correo de la agencia: no están cargados.
- Los tiempos exactos de entrega de cada etapa.
- Si hay descuentos por contratar varias etapas juntas.
- Formas de pago y facturación.
Cuando te pregunten algo de esta lista, dilo y ofrece pasar el chat a una
persona. No lo deduzcas.'
WHERE clave = 'ia_sobre_el_negocio';


-- ---------------------------------------------------------------------
-- El catálogo: la escalera comercial de `docs/CLIENTES.md` §1
--
-- El contestador telefónico con voz entra con `disponible = false`. Está
-- cotizado en una propuesta y **no existe**: si estuviera disponible, el
-- asistente lo ofrecería con toda naturalidad y nos vendería algo que no
-- podemos entregar. Que el sistema lo impida vale más que la nota en el
-- documento que alguien va a recordar.
-- ---------------------------------------------------------------------
INSERT INTO servicio (codigo, nombre, categoria, etapa, resumen, incluye,
                      valor_min, valor_max, unidad, duracion, requiere,
                      disponible, nota_interna, orden) VALUES

('portal', 'Corrección técnica del portal', 'etapa', 'A',
 'Dejamos el sitio legible para Google y para los modelos de IA, y la ficha de Google completa.',
 'Correcciones técnicas (idioma, títulos, encabezados, imágenes, velocidad); '
 'schema validado; Search Console y Analytics instalados; ficha de Google '
 'reclamada y completada; datos de contacto unificados en todas partes.',
 2400000, 2400000, 'proyecto', '30 días', NULL,
 true, 'Listo. Se puede vender hoy.', 10),

('contenido', 'Arquitectura de contenido y territorio', 'etapa', 'B',
 'Una página por cada cosa que la gente busca, en vez de una sola página que intenta responderlo todo.',
 'Levantamiento de las búsquedas reales; una página por servicio, por '
 'especialista y por sede; página para remisión profesional; guías de las '
 'preguntas frecuentes; preguntas frecuentes con schema.',
 8500000, 8500000, 'proyecto', '60 a 90 días', 'portal',
 true, 'Listo, es trabajo manual.', 20),

('piloto', 'Piloto del asistente', 'etapa', 'C',
 'El asistente funcionando con el negocio real, para probarlo antes de comprometerse.',
 'Configuración del asistente con los servicios y horarios del negocio; '
 'pruebas con conversaciones reales; se abona íntegro a la etapa D si se sigue.',
 1800000, 1800000, 'proyecto', '15 días', NULL,
 true, 'Se abona íntegro a D. Es la mejor entrada.', 30),

('asistente', 'Asistente en producción', 'etapa', 'D',
 'El asistente atendiendo de verdad: responde, cotiza, agenda y escala a una persona cuando toca.',
 'Asistente en WhatsApp o Telegram; catálogo y precios desde la base; agenda '
 'con confirmación; escalamiento a persona; portal de administración; '
 'auditoría de todo lo que hace.',
 12000000, 18000000, 'proyecto', '60 a 90 días', NULL,
 true, 'En construcción. Lo que se muestra en el demo es lo que ya funciona.', 40),

('canal_extra', 'Canal adicional', 'complemento', NULL,
 'Sumar otro canal al mismo asistente: WhatsApp si ya está en Telegram, o al revés.',
 'Mismo motor, misma base, mismo catálogo. Solo cambia por dónde entra la conversación.',
 2500000, 2500000, 'proyecto', '15 días', 'asistente',
 true, 'Depende de D.', 50),

('gestion', 'Gestión interna', 'etapa', 'E',
 'El mismo asistente hacia adentro: el equipo le pregunta por el estado de las cosas en vez de buscar en el sistema.',
 'Consultas en lenguaje natural sobre la operación; acciones con confirmación; '
 'permisos por rol; todo auditado.',
 3500000, 6000000, 'proyecto', '60 días', NULL,
 true, 'Existe como chasquiPet; falta generalizarlo.', 60),

('operacion', 'Operación mensual', 'recurrente', NULL,
 'El trabajo permanente: informe de una página, medición contra la línea base, ficha y contenido al día.',
 'Informe mensual de una página con cinco números; publicaciones y fotos en la '
 'ficha de Google; respuesta a reseñas; ajustes de contenido según lo que '
 'revelen los datos; comparación trimestral de las respuestas de la IA.',
 950000, 1500000, 'mes', 'permanente', NULL,
 true, 'Es el ancla de ingreso recurrente.', 70),

('voz', 'Contestador telefónico con voz', 'complemento', NULL,
 'Atención telefónica automática con voz.',
 NULL,
 4500000, 6500000, 'proyecto', NULL, NULL,
 false,
 'NO EXISTE. Está cotizado en la propuesta de Abanimal: si lo aceptan, hay que '
 'construirlo. No ofrecerlo en propuestas nuevas hasta tenerlo. `disponible = '
 'false` es lo que impide que el asistente lo mencione.', 80)

ON CONFLICT (codigo) DO UPDATE
  SET nombre = EXCLUDED.nombre, resumen = EXCLUDED.resumen,
      incluye = EXCLUDED.incluye, valor_min = EXCLUDED.valor_min,
      valor_max = EXCLUDED.valor_max, duracion = EXCLUDED.duracion,
      disponible = EXCLUDED.disponible, nota_interna = EXCLUDED.nota_interna,
      orden = EXCLUDED.orden;


-- ---------------------------------------------------------------------
-- La agenda
-- ---------------------------------------------------------------------
INSERT INTO tipo_reunion (codigo, nombre, descripcion, duracion_min, modalidad, orden) VALUES
  ('diagnostico', 'Reunión de diagnóstico',
   'Media hora para entender el negocio, mirar el sitio y la ficha de Google, y '
   'decir con franqueza si esto le sirve o no.', 30, 'virtual', 10),
  ('auditoria', 'Presentación de la auditoría',
   'Se muestra el diagnóstico completo, hallazgo por hallazgo, con el sitio '
   'delante.', 45, 'virtual', 20),
  ('demo', 'Demostración del asistente',
   'Se muestra el asistente funcionando y se responde qué se puede y qué no.',
   30, 'virtual', 30)
ON CONFLICT (codigo) DO NOTHING;

-- Lunes a viernes, mañana y tarde. Se edita sin desplegar nada.
INSERT INTO franja_agenda (dia_semana, hora_desde, hora_hasta)
SELECT d, h.desde, h.hasta
  FROM generate_series(1, 5) d
  CROSS JOIN (VALUES ('09:00'::time, '12:00'::time),
                     ('14:00'::time, '18:00'::time)) AS h(desde, hasta)
WHERE NOT EXISTS (SELECT 1 FROM franja_agenda);


-- ---------------------------------------------------------------------
-- Las respuestas literales
--
-- Son el anexo «Lo que no se promete» de `docs/METODO.md`, convertido en
-- filas que el sistema recita antes de que el modelo abra la boca.
--
-- El texto se manda tal cual, con parse_mode HTML: aquí se escribe `<b>`, no
-- markdown, porque `enviar_texto` no traduce nada — y no debe, es texto
-- aprobado palabra por palabra.
--
-- `aprobada_por` va en NULL a propósito y `v_literal_sin_aprobar` las lista.
-- Para el demo se usan; el día que estos textos sean parte de una propuesta
-- firmada, se revisan y se firman aquí.
-- ---------------------------------------------------------------------
INSERT INTO respuesta_literal (codigo, nombre, prioridad, fuente, texto) VALUES

('sin_garantia_posicion', 'Garantía de primera posición', 90, 'METODO.md, anexo',
'Te voy a contestar derecho porque es importante: <b>no</b>. Nadie puede garantizar
la primera posición en Google, y quien te la prometa te está mintiendo o no
sabe. Google no vende ese lugar.

Lo que sí se puede comprometer, y se mide todos los meses: que el negocio pase
de ilegible a legible, que aparezca en las búsquedas donde ganar es posible, y
que exista una línea base fechada para comparar el antes y el después.

Prometer poco y demostrarlo es lo que hace que el segundo año se firme solo.'),

('sin_plazo_resultados', 'Plazos de resultados', 80, 'METODO.md, anexo',
'Depende de qué parte. Y te lo separo porque mezclarlo es como se generan las
falsas expectativas:

Lo técnico —que el sitio cargue, que Google lo entienda, que la ficha esté
completa— se ve en semanas. Eso sí se compromete.

El posicionamiento por contenido tarda entre 3 y 6 meses, y depende de qué tan
peleado esté el sector. Ahí no hay plazo que prometer, hay medición mensual
contra la línea base.'),

('sin_chatgpt', 'Aparecer en ChatGPT', 70, 'METODO.md, anexo',
'No se puede garantizar. Nadie controla a quién cita un modelo.

Lo que sí se hace es todo lo que hoy se sabe que aumenta la probabilidad de
ser citado: schema completo, respuestas que se entienden solas, datos
verificables y fechados, y no bloquear a los rastreadores de IA — cosa que
muchos sitios hacen sin saberlo.

Y se mide: se corren diez preguntas reales en los modelos el día cero, se
guardan con fecha, y se repiten cada trimestre para poner el antes y el
después lado a lado.'),

('no_compramos', 'Comprar enlaces o reseñas', 85, 'METODO.md, anexo',
'Eso no lo hacemos, y no es una postura moral: es que funciona un tiempo y
después borra años de trabajo. Google lo detecta y la sanción es peor que no
haber hecho nada.

Las reseñas se consiguen pidiéndolas bien: en el momento exacto en que el
cliente está más satisfecho, por un enlace corto, de forma sistemática. Eso sí
se puede automatizar y funciona.'),

('datos_personales', 'Bases de datos y envíos masivos', 95, 'CLIENTES.md §5; Ley 1581 de 2012',
'No trabajamos así. No compramos bases de datos y no mandamos WhatsApp
masivos.

En Colombia eso lo regula la Ley 1581 de 2012 y las multas de la SIC llegan a
2.000 salarios mínimos. Pero además no sirve: la gente lo reporta como spam y
el número termina bloqueado.

El asistente atiende a quien escribe. Esa es la diferencia, y es toda la
diferencia.')

ON CONFLICT (codigo) DO UPDATE
  SET texto = EXCLUDED.texto, prioridad = EXCLUDED.prioridad,
      fuente = EXCLUDED.fuente;

-- Los términos, normalizados: sin tildes y en minúscula, porque así los
-- compara `detectar_literal`. Varias filas por respuesta, con las variantes
-- que de verdad escribe la gente.
INSERT INTO termino_literal (termino, codigo) VALUES
  ('me garantizan',                'sin_garantia_posicion'),
  ('garantizan',                   'sin_garantia_posicion'),
  ('garantia',                     'sin_garantia_posicion'),
  ('primer lugar',                 'sin_garantia_posicion'),
  ('primera posicion',             'sin_garantia_posicion'),
  ('primero en google',            'sin_garantia_posicion'),
  ('numero 1 en google',           'sin_garantia_posicion'),
  ('salir de primero',             'sin_garantia_posicion'),
  ('quedar de primero',            'sin_garantia_posicion'),
  ('top 1',                        'sin_garantia_posicion'),

  ('en cuanto tiempo veo resultados', 'sin_plazo_resultados'),
  ('cuanto se demora en posicionar',  'sin_plazo_resultados'),
  ('cuanto tarda en posicionar',      'sin_plazo_resultados'),
  ('cuando veo resultados',           'sin_plazo_resultados'),
  ('en cuanto tiempo subo',           'sin_plazo_resultados'),

  ('aparecer en chatgpt',          'sin_chatgpt'),
  ('salir en chatgpt',             'sin_chatgpt'),
  ('que chatgpt me recomiende',    'sin_chatgpt'),
  ('aparecer en la ia',            'sin_chatgpt'),

  ('comprar enlaces',              'no_compramos'),
  ('comprar backlinks',            'no_compramos'),
  ('comprar resenas',              'no_compramos'),
  ('comprar reseñas',              'no_compramos'),
  ('borrar resenas',               'no_compramos'),
  ('quitar resenas malas',         'no_compramos'),
  ('eliminar resenas',             'no_compramos'),

  ('base de datos de clientes',    'datos_personales'),
  ('bases de datos',               'datos_personales'),
  ('envio masivo',                 'datos_personales'),
  ('envios masivos',               'datos_personales'),
  ('whatsapp masivo',              'datos_personales'),
  ('mensajes masivos',             'datos_personales')
ON CONFLICT (termino) DO UPDATE SET codigo = EXCLUDED.codigo;


-- ---------------------------------------------------------------------
-- El pipeline, tal como está en `docs/CLIENTES.md` al 6 de agosto de 2026
--
-- Los nombres son los del documento. Sin sitios web ni teléfonos: los que
-- había allí no están verificados y aquí no se cargan datos de contacto sin
-- saber de dónde salieron. Se completan a mano, prospecto por prospecto,
-- cuando se les aplique la prueba de WhatsApp.
-- ---------------------------------------------------------------------
INSERT INTO prospecto (nombre, ciudad, sector, peldano, estado, origen, notas) VALUES
  ('Abanimal Clínica Veterinaria', 'Bogotá', 'veterinaria', 2, 'propuesta',
   'auditoría propia',
   'Centro de referencia en imágenes diagnósticas. Propuesta enviada el 5 de '
   'agosto de 2026, sin respuesta. Se le mandó auditoría completa (12 hallazgos) '
   'y acceso al demo. Hallazgo más citable: la página del director tiene una '
   'sola frase indexable. Aritmética presentada: ~5.000 ecografías/año × '
   '$172.000 ≈ $860M/año; recuperar el 5 % ≈ $43M/año.'),

  ('Orthovet',    'Bogotá', 'veterinaria', 1, 'calificado', 'auditoría técnica del 6 de agosto de 2026',
   'Falla técnica confirmada. Falta la prueba de WhatsApp.'),
  ('Vetovet',     'Bogotá', 'veterinaria', 1, 'calificado', 'auditoría técnica del 6 de agosto de 2026',
   'Falla técnica confirmada. Falta la prueba de WhatsApp.'),
  ('CPVet',       'Bogotá', 'veterinaria', 1, 'calificado', 'auditoría técnica del 6 de agosto de 2026',
   'Falla técnica confirmada. Falta la prueba de WhatsApp.'),
  ('Dogtor',      'Bogotá', 'veterinaria', 1, 'calificado', 'auditoría técnica del 6 de agosto de 2026',
   'Falla técnica confirmada. Falta la prueba de WhatsApp.'),
  ('Animalandia', 'Bogotá', 'veterinaria', 1, 'calificado', 'auditoría técnica del 6 de agosto de 2026',
   'Falla técnica confirmada. Falta la prueba de WhatsApp.'),
  ('Betel',       'Bogotá', 'veterinaria', 1, 'calificado', 'auditoría técnica del 6 de agosto de 2026',
   'Falla técnica confirmada. Falta la prueba de WhatsApp.'),
  ('Normandía',   'Bogotá', 'veterinaria', 1, 'calificado', 'auditoría técnica del 6 de agosto de 2026',
   'Falla técnica confirmada. Falta la prueba de WhatsApp.'),

  -- Técnicamente correctos: no tiene sentido venderles la etapa A. La entrada
  -- es el problema de atención, no el de visibilidad.
  ('Dover',                        'Bogotá', 'veterinaria', 1, 'nuevo', 'auditoría técnica del 6 de agosto de 2026',
   'Sitio técnicamente correcto. Entrada por el asistente, no por la etapa A.'),
  ('Clínica Protectora de Animales','Bogotá', 'veterinaria', 1, 'nuevo', 'auditoría técnica del 6 de agosto de 2026',
   'Sitio técnicamente correcto. Entrada por el asistente, no por la etapa A.'),
  ('Cliniderma',                   'Bogotá', 'veterinaria', 1, 'nuevo', 'auditoría técnica del 6 de agosto de 2026',
   'Sitio técnicamente correcto. Entrada por el asistente, no por la etapa A.'),
  ('VetLevel',                     'Bogotá', 'veterinaria', 1, 'nuevo', 'auditoría técnica del 6 de agosto de 2026',
   'Sitio técnicamente correcto. Entrada por el asistente, no por la etapa A.'),

  -- Peldaño 3: aplazados por decisión, no por falta de interés.
  ('Malo Dental', 'Bogotá', 'odontología', 3, 'descartado', 'auditoría técnica del 6 de agosto de 2026',
   'Tiene bot y llamada de recuperación al abandonar la conversación: embudo '
   'diseñado por alguien que sabe. Su SEO sí está roto (36 de 36 imágenes sin '
   'alt, sin H1, sin schema), lo que revela un proveedor de automatización '
   'comercial, no de posicionamiento. Es un flanco real, pero entrar por SEO '
   'donde ya hay proveedor de bot es competir desde la posición débil. '
   'Revisar en 12 meses, con portafolio.'),
  ('Vetas',       'Bogotá', 'veterinaria', 3, 'descartado', 'auditoría técnica del 6 de agosto de 2026',
   'Red de varias sedes; ticket y ciclo de venta por encima del peldaño 1.')
ON CONFLICT DO NOTHING;

UPDATE prospecto SET motivo = 'peldaño 3: se retoma con portafolio'
 WHERE estado = 'descartado' AND motivo IS NULL;

-- El seguimiento que `CLIENTES.md` deja explícitamente pendiente. Es el
-- primero que debería sonar en el chat interno.
INSERT INTO seguimiento (prospecto_id, que, excusa, para_fecha)
SELECT id,
       'Definir y hacer el seguimiento de la propuesta enviada el 5 de agosto.',
       'Un dato nuevo, no un «¿ya lo vio?». Lo natural: el demo ya responde y se le puede mostrar.',
       hoy_bogota()
  FROM prospecto WHERE nombre = 'Abanimal Clínica Veterinaria'
   AND NOT EXISTS (SELECT 1 FROM seguimiento WHERE prospecto_id = prospecto.id);

INSERT INTO seguimiento (prospecto_id, que, excusa, para_fecha)
SELECT id,
       'Aplicar la prueba de WhatsApp: escribir en día hábil y repetir un domingo o a las 10 de la noche.',
       'Es el dato más persuasivo de toda la propuesta y cuesta un mensaje.',
       hoy_bogota() + 2
  FROM prospecto WHERE peldano = 1 AND estado = 'calificado'
   AND NOT EXISTS (SELECT 1 FROM seguimiento WHERE prospecto_id = prospecto.id);
