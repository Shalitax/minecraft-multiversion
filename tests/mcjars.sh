#!/bin/bash
#
# Banco de pruebas del instalador de mcjars del egg.
#
# Ejecuta LAS FUNCIONES REALES de install.sh —el bloque que va desde el
# comentario de mcjars hasta justo antes del despacho— contra la API de verdad,
# y comprueba que resuelven builds y que una instalacion deja en disco lo que
# tiene que dejar.
#
# Necesita salida a internet. Sin ella no hay nada que probar y el banco lo dice
# en lugar de fallar, porque un corte de red no es un fallo del egg.
#
# Uso:
#   ./mcjars.sh /ruta/a/install.sh

set -u

INSTALL_SH="${1:-$(dirname "$0")/../install.sh}"

# El jq de tests/bin es un remedo con lo justo para el banco de solicitudes;
# aqui hacen falta filtros de verdad. Se acepta uno por argumento para poder
# ejecutarlo en una maquina que no lo traiga instalado.
if [ "${2:-}" = "--jq" ] && [ -n "${3:-}" ]; then
    JQ_DIR=$(cd "$(dirname "$3")" && pwd)
    export PATH="${JQ_DIR}:${PATH}"
fi

if ! jq --version >/dev/null 2>&1; then
    echo ""
    echo "Hace falta jq para este banco. Pasa uno con --jq /ruta/a/jq."
    exit 0
fi

INICIO=$(grep -n '^# --- mcjars ---' "${INSTALL_SH}" | head -1 | cut -d: -f1)
FIN=$(grep -n '^# Una build guardada por el modulo de versiones' "${INSTALL_SH}" | head -1 | cut -d: -f1)

if [ -z "${INICIO}" ] || [ -z "${FIN}" ]; then
    echo "No se encontro el bloque de mcjars; el corte del banco esta desfasado." >&2
    exit 2
fi

TRABAJO=$(mktemp -d)
trap 'rm -rf "${TRABAJO}"' EXIT

{
    echo 'UA="pterodactyl-mc-multiversion/test"'
    echo 'fetch()      { curl -sSL --fail --connect-timeout 10 --max-time 900 --retry 2 -A "${UA}" "$@"; }'
    echo 'fetch_meta() { curl -sSL --fail --connect-timeout 10 --max-time 30  --retry 2 -A "${UA}" "$@"; }'
    sed -n "${INICIO},$((FIN - 2))p" "${INSTALL_SH}"
} > "${TRABAJO}/mcjars.sh"

# shellcheck disable=SC1090
. "${TRABAJO}/mcjars.sh"

if ! fetch_meta "${MCJARS_URL}/api/v2/types" >/dev/null 2>&1; then
    echo ""
    echo "mcjars no responde desde aqui; no hay nada que comprobar."
    exit 0
fi

fallos=0
total=0

comprobar() {
    total=$((total + 1))
    if [ "$2" = "ok" ]; then
        printf '  ok    %s\n' "$1"
    else
        fallos=$((fallos + 1))
        printf '  FALLA %s   (%s)\n' "$1" "$2"
    fi
}

echo ""
echo "Instalador de mcjars del egg"
echo ""

# --- Rutas que no pueden salir de /mnt/server ------------------------------
for RUTA in '/etc/passwd' '../fuera' 'a/../../b' ''; do
    if mcjars_safe_path "${RUTA}"; then
        comprobar "rechaza la ruta '${RUTA}'" "la acepto"
    else
        comprobar "rechaza la ruta '${RUTA}'" ok
    fi
done

for RUTA in 'server.jar' 'libraries' 'mods/algo.jar'; do
    if mcjars_safe_path "${RUTA}"; then
        comprobar "acepta la ruta '${RUTA}'" ok
    else
        comprobar "acepta la ruta '${RUTA}'" "la rechazo"
    fi
done

# --- Resolucion de builds ---------------------------------------------------
BUILD=$(mcjars_latest_build "neoforge" "1.21.1")
case "${BUILD}" in
    ''|*[!0-9]*) comprobar "resuelve una build de neoforge 1.21.1" "devolvio '${BUILD}'" ;;
    *)           comprobar "resuelve una build de neoforge 1.21.1" ok ;;
esac

# Uno de los diez que este egg no sabe instalar a mano: es justo el caso que
# obligo a escribir todo esto.
BUILD_NUEVO=$(mcjars_latest_build "divinemc" "latest")
case "${BUILD_NUEVO}" in
    ''|*[!0-9]*) comprobar "resuelve una build de divinemc, que el egg no trae" "devolvio '${BUILD_NUEVO}'" ;;
    *)           comprobar "resuelve una build de divinemc, que el egg no trae" ok ;;
esac

BUILD_FALSO=$(mcjars_latest_build "noexisteestesoftware" "1.21.1")
if [ -z "${BUILD_FALSO}" ]; then
    comprobar "no inventa una build para un software inexistente" ok
else
    comprobar "no inventa una build para un software inexistente" "devolvio '${BUILD_FALSO}'"
fi

# --- La build guardada tiene que ser del software que se pide ---------------
# Sin esta comprobacion, un cliente que cambiara el software a mano en la
# pestana Arranque veria como Reinstalar le devuelve el anterior.
cd "${TRABAJO}" || exit 2
SOFTWARE="vanilla"
VERSION="1.21.1"
if install_mcjars_build "${BUILD}" >/dev/null 2>&1; then
    comprobar "ignora una build de otro software" "instalo neoforge pidiendo vanilla"
else
    comprobar "ignora una build de otro software" ok
fi

# --- Instalacion de verdad --------------------------------------------------
# NanoLimbo es el mas pequeno del catalogo, asi que es el que se puede instalar
# en un banco de pruebas sin bajarse cien megas.
SOFTWARE="nanolimbo"
VERSION="latest"
BUILD_LIMBO=$(mcjars_latest_build "nanolimbo" "latest")

if [ -z "${BUILD_LIMBO}" ]; then
    comprobar "instala nanolimbo desde mcjars" "no se pudo resolver la build"
else
    INSTALACION="${TRABAJO}/instalacion"
    mkdir -p "${INSTALACION}"
    cd "${INSTALACION}" || exit 2

    if install_mcjars_build "${BUILD_LIMBO}" > "${TRABAJO}/salida.txt" 2>&1; then
        if [ -s server.jar ]; then
            comprobar "instala nanolimbo desde mcjars" ok
        else
            comprobar "instala nanolimbo desde mcjars" "no quedo ningun server.jar"
        fi
    else
        comprobar "instala nanolimbo desde mcjars" "$(tail -1 "${TRABAJO}/salida.txt")"
    fi

    if [ -f mcvapi.server.jar.zip ]; then
        comprobar "no deja archivos temporales" "quedo mcvapi.server.jar.zip"
    else
        comprobar "no deja archivos temporales" ok
    fi
fi

# --- Una build que no existe no puede pasar por buena -----------------------
SOFTWARE="paper"
if install_mcjars_build 999999999 >/dev/null 2>&1; then
    comprobar "rechaza una build inexistente" "la dio por buena"
else
    comprobar "rechaza una build inexistente" ok
fi

echo ""
if [ "${fallos}" -gt 0 ]; then
    echo "${total} comprobaciones, ${fallos} con el resultado equivocado."
    exit 1
fi
echo "${total} comprobaciones, todas correctas."
