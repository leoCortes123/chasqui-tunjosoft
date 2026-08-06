-- =====================================================================
-- Chasqui TunjoSoft — 130_triaje.sql
-- Detección de urgencias e instrucciones de traslado.
--
-- La regla de oro del proyecto, y el argumento con el que se le vende esto a
-- un director médico: **el bot nunca diagnostica ni aconseja tratamiento.**
-- Ante una urgencia corta el flujo, entrega instrucciones de traslado y
-- escala a una persona.
--
-- Dónde está la frontera
-- ----------------------
-- Decir «qué tiene» o «qué darle» es acto médico y aquí no ocurre nunca.
-- Decir «cómo moverlo sin empeorarlo mientras llega» no lo es: es lo mismo
-- que hace una línea de emergencias mientras despacha la ambulancia. Esa
-- segunda mitad es la que vive en este archivo.
--
-- Por qué son datos y no prompt
-- -----------------------------
-- Las instrucciones son texto LITERAL en una tabla, y el bot las recita sin
-- reescribirlas. No las redacta el modelo, y esto no es una preferencia de
-- estilo:
--
--   · A un atropellado hay que moverlo sobre una superficie rígida; a un
--     convulsivo hay que NO meterle la mano en la boca; a un intoxicado a
--     veces no se induce vómito. Un modelo que improvisa acierta casi
--     siempre, y el «casi» lo paga un paciente.
--   · Un texto fijo se puede hacer revisar y firmar por el veterinario. Una
--     redacción distinta cada vez, no.
--   · Corregir una instrucción es un UPDATE, no un despliegue.
--
-- Por qué la detección no la hace el modelo
-- -----------------------------------------
-- Probado al cerrar la fase 1: ante «mi perro convulsiona, ¿qué le doy?» el
-- modelo respondió impecable —no diagnosticó, no sugirió medicamento, dijo
-- que lo trajeran ya y anunció que pasaba el chat a una persona— pero
-- `atendida_por_humano` seguía en false. Dijo que escalaba y no escaló.
--
-- Un límite clínico que depende de que el modelo se acuerde de llamar una
-- herramienta es un límite que se pierde el día que se distrae. Aquí la
-- detección ocurre en `asistente_recibir`, con un SELECT, ANTES de que el
-- modelo vea el mensaje. El modelo ni siquiera participa: si hay urgencia, la
-- tarea no se encola.
--
-- Fuentes de las instrucciones
-- ----------------------------
-- American Veterinary Medical Association (first aid tips for pet owners),
-- VCA Animal Hospitals (common emergencies in dogs / emergencias en gatos),
-- RSPCA (first aid for dogs), Royal Veterinary College (heatstroke fact file),
-- Merck/MSD Veterinary Manual (atención de urgencia para perros y gatos).
--
-- **Ninguna está aprobada todavía por un veterinario de Abanimal.** La columna
-- `aprobada_por` está en NULL a propósito y la vista `v_urgencia_sin_aprobar`
-- las lista. Para el demo se usan; antes de producción las firma el Dr.
-- Sánchez, y esa media hora de su tiempo es parte de la venta.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Los cuadros
-- ---------------------------------------------------------------------
CREATE TABLE cuadro_urgencia (
  codigo       text PRIMARY KEY,
  nombre       text NOT NULL,
  -- Lo que el bot dice, palabra por palabra. Se escribe para que lo lea una
  -- persona asustada en un celular: frases cortas, imperativas, y lo que NO
  -- hay que hacer antes de lo que sí, porque el daño evitable pesa más.
  instruccion  text NOT NULL,
  -- Mayor = se atiende primero cuando un mensaje dispara varios cuadros.
  prioridad    int  NOT NULL DEFAULT 50,
  aprobada_por text,
  aprobada_at  timestamptz,
  fuente       text,
  activa       boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER cuadro_urgencia_touch BEFORE UPDATE ON cuadro_urgencia
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ---------------------------------------------------------------------
-- Los términos que disparan cada cuadro
--
-- Se guardan normalizados (sin tildes, minúsculas): la gente escribe
-- «convulsiono», «esta convulsionando», «combulsiona». Por eso hay varias
-- filas por cuadro y varias con errores de ortografía frecuentes — el
-- objetivo no es la lengua, es no perder el mensaje.
-- ---------------------------------------------------------------------
CREATE TABLE termino_urgencia (
  termino        text PRIMARY KEY,
  cuadro_codigo  text NOT NULL REFERENCES cuadro_urgencia(codigo) ON DELETE CASCADE,
  activo         boolean NOT NULL DEFAULT true
);

CREATE INDEX idx_termino_urgencia_cuadro ON termino_urgencia (cuadro_codigo);

INSERT INTO cuadro_urgencia (codigo, nombre, prioridad, fuente, instruccion) VALUES

('convulsion', 'Convulsión', 90, 'AVMA; VCA; RSPCA',
'No le metas la mano ni ningún objeto en la boca. No se va a tragar la lengua, y ahí es donde muerde sin darse cuenta.
No lo sujetes ni intentes despertarlo.

Aparta los muebles y todo con lo que pueda golpearse. Si está en un mueble o una escalera, bájalo al piso con cuidado.
Apaga la luz y el ruido. Mira la hora: cuánto dura es el dato que más le sirve al médico.
Si puedes, grábalo con el celular.

Cuando pase el episodio va a estar desorientado. Déjalo en un lugar oscuro y tranquilo, sin escaleras cerca.

Para traerlo: envuélvelo en una cobija y muévelo lo menos posible. Si es pequeño, en guacal. No le des agua ni comida ni ningún medicamento.

Tráelo YA. Si lleva más de 5 minutos convulsionando o encadena varios episodios, sal de inmediato.'),

-- La prioridad más alta de todas, por encima incluso de la dificultad
-- respiratoria: cuando hay trauma, mover mal al paciente causa daño nuevo, y
-- las dos instrucciones se contradicen —la respiratoria dice «no lo metas en
-- guacal cerrado», la de trauma dice «sobre superficie rígida, sin doblarlo»—.
-- Una caída de un octavo piso con respiración rara es trauma primero.
('atropellamiento', 'Atropellamiento, caída o trauma', 105, 'AVMA; VCA',
'Aunque parezca que está bien, tráelo. Los golpes internos y las hemorragias no se ven por fuera.

Antes de tocarlo: hasta un animal manso muerde cuando le duele. Si está consciente y agitado, cúbrele la cabeza con una toalla, sin taparle el hocico si le cuesta respirar.

Muévelo sobre algo rígido —una tabla, una bandeja de horno, el fondo de un guacal— deslizándolo, sin doblarlo ni cargarlo en brazos. Si sospechas golpe en la columna o no mueve las patas traseras, esto es lo más importante de todo.
Si es pequeño, en guacal firme.

Si además le cuesta respirar, no lo tapes ni lo encierres: rígido por debajo, pero destapado y con aire.

Si hay una herida que sangra, presiona encima con una tela limpia y no la levantes a mirar. Cúbrelo con una cobija: el frío empeora el shock.

No le des agua, comida ni medicamentos —nada de analgésicos humanos, son tóxicos.

Sal ya y avísanos que vienes en camino.'),

('dificultad_respiratoria', 'Dificultad para respirar', 100, 'AVMA; VCA',
'Esto no espera. Sal ahora.

Déjalo en la posición en que él se acomode. Si está sentado con el cuello estirado y los codos separados, es porque así respira mejor: no lo acuestes ni lo abraces.
No lo metas en un guacal cerrado ni lo tapes.

Si tiene la lengua o las encías moradas o grises, es crítico.

En el carro, ventanas abajo y aire fresco. Nada de correa apretada ni collar al cuello: si tienes pechera, mejor.
No le des agua ni le metas los dedos en la boca.

Ven de una vez y avísanos que vienes.'),

('intoxicacion', 'Intoxicación o envenenamiento', 95, 'AVMA; VCA; Pet Poison Helpline',
'NO lo hagas vomitar. Con algunos venenos —destapacaños, gasolina, limpiadores— el vómito quema dos veces.
No le des leche, aceite, sal ni remedios caseros.

Trae el empaque, la etiqueta o una foto de lo que se comió, y calcula a qué hora fue y cuánto. Eso decide el tratamiento.
Si vomitó solo, trae una muestra en una bolsa.

Si le cayó algo en la piel o los ojos, enjuaga con agua tibia abundante 15 minutos mientras salen.

Tráelo ya, incluso si todavía se ve normal: muchos venenos tardan horas en dar la cara.'),

('torsion_gastrica', 'Estómago hinchado o arcadas sin vomitar', 100, 'VCA; AVMA',
'Si tiene la barriga hinchada y dura, hace fuerza para vomitar y no sale nada, y está inquieto o babeando: sal ahora mismo. Se cuenta en minutos.

No le des agua ni comida. No le des nada para los gases. No le presiones ni le sobes la barriga.

Muévelo lo menos posible: cárgalo o llévalo en guacal, no lo hagas caminar.

Avísanos que vienes con esto para tener el quirófano listo.'),

('golpe_calor', 'Golpe de calor', 95, 'RVC; AVMA; VCA',
'Empieza a enfriarlo AHORA y sigue enfriándolo en el camino. Enfriar primero, viajar después.

Mójalo con agua fresca de la llave —no helada, no hielo—. Insiste en el cuello, las axilas, la ingle y las almohadillas. Si tienes ventilador, ponlo al frente.
Cambia las toallas mojadas cada pocos minutos; una toalla que ya se calentó lo abriga en vez de enfriarlo.

No lo cubras con toallas secas ni lo metas en hielo.
Si quiere tomar agua, déjalo, poca y fresca. Si está inconsciente, no le des nada.

En el carro, ventanas abajo y aire acondicionado.
Tráelo aunque se vea recuperado: el daño de un golpe de calor aparece horas después.'),

('parto', 'Parto complicado', 95, 'Merck/MSD Veterinary Manual',
'Tráela ya si lleva más de 30 minutos pujando fuerte sin que salga nada, si pasaron más de 2 horas entre cachorros, si lleva más de 24 horas con contracciones débiles, o si se ve un cachorro atascado a medio salir.

No le jales el cachorro. Puedes desgarrarla a ella y matarlo a él.
No le des oxitocina, calcio ni nada que le hayan recomendado.

Trae a la mamá y a los cachorros que ya nacieron, en una caja con una cobija y algo tibio —una botella con agua caliente envuelta en tela, no en contacto directo—. Los recién nacidos se enfrían en minutos.

Anota cuántos nacieron y a qué hora.'),

('hemorragia', 'Sangrado abundante', 95, 'AVMA; VCA',
'Presiona directo sobre la herida con una tela limpia, una toalla o gasa. Fuerte y sostenido.
No levantes la tela a mirar durante los primeros 3 minutos: despegar el coágulo reinicia el sangrado. Si se empapa, pon otra encima sin quitar la de abajo.

Si es en una pata y no para, presiona también un poco más arriba, del lado del cuerpo.
No hagas torniquete a menos que sea eso o que se desangre: mal puesto se pierde la pata.

Cúbrelo con una cobija y muévelo lo menos posible.
No le des agua, comida ni medicamentos.

Sal ya y avísanos que vienes.'),

('atragantamiento', 'Se está ahogando con algo', 100, 'AVMA; VCA',
'Si todavía respira, tose o hace ruido: NO le metas los dedos en la boca. Empujarías el objeto más adentro y te muerde. Mantenlo calmado y sal ya.

Solo si está inconsciente o ya no entra aire: ábrele la boca con las dos manos, mira, y saca el objeto con los dedos únicamente si lo ves y lo puedes agarrar. Si no lo ves, no busques a ciegas.

Perro pequeño o gato: cárgalo boca abajo, con la cabeza hacia el piso, y dale palmadas firmes entre los omóplatos.
Perro grande: de pie detrás de él, rodéale la barriga justo detrás de las costillas y aprieta hacia arriba y adentro, varias veces.

Tráelo aunque el objeto salga: la maniobra puede haber lastimado por dentro.'),

('obstruccion_urinaria', 'No puede orinar', 100, 'Merck/MSD; ACVS',
'Si es un gato macho que va y viene de la arenera, puja y no sale nada, maúlla o se lame mucho: esto mata en menos de dos días y no da espera. Sal ahora.
Muchos tutores creen que está estreñido. Casi nunca lo está.

No le presiones la barriga ni intentes que orine. La vejiga llena se puede romper.
No le des agua a la fuerza ni diuréticos ni remedios caseros.

Tráelo en guacal, con una toalla. Vale igual para perros y para hembras.

Avísanos que vienes con esto.'),

('trauma_ocular', 'Ojo salido o golpe en el ojo', 90, 'VCA; AVMA',
'Si el ojo se le salió de la cuenca: no intentes metérselo. Mantenlo húmedo todo el tiempo con suero fisiológico o, si no tienes, agua limpia tibia, y cúbrelo con una gasa o tela mojada sin apretar.

Impídele rascarse o frotarse: es lo que termina de perder el ojo. Si tienes collar isabelino, pónselo; si no, sujétale la pata con suavidad.

No le eches gotas, ni colirios de humano, ni nada que tengas guardado.
Nada de comida ni agua por si hay que operar.

Sal ya: el ojo se salva en horas, no en días.'),

('quemadura', 'Quemadura', 85, 'AVMA',
'Enjuaga la zona con agua a temperatura ambiente, sin presión, varios minutos.
No uses hielo, ni agua helada, ni hagas fricción.
No le pongas cremas, mantequilla, pasta de dientes, aceite ni nada casero: complican la curación y hay que quitarlo después, que duele más.

Cúbrelo con una tela limpia humedecida con agua a temperatura ambiente.
Si fue con químico, enjuaga 15 minutos y trae el empaque.
Si fue eléctrica —un cable mordido—, tráelo aunque no se vea nada por fuera: el daño serio es en el pulmón.

Impide que se lama la zona.'),

('colapso', 'Se desmayó, no responde o no reacciona', 100, 'AVMA; VCA',
'Ponlo de costado, con la cabeza al mismo nivel que el cuerpo —no se la levantes con una almohada—.
Estírale el cuello con suavidad y sácale la lengua hacia afuera para que le entre aire.

Cúbrelo con una cobija: en shock se enfría rápido.
No le des agua, comida ni medicamentos. No le eches agua en la cara.
No lo cargues en brazos apretado: sobre una tabla o dentro de un guacal.

Sal ahora mismo y avísanos que vienes en camino.'),

-- La red de seguridad. Prioridad baja: si el mensaje también dispara un
-- cuadro concreto, gana el concreto, que tiene mejores instrucciones.
--
-- Existe porque la lista de términos nunca va a estar completa. En la primera
-- prueba, «se cayó del octavo piso» no coincidió con `se cayo de un` por una
-- preposición, y «respira raro» no coincidió con `respira mal`. Se pueden
-- agregar términos toda la vida y siempre faltará uno; lo que no puede faltar
-- es la salida.
('urgencia_general', 'Urgencia sin clasificar', 10, 'AVMA (transporte general)',
'Si lo ves grave, tráelo ya. No esperes a que mejore solo.

Mientras tanto, lo que sirve para casi cualquier urgencia:
• No le des comida, agua ni medicamentos. Nada de remedios humanos: el acetaminofén y el ibuprofeno son tóxicos, y si hay que operar, el estómago lleno es un problema.
• Muévelo lo menos posible. En guacal si es pequeño; sobre una tabla, una cobija tensa o una superficie rígida si es grande. Deslízalo, no lo cargues doblado.
• Cúbrelo con una cobija: casi todo animal grave se enfría.
• Hasta el más manso muerde cuando le duele. Ten cuidado al levantarlo.
• Si sangra, presiona encima con una tela limpia y no la levantes a mirar.

Anota qué pasó y a qué hora. Si se comió algo, trae el empaque.

Ven de una vez y avísanos que vienes en camino.'),

('mordedura', 'Mordedura o pelea con otro animal', 85, 'AVMA; VCA',
'Tráelo aunque solo se vean dos huequitos. Una mordida es una inyección de bacterias: por fuera cierra en un día y por dentro se infecta toda la semana. En animales pequeños, además, el sacudón hace daño interno sin dejar marca.

Si sangra, presiona con una tela limpia.
Enjuaga con agua limpia si puedes. No le pongas alcohol, yodo ni cremas.

Ten a la mano si el otro animal está vacunado contra la rabia y quién es su dueño.
Cuidado al manipularlo: le duele y puede morderte a ti.');

INSERT INTO termino_urgencia (termino, cuadro_codigo) VALUES
  ('convulsion', 'convulsion'), ('convulsiona', 'convulsion'),
  ('convulsiono', 'convulsion'), ('convulsionando', 'convulsion'),
  ('combulsion', 'convulsion'), ('combulsiona', 'convulsion'),
  ('convulciona', 'convulsion'), ('convulcion', 'convulsion'),
  ('ataque epileptico', 'convulsion'), ('epilepsia', 'convulsion'),
  ('esta temblando y no reacciona', 'convulsion'),

  ('atropellado', 'atropellamiento'), ('atropello', 'atropellamiento'),
  ('lo atropellaron', 'atropellamiento'), ('lo piso un carro', 'atropellamiento'),
  ('lo cogio un carro', 'atropellamiento'), ('accidente', 'atropellamiento'),
  ('se cayo de un', 'atropellamiento'), ('se callo de un', 'atropellamiento'),
  ('lo golpearon', 'atropellamiento'), ('le dieron una patada', 'atropellamiento'),

  ('no respira', 'dificultad_respiratoria'), ('no puede respirar', 'dificultad_respiratoria'),
  ('le cuesta respirar', 'dificultad_respiratoria'), ('respira mal', 'dificultad_respiratoria'),
  ('dificultad para respirar', 'dificultad_respiratoria'),
  ('esta ahogandose', 'dificultad_respiratoria'), ('se ahoga', 'dificultad_respiratoria'),
  ('lengua morada', 'dificultad_respiratoria'), ('encias moradas', 'dificultad_respiratoria'),
  ('lengua azul', 'dificultad_respiratoria'), ('esta agitado y no mejora', 'dificultad_respiratoria'),

  ('intoxicado', 'intoxicacion'), ('intoxicacion', 'intoxicacion'),
  ('envenenado', 'intoxicacion'), ('veneno', 'intoxicacion'),
  ('se comio veneno', 'intoxicacion'), ('comio raticida', 'intoxicacion'),
  ('raticida', 'intoxicacion'), ('se tomo', 'intoxicacion'),
  ('se comio chocolate', 'intoxicacion'), ('comio chocolate', 'intoxicacion'),
  ('comio uvas', 'intoxicacion'), ('xilitol', 'intoxicacion'),
  ('se comio una pastilla', 'intoxicacion'), ('acetaminofen', 'intoxicacion'),
  ('ibuprofeno', 'intoxicacion'), ('anticongelante', 'intoxicacion'),

  ('estomago hinchado', 'torsion_gastrica'), ('barriga hinchada', 'torsion_gastrica'),
  ('abdomen hinchado', 'torsion_gastrica'), ('esta inflado', 'torsion_gastrica'),
  ('torsion', 'torsion_gastrica'), ('torsion gastrica', 'torsion_gastrica'),
  ('dilatacion gastrica', 'torsion_gastrica'), ('arcadas', 'torsion_gastrica'),
  ('quiere vomitar y no puede', 'torsion_gastrica'),
  ('hace como para vomitar', 'torsion_gastrica'),

  ('golpe de calor', 'golpe_calor'), ('insolacion', 'golpe_calor'),
  ('se sobrecalento', 'golpe_calor'), ('quedo en el carro', 'golpe_calor'),
  ('lo dejaron en el carro', 'golpe_calor'),

  ('esta pariendo', 'parto'), ('no puede parir', 'parto'),
  ('parto', 'parto'), ('lleva horas pujando', 'parto'),
  ('esta pujando', 'parto'), ('distocia', 'parto'),
  ('se le atoro un cachorro', 'parto'), ('cachorro atascado', 'parto'),

  ('sangra mucho', 'hemorragia'), ('esta sangrando', 'hemorragia'),
  ('sangrado', 'hemorragia'), ('hemorragia', 'hemorragia'),
  ('no para de sangrar', 'hemorragia'), ('perdiendo sangre', 'hemorragia'),
  ('herida profunda', 'hemorragia'), ('se corto', 'hemorragia'),

  ('se atoro', 'atragantamiento'), ('se atraganto', 'atragantamiento'),
  ('tiene algo atorado', 'atragantamiento'), ('atragantado', 'atragantamiento'),
  ('se trago un hueso', 'atragantamiento'), ('tiene un hueso atorado', 'atragantamiento'),

  ('no puede orinar', 'obstruccion_urinaria'), ('no orina', 'obstruccion_urinaria'),
  ('no puede hacer pis', 'obstruccion_urinaria'), ('no hace pipi', 'obstruccion_urinaria'),
  ('puja y no orina', 'obstruccion_urinaria'), ('obstruccion urinaria', 'obstruccion_urinaria'),
  ('esta tapado', 'obstruccion_urinaria'), ('orina con sangre', 'obstruccion_urinaria'),

  ('se le salio el ojo', 'trauma_ocular'), ('ojo salido', 'trauma_ocular'),
  ('ojo afuera', 'trauma_ocular'), ('golpe en el ojo', 'trauma_ocular'),
  ('proptosis', 'trauma_ocular'), ('se lastimo el ojo', 'trauma_ocular'),

  ('quemadura', 'quemadura'), ('se quemo', 'quemadura'),
  ('mordio un cable', 'quemadura'), ('agua hirviendo', 'quemadura'),

  ('se desmayo', 'colapso'), ('no reacciona', 'colapso'),
  ('esta inconsciente', 'colapso'), ('no responde', 'colapso'),
  ('colapso', 'colapso'), ('se puso frio', 'colapso'),
  ('no se levanta', 'colapso'), ('esta muy decaido y no responde', 'colapso'),

  ('lo mordio', 'mordedura'), ('lo mordieron', 'mordedura'),
  ('mordedura', 'mordedura'), ('se peleo con otro perro', 'mordedura'),
  ('pelea de perros', 'mordedura'), ('lo ataco un perro', 'mordedura'),

  -- La red de seguridad: alguien que dice que es grave, lo es hasta que un
  -- humano diga lo contrario.
  ('urgencia', 'urgencia_general'), ('es urgente', 'urgencia_general'),
  ('emergencia', 'urgencia_general'), ('esta grave', 'urgencia_general'),
  ('muy grave', 'urgencia_general'), ('esta muy mal', 'urgencia_general'),
  ('se esta muriendo', 'urgencia_general'), ('se muere', 'urgencia_general'),
  ('ayuda por favor', 'urgencia_general'), ('auxilio', 'urgencia_general'),
  ('esta agonizando', 'urgencia_general'), ('critico', 'urgencia_general');

-- Variantes que la primera tanda de pruebas dejó pasar. Se agregan como
-- filas y no editando las de arriba porque así queda claro que la lista se
-- alimenta de lo que falla en la calle, no de lo que uno imagina en el
-- escritorio.
INSERT INTO termino_urgencia (termino, cuadro_codigo) VALUES
  ('se cayo', 'atropellamiento'), ('se callo', 'atropellamiento'),
  ('cayo de', 'atropellamiento'), ('cayo del', 'atropellamiento'),
  ('se cayo de', 'atropellamiento'), ('se cayo del', 'atropellamiento'),
  ('del balcon', 'atropellamiento'), ('por la ventana', 'atropellamiento'),
  ('de la terraza', 'atropellamiento'), ('desde el piso', 'atropellamiento'),
  ('lo pateo', 'atropellamiento'), ('se estrello', 'atropellamiento'),

  ('respira raro', 'dificultad_respiratoria'),
  ('respira con dificultad', 'dificultad_respiratoria'),
  ('respira rapido', 'dificultad_respiratoria'),
  ('respira muy rapido', 'dificultad_respiratoria'),
  ('le falta el aire', 'dificultad_respiratoria'),
  ('jadea mucho', 'dificultad_respiratoria'),
  ('esta jadeando mucho', 'dificultad_respiratoria'),
  ('hace ruido al respirar', 'dificultad_respiratoria'),

  ('no se mueve', 'colapso'), ('no se puede parar', 'colapso'),
  ('no se para', 'colapso'), ('esta tirado', 'colapso'),
  ('no abre los ojos', 'colapso'), ('esta muy debil', 'colapso'),

  ('vomita sangre', 'hemorragia'), ('sangre por la nariz', 'hemorragia'),
  ('sangre por el ano', 'hemorragia'), ('escupe sangre', 'hemorragia'),
  -- Los términos se comparan enteros y con límite de palabra, así que
  -- «vomita sangre» no cubre «está vomitando sangre» —que fue justo como lo
  -- escribió la primera persona que lo probó—. No es un cuadro nuevo ni un
  -- criterio clínico nuevo: es el mismo término conjugado. Cuando se agregue
  -- un término, conviene agregarlo también como lo diría alguien asustado,
  -- que escribe en gerundio y no en tercera persona del presente.
  ('vomitando sangre', 'hemorragia'), ('vomito con sangre', 'hemorragia'),
  ('vomita con sangre', 'hemorragia'), ('vomitando con sangre', 'hemorragia'),
  ('sangrando por la nariz', 'hemorragia'), ('sangrando por el ano', 'hemorragia'),
  ('escupiendo sangre', 'hemorragia'), ('heces con sangre', 'hemorragia'),
  ('popo con sangre', 'hemorragia'), ('diarrea con sangre', 'hemorragia'),
  -- La sangre en la orina NO va aquí: «orina con sangre» ya está arriba, en
  -- obstrucción urinaria, que es el cuadro que hay que atender primero. El
  -- término es único en la tabla, así que ponerlo en dos cuadros no compite:
  -- rompe la instalación desde cero con una violación de clave.
  ('orinando sangre', 'obstruccion_urinaria'),

  ('comio veneno para ratas', 'intoxicacion'), ('lamio', 'intoxicacion'),
  ('se comio una planta', 'intoxicacion'), ('cebolla', 'intoxicacion'),
  ('mordio una rana', 'intoxicacion'), ('sapo', 'intoxicacion');

-- Las que todavía no ha firmado un veterinario de la clínica.
CREATE OR REPLACE VIEW v_urgencia_sin_aprobar AS
  SELECT codigo, nombre, fuente, created_at
    FROM cuadro_urgencia
   WHERE activa AND aprobada_por IS NULL
   ORDER BY prioridad DESC, codigo;

-- ---------------------------------------------------------------------
-- La detección
--
-- Sobre los falsos positivos: los hay, y se prefieren. «No respira bien
-- desde ayer» dispara igual que «no respira». Un escalamiento de más le
-- cuesta un minuto a una persona; uno de menos le puede costar el paciente.
-- La asimetría es tan grande que no vale la pena afinar la coincidencia.
--
-- El término se busca entre bordes de palabra para que «parto» no salte con
-- «departamento» ni «se corto» con «acortó».
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION detectar_urgencia(p_texto text)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_txt text := normalizar(COALESCE(p_texto, ''));
  c     record;
BEGIN
  IF v_txt = '' THEN RETURN NULL; END IF;

  SELECT cu.codigo, cu.nombre, cu.instruccion, t.termino
    INTO c
    FROM termino_urgencia t
    JOIN cuadro_urgencia cu ON cu.codigo = t.cuadro_codigo
   WHERE t.activo AND cu.activa
     AND v_txt ~ ('(^|[^a-z0-9])' || t.termino || '([^a-z0-9]|$)')
   ORDER BY cu.prioridad DESC, length(t.termino) DESC
   LIMIT 1;

  IF c.codigo IS NULL THEN RETURN NULL; END IF;

  RETURN jsonb_build_object(
    'cuadro', c.codigo, 'nombre', c.nombre,
    'termino', c.termino, 'instruccion', c.instruccion);
END;
$$;

-- El mensaje completo que se le manda a la persona. Se arma en SQL, con la
-- dirección de la base y la instrucción literal de la tabla. El modelo no
-- toca ni una palabra de esto.
CREATE OR REPLACE FUNCTION texto_urgencia(p_cuadro text)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
  c    cuadro_urgencia%ROWTYPE;
  v_dir  text := config_txt('clinica_direccion', '');
  v_mapa text := config_txt('clinica_mapa_url', '');
  v_tel  text := config_txt('clinica_telefono_principal', '');
BEGIN
  SELECT * INTO c FROM cuadro_urgencia WHERE codigo = p_cuadro;
  IF c.codigo IS NULL THEN RETURN NULL; END IF;

  RETURN
    '🚨 <b>Esto es una urgencia. Tráelo ya.</b>' || E'\n\n' ||
    c.instruccion || E'\n\n' ||
    CASE WHEN v_dir <> '' THEN '📍 <b>' || esc(v_dir) || '</b>' || E'\n' ELSE '' END ||
    CASE WHEN v_mapa <> '' THEN v_mapa || E'\n' ELSE '' END ||
    CASE WHEN v_tel  <> '' THEN '📞 ' || esc(v_tel) || E'\n' ELSE '' END ||
    'Estamos abiertos 24 horas.' || E'\n\n' ||
    '👤 Ya le avisé a una persona del equipo. Te escribe en un momento por ' ||
    'este mismo chat para acompañarte mientras llegas.';
END;
$$;

-- ---------------------------------------------------------------------
-- El enganche: se reemplaza `asistente_recibir` de 040_asistente.sql
--
-- Es el mismo cuerpo con un bloque nuevo, y ese bloque va ANTES de todo lo
-- demás: antes del rate limit, antes de mirar si la IA está encendida, antes
-- de encolar nada. Una urgencia no la puede frenar un límite de mensajes por
-- hora ni una API caída.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION asistente_recibir(
  p_conversacion_id uuid,
  p_texto text,
  p_id_externo text DEFAULT NULL,
  p_tipo text DEFAULT 'texto',
  p_payload jsonb DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  c          conversacion%ROWTYPE;
  v_msg_id   bigint;
  v_urgencia jsonb;
  v_texto    text;
BEGIN
  SELECT * INTO c FROM conversacion WHERE id = p_conversacion_id;
  IF c.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa conversación no existe.');
  END IF;

  -- Idempotencia: el canal reintenta. Si este mensaje ya se registró, se
  -- descarta entero — no se vuelve a encolar una respuesta.
  v_msg_id := mensaje_registrar(p_conversacion_id, 'entrante', p_texto,
                                p_tipo, p_payload, p_id_externo);
  IF v_msg_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'duplicado', true, 'responde', false);
  END IF;

  -- ---------------------------------------------------------------
  -- Triaje. Lo primero, siempre.
  -- ---------------------------------------------------------------
  v_urgencia := detectar_urgencia(p_texto);

  IF v_urgencia IS NOT NULL THEN
    v_texto := texto_urgencia(v_urgencia->>'cuadro');

    -- Si el hilo ya lo atiende una persona, no se repite la cartilla ni se
    -- vuelve a alertar: ya hay alguien encima.
    IF NOT c.atendida_por_humano THEN
      PERFORM escalar_a_humano(
        p_conversacion_id,
        'urgencia: ' || (v_urgencia->>'nombre'),
        'urgencia');

      -- El texto sale por la cola, no por `asistente_responder`. La razón es
      -- el canal: en el simulador registrar un mensaje ES enviarlo, pero en
      -- WhatsApp y Telegram hay que hablar con una API, y eso no cabe en el
      -- segundo que el webhook tiene para contestar. El worker lo manda y lo
      -- registra en un solo paso.
      --
      -- Prioridad 20, la más alta que se usa: esta tarea se adelanta a
      -- cualquier respuesta del modelo que estuviera en la fila.
      PERFORM encolar_tarea('enviar_texto',
        jsonb_build_object('conversacion_id', p_conversacion_id, 'texto', v_texto),
        20, NULL, 0, 5);

      -- En la memoria del modelo sí se deja ya: si después una persona
      -- devuelve el hilo al bot, tiene que saber que esto ya se dijo.
      PERFORM ia_registrar(p_conversacion_id, 'assistant', to_jsonb(v_texto));
    END IF;

    -- El modelo no ve este mensaje. No se encola nada.
    RETURN jsonb_build_object(
      'ok', true, 'responde', false, 'motivo', 'urgencia',
      'urgencia', v_urgencia->>'cuadro',
      'escalada', NOT c.atendida_por_humano,
      'texto', v_texto);
  END IF;

  -- ---------------------------------------------------------------
  -- «ASESOR». Tampoco pasa por el modelo: pedir una persona no puede
  -- depender de que el modelo entienda que se la están pidiendo.
  -- ---------------------------------------------------------------
  IF pide_asesor(p_texto) AND NOT c.atendida_por_humano THEN
    PERFORM escalar_a_humano(p_conversacion_id, 'el cliente pidió un asesor');
    v_texto := 'Listo, ya le avisé a una persona del equipo. Te escribe por este '
               'mismo chat en un momento.';
    PERFORM encolar_tarea('enviar_texto',
      jsonb_build_object('conversacion_id', p_conversacion_id, 'texto', v_texto),
      20, NULL, 0, 5);
    PERFORM ia_registrar(p_conversacion_id, 'assistant', to_jsonb(v_texto));
    RETURN jsonb_build_object('ok', true, 'responde', false, 'motivo', 'pidio_asesor');
  END IF;

  -- ---------------------------------------------------------------
  -- «¿Eres un bot?». La misma reja, por la misma razón.
  --
  -- El prompt se lo pide desde el principio —«no te haces pasar por humano si
  -- te preguntan de frente»— y aun así el modelo contestó «soy una persona
  -- real, tranquilo» dos de cada tres veces. No es un descuido del prompt: es
  -- que la instrucción compite con otras veinte sobre sonar natural, y sonar
  -- natural es justo lo que empuja hacia la mentira.
  --
  -- Es el mismo caso de la urgencia y de «ASESOR»: un límite que no puede
  -- depender de que el modelo se acuerde. Y es el más caro de los tres, porque
  -- no se nota cuando falla. Una urgencia mal atendida se ve; esta mentira
  -- sólo se descubre cuando el cliente ya confió.
  --
  -- Corta el turno, como las otras dos. Si el mensaje traía además una
  -- consulta, se pierde y la persona la repite: es un costo real y aceptado,
  -- porque la alternativa —dejar que el modelo siga hablando del tema— es
  -- volver a poner el límite en sus manos.
  -- ---------------------------------------------------------------
  IF pregunta_si_es_bot(p_texto) AND NOT c.atendida_por_humano THEN
    v_texto := config_txt('texto_es_bot');

    PERFORM encolar_tarea('enviar_texto',
      jsonb_build_object('conversacion_id', p_conversacion_id, 'texto', v_texto),
      20, NULL, 0, 5);
    PERFORM ia_registrar(p_conversacion_id, 'assistant', to_jsonb(v_texto));

    RETURN jsonb_build_object('ok', true, 'responde', false, 'motivo', 'pregunta_si_es_bot',
                              'texto', v_texto);
  END IF;

  -- El hilo está en manos de una persona: se guarda lo que dijo el cliente
  -- para que el panel lo muestre, y el bot se queda callado.
  IF NOT bot_responde(p_conversacion_id) THEN
    RETURN jsonb_build_object('ok', true, 'responde', false,
                              'motivo', 'atendida_por_humano');
  END IF;

  IF NOT ia_disponible(c.contacto_id) THEN
    RETURN jsonb_build_object('ok', true, 'responde', false, 'motivo', 'ia_apagada');
  END IF;

  -- Un chat secuestrado no puede quemar la cuenta del modelo en una noche.
  IF NOT consumir_rate_limit('ia:' || c.contacto_id::text,
                             config_int('ia_limite_hora', 60), 3600) THEN
    RETURN jsonb_build_object('ok', true, 'responde', false, 'motivo', 'rate_limit',
      'texto', 'Hemos hablado mucho en la última hora. Dame un momento, '
               'o escribe ASESOR si necesitas atención inmediata.');
  END IF;

  PERFORM ia_registrar(p_conversacion_id, 'user', to_jsonb(p_texto));

  PERFORM encolar_tarea('chasqui_responder',
    jsonb_build_object('conversacion_id', p_conversacion_id,
                       'contacto_id', c.contacto_id,
                       'canal', c.canal),
    5,          -- prioridad alta: hay alguien esperando frente al teléfono
    NULL, 0, 2  -- 2 intentos: si el modelo falla dos veces, mejor avisar que insistir
  );

  RETURN jsonb_build_object('ok', true, 'responde', true, 'mensaje_id', v_msg_id);
END;
$$;

-- ---------------------------------------------------------------------
-- «ASESOR»: la otra salida a humano
--
-- No es una urgencia, pero se resuelve en el mismo punto y por la misma
-- razón: no puede depender de que el modelo entienda que le están pidiendo
-- una persona. Se atiende antes de gastar una llamada a la API.
-- ---------------------------------------------------------------------
-- Las frases tienen que ser inequívocas. La primera versión incluía «humano» y
-- «persona real», y con eso «¿eres una persona real o un bot?» escalaba el
-- chat en vez de responderse — que es justo lo contrario de lo que la persona
-- pedía. Aquí un falso positivo no es barato: interrumpe a alguien del equipo
-- y deja al cliente esperando a un humano que no pidió.
INSERT INTO config (clave, valor, tipo, descripcion, editable_ui) VALUES
  ('palabras_asesor',
   'asesor,operador,quiero hablar con alguien,hablar con una persona,'
   'con un humano,con una persona,pasame con alguien,pasame con una persona,'
   'necesito hablar con alguien,atencion humana',
   'texto', 'Frases que hacen que el bot entregue el chat a una persona, separadas por coma', true)
ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor;

CREATE OR REPLACE FUNCTION pide_asesor(p_texto text)
RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_txt text := normalizar(COALESCE(p_texto, ''));
  p     text;
BEGIN
  IF v_txt = '' THEN RETURN false; END IF;

  FOREACH p IN ARRAY string_to_array(
                 normalizar(config_txt('palabras_asesor', 'asesor')), ',') LOOP
    p := trim(p);
    IF p <> '' AND v_txt ~ ('(^|[^a-z0-9])' || p || '([^a-z0-9]|$)') THEN
      RETURN true;
    END IF;
  END LOOP;

  RETURN false;
END;
$$;

-- ---------------------------------------------------------------------
-- «¿Eres un bot?»: la respuesta es un dato, no una generación
--
-- Igual que las instrucciones de urgencia: se recita, no se redacta. El texto
-- es editable desde el portal porque el tono es de la clínica, pero lo que no
-- se negocia es que exista y que salga sin pasar por el modelo.
--
-- Reconoce, responde derecho y devuelve la conversación a donde iba: decir
-- que es un programa no es una disculpa ni un final de conversación.
-- ---------------------------------------------------------------------
INSERT INTO config (clave, valor, tipo, descripcion, editable_ui) VALUES
  ('texto_es_bot',
   'Soy un asistente virtual de Abanimal, no una persona. Te lo digo de una '
   'porque preguntaste directo.' || E'\n\n' ||
   'Lo que te diga de precios, horarios y preparación sale del sistema de la '
   'clínica, así que es lo mismo que te diría el equipo. Y si en cualquier '
   'momento prefieres hablar con alguien, escribe ASESOR y te paso.'
   || E'\n\n' || '¿Seguimos con lo tuyo?',
   'texto', 'Lo que responde el bot cuando le preguntan de frente si es un bot o una persona', true),

  -- Las frases van completas y no sueltas: «bot» a secas también estaría en
  -- «robot» y en cualquier palabra que lo contenga, y «persona» sola choca de
  -- frente con «eres una persona muy amable», que no pregunta nada.
  ('frases_es_bot',
   'eres un bot,eres bot,sos un bot,un bot,eres una maquina,eres un robot,'
   'eres una ia,eres un programa,eres un algoritmo,eres una persona real,'
   'eres real,eres humano,eres una persona o un bot,persona o un bot,'
   'hablo con un bot,hablo con una maquina,hablo con un robot,'
   'hablo con una persona real,esto es un bot,esto es un robot,'
   'estoy hablando con un bot,eres un contestador,eres automatico',
   'texto', 'Frases que hacen que el bot admita que es un bot, separadas por coma', true)
ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor;

CREATE OR REPLACE FUNCTION pregunta_si_es_bot(p_texto text)
RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_txt text := normalizar(COALESCE(p_texto, ''));
  p     text;
BEGIN
  IF v_txt = '' THEN RETURN false; END IF;

  FOREACH p IN ARRAY string_to_array(
                 normalizar(config_txt('frases_es_bot', 'eres un bot')), ',') LOOP
    p := trim(p);
    IF p <> '' AND v_txt ~ ('(^|[^a-z0-9])' || p || '([^a-z0-9]|$)') THEN
      RETURN true;
    END IF;
  END LOOP;

  RETURN false;
END;
$$;

-- ---------------------------------------------------------------------
-- La tercera reja: una herramienta para escalar
--
-- La primera es la lista de términos; la segunda, el cuadro general. Esta es
-- para lo que ninguna de las dos vio: un cuadro descrito con palabras que a
-- nadie se le ocurrieron, o un cliente que se está enojando y no ha dicho
-- «asesor».
--
-- **Por qué no pide confirmación**, siendo que cambia estado y la regla del
-- proyecto es que escribir se confirma con un botón: esa regla existe para
-- proteger a la persona de una acción que no pidió —agendar, cancelar,
-- cobrar—. Pasarle el chat a un humano no le hace daño a nadie, y esperar un
-- toque de botón para hacerlo sí. La excepción es esta y ninguna más.
--
-- Es la ÚLTIMA reja, no la primera: si esto fuera lo único, un modelo
-- distraído dejaría pasar una convulsión. Por eso las otras dos corren antes
-- y sin preguntarle a nadie.
-- ---------------------------------------------------------------------
INSERT INTO ia_herramienta (nombre, audiencia, escribe, critica, orden, descripcion, esquema) VALUES
('pedir_asesor', 'publica', false, false, 5,
 -- La frase de «no preguntes, hazlo» se agregó tras la primera prueba: ante
 -- «mi perra tiene una masa que crece, ¿será cáncer?», el modelo no
 -- diagnosticó —bien— pero ofreció pasar el chat en vez de pasarlo. A alguien
 -- preocupado, preguntarle le cuesta un mensaje más y otra espera.
 'Le pasa la conversación a una persona del equipo. Úsala en cuanto veas '
 'cualquiera de estas cosas: el paciente puede estar grave o el caso suena a '
 'urgencia, aunque no sepas de qué se trata; te describen un signo clínico y '
 'te piden una opinión médica; te piden un dato que no tienes y que importa; '
 'la persona está enojada, angustiada o insiste en algo que ya le dijiste que '
 'no puedes. Ante la duda, úsala: que entre una persona nunca es un error, no '
 'llamarla sí puede serlo. '
 'NO preguntes «¿quieres que te pase con un asesor?» — llámala y avísale que '
 'ya lo hiciste. Preguntar le cuesta a la persona un mensaje más y una espera '
 'más en un momento en que está preocupada. '
 'Después de usarla, dilo en una frase corta y no sigas preguntando cosas.',
 '{"type":"object","properties":{"motivo":{"type":"string","description":"Por qué escalas, en pocas palabras y en español. Lo lee el personal de la clínica, no el cliente."}},"required":["motivo"]}'::jsonb)
ON CONFLICT (nombre) DO UPDATE
  SET audiencia = EXCLUDED.audiencia, escribe = EXCLUDED.escribe,
      descripcion = EXCLUDED.descripcion, esquema = EXCLUDED.esquema,
      orden = EXCLUDED.orden;

-- `ia_leer` la dejó vacía el núcleo (040) a propósito. Esta es la primera
-- herramienta que la llena. `150_herramientas.sql` la vuelve a reemplazar con
-- el catálogo completo del dominio — y tiene que conservar esta rama.
CREATE OR REPLACE FUNCTION ia_leer(
  p_contacto_id uuid, p_sede_id uuid, p_nombre text, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_conv uuid;
BEGIN
  CASE p_nombre

    WHEN 'pedir_asesor' THEN
      -- El hilo abierto de este contacto: la herramienta no recibe el id de
      -- la conversación porque el modelo no tiene por qué manejarlo, ni por
      -- qué poder escalar el hilo de otro.
      SELECT id INTO v_conv
        FROM conversacion
       WHERE contacto_id = p_contacto_id AND estado = 'abierta'
       ORDER BY ultima_actividad_at DESC
       LIMIT 1;

      IF v_conv IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'No hay una conversación abierta.');
      END IF;

      PERFORM escalar_a_humano(
        v_conv,
        COALESCE(NULLIF(trim(p_args->>'motivo'), ''), 'el asistente pidió ayuda'));

      RETURN jsonb_build_object('ok', true, 'datos', jsonb_build_object(
        'escalada', true,
        'nota', 'Ya se le avisó a una persona. Dile en una sola frase que ya '
                'avisaste y que le escriben por este chat. No preguntes nada más.'));

    ELSE
      RETURN jsonb_build_object('ok', false,
        'error', format('La herramienta %s no existe.', p_nombre));
  END CASE;
END;
$$;
