#!/bin/bash
#
# Banco de pruebas de ensure_args_jar, la reparacion del lanzador de Forge.
#
# Forge 61.x redujo unix_args.txt a "-jar forge-<version>-shim.jar", y ese
# nombre se resuelve contra la raiz del servidor. El instalador oficial deja el
# shim ahi; mcjars lo normaliza a server.jar y solo lo deja dentro de
# libraries/, con lo que el arranque muere con "Unable to access jarfile".
#
# Ejecuta LA FUNCION REAL del entrypoint sobre arboles de servidor que imitan
# las dos formas de instalar, ademas de las que no debe tocar.
#
# Uso:
#   ./args-jar.sh /ruta/a/entrypoint.sh

set -u

ENTRYPOINT="${1:-$(dirname "$0")/../images/entrypoint.sh}"
ENTRYPOINT="$(cd "$(dirname "${ENTRYPOINT}")" && pwd)/$(basename "${ENTRYPOINT}")"

if ! grep -q '^ensure_args_jar() {' "${ENTRYPOINT}"; then
    echo "No se encontro ensure_args_jar; el corte del banco esta desfasado." >&2
    exit 2
fi

TRABAJO=$(mktemp -d)
trap 'rm -rf "${TRABAJO}"' EXIT

# La funcion real, con los ayudantes de registro reducidos a lo que el banco
# necesita observar.
{
    echo 'log_info() { echo "INFO $*"; }'
    echo 'log_warn() { echo "WARN $*"; }'
    sed -n '/^ensure_args_jar() {/,/^}/p' "${ENTRYPOINT}"
} > "${TRABAJO}/funcion.sh"

# shellcheck disable=SC1090
. "${TRABAJO}/funcion.sh"

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

# Prepara una raiz de servidor limpia y se situa dentro.
nuevo_servidor() {
    RAIZ="${TRABAJO}/s$((total + 1))_$RANDOM"
    mkdir -p "${RAIZ}"
    cd "${RAIZ}" || exit 2
    ARGS_FILE=""
    SERVER_JARFILE="server.jar"
}

# Un arbol como el que deja mcjars: todo bajo libraries/ y el lanzador
# duplicado en la raiz con el nombre server.jar.
arbol_mcjars() {
    local version="$1" contenido="$2"
    local dir="libraries/net/minecraftforge/forge/${version}"
    mkdir -p "${dir}"
    printf '%s' "${contenido}" > "${dir}/unix_args.txt"
    echo 'LANZADOR' > "${dir}/forge-${version}-shim.jar"
    echo 'LANZADOR' > server.jar
    ARGS_FILE="${dir}/unix_args.txt"
}

echo ""
echo "Reparacion del lanzador de Forge"
echo ""

# --- El caso que rompia: Forge 61.x instalado desde mcjars ------------------
nuevo_servidor
arbol_mcjars "1.21.11-61.2.1" '-Djava.net.preferIPv6Addresses=system -jar forge-1.21.11-61.2.1-shim.jar'
SALIDA=$(ensure_args_jar)
if [ -f "forge-1.21.11-61.2.1-shim.jar" ]; then
    comprobar "deja el lanzador donde el args file lo busca" ok
else
    comprobar "deja el lanzador donde el args file lo busca" "no se creo"
fi

# Y tiene que ser el lanzador de verdad, no un archivo vacio.
if [ "$(cat forge-1.21.11-61.2.1-shim.jar 2>/dev/null)" = "LANZADOR" ]; then
    comprobar "el archivo copiado es el lanzador" ok
else
    comprobar "el archivo copiado es el lanzador" "contenido distinto"
fi

case "${SALIDA}" in
    *INFO*) comprobar "lo dice en la consola" ok ;;
    *)      comprobar "lo dice en la consola" "no anuncio nada" ;;
esac

# --- Idempotencia: arrancar dos veces no puede duplicar trabajo -------------
SALIDA2=$(ensure_args_jar)
if [ -z "${SALIDA2}" ]; then
    comprobar "en el segundo arranque no hace nada" ok
else
    comprobar "en el segundo arranque no hace nada" "dijo '${SALIDA2}'"
fi

# --- Instalacion oficial: el shim ya esta en la raiz ------------------------
# El instalador de Forge lo deja ahi y no hay ningun server.jar. Tocar algo
# aqui seria inventarse un archivo que nadie ha pedido.
nuevo_servidor
mkdir -p libraries/net/minecraftforge/forge/1.21.11-61.2.1
printf '%s' '-jar forge-1.21.11-61.2.1-shim.jar' > libraries/net/minecraftforge/forge/1.21.11-61.2.1/unix_args.txt
ARGS_FILE="libraries/net/minecraftforge/forge/1.21.11-61.2.1/unix_args.txt"
echo 'OFICIAL' > forge-1.21.11-61.2.1-shim.jar
SALIDA=$(ensure_args_jar)
if [ "$(cat forge-1.21.11-61.2.1-shim.jar)" = "OFICIAL" ] && [ -z "${SALIDA}" ]; then
    comprobar "no toca una instalacion oficial que ya esta bien" ok
else
    comprobar "no toca una instalacion oficial que ya esta bien" "lo modifico o hablo"
fi

# --- Forge 47.x: el args file lleva el classpath, no un -jar ---------------
nuevo_servidor
arbol_mcjars "1.20.1-47.4.23" '-p libraries/a.jar:libraries/b.jar --add-modules ALL-MODULE-PATH cpw.mods.bootstraplauncher.BootstrapLauncher --launchTarget forgeserver'
SALIDA=$(ensure_args_jar)
if [ -z "${SALIDA}" ] && [ ! -f "forge-1.20.1-47.4.23-shim.jar" ]; then
    comprobar "no toca un Forge que arranca por classpath" ok
else
    comprobar "no toca un Forge que arranca por classpath" "creo algo o hablo"
fi

# --- NeoForge: usa -classpath con rutas relativas, nunca -jar --------------
nuevo_servidor
mkdir -p libraries/net/neoforged/neoforge/21.11.45
printf '%s' '--add-opens java.base/java.lang.invoke=ALL-UNNAMED -classpath libraries/x.jar:libraries/y.jar net.neoforged.fml.startup.Server' \
    > libraries/net/neoforged/neoforge/21.11.45/unix_args.txt
ARGS_FILE="libraries/net/neoforged/neoforge/21.11.45/unix_args.txt"
echo 'LANZADOR' > server.jar
SALIDA=$(ensure_args_jar)
if [ -z "${SALIDA}" ]; then
    comprobar "no toca NeoForge" ok
else
    comprobar "no toca NeoForge" "dijo '${SALIDA}'"
fi

# --- Un -jar con ruta ya se resuelve solo ----------------------------------
# Si el args file trae una ruta y no un nombre suelto, no hay nada que
# reparar: el que la escribio sabia donde estaba el archivo.
nuevo_servidor
arbol_mcjars "1.21.11-61.2.1" '-jar libraries/net/minecraftforge/forge/1.21.11-61.2.1/forge-1.21.11-61.2.1-shim.jar'
SALIDA=$(ensure_args_jar)
if [ -z "${SALIDA}" ]; then
    comprobar "no toca un -jar que ya trae su ruta" ok
else
    comprobar "no toca un -jar que ya trae su ruta" "dijo '${SALIDA}'"
fi

# --- Sin args file no hay nada que mirar -----------------------------------
nuevo_servidor
SALIDA=$(ensure_args_jar)
if [ -z "${SALIDA}" ]; then
    comprobar "un servidor sin args file no le interesa" ok
else
    comprobar "un servidor sin args file no le interesa" "dijo '${SALIDA}'"
fi

# --- Ni el lanzador ni server.jar: hay que avisar, no callar ---------------
# Este es un servidor de verdad roto. Callarse lo dejaria fallando con el
# error crudo de la JVM, que no dice que hacer.
nuevo_servidor
mkdir -p libraries/net/minecraftforge/forge/1.21.11-61.2.1
printf '%s' '-jar forge-1.21.11-61.2.1-shim.jar' > libraries/net/minecraftforge/forge/1.21.11-61.2.1/unix_args.txt
ARGS_FILE="libraries/net/minecraftforge/forge/1.21.11-61.2.1/unix_args.txt"
SALIDA=$(ensure_args_jar)
case "${SALIDA}" in
    *WARN*) comprobar "avisa cuando no hay de donde copiar" ok ;;
    *)      comprobar "avisa cuando no hay de donde copiar" "se callo" ;;
esac

# --- Un SERVER_JARFILE renombrado sigue sirviendo de origen ----------------
nuevo_servidor
mkdir -p libraries/net/minecraftforge/forge/1.21.11-61.2.1
printf '%s' '-jar forge-1.21.11-61.2.1-shim.jar' > libraries/net/minecraftforge/forge/1.21.11-61.2.1/unix_args.txt
ARGS_FILE="libraries/net/minecraftforge/forge/1.21.11-61.2.1/unix_args.txt"
SERVER_JARFILE="mi-servidor.jar"
echo 'LANZADOR' > mi-servidor.jar
ensure_args_jar >/dev/null
if [ "$(cat forge-1.21.11-61.2.1-shim.jar 2>/dev/null)" = "LANZADOR" ]; then
    comprobar "usa el jar configurado si es el unico que hay" ok
else
    comprobar "usa el jar configurado si es el unico que hay" "no lo copio"
fi

cd "${TRABAJO}" || exit 2

echo ""
if [ "${fallos}" -gt 0 ]; then
    echo "${total} comprobaciones, ${fallos} con el resultado equivocado."
    exit 1
fi
echo "${total} comprobaciones, todas correctas."
