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

# --- Leaves ----------------------------------------------------------------
# Paper fork with an API shaped like PaperMC's own v2.
install_leaves() {
    if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
        VERSION=$(fetch "https://api.leavesmc.org/v2/projects/leaves" | jq -r '.versions[-1]')
        echo "Ultima version de Leaves: ${VERSION}"
    fi

    BUILD=$(fetch "https://api.leavesmc.org/v2/projects/leaves/versions/${VERSION}" | jq -r '.builds[-1]')
    [ -z "${BUILD}" ] || [ "${BUILD}" = "null" ] && { echo "ERROR: no hay builds de Leaves para ${VERSION}." >&2; exit 1; }

    NAME=$(fetch "https://api.leavesmc.org/v2/projects/leaves/versions/${VERSION}/builds/${BUILD}" \
        | jq -r '.downloads.application.name')

    echo "Descargando Leaves ${VERSION} build ${BUILD}"
    fetch -o "${JARFILE}" "https://api.leavesmc.org/v2/projects/leaves/versions/${VERSION}/builds/${BUILD}/downloads/${NAME}"
}

# --- Pufferfish ------------------------------------------------------------
# Published on Jenkins, one job per Minecraft minor (Pufferfish-1.21, ...).
install_pufferfish() {
    if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
        JOB=$(fetch "https://ci.pufferfish.host/api/json?tree=jobs[name]" \
            | jq -r '[.jobs[].name | select(test("^Pufferfish-[0-9]"))] | sort_by(split("-")[1] | split(".") | map(tonumber)) | last')
    else
        # 1.21.4 lives in the Pufferfish-1.21 job.
        JOB="Pufferfish-$(echo "${VERSION}" | cut -d. -f1,2)"
    fi
    echo "Job de Pufferfish: ${JOB}"

    ART=$(fetch "https://ci.pufferfish.host/job/${JOB}/lastSuccessfulBuild/api/json?tree=artifacts[relativePath]" \
        | jq -r '.artifacts[0].relativePath')
    [ -z "${ART}" ] || [ "${ART}" = "null" ] && { echo "ERROR: no se encontro artefacto en ${JOB}." >&2; exit 1; }

    echo "Descargando ${ART}"
    fetch -o "${JARFILE}" "https://ci.pufferfish.host/job/${JOB}/lastSuccessfulBuild/artifact/${ART}"
}

# --- Mohist ----------------------------------------------------------------
# Hybrid: runs Forge mods and Bukkit plugins at the same time.
mohist_build_url() {
    fetch "https://mohistmc.com/api/v2/projects/mohist/$1/builds" 2>/dev/null \
        | jq -r '.builds[-1].originUrl // empty'
}

install_mohist() {
    if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
        # Mohist lists versions that have no builds yet (1.21.4 at time of
        # writing), so walk backwards until one actually has a download.
        for CANDIDATE in $(fetch "https://mohistmc.com/api/v2/projects/mohist" | jq -r '.versions | reverse | .[]'); do
            URL=$(mohist_build_url "${CANDIDATE}")
            if [ -n "${URL}" ]; then
                VERSION="${CANDIDATE}"
                break
            fi
            echo "Mohist ${CANDIDATE} aun no tiene builds, probando la anterior..."
        done
        echo "Ultima version de Mohist con builds: ${VERSION}"
    else
        URL=$(mohist_build_url "${VERSION}")
    fi

    [ -z "${URL}" ] && { echo "ERROR: no hay builds de Mohist para ${VERSION}." >&2; exit 1; }

    echo "Descargando Mohist ${VERSION}"
    fetch -o "${JARFILE}" "${URL}"
}

# --- Arclight --------------------------------------------------------------
# Also hybrid. Published as GitHub release assets named
# arclight-<loader>-<mcversion>-<build>.jar, spread across several releases,
# so the right release has to be searched for by asset name.
install_arclight() {
    LOADER=$(echo "${ARCLIGHT_LOADER:-forge}" | tr '[:upper:]' '[:lower:]')
    API="https://api.github.com/repos/IzzelAliz/Arclight/releases?per_page=100"

    if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
        URL=$(fetch "${API}" | jq -r --arg l "${LOADER}" \
            '[.[].assets[] | select(.name | startswith("arclight-" + $l + "-"))][0].browser_download_url // empty')
    else
        URL=$(fetch "${API}" | jq -r --arg l "${LOADER}" --arg v "${VERSION}" \
            '[.[].assets[] | select(.name | startswith("arclight-" + $l + "-" + $v + "-"))][0].browser_download_url // empty')
    fi

    if [ -z "${URL}" ]; then
        echo "ERROR: no se encontro Arclight para ${LOADER} ${VERSION}." >&2
        echo "Versiones disponibles:" >&2
        fetch "${API}" | jq -r --arg l "${LOADER}" \
            '[.[].assets[].name | select(startswith("arclight-" + $l + "-"))] | unique | .[]' >&2
        exit 1
    fi

    echo "Descargando ${URL}"
    fetch -o "${JARFILE}" "${URL}"
}

case "${SOFTWARE}" in
    paper|folia|velocity|waterfall) install_paper_family "${SOFTWARE}" ;;
    purpur)                         install_purpur ;;
    vanilla)                        install_vanilla ;;
    fabric)                         install_fabric ;;
    leaves)                         install_leaves ;;
    pufferfish)                     install_pufferfish ;;
    mohist)                         install_mohist ;;
    arclight)                       install_arclight ;;
    *)
        echo "ERROR: software desconocido '${SOFTWARE}'." >&2
        echo "Valores validos: paper, folia, purpur, pufferfish, leaves, vanilla," >&2
        echo "                 fabric, mohist, arclight, velocity, waterfall, none" >&2
        exit 1
        ;;
esac

if [ ! -s "${JARFILE}" ]; then
    echo "ERROR: ${JARFILE} no existe o quedo vacio tras la descarga." >&2
    exit 1
fi

# Hint for the entrypoint. Mohist and Arclight cannot be told apart from Forge
# until they have booted once and written their own config files, so record
# what was installed. Detection based on real files always wins over this, so a
# later software swap by an external installer module is not misread.
echo "${SOFTWARE}" > .multiversion-software

# Proxies have no EULA and no server.properties.
case "${SOFTWARE}" in
    velocity|waterfall) ;;
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

echo "Se descargaron $(du -h "${JARFILE}" | cut -f1) en ${JARFILE}"
echo "Instalacion completada."
