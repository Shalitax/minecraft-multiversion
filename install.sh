#!/bin/ash
#
# Install script for the Minecraft Multiversion egg.
# Runs in ghcr.io/pterodactyl/installers:alpine. Server files go to /mnt/server.
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

UA="pterodactyl-mc-multiversion/1.0 (+https://hexservers.com)"
fetch() { curl -sSL --fail --retry 3 --retry-delay 2 -A "${UA}" "$@"; }

SOFTWARE=$(echo "${SERVER_SOFTWARE:-paper}" | tr '[:upper:]' '[:lower:]')
VERSION="${SERVER_VERSION:-latest}"
CHANNEL="${UPDATE_CHANNEL:-STABLE}"
JARFILE="${SERVER_JARFILE:-server.jar}"

echo "=================================================="
echo " Software : ${SOFTWARE}"
echo " Version  : ${VERSION}"
echo " Archivo  : ${JARFILE}"
echo "=================================================="

if [ "${SOFTWARE}" = "none" ]; then
    echo "El software esta configurado como 'none'. No se descargara nada."
    echo "Usa tu modulo instalador para colocar los archivos del servidor."
    exit 0
fi

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
        VERSION=$(fetch "https://fill.papermc.io/v3/projects/${PROJECT}" | jq -r '
            [ .versions | to_entries[] | .value[] ] as $all
            | ( [ $all[] | select(test("-(SNAPSHOT|rc|pre)") | not) ][0] // $all[0] // empty )')
        echo "Ultima version de ${PROJECT}: ${VERSION}"
    fi

    if [ -z "${VERSION}" ]; then
        echo "ERROR: no se pudo determinar una version para ${PROJECT}." >&2
        exit 1
    fi

    URL=$(fetch "https://fill.papermc.io/v3/projects/${PROJECT}/versions/${VERSION}/builds" \
        | jq -r --arg ch "${CHANNEL}" '
            ( [ .[] | select(.channel == $ch) ][0] // .[0] ) as $b
            | if $b == null then empty else $b.downloads["server:default"].url end')

    if [ -z "${URL}" ]; then
        echo "ERROR: no se encontraron builds para ${PROJECT} ${VERSION}." >&2
        exit 1
    fi

    echo "Descargando ${URL}"
    fetch -o "${JARFILE}" "${URL}"
}

# --- Purpur ----------------------------------------------------------------
install_purpur() {
    if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
        VERSION=$(fetch "https://api.purpurmc.org/v2/purpur" | jq -r '.metadata.current // .versions[-1]')
        echo "Ultima version de Purpur: ${VERSION}"
    fi

    echo "Descargando Purpur ${VERSION}"
    fetch -o "${JARFILE}" "https://api.purpurmc.org/v2/purpur/${VERSION}/latest/download"
}

# --- Vanilla ---------------------------------------------------------------
install_vanilla() {
    MANIFEST="https://launchermeta.mojang.com/mc/game/version_manifest.json"

    if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
        VERSION=$(fetch "${MANIFEST}" | jq -r '.latest.release')
    elif [ "${VERSION}" = "snapshot" ]; then
        VERSION=$(fetch "${MANIFEST}" | jq -r '.latest.snapshot')
    fi
    echo "Version de Vanilla: ${VERSION}"

    VERSION_URL=$(fetch "${MANIFEST}" | jq -r --arg v "${VERSION}" '.versions[] | select(.id == $v) | .url')
    if [ -z "${VERSION_URL}" ]; then
        echo "ERROR: no existe la version de Vanilla ${VERSION}." >&2
        exit 1
    fi

    DOWNLOAD_URL=$(fetch "${VERSION_URL}" | jq -r '.downloads.server.url')
    echo "Descargando ${DOWNLOAD_URL}"
    fetch -o "${JARFILE}" "${DOWNLOAD_URL}"
}

# --- Fabric ----------------------------------------------------------------
# Fabric publishes a ready-made launcher jar, so no installer run is needed.
install_fabric() {
    if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
        VERSION=$(fetch "https://meta.fabricmc.net/v2/versions/game" | jq -r '[.[] | select(.stable == true)][0].version')
    fi
    LOADER=$(fetch "https://meta.fabricmc.net/v2/versions/loader" | jq -r '[.[] | select(.stable == true)][0].version')
    INSTALLER=$(fetch "https://meta.fabricmc.net/v2/versions/installer" | jq -r '[.[] | select(.stable == true)][0].version')

    echo "Fabric: juego ${VERSION}, loader ${LOADER}, instalador ${INSTALLER}"
    fetch -o "${JARFILE}" \
        "https://meta.fabricmc.net/v2/versions/loader/${VERSION}/${LOADER}/${INSTALLER}/server/jar"
}

case "${SOFTWARE}" in
    paper|folia|velocity|waterfall) install_paper_family "${SOFTWARE}" ;;
    purpur)                         install_purpur ;;
    vanilla)                        install_vanilla ;;
    fabric)                         install_fabric ;;
    *)
        echo "ERROR: software desconocido '${SOFTWARE}'." >&2
        echo "Valores validos: paper, folia, purpur, vanilla, fabric, velocity, waterfall, none" >&2
        exit 1
        ;;
esac

if [ ! -s "${JARFILE}" ]; then
    echo "ERROR: ${JARFILE} no existe o quedo vacio tras la descarga." >&2
    exit 1
fi

# Proxies have no EULA and no server.properties.
case "${SOFTWARE}" in
    velocity|waterfall) ;;
    *)
        if [ "${EULA}" = "true" ] || [ "${EULA}" = "1" ]; then
            echo "eula=true" > eula.txt
            echo "EULA de Minecraft aceptado."
        fi
        [ -f server.properties ] || touch server.properties
        ;;
esac

echo "Se descargaron $(du -h "${JARFILE}" | cut -f1) en ${JARFILE}"
echo "Instalacion completada."
