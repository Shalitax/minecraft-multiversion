#!/bin/ash
#
# Install script for the Minecraft Multiversion egg.
# Runs in eclipse-temurin:21-alpine. Java is required by the external modpack
# installer; jq and git are required by the normal Multiversion installers.
# Server files go to /mnt/server.
#
# This only has to place the initial files. The entrypoint detects whatever is
# on disk at boot, so an external installer module can replace the software at
# any time without touching the egg.
#
# Code comments stay in English for maintenance; user-facing output is Spanish.
#
set -e

mkdir -p /mnt/server
cd /mnt/server

# Pterodactyl runs installation scripts in this separate container, not in the
# server's selected runtime image. Keep all dependencies explicit so both the
# regular egg installers and Hex Minecraft Modpacks work in the same image.
apk add --no-cache --update curl bash ca-certificates jq git >/dev/null

SOFTWARE=$(echo "${SERVER_SOFTWARE:-paper}" | tr '[:upper:]' '[:lower:]')
VERSION="${SERVER_VERSION:-latest}"
CHANNEL="${UPDATE_CHANNEL:-STABLE}"
JARFILE="${SERVER_JARFILE:-server.jar}"
INSTALL_MODE="environment"

# Hex Minecraft Modpacks protocol 2 uses an internal, non-user-editable egg
# variable. The payload is Base64 JSON so catalogue identifiers and labels are
# never interpreted as shell syntax. A nonce stored in the installed marker
# makes the request one-shot without weakening the egg file denylist.
MODPACK_REQUEST_B64="${HEXMINECRAFTMODPACK_REQUEST:-}"
MODPACK_REQUEST=0
MODPACK_ALREADY_CONSUMED=0
MODPACK_PROVIDER=""
MODPACK_ID=""
MODPACK_NAME=""
MODPACK_VERSION_ID=""
MODPACK_VERSION_NAME=""
MODPACK_MINECRAFT_VERSION=""
MODPACK_MODE=""
MODPACK_EULA=""
MODPACK_NONCE=""

# Hex Minecraft Versions hands an installation request to the egg through a
# one-shot file. This avoids a race with Wings: SERVER_SOFTWARE can
# remain "none" in the Panel while the installer still receives the requested
# software and release. The file is removed before doing anything destructive.
REQUEST_FILE="/mnt/server/.hexminecraftversion-request"
if [ -f "${REQUEST_FILE}" ]; then
    request_value() {
        sed -n "s/^$1=//p" "${REQUEST_FILE}" | head -1 | tr -d '\r'
    }

    REQUEST_PROTOCOL=$(request_value protocol)
    REQUEST_SOFTWARE=$(request_value software | tr '[:upper:]' '[:lower:]')
    REQUEST_VERSION=$(request_value release)
    REQUEST_MODE=$(request_value mode | tr '[:upper:]' '[:lower:]')
    REQUEST_EULA=$(request_value eula)
    REQUEST_LOADER=$(request_value loader | tr '[:upper:]' '[:lower:]')

    rm -f "${REQUEST_FILE}"

    if [ "${REQUEST_PROTOCOL}" != "1" ]; then
        echo "ERROR: solicitud de Hex Minecraft Versions incompatible." >&2
        exit 1
    fi

    case "${REQUEST_SOFTWARE}" in
        paper|folia|purpur|pufferfish|leaf|gale|spigot|vanilla|sponge|fabric|quilt|forge|neoforge|mohist|arclight|velocity|waterfall|bungeecord|nanolimbo)
            SOFTWARE="${REQUEST_SOFTWARE}"
            ;;
        *)
            echo "ERROR: software no permitido en la solicitud del modulo." >&2
            exit 1
            ;;
    esac

    case "${REQUEST_VERSION}" in
        ''|*[!A-Za-z0-9._+-]*)
            echo "ERROR: version no valida en la solicitud del modulo." >&2
            exit 1
            ;;
        *) VERSION="${REQUEST_VERSION}" ;;
    esac

    case "${REQUEST_MODE}" in
        preserve) WIPE_ON_INSTALL=0 ;;
        wipe)     WIPE_ON_INSTALL=1 ;;
        *)
            echo "ERROR: modo de instalacion no valido." >&2
            exit 1
            ;;
    esac

    case "${REQUEST_EULA}" in
        0|1) EULA="${REQUEST_EULA}" ;;
        *)
            echo "ERROR: valor de EULA no valido." >&2
            exit 1
            ;;
    esac

    case "${REQUEST_LOADER}" in
        forge|neoforge|fabric) ARCLIGHT_LOADER="${REQUEST_LOADER}" ;;
        '') ARCLIGHT_LOADER="forge" ;;
        *)
            echo "ERROR: loader de Arclight no valido." >&2
            exit 1
            ;;
    esac

    INSTALL_MODE="${REQUEST_MODE}"
    echo "Solicitud recibida desde Hex Minecraft Versions."
fi

# Modpack installation request. This is intentionally separate from the
# version request: a modpack chooses its own loader and Minecraft release.
if [ -n "${MODPACK_REQUEST_B64}" ]; then
    if [ "${HEXMINECRAFTMODPACK_PROTOCOL:-}" != "2" ]; then
        echo "ERROR: solicitud de Hex Minecraft Modpacks incompatible." >&2
        exit 1
    fi

    if ! MODPACK_JSON=$(printf '%s' "${MODPACK_REQUEST_B64}" | base64 -d 2>/dev/null); then
        echo "ERROR: la solicitud de modpack no usa Base64 valido." >&2
        exit 1
    fi

    if ! printf '%s' "${MODPACK_JSON}" | jq -e '
        type == "object" and
        .protocol == 2 and
        (.nonce | type == "string" and length == 32) and
        (.provider | type == "string") and
        (.modpack_id | type == "string" and length > 0 and length <= 191) and
        (.modpack_name | type == "string" and length > 0 and length <= 200) and
        (.modpack_version_id | type == "string" and length > 0 and length <= 191) and
        (.modpack_version_name | type == "string" and length > 0 and length <= 200) and
        (.minecraft_version | type == "string" and length > 0 and length <= 20) and
        (.minecraft_version == "modpack" or (.minecraft_version | test("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$"))) and
        (.mode == "preserve" or .mode == "wipe") and
        (.eula == 0 or .eula == 1)
    ' >/dev/null 2>&1; then
        echo "ERROR: la solicitud interna de modpack no es valida." >&2
        exit 1
    fi

    MODPACK_NONCE=$(printf '%s' "${MODPACK_JSON}" | jq -r '.nonce')
    case "${MODPACK_NONCE}" in
        *[!a-f0-9]*) echo "ERROR: nonce de modpack no valido." >&2; exit 1 ;;
    esac

    CONSUMED_NONCE=""
    if [ -f .hexminecraftmodpacks-installed.json ]; then
        CONSUMED_NONCE=$(jq -r '.request_nonce // empty' .hexminecraftmodpacks-installed.json 2>/dev/null || true)
    fi

    if [ "${CONSUMED_NONCE}" = "${MODPACK_NONCE}" ]; then
        MODPACK_ALREADY_CONSUMED=1
        echo "La solicitud de Hex Minecraft Modpacks ya fue consumida; no se repetira."
    else
        MODPACK_PROVIDER=$(printf '%s' "${MODPACK_JSON}" | jq -r '.provider' | tr '[:upper:]' '[:lower:]')
        MODPACK_ID=$(printf '%s' "${MODPACK_JSON}" | jq -r '.modpack_id')
        MODPACK_NAME=$(printf '%s' "${MODPACK_JSON}" | jq -r '.modpack_name')
        MODPACK_VERSION_ID=$(printf '%s' "${MODPACK_JSON}" | jq -r '.modpack_version_id')
        MODPACK_VERSION_NAME=$(printf '%s' "${MODPACK_JSON}" | jq -r '.modpack_version_name')
        MODPACK_MINECRAFT_VERSION=$(printf '%s' "${MODPACK_JSON}" | jq -r '.minecraft_version')
        MODPACK_MODE=$(printf '%s' "${MODPACK_JSON}" | jq -r '.mode' | tr '[:upper:]' '[:lower:]')
        MODPACK_EULA=$(printf '%s' "${MODPACK_JSON}" | jq -r '.eula | tostring')

        case "${MODPACK_PROVIDER}" in
            atlauncher|curseforge|feedthebeast|modrinth|technic|voidswrath) ;;
            *) echo "ERROR: proveedor de modpacks no permitido." >&2; exit 1 ;;
        esac

        case "${MODPACK_MODE}" in
            preserve) WIPE_ON_INSTALL=0 ;;
            wipe)     WIPE_ON_INSTALL=1 ;;
        esac

        EULA="${MODPACK_EULA}"
        VERSION="${MODPACK_MINECRAFT_VERSION}"
        MODPACK_REQUEST=1
        INSTALL_MODE="${MODPACK_MODE}"
        echo "Solicitud segura recibida desde Hex Minecraft Modpacks."
    fi
fi

if [ "${MODPACK_ALREADY_CONSUMED}" = "1" ] && [ "${SOFTWARE}" = "none" ]; then
    echo "No hay una nueva solicitud de instalacion; se conservan los archivos actuales."
    exit 0
fi

# ---------------------------------------------------------------------------
# Optional wipe
#
# Pterodactyl runs this script both when the server is created and when the
# customer hits "Reinstall". On creation /mnt/server is empty, so this only
# ever has an effect on a reinstall.
# ---------------------------------------------------------------------------
case "$(echo "${WIPE_ON_INSTALL:-1}" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|desactivado)
        echo "Reinstalacion sin borrado: se conservan los archivos existentes."

        if [ "${INSTALL_MODE}" = "preserve" ]; then
            echo "Limpiando solo el runtime anterior; mundos, plugins y configuraciones compartidas se conservan."

            # Old loader trees win over a newly downloaded plain jar in the
            # entrypoint detection order. Regenerating these files is required
            # for a real software switch, while user data lives elsewhere.
            rm -rf libraries versions .fabric .quilt .buildtools
            rm -f "${JARFILE}" server.jar fabric-server-launch.jar quilt-server-launch.jar
            rm -f forge-*.jar neoforge-*.jar unix_args.txt run.sh run.bat user_jvm_args.txt
            rm -f .multiversion-software .multiversion-version .multiversion-update .multiversion-optimized
            rm -f .hexminecraftversion-installed.json
            rm -f .hexminecraftmodpacks-installed.json

            # A modpack update must not leave removed mods beside the new pack.
            # Worlds, plugins and configuration files remain available in the
            # preserve mode, matching the behaviour of the reference installer.
            if [ "${MODPACK_REQUEST}" = "1" ]; then
                rm -rf mods coremods .fabric .quilt
            fi
        fi
        ;;
    *)
        if [ -n "$(ls -A /mnt/server 2>/dev/null)" ]; then
            echo "=================================================="
            echo " BORRANDO todos los archivos del servidor"
            echo " Esto incluye mundos, plugins y configuraciones."
            echo "=================================================="
            sleep 5

            # -mindepth 1 alcanza tambien los archivos ocultos. Un
            # 'rm -rf /mnt/server/*' no los toca, y las marcas del egg
            # (.multiversion-optimized, -software, -update) sobrevivirian a la
            # reinstalacion dejando al servidor nuevo con estado del anterior.
            find /mnt/server -mindepth 1 -maxdepth 1 -exec rm -rf {} +

            echo "Archivos eliminados. Empezando desde cero."
        fi
        ;;
esac

UA="pterodactyl-mc-multiversion/1.0 (+https://hexservers.com)"

# Two clients on purpose. Metadata calls must give up quickly: an upstream API
# that hangs would otherwise keep the whole install job blocked until Wings
# times it out, with nothing on screen to explain why. Jar downloads get a much
# longer budget because a modpack-sized artifact legitimately takes minutes.
fetch()      { curl -sSL --fail --connect-timeout 10 --max-time 900 --retry 3 --retry-delay 2 -A "${UA}" "$@"; }
fetch_meta() { curl -sSL --fail --connect-timeout 10 --max-time 30  --retry 2 --retry-delay 2 -A "${UA}" "$@"; }

# Serverpack providers do not all expose the Minecraft release in their
# catalogue. After extraction, recover it from well-known launcher manifests or
# loader paths so the Panel can select the right Java image before next start.
detect_modpack_minecraft_version() {
    OLD_IFS="${IFS}"
    IFS='
'
    for META_FILE in $(find . -maxdepth 4 -type f \( \
        -name 'modrinth.index.json' -o -name 'manifest.json' -o \
        -name 'minecraftinstance.json' -o -name 'instance.json' -o \
        -name 'mmc-pack.json' \) 2>/dev/null); do
        CANDIDATES=$(jq -r '
            [
                .dependencies.minecraft?,
                (.minecraft? | if type == "object" then .version? else empty end),
                .minecraftVersion?, .gameVersion?,
                (.components[]? | select(.uid == "net.minecraft") | .version?)
            ] | .[] | select(type == "string")
        ' "${META_FILE}" 2>/dev/null || true)
        for CANDIDATE in ${CANDIDATES}; do
            if printf '%s' "${CANDIDATE}" | grep -Eq '^(1\.[0-9]+(\.[0-9]+)?|[2-9][0-9]\.[0-9]+(\.[0-9]+)?)$'; then
                printf '%s\n' "${CANDIDATE}"
                IFS="${OLD_IFS}"
                return 0
            fi
        done
    done
    IFS="${OLD_IFS}"

    for LOADER_PATH in libraries/net/minecraftforge/forge/* libraries/net/fabricmc/intermediary/* libraries/net/minecraft/server/* versions/*/*.json; do
        [ -e "${LOADER_PATH}" ] || continue
        CANDIDATE=$(basename "${LOADER_PATH}" | grep -oE '^(1\.[0-9]+(\.[0-9]+)?)' | head -1 || true)
        if [ -n "${CANDIDATE}" ]; then
            printf '%s\n' "${CANDIDATE}"
            return 0
        fi
    done

    for LAUNCHER_FILE in minecraft_server.*.jar forge-*.jar neoforge-*.jar; do
        [ -e "${LAUNCHER_FILE}" ] || continue
        CANDIDATE=$(printf '%s' "${LAUNCHER_FILE}" | grep -oE '1\.[0-9]+(\.[0-9]+)?' | head -1 || true)
        if [ -n "${CANDIDATE}" ]; then
            printf '%s\n' "${CANDIDATE}"
            return 0
        fi
    done

    return 1
}

echo "=================================================="
echo " Software : ${SOFTWARE}"
echo " Version  : ${VERSION}"
echo " Archivo  : ${JARFILE}"
echo "=================================================="

if [ "${SOFTWARE}" = "none" ]; then
    if [ "${MODPACK_REQUEST}" = "1" ]; then
        MODPACK_URL="https://www.ric-rac.org/minecraft-modpack-server-installer/x86_64-unknown-linux-musl"
        case "$(uname -m)" in
            arm64|aarch64) MODPACK_URL="https://www.ric-rac.org/minecraft-modpack-server-installer/aarch64-unknown-linux-musl" ;;
        esac

        echo "Descargando instalador de modpacks (${MODPACK_PROVIDER})..."
        fetch -o /tmp/hex-minecraft-modpack-installer "${MODPACK_URL}"
        chmod +x /tmp/hex-minecraft-modpack-installer

        if ! /tmp/hex-minecraft-modpack-installer \
            --provider "${MODPACK_PROVIDER}" \
            --modpack-id "${MODPACK_ID}" \
            --modpack-version-id "${MODPACK_VERSION_ID}" \
            --directory /mnt/server; then
            rm -f /tmp/hex-minecraft-modpack-installer
            echo "ERROR: el instalador externo no pudo preparar el modpack." >&2
            exit 1
        fi

        rm -f /tmp/hex-minecraft-modpack-installer

        if [ "${MODPACK_MINECRAFT_VERSION}" = "modpack" ]; then
            DETECTED_MC_VERSION=$(detect_modpack_minecraft_version || true)
            if [ -n "${DETECTED_MC_VERSION}" ]; then
                MODPACK_MINECRAFT_VERSION="${DETECTED_MC_VERSION}"
                VERSION="${DETECTED_MC_VERSION}"
                echo "Version de Minecraft detectada en el serverpack: ${DETECTED_MC_VERSION}"
            else
                echo "AVISO: el serverpack no publica una version de Minecraft detectable; Java no se cambiara automaticamente." >&2
            fi
        fi

        # The downloaded pack can contain a launcher-specific server jar, an
        # args file, or a Fabric/Quilt launcher. The entrypoint detects the
        # resulting layout on the next boot, so no software marker is invented
        # from the catalogue provider.
        INSTALLED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
        jq -n \
            --arg provider "${MODPACK_PROVIDER}" \
            --arg modpack_id "${MODPACK_ID}" \
            --arg modpack_name "${MODPACK_NAME:-${MODPACK_ID}}" \
            --arg modpack_version_id "${MODPACK_VERSION_ID}" \
            --arg modpack_version_name "${MODPACK_VERSION_NAME:-${MODPACK_VERSION_ID}}" \
            --arg minecraft_version "${MODPACK_MINECRAFT_VERSION}" \
            --arg request_nonce "${MODPACK_NONCE}" \
            --arg installed_at "${INSTALLED_AT}" \
            '{protocol:2,provider:$provider,modpack_id:$modpack_id,modpack_name:$modpack_name,modpack_version_id:$modpack_version_id,modpack_version_name:$modpack_version_name,minecraft_version:$minecraft_version,request_nonce:$request_nonce,installed_at:$installed_at}' \
            > .hexminecraftmodpacks-installed.json

        case "$(echo "${EULA}" | tr '[:upper:]' '[:lower:]')" in
            false|0|no|desactivado)
                echo "Aceptacion automatica del EULA desactivada." ;;
            *)
                echo "eula=true" > eula.txt
                echo "EULA de Minecraft aceptado (https://aka.ms/MinecraftEULA)." ;;
        esac
        [ -f server.properties ] || touch server.properties
        echo "Instalacion del modpack completada. El egg detectara el loader al arrancar."
        exit 0
    fi

    echo "El software esta configurado como 'none'. No se descargara nada."
    echo "Usa tu modulo instalador para colocar los archivos del servidor."
    exit 0
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Turns an empty API response into a message the support team can act on.
# Without this the script dies on curl's own exit code and the console shows
# nothing but "installation failed".
require_data() {
    if [ -z "$1" ]; then
        echo "ERROR: $2" >&2
        echo "La API del proyecto no respondio. Reintenta en unos minutos; si sigue" >&2
        echo "fallando, elige otro software o instala una version concreta." >&2
        exit 1
    fi
}

# Checks a download against the hash the API published for it. A truncated jar
# otherwise fails much later as an unreadable Java error.
# No hash available means no check: not every project publishes one.
verify_sha() {
    FILE="$1"
    EXPECTED="$2"
    ALGO="${3:-sha256}"

    if [ -z "${EXPECTED}" ] || [ "${EXPECTED}" = "null" ]; then
        return 0
    fi

    case "${ALGO}" in
        sha1) ACTUAL=$(sha1sum "${FILE}" 2>/dev/null | awk '{print $1}') ;;
        md5)  ACTUAL=$(md5sum "${FILE}" 2>/dev/null | awk '{print $1}') ;;
        *)    ACTUAL=$(sha256sum "${FILE}" 2>/dev/null | awk '{print $1}') ;;
    esac

    if [ -z "${ACTUAL}" ]; then
        echo "Aviso: no se pudo calcular el hash, se omite la comprobacion."
        return 0
    fi

    if [ "${ACTUAL}" != "${EXPECTED}" ]; then
        echo "ERROR: la descarga esta corrupta, el hash no coincide con el publicado." >&2
        rm -f "${FILE}"
        exit 1
    fi

    echo "Integridad de la descarga verificada (${ALGO})."
}

# Java feature version needed to run a project's installer. For Forge, NeoForge
# and Quilt this is looser than what the finished server needs, since their
# installer is an ordinary Java program and runs fine on a newer JVM. For Spigot
# it is strict: BuildTools actually compiles the server, so the JDK has to be at
# least what that Minecraft version targets.
installer_java_for() {
    case "$1" in
        # "latest" resolves to whatever is newest, so assume the newest
        # requirement. ensure_java falls back downwards if it is unavailable.
        latest|"")           echo 25 ;;
        1.8*|1.9*|1.1[0-6]*) echo 8 ;;
        1.17*)               echo 17 ;;
        1.18*|1.19*)         echo 17 ;;
        1.20|1.20.[0-4]*)    echo 17 ;;
        1.20*|1.21*)         echo 21 ;;
        2[0-5].*)            echo 21 ;;
        26.*|2[7-9].*)       echo 25 ;;
        *)                   echo 21 ;;
    esac
}

# Forge, NeoForge, Quilt and Spigot all ship an installer that has to be
# executed, and the Pterodactyl installer image has no JVM at all. Only those
# four pay this cost; every other software is a plain download.
#
#   ensure_java <feature version> [jre|jdk]
#
# BuildTools compiles source, so it needs a JDK; the rest only need a runtime.
ensure_java() {
    NEED="$1"
    KIND="${2:-jre}"

    # A JRE already present does not satisfy a JDK request, so check for the
    # compiler rather than just the launcher when one is asked for.
    if [ "${KIND}" = "jdk" ]; then
        command -v javac >/dev/null 2>&1 && return 0
    else
        command -v java >/dev/null 2>&1 && return 0
    fi

    if ! command -v apk >/dev/null 2>&1; then
        echo "ERROR: ${SOFTWARE} necesita Java para ejecutar su instalador, y este" >&2
        echo "contenedor de instalacion no lo trae ni permite instalarlo." >&2
        exit 1
    fi

    # Requested version first, then downwards. Alpine does not carry every JDK
    # on every release, and an installer usually tolerates a nearby version.
    if [ "${KIND}" = "jdk" ]; then
        case "${NEED}" in
            8)     CANDIDATES="openjdk8 openjdk11-jdk openjdk17-jdk" ;;
            16|17) CANDIDATES="openjdk17-jdk openjdk21-jdk openjdk11-jdk" ;;
            21)    CANDIDATES="openjdk21-jdk openjdk17-jdk openjdk25-jdk" ;;
            *)     CANDIDATES="openjdk25-jdk openjdk21-jdk openjdk17-jdk" ;;
        esac
    else
        case "${NEED}" in
            8)     CANDIDATES="openjdk8-jre openjdk11-jre-headless openjdk17-jre-headless" ;;
            16|17) CANDIDATES="openjdk17-jre-headless openjdk21-jre-headless openjdk11-jre-headless" ;;
            21)    CANDIDATES="openjdk21-jre-headless openjdk17-jre-headless openjdk25-jre-headless" ;;
            *)     CANDIDATES="openjdk25-jre-headless openjdk21-jre-headless openjdk17-jre-headless" ;;
        esac
    fi

    echo "Instalando temporalmente Java (${KIND}) para el instalador de ${SOFTWARE}..."
    for PKG in ${CANDIDATES}; do
        if apk add --no-cache "${PKG}" >/dev/null 2>&1; then
            echo "Java disponible: $(java -version 2>&1 | head -1)"
            return 0
        fi
    done

    echo "ERROR: no se pudo instalar ningun Java (${KIND}) para el instalador." >&2
    echo "Probados: ${CANDIDATES}" >&2
    exit 1
}

# Runs a modloader installer and leaves the server in a state the entrypoint
# can detect on its own.
run_modloader_installer() {
    INSTALLER_JAR="$1"
    shift

    echo "Ejecutando el instalador de ${SOFTWARE}. Esto puede tardar varios minutos."
    if ! java -jar "${INSTALLER_JAR}" "$@"; then
        echo "ERROR: el instalador de ${SOFTWARE} termino con error." >&2
        exit 1
    fi

    rm -f "${INSTALLER_JAR}" "${INSTALLER_JAR}.log" installer.log

    # Forge and NeoForge from 1.17 onwards start from an args file that carries
    # the whole classpath. The entrypoint finds it by itself, so there is
    # nothing left to arrange here.
    if find libraries -name unix_args.txt 2>/dev/null | grep -q .; then
        echo "Instalacion completada. El servidor arranca desde su archivo de argumentos."
        return 0
    fi

    # Older Forge leaves a single runnable jar under a name that changes with
    # every build. Renaming it to the configured jar keeps the panel's "Archivo
    # JAR del servidor" option meaningful.
    for CAND in forge-*-universal.jar forge-*-shim.jar forge-*.jar; do
        if [ -f "${CAND}" ] && [ "${CAND}" != "${JARFILE}" ]; then
            mv "${CAND}" "${JARFILE}"
            echo "Instalacion completada. Servidor listo en ${JARFILE}."
            return 0
        fi
    done

    echo "Aviso: el instalador no dejo ni archivo de argumentos ni un jar reconocible."
    echo "Revisa la consola de instalacion antes de arrancar el servidor."
}

# --- PaperMC family (paper, folia, velocity, waterfall) --------------------
# api.papermc.io/v2 was shut down on 2026-07-01; everything goes through the
# Fill v3 API, which rejects requests without a descriptive User-Agent.
install_paper_family() {
    PROJECT="$1"

    # Released versions are preferred over in-development ones: Velocity's
    # newest entry is a -SNAPSHOT branch, and "latest" should not land there.
    # Filtering by build channel does not help, since snapshot versions still
    # publish their builds under the STABLE channel.
    if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
        VERSION=$(fetch_meta "https://fill.papermc.io/v3/projects/${PROJECT}" | jq -r '
            [ .versions | to_entries[] | .value[] ] as $all
            | ( [ $all[] | select(test("-(SNAPSHOT|rc|pre)") | not) ][0] // $all[0] // empty )')
        require_data "${VERSION}" "no se pudo determinar una version para ${PROJECT}."
        echo "Ultima version de ${PROJECT}: ${VERSION}"
    fi

    # One request for both the URL and the hash that validates it.
    BUILD_JSON=$(fetch_meta "https://fill.papermc.io/v3/projects/${PROJECT}/versions/${VERSION}/builds" \
        | jq -r --arg ch "${CHANNEL}" '
            ( [ .[] | select(.channel == $ch) ][0] // .[0] ) as $b
            | if $b == null then empty
              else "\($b.downloads["server:default"].url) \($b.downloads["server:default"].checksums.sha256 // "")"
              end')

    require_data "${BUILD_JSON}" "no se encontraron builds para ${PROJECT} ${VERSION}."

    URL=$(echo "${BUILD_JSON}" | cut -d' ' -f1)
    SHA=$(echo "${BUILD_JSON}" | cut -d' ' -f2)

    echo "Descargando ${URL}"
    fetch -o "${JARFILE}" "${URL}"
    verify_sha "${JARFILE}" "${SHA}" sha256
}

# --- Purpur ----------------------------------------------------------------
install_purpur() {
    if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
        VERSION=$(fetch_meta "https://api.purpurmc.org/v2/purpur" | jq -r '.metadata.current // .versions[-1] // empty')
        require_data "${VERSION}" "no se pudo determinar la ultima version de Purpur."
        echo "Ultima version de Purpur: ${VERSION}"
    fi

    # Validated up front so a mistyped version gives a readable message instead
    # of a bare curl 404 from the download step.
    BUILD=$(fetch_meta "https://api.purpurmc.org/v2/purpur/${VERSION}" 2>/dev/null | jq -r '.builds.latest // empty')
    require_data "${BUILD}" "Purpur no publica builds para la version ${VERSION}."

    # Purpur publishes md5 rather than a sha.
    SHA=$(fetch_meta "https://api.purpurmc.org/v2/purpur/${VERSION}/${BUILD}" 2>/dev/null | jq -r '.md5 // empty')

    echo "Descargando Purpur ${VERSION} build ${BUILD}"
    fetch -o "${JARFILE}" "https://api.purpurmc.org/v2/purpur/${VERSION}/${BUILD}/download"
    verify_sha "${JARFILE}" "${SHA}" md5
}

# --- Spigot ----------------------------------------------------------------
# The only software here with no published binary: Spigot cannot be
# redistributed, so BuildTools has to compile it from source on the spot.
# That makes it by far the slowest and most fragile path in this script.
install_spigot() {
    # BuildTools compiles, so it needs a full JDK, not just a runtime, and git
    # to clone the upstream repositories.
    ensure_java "$(installer_java_for "${VERSION}")" jdk

    if ! command -v git >/dev/null 2>&1; then
        echo "ERROR: BuildTools necesita git y este contenedor no lo tiene." >&2
        exit 1
    fi
    # BuildTools aborts on a repository it considers dirty unless identity is set.
    git config --global --add safe.directory '*' 2>/dev/null || true
    git config --global user.email "installer@localhost" 2>/dev/null || true
    git config --global user.name "Pterodactyl Installer" 2>/dev/null || true

    REV="${VERSION}"
    [ -z "${REV}" ] && REV="latest"

    echo "=================================================="
    echo " Compilando Spigot ${REV} con BuildTools."
    echo " Esto tarda entre 10 y 20 minutos y necesita ~2 GB"
    echo " de RAM. No reinstales a mitad del proceso."
    echo "=================================================="

    # Built in its own directory: BuildTools leaves several gigabytes of clones
    # and Maven artifacts behind, and dropping those straight into the server
    # folder would eat the customer's disk quota for nothing.
    BUILD_DIR="/mnt/server/.buildtools"
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"
    cd "${BUILD_DIR}"

    fetch -o BuildTools.jar \
        "https://hub.spigotmc.org/jenkins/job/BuildTools/lastSuccessfulBuild/artifact/target/BuildTools.jar"

    if ! java -jar BuildTools.jar --rev "${REV}" --compile spigot; then
        cd /mnt/server
        rm -rf "${BUILD_DIR}"
        echo "ERROR: BuildTools no pudo compilar Spigot ${REV}." >&2
        echo "Causas habituales: version inexistente, poca RAM en el nodo, o" >&2
        echo "que la version pedida necesite otra version de Java." >&2
        exit 1
    fi

    # BuildTools names the result spigot-<version>.jar.
    RESULT=$(find . -maxdepth 1 -name 'spigot-*.jar' | head -1)
    if [ -z "${RESULT}" ]; then
        cd /mnt/server
        rm -rf "${BUILD_DIR}"
        echo "ERROR: BuildTools termino pero no dejo ningun spigot-*.jar." >&2
        exit 1
    fi

    mv "${RESULT}" "/mnt/server/${JARFILE}"
    cd /mnt/server
    rm -rf "${BUILD_DIR}"
    echo "Spigot compilado correctamente."
}

# --- Vanilla ---------------------------------------------------------------
install_vanilla() {
    MANIFEST="https://launchermeta.mojang.com/mc/game/version_manifest.json"

    # Fetched once and reused: three separate calls for the same file only
    # multiplied the chances of one of them failing.
    MANIFEST_JSON=$(fetch_meta "${MANIFEST}")
    require_data "${MANIFEST_JSON}" "no se pudo contactar con el servidor de Mojang."

    if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
        VERSION=$(echo "${MANIFEST_JSON}" | jq -r '.latest.release')
    elif [ "${VERSION}" = "snapshot" ]; then
        VERSION=$(echo "${MANIFEST_JSON}" | jq -r '.latest.snapshot')
    fi
    echo "Version de Vanilla: ${VERSION}"

    VERSION_URL=$(echo "${MANIFEST_JSON}" | jq -r --arg v "${VERSION}" '.versions[] | select(.id == $v) | .url')
    require_data "${VERSION_URL}" "no existe la version de Vanilla ${VERSION}."

    META=$(fetch_meta "${VERSION_URL}")
    DOWNLOAD_URL=$(echo "${META}" | jq -r '.downloads.server.url // empty')
    # Mojang publishes sha1 rather than sha256.
    SHA=$(echo "${META}" | jq -r '.downloads.server.sha1 // empty')
    require_data "${DOWNLOAD_URL}" "Vanilla ${VERSION} no publica archivo de servidor."

    echo "Descargando ${DOWNLOAD_URL}"
    fetch -o "${JARFILE}" "${DOWNLOAD_URL}"
    verify_sha "${JARFILE}" "${SHA}" sha1
}

# --- Fabric ----------------------------------------------------------------
# Fabric publishes a ready-made launcher jar, so no installer run is needed.
install_fabric() {
    if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
        VERSION=$(fetch_meta "https://meta.fabricmc.net/v2/versions/game" | jq -r '[.[] | select(.stable == true)][0].version // empty')
        require_data "${VERSION}" "no se pudo determinar la ultima version de Fabric."
    fi
    LOADER=$(fetch_meta "https://meta.fabricmc.net/v2/versions/loader" | jq -r '[.[] | select(.stable == true)][0].version // empty')
    INSTALLER=$(fetch_meta "https://meta.fabricmc.net/v2/versions/installer" | jq -r '[.[] | select(.stable == true)][0].version // empty')
    require_data "${LOADER}" "no se pudo determinar el loader de Fabric."
    require_data "${INSTALLER}" "no se pudo determinar el instalador de Fabric."

    echo "Fabric: juego ${VERSION}, loader ${LOADER}, instalador ${INSTALLER}"
    fetch -o "${JARFILE}" \
        "https://meta.fabricmc.net/v2/versions/loader/${VERSION}/${LOADER}/${INSTALLER}/server/jar"
}

# --- Quilt -----------------------------------------------------------------
# Unlike Fabric, Quilt publishes no ready-made server jar: its installer has to
# be run, and it produces quilt-server-launch.jar, which the entrypoint detects.
install_quilt() {
    ensure_java 17

    if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
        # Quilt tracks Minecraft's own versions, and Fabric's meta is the
        # simplest source for "newest stable Minecraft".
        VERSION=$(fetch_meta "https://meta.fabricmc.net/v2/versions/game" | jq -r '[.[] | select(.stable == true)][0].version // empty')
        require_data "${VERSION}" "no se pudo determinar la ultima version de Minecraft para Quilt."
    fi

    # One request, both fields: the URL and the hash that validates it.
    IMETA=$(fetch_meta "https://meta.quiltmc.org/v3/versions/installer")
    IURL=$(echo "${IMETA}" | jq -r '.[0].url // empty')
    ISHA=$(echo "${IMETA}" | jq -r '.[0].hashes.sha1 // empty')
    require_data "${IURL}" "no se pudo determinar el instalador de Quilt."

    echo "Descargando el instalador de Quilt"
    fetch -o quilt-installer.jar "${IURL}"
    verify_sha quilt-installer.jar "${ISHA}" sha1

    echo "Instalando Quilt para Minecraft ${VERSION}. Esto puede tardar varios minutos."
    if ! java -jar quilt-installer.jar install server "${VERSION}" --download-server --install-dir=.; then
        echo "ERROR: el instalador de Quilt termino con error." >&2
        exit 1
    fi
    rm -f quilt-installer.jar

    if [ ! -f quilt-server-launch.jar ]; then
        echo "ERROR: el instalador no genero quilt-server-launch.jar." >&2
        exit 1
    fi
    echo "Instalacion completada. El servidor arranca desde quilt-server-launch.jar."
}

# --- Forge -----------------------------------------------------------------
# promotions_slim.json maps "<mc>-latest" / "<mc>-recommended" to a build
# number; the full version string is "<mc>-<build>".
install_forge() {
    ensure_java "$(installer_java_for "${VERSION}")"

    PROMOS=$(fetch_meta "https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json")
    require_data "${PROMOS}" "no se pudo consultar las versiones de Forge."

    if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
        # The file lists promotions oldest first, so the last "-latest" entry is
        # the newest Minecraft version Forge supports.
        FULL=$(echo "${PROMOS}" | jq -r '
            .promos | to_entries
            | [ .[] | select(.key | endswith("-latest")) ] | last
            | if . == null then empty else "\(.key | sub("-latest$";""))-\(.value)" end')
        require_data "${FULL}" "no se pudo determinar la ultima version de Forge."
    else
        # Recommended is preferred: it is the build Forge itself considers safe.
        BUILD=$(echo "${PROMOS}" | jq -r --arg v "${VERSION}" \
            '.promos["\($v)-recommended"] // .promos["\($v)-latest"] // empty')
        if [ -z "${BUILD}" ]; then
            echo "ERROR: Forge no publica builds para Minecraft ${VERSION}." >&2
            echo "Versiones disponibles:" >&2
            echo "${PROMOS}" | jq -r '.promos | keys[] | select(endswith("-latest")) | sub("-latest$";"")' \
                | tail -25 | tr '\n' ' ' >&2
            echo >&2
            exit 1
        fi
        FULL="${VERSION}-${BUILD}"
    fi

    echo "Instalando Forge ${FULL}"
    fetch -o forge-installer.jar \
        "https://maven.minecraftforge.net/net/minecraftforge/forge/${FULL}/forge-${FULL}-installer.jar"
    run_modloader_installer forge-installer.jar --installServer
}

# --- NeoForge --------------------------------------------------------------
# NeoForge versions drop Minecraft's leading "1.": Minecraft 1.21.1 is served by
# NeoForge 21.1.x. Calendar-versioned Minecraft keeps its own number instead.
neoforge_prefix() {
    echo "$1" | awk -F. '
        $1 == 1 && NF >= 3 { printf "%s.%s.", $2, $3; exit }
        $1 == 1 && NF == 2 { printf "%s.0.", $2; exit }
        NF == 2            { printf "%s.%s.0.", $1, $2; exit }
                           { printf "%s.", $0 }'
}

# Highest version from a list of dotted numeric versions, read on stdin.
#
# Builds a zero-padded sort key rather than relying on `sort -t. -k1,1n ...`:
# BusyBox's sort does not have to support per-key numeric modifiers, and if it
# quietly falls back to a lexical compare it picks 21.1.9 over 21.1.248 without
# any error to notice. Plain lexical sort over a padded key is correct
# everywhere.
neoforge_highest() {
    awk -F. '{ printf "%05d%05d%05d%05d %s\n", $1, $2, $3, $4, $0 }' \
        | sort | tail -1 | cut -d' ' -f2
}

install_neoforge() {
    ensure_java "$(installer_java_for "${VERSION}")"

    XML=$(fetch_meta "https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml")
    require_data "${XML}" "no se pudo consultar las versiones de NeoForge."

    ALL=$(echo "${XML}" | grep -oE '<version>[^<]+</version>' | sed -e 's|<version>||' -e 's|</version>||')
    require_data "${ALL}" "la lista de versiones de NeoForge llego vacia."

    if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
        NEO=$(echo "${ALL}" | grep -v -- '-beta' | neoforge_highest)
    else
        PREFIX=$(neoforge_prefix "${VERSION}")
        # awk index() instead of grep: the prefix is a literal whose dots must
        # not act as regex wildcards. Escaping them for grep works, but "21.1."
        # as a regex silently also matches 21.11.x, and that mistake picks a
        # build for a completely different Minecraft version.
        MATCHES=$(echo "${ALL}" | awk -v p="${PREFIX}" 'index($0, p) == 1')

        NEO=""
        if [ -n "${MATCHES}" ]; then
            NEO=$(echo "${MATCHES}" | grep -v -- '-beta' | neoforge_highest)
            # Nothing stable yet for that Minecraft version: a beta is better
            # than failing, and NeoForge ships betas for months before promoting
            # them.
            if [ -z "${NEO}" ]; then
                NEO=$(echo "${MATCHES}" | neoforge_highest)
            fi
        fi
        # Also accept a NeoForge version typed directly instead of a Minecraft one.
        if [ -z "${NEO}" ]; then
            NEO=$(echo "${ALL}" | grep -x -- "${VERSION}" || true)
        fi
        if [ -z "${NEO}" ]; then
            echo "ERROR: NeoForge no publica builds para Minecraft ${VERSION}." >&2
            echo "NeoForge solo existe desde Minecraft 1.20.2." >&2
            echo "Ultimas versiones disponibles:" >&2
            echo "${ALL}" | grep -v -- '-beta' | awk -F. '{ printf "%05d%05d%05d%05d %s\n", $1, $2, $3, $4, $0 }' \
                | sort | tail -10 | cut -d' ' -f2 | tr '\n' ' ' >&2
            echo >&2
            exit 1
        fi
    fi

    echo "Instalando NeoForge ${NEO}"
    fetch -o neoforge-installer.jar \
        "https://maven.neoforged.net/releases/net/neoforged/neoforge/${NEO}/neoforge-${NEO}-installer.jar"
    run_modloader_installer neoforge-installer.jar --installServer
}

# --- BungeeCord ------------------------------------------------------------
# Published as a single jar on md-5's Jenkins; no versions to pick from.
install_bungeecord() {
    echo "Descargando BungeeCord (ultimo build estable)"
    fetch -o "${JARFILE}" "https://ci.md-5.net/job/BungeeCord/lastSuccessfulBuild/artifact/bootstrap/target/BungeeCord.jar"
}

# --- GitHub releases helpers -----------------------------------------------
# Shared by Arclight, Gale and NanoLimbo. GitHub allows 60 unauthenticated
# requests per hour PER IP, and a whole node shares that IP, so every one of
# these projects is fetched exactly once per install and reused.
github_releases() {
    RELEASES=$(fetch_meta "https://api.github.com/repos/$1/releases?per_page=100" 2>/dev/null || true)

    if [ -z "${RELEASES}" ] || [ "$(echo "${RELEASES}" | jq -r 'type' 2>/dev/null)" != "array" ]; then
        echo "ERROR: no se pudo consultar las versiones de ${SOFTWARE} en GitHub." >&2
        echo "Causa habitual: el nodo agoto el limite de 60 consultas por hora que" >&2
        echo "GitHub aplica por IP. Reintenta en unos minutos." >&2
        exit 1
    fi
}

# Prints "<url> <sha256>" for the newest asset whose name starts with $1.
# Releases come newest first, so the first match is the newest build.
# GitHub publishes the digest as "sha256:<hex>", hence the prefix strip.
github_asset() {
    echo "${RELEASES}" | jq -r --arg p "$1" '
        [ .[].assets[] | select(.name | startswith($p)) ][0]
        | if . == null then empty
          else "\(.browser_download_url) \((.digest // "") | sub("^sha256:";""))" end'
}

# --- Leaf ------------------------------------------------------------------
# Paper fork with its own API, shaped like PaperMC's v2. Being self-hosted, it
# does not eat into the GitHub rate limit.
install_leaf() {
    if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
        VERSION=$(fetch_meta "https://api.leafmc.one/v2/projects/leaf" | jq -r '.versions[-1] // empty')
        require_data "${VERSION}" "no se pudo determinar la ultima version de Leaf."
        echo "Ultima version de Leaf: ${VERSION}"
    fi

    BUILD=$(fetch_meta "https://api.leafmc.one/v2/projects/leaf/versions/${VERSION}" | jq -r '.builds[-1] // empty')
    require_data "${BUILD}" "Leaf no publica builds para la version ${VERSION}."

    # One request, both fields: the file name for the URL and its hash.
    META=$(fetch_meta "https://api.leafmc.one/v2/projects/leaf/versions/${VERSION}/builds/${BUILD}")
    NAME=$(echo "${META}" | jq -r '.downloads.primary.name // empty')
    SHA=$(echo "${META}" | jq -r '.downloads.primary.sha256 // empty')
    require_data "${NAME}" "no se pudo resolver la descarga de Leaf ${VERSION}."

    echo "Descargando Leaf ${VERSION} build ${BUILD}"
    fetch -o "${JARFILE}" \
        "https://api.leafmc.one/v2/projects/leaf/versions/${VERSION}/builds/${BUILD}/downloads/${NAME}"
    verify_sha "${JARFILE}" "${SHA}" sha256
}

# --- Gale ------------------------------------------------------------------
# Paper fork published as GitHub release assets named gale-<mcversion>-R<x>.jar.
install_gale() {
    github_releases "GaleMC/Gale"

    if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
        RESULT=$(github_asset "gale-")
    else
        RESULT=$(github_asset "gale-${VERSION}-")
    fi

    if [ -z "${RESULT}" ]; then
        echo "ERROR: Gale no publica builds para Minecraft ${VERSION}." >&2
        echo "Versiones disponibles:" >&2
        echo "${RELEASES}" | jq -r '[ .[].assets[].name | select(startswith("gale-")) ] | unique | .[]' >&2
        exit 1
    fi

    URL=$(echo "${RESULT}" | cut -d' ' -f1)
    SHA=$(echo "${RESULT}" | cut -d' ' -f2)

    echo "Descargando ${URL}"
    fetch -o "${JARFILE}" "${URL}"
    verify_sha "${JARFILE}" "${SHA}" sha256
}

# --- NanoLimbo -------------------------------------------------------------
# Minimal limbo server: holds players in a waiting room while the real server
# restarts. Not a Minecraft server in the usual sense, so it has no EULA and no
# server.properties; the entrypoint knows this from the marker written below.
install_nanolimbo() {
    github_releases "Nan1t/NanoLimbo"

    RESULT=$(github_asset "NanoLimbo")
    if [ -z "${RESULT}" ]; then
        echo "ERROR: no se encontro ningun jar publicado de NanoLimbo." >&2
        exit 1
    fi

    URL=$(echo "${RESULT}" | cut -d' ' -f1)
    SHA=$(echo "${RESULT}" | cut -d' ' -f2)

    echo "Descargando ${URL}"
    fetch -o "${JARFILE}" "${URL}"
    verify_sha "${JARFILE}" "${SHA}" sha256
    echo "NanoLimbo se configura en settings.yml, no en server.properties."
}

# --- Sponge (SpongeVanilla) ------------------------------------------------
# A different plugin platform, not compatible with Bukkit/Spigot plugins.
# Versions are named "<minecraft>-<api>-RC<n>", so the Minecraft version has to
# be read from tagValues rather than parsed out of the version string.
install_sponge() {
    API="https://dl-api.spongepowered.org/v2/groups/org.spongepowered/artifacts/spongevanilla"

    LIST=$(fetch_meta "${API}/versions?offset=0&limit=100")
    require_data "${LIST}" "no se pudo consultar las versiones de Sponge."

    if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
        # Snapshots of unreleased Minecraft versions are skipped, and a build
        # Sponge itself marks as recommended wins over a plain newest.
        SPONGE_VER=$(echo "${LIST}" | jq -r '
            [ .artifacts | to_entries[]
              | select(.value.tagValues.minecraft | test("snapshot") | not) ] as $stable
            | ( [ $stable[] | select(.value.recommended) ][0] // $stable[0] // empty )
            | .key // empty')
        require_data "${SPONGE_VER}" "no se pudo determinar la ultima version de Sponge."
    else
        SPONGE_VER=$(echo "${LIST}" | jq -r --arg v "${VERSION}" '
            [ .artifacts | to_entries[]
              | select(.value.tagValues.minecraft == $v) ][0].key // empty')
        if [ -z "${SPONGE_VER}" ]; then
            echo "ERROR: Sponge no publica builds para Minecraft ${VERSION}." >&2
            echo "Versiones de Minecraft disponibles:" >&2
            echo "${LIST}" | jq -r '[ .artifacts[].tagValues.minecraft ] | unique | .[]' | tr '\n' ' ' >&2
            echo >&2
            exit 1
        fi
    fi

    echo "Version de Sponge: ${SPONGE_VER}"

    # The "universal" classifier is the runnable server jar; the rest are
    # sources and internal modules.
    DETAIL=$(fetch_meta "${API}/versions/${SPONGE_VER}")
    RESULT=$(echo "${DETAIL}" | jq -r '
        [ .assets[] | select(.classifier == "universal" and .extension == "jar") ][0]
        | if . == null then empty else "\(.downloadUrl) \(.sha1 // "")" end')
    require_data "${RESULT}" "Sponge ${SPONGE_VER} no publica un jar ejecutable."

    URL=$(echo "${RESULT}" | cut -d' ' -f1)
    SHA=$(echo "${RESULT}" | cut -d' ' -f2)

    echo "Descargando ${URL}"
    fetch -o "${JARFILE}" "${URL}"
    verify_sha "${JARFILE}" "${SHA}" sha1
}

# --- Pufferfish ------------------------------------------------------------
# Published on Jenkins, one job per Minecraft minor (Pufferfish-1.21, ...).
install_pufferfish() {
    if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
        # Pufferfish-Purpur-* jobs also live here and must not be picked up,
        # hence the digit right after the dash.
        JOB=$(fetch_meta "https://ci.pufferfish.host/api/json?tree=jobs%5Bname%5D" \
            | jq -r '[.jobs[].name | select(test("^Pufferfish-[0-9]"))] | sort_by(split("-")[1] | split(".") | map(tonumber)) | last // empty')
        require_data "${JOB}" "no se pudo determinar la ultima version de Pufferfish."
    else
        # 1.21.4 lives in the Pufferfish-1.21 job.
        JOB="Pufferfish-$(echo "${VERSION}" | cut -d. -f1,2)"
    fi
    echo "Job de Pufferfish: ${JOB}"

    ART=$(fetch_meta "https://ci.pufferfish.host/job/${JOB}/lastSuccessfulBuild/api/json?tree=artifacts%5BrelativePath%5D" 2>/dev/null \
        | jq -r '.artifacts[0].relativePath // empty')
    if [ -z "${ART}" ]; then
        echo "ERROR: Pufferfish no tiene builds para ${VERSION}." >&2
        echo "Pufferfish solo publica algunas versiones de Minecraft; prueba con 'latest'." >&2
        exit 1
    fi

    echo "Descargando ${ART}"
    fetch -o "${JARFILE}" "https://ci.pufferfish.host/job/${JOB}/lastSuccessfulBuild/artifact/${ART}"
}

# --- Mohist ----------------------------------------------------------------
# Hybrid: runs Forge mods and Bukkit plugins at the same time.
# Prints "<url> <sha256>" for the newest build of a Minecraft version.
mohist_build_url() {
    fetch_meta "https://mohistmc.com/api/v2/projects/mohist/$1/builds" 2>/dev/null \
        | jq -r '.builds[-1] // empty | if . == null or . == "" then empty
                 else "\(.originUrl) \(.fileSha256 // "")" end'
}

install_mohist() {
    if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
        # Mohist lists versions that have no builds yet (1.21.4 at time of
        # writing), so walk backwards until one actually has a download.
        VERSIONS=$(fetch_meta "https://mohistmc.com/api/v2/projects/mohist" | jq -r '.versions | reverse | .[]')
        require_data "${VERSIONS}" "no se pudo consultar las versiones de Mohist."

        for CANDIDATE in ${VERSIONS}; do
            RESULT=$(mohist_build_url "${CANDIDATE}")
            if [ -n "${RESULT}" ]; then
                VERSION="${CANDIDATE}"
                break
            fi
            echo "Mohist ${CANDIDATE} aun no tiene builds, probando la anterior..."
        done
        echo "Ultima version de Mohist con builds: ${VERSION}"
    else
        RESULT=$(mohist_build_url "${VERSION}")
    fi

    if [ -z "${RESULT}" ]; then
        echo "ERROR: no hay builds de Mohist para ${VERSION}." >&2
        exit 1
    fi

    URL=$(echo "${RESULT}" | cut -d' ' -f1)
    SHA=$(echo "${RESULT}" | cut -d' ' -f2)

    echo "Descargando Mohist ${VERSION}"
    fetch -o "${JARFILE}" "${URL}"
    verify_sha "${JARFILE}" "${SHA}" sha256
}

# --- Arclight --------------------------------------------------------------
# Also hybrid. Published as GitHub release assets named
# arclight-<loader>-<mcversion>-<build>.jar, spread across several releases,
# so the right release has to be searched for by asset name.
install_arclight() {
    LOADER=$(echo "${ARCLIGHT_LOADER:-forge}" | tr '[:upper:]' '[:lower:]')

    github_releases "IzzelAliz/Arclight"

    if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
        RESULT=$(github_asset "arclight-${LOADER}-")
    else
        RESULT=$(github_asset "arclight-${LOADER}-${VERSION}-")
    fi

    URL=$(echo "${RESULT}" | cut -d' ' -f1)
    SHA=$(echo "${RESULT}" | cut -d' ' -f2)

    if [ -z "${URL}" ]; then
        echo "ERROR: no se encontro Arclight para ${LOADER} ${VERSION}." >&2
        echo "Versiones disponibles:" >&2
        echo "${RELEASES}" | jq -r --arg l "${LOADER}" \
            '[.[].assets[].name | select(startswith("arclight-" + $l + "-"))] | unique | .[]' >&2
        exit 1
    fi

    echo "Descargando ${URL}"
    fetch -o "${JARFILE}" "${URL}"
    verify_sha "${JARFILE}" "${SHA}" sha256
}

case "${SOFTWARE}" in
    paper|folia|velocity|waterfall) install_paper_family "${SOFTWARE}" ;;
    purpur)                         install_purpur ;;
    leaf)                           install_leaf ;;
    gale)                           install_gale ;;
    spigot)                         install_spigot ;;
    sponge)                         install_sponge ;;
    nanolimbo)                      install_nanolimbo ;;
    vanilla)                        install_vanilla ;;
    fabric)                         install_fabric ;;
    quilt)                          install_quilt ;;
    forge)                          install_forge ;;
    neoforge)                       install_neoforge ;;
    bungeecord)                     install_bungeecord ;;
    pufferfish)                     install_pufferfish ;;
    mohist)                         install_mohist ;;
    arclight)                       install_arclight ;;
    *)
        echo "ERROR: software desconocido '${SOFTWARE}'." >&2
        echo "Valores validos: paper, folia, purpur, pufferfish, leaf, gale," >&2
        echo "                 spigot, vanilla, sponge, fabric, quilt, forge," >&2
        echo "                 neoforge, mohist, arclight, velocity, waterfall," >&2
        echo "                 bungeecord, nanolimbo, none" >&2
        exit 1
        ;;
esac

# Forge, NeoForge and Quilt start from files the installer generated, not from a
# jar this script placed, so the size check below does not apply to them.
case "${SOFTWARE}" in
    forge|neoforge|quilt) ;;
    *)
        if [ ! -s "${JARFILE}" ]; then
            echo "ERROR: ${JARFILE} no existe o quedo vacio tras la descarga." >&2
            exit 1
        fi
        echo "Se descargaron $(du -h "${JARFILE}" | cut -f1) en ${JARFILE}"
        ;;
esac

# Hint for the entrypoint. Mohist and Arclight cannot be told apart from Forge
# until they have booted once and written their own config files, so record
# what was installed. Detection based on real files always wins over this, so a
# later software swap by an external installer module is not misread.
echo "${SOFTWARE}" > .multiversion-software
echo "${VERSION}" > .multiversion-version

# Machine-readable state for Hex Minecraft Versions. SOFTWARE and VERSION are
# allowlisted above, so neither can break the JSON string.
INSTALLED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
printf '{"protocol":1,"software":"%s","release":"%s","installed_at":"%s"}\n' \
    "${SOFTWARE}" "${VERSION}" "${INSTALLED_AT}" > .hexminecraftversion-installed.json

# Proxies have no EULA and no server.properties, and neither does NanoLimbo:
# it never runs Minecraft itself, it only speaks the protocol.
case "${SOFTWARE}" in
    velocity|waterfall|bungeecord|nanolimbo) ;;
    *)
        # Unset counts as accepted, matching the entrypoint. Only an explicit
        # false/0 opts out.
        case "$(echo "${EULA}" | tr '[:upper:]' '[:lower:]')" in
            false|0|no|desactivado)
                echo "Aceptacion automatica del EULA desactivada."
                ;;
            *)
                echo "eula=true" > eula.txt
                echo "EULA de Minecraft aceptado (https://aka.ms/MinecraftEULA)."
                ;;
        esac
        [ -f server.properties ] || touch server.properties
        ;;
esac

echo "Instalacion completada."
