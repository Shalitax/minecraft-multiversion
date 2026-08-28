# Minecraft Multiversion — Egg para Pterodactyl

Un solo egg para todo Minecraft Java. El entrypoint del contenedor detecta al arrancar qué software hay instalado y arma el comando de inicio correcto.

Como la detección lee **lo que hay en disco**, tu módulo instalador puede cambiar el software cuando quiera sin que haya que tocar el egg ni reasignarlo.

```
Minecraft Multiversion/
├── egg-minecraft-multiversion.json   ← importar en el panel
├── set-registry.sh                   ← apuntar el egg a tu registry
├── TROUBLESHOOTING.md                ← guía para el equipo de soporte
├── install.sh                        ← fuente del script de instalación (ya embebido en el JSON)
├── README.md
├── .github/workflows/
│   └── build-images.yml              ← construye y publica las 17 imágenes
└── images/
    ├── entrypoint.sh                 ← toda la lógica vive aquí
    ├── build.sh                      ← build local (alternativa al workflow)
    └── java/{8,8j9,...,25}/Dockerfile
```

---

## Requisito previo

Este egg **no funciona con las imágenes yolks estándar**. La lógica va horneada en el entrypoint, así que hay que construir y publicar las imágenes propias antes de importar el egg.

Se derivan de yolks y agregan `jq`, `yq`, `unzip`, `zip` y el entrypoint nuevo.

El script de instalación usa el contenedor `eclipse-temurin:21-alpine`, separado de
la imagen de arranque del servidor, porque Hex Minecraft Modpacks necesita Java
durante la preparación del pack. El propio script instala también `curl`, `jq`,
`git` y las herramientas auxiliares necesarias para los instaladores normales.

### Opción A — GitHub Actions (recomendada, no requiere Docker)

Sube esta carpeta como repo. `.github/workflows/build-images.yml` construye y publica las 17 variantes a GHCR.

No hay que configurar nada: el workflow deriva el namespace de `github.repository_owner`, así que publica en `ghcr.io/TU-USUARIO/minecraft-multiversion` automáticamente.

Se dispara con push a `main` (solo si cambió `images/**`), a mano desde la pestaña Actions, y una vez al mes para recoger parches de las imágenes base. Los PRs construyen para verificar pero no publican. Con `workflow_dispatch` puedes pasar `21 17` para construir solo esos tags.

El job `summary` imprime al final el bloque `docker_images` ya listo para pegar en el egg.

### Opción B — Docker local

Necesita Docker Desktop con WSL2, y QEMU para arm64. Más lento, pero útil para iterar sobre el entrypoint sin esperar al CI.

```bash
cd images && REGISTRY=ghcr.io/TU-USUARIO/minecraft-multiversion ./build.sh 21
```

```bash
cd images && REGISTRY=ghcr.io/TU-USUARIO/minecraft-multiversion PUSH=1 ./build.sh
```

El contexto de build es `images/`, no la carpeta de cada versión, porque el `COPY` toma `entrypoint.sh` desde la raíz del contexto. `build.sh` y el workflow ya lo manejan. Las variantes OpenJ9 (`*j9`) se construyen solo para amd64 porque las imágenes base de IBM Semeru no publican arm64.

### Hacer público el paquete (una sola vez)

GHCR crea los paquetes **privados por defecto**, y Wings falla el pull con un error de credenciales poco claro.

Las 17 variantes son **tags de un mismo paquete** (`minecraft-multiversion`), no 17 paquetes, así que el cambio se hace una vez: perfil → **Packages** → `minecraft-multiversion` → **Package settings** → **Change visibility** → Public.

### Apuntar el egg a tu registry

El workflow no lo necesita, pero el egg sí lleva la ruta literal de la imagen:

```bash
./set-registry.sh ghcr.io/TU-USUARIO/minecraft-multiversion
```

Reemplaza las 17 entradas de `docker_images` y la variable `REGISTRY` de `build.sh`, y valida que el JSON siga siendo correcto.

### Importar el egg

Panel → **Nests** → elegir un nest → **Import Egg** → subir `egg-minecraft-multiversion.json`.

### Actualizar el entrypoint después

Wings intenta hacer pull de la imagen cada vez que arranca un servidor. Al republicar el mismo tag con un entrypoint corregido, los servidores lo toman en el siguiente reinicio — sin tocar el egg ni reinstalar. Esa es la ventaja de tener la lógica en la imagen y no en el egg.

### Compatibilidad con Hex Minecraft Tools

Desde el entrypoint `1.3.2`, el egg no ofrece ni modifica ajustes de `server.properties`. Hex Minecraft Tools es la única pantalla para cambiar la dificultad, modo de juego, acceso, mundo, mensaje y demás ajustes de Minecraft. El egg conserva solo las opciones necesarias para instalar, arrancar, actualizar y validar el servidor.

---

## Detección de software

Se evalúa en este orden, y lo primero que coincide gana:

| Se detecta si existe | Tipo | Cómo arranca |
|---|---|---|
| `velocity.toml` | `velocity` | `-jar`, sin `nogui`, flags propias de Velocity |
| `config.yml` con `listeners:` | `bungeecord` | `-jar`, sin `nogui` (cubre también Waterfall) |
| `mohist.yml` o `mohist_config/` | `mohist` | `-jar` |
| `arclight.conf` o `arclight/` | `arclight` | `-jar` |
| `libraries/net/neoforged/neoforge/*/unix_args.txt` | `neoforge` | `@archivo-de-args` |
| `libraries/net/minecraftforge/forge/*/unix_args.txt` | `forge` | `@archivo-de-args` |
| `unix_args.txt` en la raíz | `forge` | `@unix_args.txt` |
| `quilt-server-launch.jar` | `quilt` | `-jar` |
| `fabric-server-launch.jar` | `fabric` | `-jar` |
| `forge-*-universal.jar` / `forge-*-shim.jar` | `forge-legacy` | `-jar` |
| nada de lo anterior | `vanilla` | `-jar` (cubre Paper, Purpur, Spigot, Pufferfish…) |

Si hace falta, `SERVER_TYPE_OVERRIDE` fuerza un tipo y salta la detección.

**Los híbridos van antes que Forge a propósito.** Mohist y Arclight traen un árbol de librerías de Forge, así que arrancarlos desde el args file de Forge dejaría fuera toda la parte de Bukkit y los plugins no cargarían. En el primer arranque todavía no han escrito sus archivos de config, así que ahí se recurre a `.multiversion-software`, una marca que deja el instalador. La detección por archivos reales siempre gana sobre esa marca, para que un cambio posterior de software no se lea mal.

---

## Variables del panel

### Instalación

| Variable | Default | Notas |
|---|---|---|
| `SERVER_SOFTWARE` | `none` | 29 valores más `none`. Los diecinueve con instalador propio (`paper`, `purpur`, `pufferfish`, `leaf`, `gale`, `folia`, `spigot`, `vanilla`, `sponge`, `forge`, `neoforge`, `fabric`, `quilt`, `mohist`, `arclight`, `velocity`, `waterfall`, `bungeecord`, `nanolimbo`) y diez que solo instala mcjars (`velocity_ctd`, `canvas`, `youer`, `magma`, `divinemc`, `leaves`, `aspaper`, `legacyfabric`, `pluto`, `loohplimbo`). |
| `HEXMINECRAFTVERSION_BUILD` | *(vacía)* | Interna. Build de mcjars que instaló el módulo de versiones; con ella, Reinstalar reproduce exactamente lo que el cliente tenía. Ver más abajo. |
| `SERVER_VERSION` | `latest` | Solo se aplica al instalar/reinstalar. Hex Minecraft Modpacks guarda la versión exacta cuando el proveedor la publica sin ambigüedad; en caso contrario usa `modpack`. |
| `SERVER_JARFILE` | `server.jar` | Se ignora en Forge/NeoForge 1.17+ |

### Arranque

| Variable | Default | Notas |
|---|---|---|
| `SERVER_TYPE_OVERRIDE` | `Automático` | Forzar un tipo en vez de detectarlo |
| `STARTUP_MODE` | `auto` | `auto` arma el comando; `manual` respeta el Startup Command del panel e inyecta flags |
| `SERVER_MIN_MEMORY` | `128` | Valor de `-Xms` |
| `EXTRA_JAVA_ARGS` | *(vacío)* | Flags JVM extra, separadas por espacio |
| `TZ` | `UTC` | Zona horaria del contenedor y de la JVM |

### JVM

| Variable | Default | Notas |
|---|---|---|
| `AIKAR_FLAGS` | `1` | En Velocity aplica automáticamente el set recomendado de Velocity, no el de Aikar |
| `GC_TYPE` | `Automático` | `g1`, `zgc`, `zgc-gen`, `shenandoah`. Solo se usa si Aikar está apagado |
| `LOWER_XMX` | `0` | Cambia `-Xmx` por `-XX:MaxRAMPercentage` |
| `MAX_RAM_PERCENTAGE` | `80.0` | Porcentaje usado por lo anterior |
| `SIMD_OPERATIONS` | `0` | Necesita Java 16+ |
| `LOG4J2_VULN_WORKAROUND` | `0` | Solo para builds sin parchear |

Estas son booleanas `0`/`1` clásicas para controlar el entorno de Java y el arranque del servidor.

Las incompatibilidades se manejan solas: ZGC en Java 8 se ignora con un aviso en vez de romper el arranque, y `-XX:+ZGenerational` no se pasa en Java 24+, donde la bandera fue eliminada.

### Ajustes de Minecraft

El egg no duplica opciones de Minecraft en la pestaña Startup. Usa **Hex Minecraft Tools** para editar `server.properties` de forma guiada. Esto evita que un cambio hecho en una pantalla se vuelva a sobrescribir al reiniciar desde otra.

En los proxies, el egg sigue ajustando únicamente la dirección y el puerto asignados por Pterodactyl. Opciones como el modo online o el mensaje del servidor se modifican desde sus propios archivos de configuración.

### Auto-update

| Variable | Default | Notas |
|---|---|---|
| `AUTO_UPDATE` | `0` | Revisa si hay build nueva en cada arranque |
| `UPDATE_PROJECT` | `Automático` | `paper`, `purpur`, `pufferfish`, `leaves`, `folia`, `velocity`, `waterfall`, `vanilla` |
| `UPDATE_MC_VERSION` | `latest` | Fija una versión para recibir solo builds nuevas de esa versión |
| `UPDATE_CHANNEL` | `STABLE` | `STABLE`, `RECOMMENDED`, `BETA`, `ALPHA` |

El estado se guarda en `.multiversion-update`; si la build ya es la instalada no se descarga nada. Si la descarga falla, se conserva el jar actual.

**`Automático` usa la marca del instalador, no el tipo detectado.** Purpur, Leaves y Pufferfish son jars simples y los tres se detectan como `vanilla`, así que deducir el proyecto del tipo detectado reemplazaría el software del cliente por Paper sin avisar. Si no hay marca y no es un proxy, no se actualiza nada y se avisa, en vez de adivinar.

### Integración con Hex Minecraft Versions

La revisión compatible con el módulo declara `HEXMINECRAFTVERSION_PROTOCOL=1` y
`HEXMINECRAFTVERSION_BUILD`, las dos ocultas.

**Desde la 2.0.0 del módulo, este egg ya no descarga cuando el cliente cambia de versión.** El
módulo instala por la API de archivos de Wings, con los pasos que le da mcjars. El egg cubre los
otros dos momentos: crear el servidor, y atender el botón nativo de *Reinstalar*.

El protocolo del archivo `.hexminecraftversion-request` sigue implementado para eggs y módulos
antiguos, pero el módulo actual ya no lo escribe.

Al terminar se escriben tres estados, los escriba el egg o el módulo:

- `.multiversion-software`: plataforma instalada.
- `.multiversion-version`: versión de Minecraft o del proyecto resuelta por el instalador.
- `.hexminecraftversion-installed.json`: resultado confirmado, con fecha, build y protocolo, que los módulos usan antes que variables o logs antiguos.

#### Por qué estos tres salieron del `file_denylist`

Wings comprueba el denylist **al escribir, al renombrar y al descomprimir; no al borrar**. Mientras
los escribía solo este instalador, que corre dentro del contenedor de instalación y no pasa por la
capa de archivos de Wings, podían estar protegidos y todo funcionaba.

Desde que el módulo de versiones instala él, los escribe por esa capa, donde Wings **no puede
distinguirlo del cliente**. Con ellos en el denylist, toda instalación del módulo muere al final,
con la versión anterior ya retirada:

```
This file cannot be modified: present in egg denylist.
```

Lo que se pierde al sacarlos: un cliente puede editarlos a mano y hacer que los módulos de mods y
plugins le ofrezcan contenido de otra plataforma. Se lo hace a sí mismo, y esos módulos ya caían a
`logs/latest.log` cuando falta la marca — un archivo que el cliente siempre ha podido escribir. El
denylist nunca fue una frontera de seguridad aquí, era una guarda contra descuidos.

Lo que se gana: `.multiversion-consumed-nonce` entra en el denylist. Ese sí lo escribe solo este
instalador, y es el que impide que una solicitud de modpack ya atendida vuelva a parecer nueva.

`.github/workflows/lint-egg.yml` comprueba las dos mitades de la regla, para que nadie las devuelva
sin darse cuenta.

El modo `preserve` del módulo conserva mundos, `plugins/`, `mods/` y configuraciones, pero elimina
el runtime regenerable anterior (`libraries/`, launchers, JAR y args). Esto evita que el detector
siga viendo Forge después de instalar Paper. El modo `wipe` conserva el comportamiento de borrado
completo de `WIPE_ON_INSTALL=1`.

#### El instalador de mcjars

Este egg trae diecisiete instaladores escritos a mano, uno por proyecto, y además uno universal
que le pide la receta a [mcjars](https://mcjars.app) y la ejecuta. El universal sirve para dos
cosas distintas:

1. **Reproducir lo que el módulo instaló.** Si `HEXMINECRAFTVERSION_BUILD` tiene valor, el
   instalador resuelve esa build y la instala tal cual. Es lo que hace que *Reinstalar* devuelva
   al cliente lo que tenía y no el software con el que se creó el servidor.
2. **Instalar los diez que este egg no trae escritos.** Sin él, ampliar la lista de
   `SERVER_SOFTWARE` habría sido ofrecer un error.

El orden importa y es deliberado:

- Una **solicitud en curso** (versión o modpack) gana a la build guardada: es más reciente.
- La **build guardada** gana a los instaladores propios: describe una instalación exacta.
- Si mcjars no responde, o si la build es de otro software distinto al que se pide —porque el
   cliente lo cambió a mano en la pestaña Arranque—, se cae al **instalador propio**. Esos
   diecisiete no dependen de un tercero, y son la red cuando mcjars falla.

Las rutas y los archivos de cada paso se comprueban antes de usarlos: vienen de un servicio
externo, y ninguno puede salir de `/mnt/server`.

Está cubierto por `tests/mcjars.sh`, que ejecuta las funciones reales contra la API de verdad e
instala NanoLimbo de principio a fin.

### Integración con Hex Minecraft Modpacks

La revisión compatible declara `HEXMINECRAFTMODPACK_PROTOCOL=2` y la variable oculta no editable `HEXMINECRAFTMODPACK_REQUEST`. El módulo entrega un payload Base64 validado y un nonce; el instalador registra ese nonce en `.hexminecraftmodpacks-installed.json` para que una reinstalación posterior no repita accidentalmente la misma solicitud.

El módulo deja `SERVER_SOFTWARE=none`, porque el serverpack contiene y decide su propio loader. También actualiza `SERVER_VERSION` y `MC_VERSION_HINT` con la versión exacta de Minecraft cuando el catálogo publica una sola. Si no hay una versión inequívoca, usa `SERVER_VERSION=modpack` y vacía el hint; el arranque detecta el runtime y la versión desde los archivos reales.

Cuando el catálogo no entrega una versión única, el instalador busca la versión de Minecraft en los manifiestos del serverpack y en las rutas generadas por Forge, Fabric y el servidor de Mojang. El módulo usa el valor guardado en `.hexminecraftmodpacks-installed.json` para seleccionar después una imagen Java compatible declarada por este egg.

### Cuando el cliente cambia de software por su cuenta

Escenario habitual: el cliente contrata con `SERVER_SOFTWARE=paper` y después instala Forge desde el gestor de versiones. La variable del panel sigue diciendo "Paper".

**Para arrancar no pasa nada.** `SERVER_SOFTWARE` no se usa en el entrypoint, solo en el script de instalación. La detección mira los archivos reales, encuentra el árbol de Forge y arranca con su args file. Que el panel muestre "Paper" es puramente cosmético.

**Para el auto-update sí importaba**, y por eso la marca se valida antes de usarla. Si lo registrado ya no coincide con lo que hay en disco, no se actualiza nada y se avisa en consola. Sin esa comprobación, un servidor que pasó de Paper a Forge se habría descargado un Paper encima; con Forge anterior a 1.17, que arranca desde un jar único, eso lo habría dejado sin funcionar.

La validación cubre dos niveles:

- **Cambio de plataforma** (Paper → Forge, Fabric, un proxy…): lo delata el tipo detectado.
- **Cambio de fork** (Paper → Purpur): ambos son jars simples y detectan como `vanilla`, así que se compara además el nombre que el propio servidor escribe en `version_history.json`. Ese archivo no existe hasta el primer arranque; hasta entonces se confía en la marca.

Si un cliente cambia de software y quiere seguir teniendo actualizaciones automáticas, basta con elegir el software a mano en **Qué actualizar** en vez de dejarlo en `Automático`.

Queda un caso que no se puede detectar: si tu gestor de versiones instala un software nuevo **sin borrar** los archivos del anterior (por ejemplo, deja el árbol `libraries/` de Forge al volver a Paper), la detección seguirá viendo Forge. Eso depende de que el gestor limpie al cambiar.

### Validación

| Variable | Default | Notas |
|---|---|---|
| `VALIDATE_STARTUP` | `1` | Verifica jar/args file, EULA y versión de Java antes de arrancar |
| `MC_VERSION_HINT` | *(vacío)* | Ayuda al chequeo de Java cuando no se puede detectar la versión sola |

### Optimización y extras

| Variable | Default | Notas |
|---|---|---|
| `OPTIMIZE_CONFIGS` | `1` | Aplica el preset optimizado a `bukkit.yml`, `spigot.yml` y las configs de Paper |
| `SHOW_DIAGNOSTICS` | `1` | Resumen y avisos en consola al arrancar |
| `INSTALL_GEYSER` | `0` | Descarga Geyser y Floodgate (jugadores Bedrock) |
| `GEYSER_AUTO_UPDATE` | `0` | Vuelve a descargarlos en cada arranque |
| `ARCLIGHT_LOADER` | `forge` | Base de mods de Arclight: `forge`, `neoforge` o `fabric` |
| `CLIENT_MODS_ACTION` | `Solo avisar` | `No revisar`, `Solo avisar`, `Mover a una carpeta aparte` |
| `EULA` | `1` | Escribe `eula.txt` automáticamente para que el servidor arranque sin intervención |
| `WIPE_ON_INSTALL` | `1` | Borra todos los archivos al reinstalar, dejando una instalación limpia |

### Trazabilidad y rollback

Cada arranque imprime la versión del egg y la fecha de build de la imagen:

```
[i] Egg Multiversion v1.0.0 | imagen 2026-08-03 01:34 UTC (20260803-a1b2c3d)
```

Hace falta porque **Wings cachea las imágenes**: un servidor puede estar corriendo código de hace semanas aunque hayas publicado una versión nueva. Sin este dato, un ticket es indiagnosticable.

El workflow publica **dos tags** por variante: el móvil (`java_21`) y uno fechado e inmutable (`java_21-20260803-a1b2c3d`). Después de una compilación completa también genera como artifact un egg de producción que referencia exclusivamente los tags inmutables. Ese es el JSON que debe importarse en producción; el egg del repositorio conserva tags móviles para desarrollo.

Para cambiar la versión del egg, sube `MULTIVERSION_VERSION` en el entrypoint.

### Integridad de las descargas

PaperMC y Leaves publican el `sha256` de cada build, y Mojang el `sha1`. Se verifican tras descargar. El ejecutable externo de Ric-Rac usado para serverpacks también está fijado por arquitectura con SHA-256: si el proveedor cambia el binario, la instalación se detiene hasta revisar y actualizar conscientemente el hash. Purpur, Pufferfish y algunos Jenkins no publican hash, así que esa limitación permanece explícita.

Las imágenes fijan `yq` a una versión y checksum concretos; no descargan `latest`. Java 8 y 11 usan ramas mantenidas de Temurin sobre Jammy en vez de tags antiguos fechados de 2021.

### Borrado al reinstalar

Pterodactyl ejecuta el script de instalación tanto al **crear** el servidor como al pulsar **Reinstalar**. Al crearlo la carpeta está vacía, así que esto solo actúa en una reinstalación.

Con `WIPE_ON_INSTALL=1` (default) se borra todo el contenido de `/mnt/server` antes de instalar: mundos, plugins, configuraciones. Con `0` se conservan y la reinstalación solo reemplaza el `.jar`.

**Se borran también los archivos ocultos.** Es la diferencia con el `rm -rf /mnt/server/*` habitual: ese glob no alcanza los dotfiles, así que las marcas del egg (`.multiversion-optimized`, `.multiversion-software`, `.multiversion-update`) sobrevivirían a la reinstalación y el servidor nuevo arrancaría con estado del anterior — sin re-aplicar las configs optimizadas y con el registro de auto-update obsoleto. Por eso se usa:

```bash
find /mnt/server -mindepth 1 -maxdepth 1 -exec rm -rf {} +
```

Los backups de Pterodactyl viven fuera de `/mnt/server`, así que no se ven afectados.

### EULA

Con `EULA=1` (el default) se escribe `eula=true` en cada arranque, así que el servidor levanta sin que el cliente tenga que hacer nada. Se reescribe también si el archivo dice `eula=false`.

**Una variable sin definir cuenta como aceptada.** Es intencional: un servidor creado con una versión anterior del egg no tiene esa variable, y sin este comportamiento se quedaría sin arrancar con un error que casi ningún cliente sabe interpretar.

Con `EULA=0` no se toca el archivo y se avisa en consola; el cliente tendrá que aceptarlo a mano o desde el diálogo del panel, que sigue disponible porque `features` mantiene `eula`.

Los proxies se omiten: Velocity, BungeeCord y Waterfall no tienen EULA.

Ten en cuenta que aceptarlo automáticamente traslada esa aceptación a quien opera el servidor, es decir a ti como hosting, y no al cliente final. Es lo habitual en el sector, pero conviene que tus términos de servicio lo recojan.

---

## Configuración optimizada

Con `OPTIMIZE_CONFIGS=1` se aplica un preset a `bukkit.yml`, `spigot.yml`, `config/paper-world-defaults.yml`, `config/paper-global.yml` y `paper.yml` (Paper anterior a 1.19).

**Se aplica una sola vez.** Después queda la marca `.multiversion-optimized` y esos archivos pasan a ser del cliente: reaplicarlo en cada arranque le borraría su propio ajuste sin avisar. Si cambias el preset, sube `OPTIMIZE_PRESET_VERSION` en el entrypoint y se vuelve a aplicar en todos los servidores.

Qué toca: límites de spawn de mobs, rangos de actividad de entidades, radio de fusión de items, chunks guardados por tick, explosiones optimizadas y `ALTERNATE_CURRENT` como implementación de redstone.

Es un preset **conservador**: deliberadamente **no** activa `nerf-spawner-mobs`, que rinde bien pero rompe las granjas de spawner y generaría más tickets de los que ahorra.

Los archivos no existen hasta que el servidor arranca una vez, así que en un servidor nuevo el preset se aplica en el **segundo** arranque. Se avisa en consola.

Solo aplica a Paper y derivados, y a los híbridos. Los proxies y los servidores de Forge, NeoForge, Fabric o Quilt puros no tienen estos archivos y se omiten.

### Por qué yq y no sed

Las imágenes incluyen [`yq`](https://github.com/mikefarah/yq). Editar estos YAML con `sed` funciona hasta que un nombre de clave se repite bajo otro padre — cosa que en `spigot.yml` y `paper-world-defaults.yml` pasa constantemente — y entonces corrompe el archivo en silencio.

Además, **solo se modifican claves que ya existen**. Si una clave no está en el archivo, se omite en vez de inventarla, para no dejar ajustes que no hacen nada y confunden a quien lea el archivo después.

---

## Jugadores de Bedrock (Geyser)

Con `INSTALL_GEYSER=1` se descargan Geyser y Floodgate en `plugins/`, eligiendo la variante correcta: `spigot` para servidores, `velocity` o `bungeecord` para proxies.

**Necesita un puerto UDP adicional**, normalmente el 19132, asignado en el nodo. Sin eso los jugadores de Bedrock no conectan aunque el plugin cargue. El entrypoint lo recuerda en consola cada arranque.

`GEYSER_AUTO_UPDATE=1` los vuelve a descargar en cada arranque. Vale la pena: Geyser deja de funcionar cuando Mojang publica una versión nueva de Bedrock, y así se arregla solo.

---

## Modpacks que no arrancan: mods solo de cliente

La causa más habitual de que un modpack no arranque en servidor **no es la falta de entorno gráfico**. Es un mod client-only que referencia clases `net.minecraft.client.*` que no existen en el jar del servidor. El error típico es `NoClassDefFoundError: net/minecraft/client/...`, y no lo arregla ningún truco de display: el código del cliente no está ahí.

Antes de arrancar se revisa `mods/` y se detectan esos mods por dos vías:

**Metadatos declarados, que es la vía fiable.** Los mods de Fabric declaran su lado en `fabric.mod.json` (`"environment": "client"`) y los de Quilt en `quilt.mod.json`. Eso es información explícita del propio mod, no una suposición. Un mod marcado `"*"` o `"server"` nunca se toca.

**Nombres conocidos, como respaldo para Forge**, que no tiene un campo equivalente. La lista está en `CLIENT_ONLY_NAMES` dentro del entrypoint y es deliberadamente corta: solo mods inequívocamente de cliente. Cualquier cosa con componente de servidor real se queda fuera, porque un falso positivo quita contenido que el pack necesitaba y es más difícil de depurar que el crash original.

En Forge y NeoForge, cuando el `.toml` declara `side`, se lee **solo si está fuera de un bloque `[[dependencies]]`**. Ese mismo campo aparece constantemente dentro de las dependencias describiendo la dependencia, no el mod, y tomarlo al pie de la letra desactivaría mods universales perfectamente válidos.

### Qué hace al detectarlos

| Valor | Comportamiento |
|---|---|
| `No revisar` | Desactiva la comprobación |
| `Solo avisar` (default) | Los lista en consola y no toca nada |
| `Mover a una carpeta aparte` | Los mueve a `mods-desactivados/` y el servidor arranca solo |

El default es avisar porque un falso positivo que desactiva un mod en silencio genera un ticket peor que el crash. `Mover` es cómodo si prefieres que el servidor levante sin intervención; los mods no se borran y se recuperan devolviéndolos a `mods/`.

---

## Resumen al arrancar

Con `SHOW_DIAGNOSTICS=1` la consola muestra software detectado, versión de Java, memoria, número de plugins y mods, y distancia de renderizado. Además avisa cuando:

- Hay menos de 1 GB de RAM
- Hay más de 50 mods con menos de 4 GB
- La distancia de renderizado supera 12 con menos de 4 GB
- Conviene activar `LOWER_XMX` porque la asignación es grande

Los umbrales son deliberadamente amplios: buscan atrapar las configuraciones obviamente rotas que generan tickets, no ser exactos.

---

## Decisiones de diseño que conviene conocer

**El comando de stop es `^C`, no `stop`.** Los servidores usan `stop` y los proxies usan `end`; un egg solo puede definir uno. `^C` envía SIGINT, y tanto Minecraft como Velocity y BungeeCord tienen shutdown hooks que guardan y cierran limpio. Si solo vas a correr servidores y prefieres el comando explícito, cambia `config.stop` a `stop` en el egg.

**La línea de "done" es un array.** Wings acepta varios matchers y marca el servidor como online con el primero que aparezca: `)! For help, type ` (vanilla/Paper), `Done (` (Velocity) y `Listening on ` (BungeeCord).

**Los proxies reciben un `server.properties` vacío.** Wings *crea* cualquier archivo listado en `config.files`. Es inofensivo pero aparece en el file manager. La alternativa —listar también `velocity.toml`— sería peor: le dejaría un `velocity.toml` basura a todos los servidores Paper. Por eso la config de proxies se hace en el entrypoint.

**El auto-update excluye Forge, NeoForge, Fabric y Quilt.** Actualizarlos implica regenerar todo el árbol `libraries/`, que no se puede hacer con seguridad desde el arranque sin arriesgar un servidor que no bootea. Para esos, reinstala desde el panel. Si `AUTO_UPDATE` está encendido en uno de ellos, se avisa y se sigue.

---

## Sobre el entrypoint de SparkedHost

Lo que se tomó: modo compatibilidad Forge, mitigación Log4j2, SIMD, flags de Aikar, `MaxRAMPercentage`, y la detección de `unix_args.txt` de Forge y NeoForge.

Lo que cambió:

- **El comando se arma con un array de bash**, no con `sed` sobre el string de `STARTUP`. Encadenar `sed -E 's/-Xmx([0-9]+)[KMG]?/& ...flags.../'` se rompe si el usuario edita el startup y falla en silencio. El modo `manual` conserva ese comportamiento para quien lo quiera.
- **`FORGE_COMPATIBILITY` desapareció como variable.** Los flags `-Dterminal.jline=false -Dterminal.ansi=true` se aplican siempre: hacen falta para que la consola de Pterodactyl funcione bien en cualquier software, no solo en Forge.
- **El auto-update no depende de una API privada.** El de SparkedHost consulta su propio servicio por hash de archivo. Este usa APIs públicas: PaperMC Fill v3, Purpur y el manifiesto de Mojang.
- **Se agregaron** los toggles de `server.properties`, la configuración de proxies, la validación previa y el selector de GC.

## Nota sobre la API de PaperMC

`api.papermc.io/v2` **fue apagado el 1 de julio de 2026**. Cualquier egg tuyo que todavía descargue Paper, Velocity o Waterfall desde ahí ya está roto y hay que migrarlo.

Este egg usa `fill.papermc.io/v3`, que **documenta como obligatorio** un header `User-Agent` descriptivo con contacto. Al probarlo, un User-Agent genérico todavía recibe HTTP 200, así que la regla aún no se aplica de forma estricta — pero pueden empezar a hacerlo cuando quieran, y los scripts ya lo mandan. Está en `UPDATE_USER_AGENT` (entrypoint) y en la variable `UA` (install script); si publicas esto, pon ahí un contacto tuyo.

**`latest` prefiere versiones publicadas, no snapshots.** La versión más reciente que devuelve la API de Velocity es una rama `-SNAPSHOT` en desarrollo (hoy `4.1.0-SNAPSHOT` en vez de `4.0.0`), y filtrar por canal no sirve porque los snapshots también publican sus builds como `STABLE`. Ambos scripts descartan `-SNAPSHOT`, `-rc` y `-pre` al resolver `latest`, con fallback a la primera entrada si todas lo fueran. Si quieres un snapshot, fija la versión exacta en `SERVER_VERSION` o `UPDATE_MC_VERSION`.

Fuentes: [PaperMC Downloads API](https://docs.papermc.io/misc/downloads-api/) · [Nota de deprecación de v2](https://github.com/PaperMC/PaperDocs/issues/47)
