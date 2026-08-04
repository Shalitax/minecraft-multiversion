# Guía de soporte — Egg Minecraft Multiversión

Referencia para el equipo de soporte. Cada entrada es un mensaje que el
entrypoint imprime en la consola del servidor, con su causa y qué responder.

Los mensajes llevan prefijo según gravedad:

| Prefijo | Significado |
|---|---|
| `[i]` | Informativo. El servidor arranca igual |
| `[+]` | Algo se hizo correctamente |
| `[!]` | Aviso. El servidor arranca, pero conviene mirarlo |
| `[x]` | Error. El servidor **no** arranca |

---

## Lo primero que hay que pedir siempre

Todo el arranque se muestra **de golpe, en un solo bloque**, justo antes de que
el servidor tome el control. Mientras se hacen las comprobaciones solo se ve:

```
[i] Preparando el servidor...
```

Eso es normal, no es un cuelgue: hay consultas de red por medio. Después la
consola se limpia y aparece el bloque completo, que se queda 5 segundos en
pantalla antes de que el servidor empiece a escribir.

Las dos primeras líneas del bloque identifican el entorno:

```
[i] Java 21.0.5 (version 21) | Zona horaria UTC | IP 172.18.0.5
[i] Egg Multiversion v1.3.0 | imagen 2026-08-03 01:34 UTC (20260803-a1b2c3d)
```

> **Antes de reiniciar un servidor que falló, copia el error.** La limpieza de
> consola borra también lo del arranque anterior. Se controla con **Limpiar la
> consola al arrancar**; ponla en `0` si estás diagnosticando algo.
>
> Si necesitas ver el progreso en vivo (por ejemplo, para saber en qué paso se
> atasca un arranque lento), pon **Log de inicio en un solo bloque** en `0` y
> los mensajes vuelven a salir uno a uno.

Sin eso no se puede diagnosticar nada: **Wings cachea las imágenes**, así que
un servidor puede estar corriendo código de hace semanas aunque se haya
publicado una versión nueva. Si la fecha de imagen es antigua, un reinicio suele
bastar para que Wings baje la actual.

La tercera línea dice qué software se detectó:

```
[+] Software detectado: forge (args: libraries/net/minecraftforge/forge/.../unix_args.txt)
```

Si eso no coincide con lo que el cliente cree tener, ahí está el problema.

---

## El servidor no arranca

### `[x] No se encuentra el archivo 'server.jar' en la carpeta del servidor.`

El `.jar` no está donde el egg lo busca.

Causas habituales: el cliente lo borró desde el gestor de archivos, o lo renombró
sin actualizar la opción **Archivo JAR del servidor**.

**Respuesta:** comprobar que el nombre en la pestaña Startup coincide con el
archivo real. Si el archivo no está, reinstalar desde el panel.

### `[x] Falta el archivo de argumentos 'libraries/...'. Reinstala el servidor desde el panel.`

Es un servidor Forge o NeoForge al que le falta parte de su árbol de librerías.
Suele pasar si el cliente borró la carpeta `libraries/` creyendo que sobraba, o
si una instalación se cortó a medias.

**Respuesta:** reinstalar. No se puede recuperar de otra forma: ese archivo lo
genera el instalador de Forge y contiene el classpath completo.

### `[x] La descarga esta corrupta: el hash no coincide con el publicado.`

Una actualización automática se descargó incompleta. **El jar anterior se
conserva**, así que el servidor sigue funcionando con la versión previa.

**Respuesta:** reiniciar para reintentar. Si se repite, es problema de red del
nodo, no del cliente.

### `[!] El EULA no esta aceptado. El servidor se cerrara nada mas arrancar.`

Solo aparece si alguien puso **Aceptar el EULA de Minecraft** en `0`.

**Respuesta:** ponerlo en `1`, o que el cliente edite `eula.txt`.

---

## Modpacks que no arrancan

### `[!] Se detectaron N mod(s) que solo funcionan en el cliente`

La causa más común con diferencia. El cliente subió el modpack completo de su
launcher, que incluye mods que **solo existen en la versión de cliente** de
Minecraft (OptiFine, shaders, minimapas). Esos mods llaman a código que no
existe en el servidor y lo tumban.

El aviso lista los archivos concretos y por qué se marcaron:

- *declarado como solo cliente* — el propio mod lo dice en sus metadatos. Es
  información fiable, no una suposición.
- *mod conocido de solo cliente* — coincide con la lista de sospechosos
  habituales.

**Respuesta:** que los quite de `mods/`. Si quieres que se resuelva solo, la
opción **Revisar mods solo de cliente** puede ponerse en *Mover a una carpeta
aparte*: los saca a `mods-desactivados/` sin borrarlos y el servidor arranca.

> Si el modpack sigue sin arrancar tras quitarlos, el mod problemático no está
> en la lista. Pide el `crash-report` y busca la línea `NoClassDefFoundError:
> net/minecraft/client/...` — el mod que aparezca ahí es el culpable. Avisa para
> añadirlo a la lista.

---

## La instalación falla

Estos mensajes salen en la consola de **instalación**, no en la del servidor.

### `Ejecutando el instalador de forge. Esto puede tardar varios minutos.`

No es un error. Forge, NeoForge y Quilt no publican un jar listo para usar: hay
que ejecutar su instalador, que descarga las librerías una a una. Entre 2 y 10
minutos es normal; el resto de softwares es una única descarga.

**Respuesta:** esperar. Si el cliente reinstala a mitad, empieza de cero.

### `ERROR: Forge no publica builds para Minecraft X.`

La versión pedida no existe en Forge. El mensaje lista debajo las versiones que
sí existen.

**Respuesta:** elegir una de las listadas, o poner `latest`.

> NeoForge solo existe desde Minecraft 1.20.2. Para versiones anteriores hay que
> usar `forge`.

### Spigot: `Compilando Spigot X con BuildTools.`

Spigot no se puede redistribuir, así que **hay que compilarlo en el momento**.
Es la instalación más lenta y frágil del egg: 10-20 minutos y ~2 GB de RAM.

Durante ese rato la consola de instalación parece parada mientras clona los
repositorios de upstream. Es normal.

**Respuesta:** esperar. Si el cliente tiene prisa o el nodo va justo de RAM,
**Paper es preferible**: es compatible con todos los plugins de Spigot, rinde
mejor y se instala en segundos.

### `ERROR: BuildTools no pudo compilar Spigot X.`

Causas por orden de frecuencia:

1. La versión pedida no existe (`--rev` inválido)
2. El nodo se quedó sin RAM a mitad de la compilación
3. Esa versión de Minecraft necesita otro JDK del que se instaló

Los archivos temporales se borran solos, así que el servidor queda vacío y se
puede reinstalar sin limpiar nada a mano.

**Respuesta:** reintentar; si vuelve a fallar, ofrecer Paper.

### `ERROR: no se pudo consultar las versiones de Arclight en GitHub.`

GitHub limita a **60 consultas por hora y por IP**, y esa IP la comparte todo el
nodo. Con varias instalaciones de Arclight seguidas se agota.

**Respuesta:** reintentar en unos minutos. Solo afecta a Arclight; ningún otro
software usa la API de GitHub.

### `ERROR: no se pudo instalar ningun Java para ejecutar el instalador.`

El contenedor de instalación no trae JVM y se instala una al vuelo solo para
Forge, NeoForge y Quilt. Si esto falla, el nodo no llega a los repositorios de
Alpine.

**Respuesta:** es un problema de red del nodo, no del cliente. Escalar.

### `La API del proyecto no respondio.`

El proyecto elegido (Mohist, Purpur, Pufferfish...) tiene su API caída. La
instalación se detiene con un mensaje claro en vez de dejar un servidor a medias.

**Respuesta:** reintentar más tarde, o instalar otro software. Paper y Vanilla
son los más fiables porque sus APIs casi nunca fallan.

---

## Problemas de versión de Java

### `[!] Minecraft X necesita Java Y o superior, y esta imagen tiene Java Z.`

La imagen Docker no corresponde a la versión de Minecraft instalada.

**Respuesta:** cambiar la versión de Java en la pestaña Startup del panel. Guía
rápida:

| Minecraft | Java |
|---|---|
| 1.16 y anteriores | 8 |
| 1.17 | 16 (17 también sirve) |
| 1.18 – 1.20.4 | 17 |
| 1.20.5 – 1.21.x | 21 |
| 26.x en adelante | **25** |

El egg ofrece exactamente esas versiones (8, 11, 16, 17, 21, 25) más OpenJ9 de 8
y 17 para planes con poca RAM. No hay 18, 19, 20, 22, 23 ni 24 porque ninguna
versión de Minecraft las necesita: 17, 21 y 25 cubren todo su rango.

Forge anterior a 1.17 **necesita Java 8**; con versiones más nuevas falla de
formas poco claras.

> El salto a Java 25 llegó con las versiones de calendario (26.x) y nada en el
> número de versión lo anticipa. Al aparecer una versión nueva de Minecraft,
> confirma el mínimo real en
> `https://fill.papermc.io/v3/projects/paper/versions/<version>`, campo
> `version.java.version.minimum`, y actualiza la tabla de `required_java_for`
> en el entrypoint.

### `[!] ZGC necesita Java 15 o superior. Se usa el recolector por defecto.`

Se pidió un recolector de memoria que la imagen no soporta. Es solo un aviso: el
servidor arranca con el recolector por defecto.

**Respuesta:** dejar **Recolector de memoria** en `Automático` salvo que haya un
motivo concreto.

---

## Rendimiento y recursos

### `[!] Menos de 1 GB de RAM.` / `[!] N mods con solo X MB.`

El plan contratado no da para lo que el cliente quiere ejecutar. Un modpack
grande necesita 4–6 GB.

### `[!] Distancia de renderizado N con X MB.`

**Respuesta:** bajar **Distancia de renderizado** a 6 u 8. Es la mejora de
rendimiento más efectiva que existe y no requiere subir de plan.

### `[i] Con esta memoria, activar 'Reservar memoria para el sistema' suele evitar cierres inesperados.`

Aparece con asignaciones de 4 GB o más. Si el servidor se cierra solo sin dejar
error en la consola, es que el contenedor está siendo terminado por consumo de
memoria: Java estaba usando toda la asignación para el juego y no dejaba nada
para su propio funcionamiento interno.

**Respuesta:** activar esa opción.

---

## Actualización automática

### `[!] El software instalado ahora es 'X', pero el egg registro 'Y'.`

El cliente cambió de software con el gestor de versiones (por ejemplo, de Paper
a Forge) y la opción del panel sigue diciendo lo anterior.

**No es un fallo, es una protección:** sin ella, la actualización automática
descargaría Paper encima de un servidor Forge. No se actualiza nada y el
servidor arranca con normalidad.

**Respuesta:** si quiere seguir recibiendo actualizaciones, que elija el software
a mano en **Qué actualizar** en vez de dejarlo en `Automático`.

### `[!] No se pudo determinar la ultima version de X, se omite`

La API del proyecto no respondió. **El servidor arranca igual** con la versión
que ya tenía.

Las consultas de metadatos abandonan a los 20 segundos (60 como mucho contando
reintentos), así que una API caída retrasa el arranque unos segundos, no lo
bloquea. Si un proyecto lleva días caído, sus servidores siguen funcionando:
simplemente dejan de recibir actualizaciones.

**Respuesta:** ninguna. Si persiste días, avisar al equipo técnico.

### `[!] No se pudo consultar Gale en GitHub (limite de consultas por IP), se omite`

Gale se distribuye por releases de GitHub, que permite 60 consultas por hora y
por IP, compartidas por todo el nodo. **El servidor arranca igual** con el jar
que ya tenía.

**Respuesta:** ninguna si es esporádico. Si pasa constantemente, es que hay
muchos servidores de Gale o Arclight con actualización automática en el mismo
nodo; desactivarla en algunos lo resuelve.

---

## Softwares con particularidades

### Sponge

**No admite plugins de Spigot, Paper ni Bukkit.** Tiene su propio ecosistema de
plugins, incompatible con el resto. Es el malentendido número uno: el cliente
sube sus plugins de siempre y ninguno carga.

**Respuesta:** o busca equivalentes para Sponge, o cambia a Paper.

### NanoLimbo

No es un servidor de Minecraft completo: es una sala de espera para redes con
proxy. **No tiene EULA, ni `server.properties`, ni mundos.** Se configura entero
en `settings.yml`.

En el primer arranque todavía no existe ese archivo, así que usa su puerto por
defecto. **Al reiniciar una vez** queda apuntando al puerto asignado. Lo mismo
pasa con Velocity, BungeeCord y Waterfall.

### Leaf y Gale

Forks de Paper: admiten los mismos plugins y las mismas configuraciones. Si un
cliente reporta un problema raro con plugins, probar con Paper a secas descarta
que sea cosa del fork.

---

## Configuración

### `[!] Valor no reconocido para 'difficulty': 'X'.`

Alguien escribió un valor que no está en la lista. **El archivo no se toca**, se
conserva lo que hubiera.

**Respuesta:** usar los valores del desplegable. Dificultad acepta `Pacífico`,
`Fácil`, `Normal`, `Difícil` o `No modificar`.

### `[!] 'max-players' esperaba un numero y recibio 'X'.`

Se escribió texto en un campo numérico. **El valor anterior se conserva**, no se
rompe nada.

**Respuesta:** escribir solo el número, sin palabras.

### `[i] Configuracion optimizada: los archivos aun no existen, se aplicara en el proximo arranque`

Normal en un servidor recién creado: `bukkit.yml` y `spigot.yml` no existen hasta
que el servidor arranca una vez.

**Respuesta:** ninguna. Se aplica solo en el segundo arranque.

### `[+] Configuracion optimizada aplicada: N ajustes`

Se aplicó el preset. **Solo ocurre una vez**; a partir de ahí esos archivos son
del cliente y el egg no los vuelve a tocar.

Si el cliente se queja de que sus granjas de mobs rinden menos, es por los
límites de spawn. Puede editar `bukkit.yml` a mano y no se le sobrescribirá.

---

## Bedrock (Geyser)

### `[+] Geyser escuchara en el puerto UDP N` / `[+] Geyser configurado en el puerto UDP N`

El egg escribe el puerto de **Puerto de Geyser (Bedrock)** en la config de
Geyser en cada arranque, así que cambiarlo en el panel y reiniciar es
suficiente: nadie tiene que editar YAML.

- *"escuchara en"* → ya existía la config y se le ha actualizado el puerto.
- *"configurado en"* → primer arranque, no existía; se ha creado una config
  mínima y Geyser rellena el resto al cargar.

**Si los jugadores de Bedrock no conectan** aunque el plugin cargue, el motivo
casi seguro es que **ese puerto UDP no está asignado al servidor en el nodo**.
La variable solo le dice a Geyser qué puerto abrir; si el nodo no lo tiene
reservado para este servidor, no hay nada que abrir.

**Respuesta:** comprobar en el nodo que existe una asignación **UDP** con ese
número para este servidor. El puerto es el que el cliente escribe en su lista
de servidores de Bedrock.

### `[!] 'Puerto de Geyser' esperaba un numero y recibio 'X'`

Llegó un valor no numérico. **No se toca la config**, Geyser se queda con el
puerto que ya tuviera.

**Respuesta:** revisar qué está escribiendo el sistema de billing en esa
variable.

### `[!] Geyser no funciona en 'vanilla': ese software no carga plugins de Bukkit`

Sale con Vanilla puro, Sponge y NanoLimbo. Geyser es un **plugin de Bukkit** y
esos tres no tienen dónde cargarlo. Antes el jar se copiaba igualmente a
`plugins/` y no pasaba nada: la opción decía "activado" y los jugadores de
Bedrock simplemente no entraban, sin ningún error.

**Respuesta:** cambiar a Paper o un fork suyo, o poner un proxy (Velocity)
delante y activar Geyser en el proxy.

---

## Chat de voz (Simple Voice Chat)

El síntoma clásico es siempre el mismo: los jugadores entran al juego sin
problema, pero el icono del micro se queda en rojo y no hay nada en la consola
que lo explique. Es porque el audio va por **UDP en un puerto propio**
(`24454` por defecto) que el servidor no tiene asignado.

El egg lo resuelve solo con la opción **Puerto del chat de voz**, que se escribe
en `voicechat/voicechat-server.properties` en cada arranque. Por defecto vale
`-1`, que significa **usar el mismo puerto del servidor**: funciona sin asignar
nada extra, porque Wings abre TCP *y* UDP en cada allocation.

> A diferencia de Geyser, **cambiar este puerto no afecta a los jugadores**: el
> mod se lo comunica al cliente al conectar, nadie lo escribe a mano. Por eso se
> puede aplicar en cada arranque sin romper nada en un servidor ya en marcha.

### `[+] Chat de voz configurado en el puerto del servidor (X/UDP)`

Todo correcto, no hay que hacer nada.

### `[+] Chat de voz configurado en el puerto UDP X` + `[!] Ese puerto tiene que estar asignado...`

Se le dio un puerto propio. Hay que **asignarlo en el nodo** o el chat de voz no
conectará. Si no quieres gastar una allocation, pon la opción en `-1`.

### `[!] El chat de voz esta puesto en 'compartir puerto', pero 'query' esta activado`

`-1` no sirve aquí: **query** ya ocupa ese mismo puerto UDP. El egg lo detecta y
**no toca la configuración del mod** en vez de romper una de las dos cosas.

**Respuesta:** darle un puerto propio al chat de voz, o desactivar query.

### `[!] 'Puerto del chat de voz' esperaba un numero o -1`

Se escribió texto en el campo. **No se toca nada** y el egg pasa a modo aviso.

### `[!] Simple Voice Chat detectado, pero aun no ha creado su configuracion.`

Solo sale con la opción en **"No modificar"**. En ese modo el egg no escribe
nada, y el mod usará su 24454 por defecto.

### `[!] CONFLICTO: Geyser y el chat de voz quedarian los dos en X/UDP.`

Solo sale cuando los dos acaban **en el mismo número de puerto**. Con Geyser en
su 19132 de siempre y el chat de voz en 24454 o compartiendo el del servidor, no
hay conflicto y no se avisa de nada.

Cuando sí coinciden, uno de los dos deja de funcionar **sin dar ningún error**.

**Respuesta:** cambiar **Puerto de Geyser (Bedrock)** en el panel, o el puerto
del chat de voz en su `voicechat-server.properties`.

---

### `[!] Geyser no es compatible con 'forge', se omite`

Geyser publica builds para Paper y derivados, los proxies (Velocity,
BungeeCord, Waterfall), **Fabric y NeoForge**. Forge a secas y Quilt se quedan
fuera porque Geyser no publica nada para ellos.

### `[i] Floodgate no publica build para 'fabric'`

En Fabric y NeoForge se instala Geyser pero **no Floodgate**, porque el
proyecto no publica esas versiones. Consecuencia práctica: los jugadores de
Bedrock pueden entrar, pero necesitan una cuenta de Java.

**Respuesta:** si el cliente quiere Bedrock sin cuenta de Java en un servidor de
mods, la solución es poner un proxy (Velocity) delante y activar Geyser ahí.

---

## Cuando nada de lo anterior encaja

Pedir siempre, en este orden:

1. Las **tres primeras líneas** de la consola (Java, versión del egg, software detectado)
2. La línea `container@pterodactyl~` con el **comando de arranque completo**
3. El error tal cual aparece, sin recortar

Con eso se reproduce casi cualquier caso. El comando de arranque es
especialmente útil: dice exactamente qué flags se aplicaron y desde qué archivo
se lanzó el servidor.
