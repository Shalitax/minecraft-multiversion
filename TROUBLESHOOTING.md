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
[i] Egg Multiversion v1.0.0 | imagen 2026-08-03 01:34 UTC (20260803-a1b2c3d)
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
| 1.20.5 en adelante, y 25.x/26.x | 21 |

Forge anterior a 1.17 **necesita Java 8**; con versiones más nuevas falla de
formas poco claras.

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

### `[!] Solo quedan X MB libres. El servidor puede fallar al guardar el mundo.`

Quedarse sin disco a mitad de guardado **corrompe chunks**. Hay que actuar antes,
no después.

**Respuesta:** que borre backups viejos o mundos que no use. Si el plan está al
límite, ampliar.

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

Geyser necesita una plataforma con plugins (Paper y derivados, o un proxy). En
Forge o Fabric puros no hay dónde instalarlo.

---

## Cuando nada de lo anterior encaja

Pedir siempre, en este orden:

1. Las **tres primeras líneas** de la consola (Java, versión del egg, software detectado)
2. La línea `container@pterodactyl~` con el **comando de arranque completo**
3. El error tal cual aparece, sin recortar

Con eso se reproduce casi cualquier caso. El comando de arranque es
especialmente útil: dice exactamente qué flags se aplicaron y desde qué archivo
se lanzó el servidor.
