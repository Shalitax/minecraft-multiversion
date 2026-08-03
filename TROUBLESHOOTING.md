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

Las dos primeras líneas de la consola identifican el entorno:

```
[i] Java 21.0.5 (version 21) | Zona horaria UTC | IP 172.18.0.5
[i] Egg Multiversion v1.1.0 | imagen 2026-08-03 01:34 UTC (20260803-a1b2c3d)
```

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

El proyecto elegido (Leaves, Mohist, Purpur...) tiene su API caída. La
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
| 1.17 | 16 |
| 1.18 – 1.20.4 | 17 |
| 1.20.5 – 1.21.x | 21 |
| 26.x en adelante | **25** |

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

### `[!] Geyser necesita un puerto UDP propio (por defecto 19132).`

Sale siempre que Geyser está activado, como recordatorio.

**Si los jugadores de Bedrock no conectan** aunque el plugin cargue, es esto
casi seguro: falta asignar el puerto UDP al servidor desde el nodo.

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
