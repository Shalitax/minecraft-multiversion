#!/bin/bash
#
# Regresion: el choque entre los dos protocolos de solicitud del egg.
#
# Ejecuta EL BLOQUE REAL de resolucion de solicitudes de install.sh —desde el
# principio hasta justo antes del borrado opcional— y comprueba con que SOFTWARE
# y VERSION se queda el instalador en cada escenario.
#
# Uso:
#   ./tests/requests.sh                    # prueba ../install.sh
#   ./tests/requests.sh /otro/install.sh   # o el que se le pase
#
# El corte se hace por el comentario del bloque de borrado, que es estable.

set -u

INSTALL_SH="${1:-$(cd "$(dirname "$0")/.." && pwd)/install.sh}"
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$BASE_DIR/bin:$PATH"

CORTE=$(grep -n '^# Optional wipe$' "$INSTALL_SH" | head -1 | cut -d: -f1)
if [ -z "$CORTE" ]; then
    echo "No se encontro el bloque de borrado; el corte del banco esta desfasado." >&2
    exit 2
fi

# Dos lineas antes empieza el comentario de bloque.
CORTE=$((CORTE - 2))

TRABAJO=$(mktemp -d)
trap 'rm -rf "$TRABAJO"' EXIT

head -n "$CORTE" "$INSTALL_SH" > "$TRABAJO/bloque.sh"

# El original hace `mkdir -p /mnt/server; cd /mnt/server` y un `apk add`. Se
# redirigen al directorio de trabajo y se anula la instalacion de paquetes.
sed -i 's#^mkdir -p /mnt/server$#mkdir -p "${BANCO_RAIZ}"#' "$TRABAJO/bloque.sh"
sed -i 's#^cd /mnt/server$#cd "${BANCO_RAIZ}"#' "$TRABAJO/bloque.sh"
sed -i 's#^apk add .*$#true#' "$TRABAJO/bloque.sh"
sed -i 's#/mnt/server/\.hexminecraftversion-request#${BANCO_RAIZ}/.hexminecraftversion-request#' "$TRABAJO/bloque.sh"

NONCE="0123456789abcdef0123456789abcdef"

payload_modpack() {
    printf '{"protocol":2,"nonce":"%s","provider":"curseforge","modpack_id":"1","modpack_name":"Pack","modpack_version_id":"2","modpack_version_name":"v2","minecraft_version":"modpack","mode":"preserve","eula":1}' "$NONCE" | base64 -w0
}

fallos=0
total=0

escenario() {
    local nombre="$1" solicitud_version="$2" variable_modpack="$3" marcador="$4" nonce_aparte="$5"
    local esperado_software="$6" esperado_version="$7"

    total=$((total + 1))

    local raiz="$TRABAJO/caso$total"
    mkdir -p "$raiz"

    if [ "$solicitud_version" = "si" ]; then
        printf 'protocol=1\nsoftware=neoforge\nrelease=1.21.1\nmode=preserve\neula=1\nloader=forge\n' \
            > "$raiz/.hexminecraftversion-request"
    fi
    if [ "$marcador" = "si" ]; then
        printf '{"protocol":2,"request_nonce":"%s"}' "$NONCE" > "$raiz/.hexminecraftmodpacks-installed.json"
    fi
    if [ "$nonce_aparte" = "si" ]; then
        printf '%s\n' "$NONCE" > "$raiz/.multiversion-consumed-nonce"
    fi

    local env_modpack=""
    if [ "$variable_modpack" = "si" ]; then
        env_modpack=$(payload_modpack)
    fi

    local salida
    salida=$(
        BANCO_RAIZ="$raiz" \
        SERVER_SOFTWARE="none" \
        SERVER_VERSION="latest" \
        HEXMINECRAFTMODPACK_REQUEST="$env_modpack" \
        HEXMINECRAFTMODPACK_PROTOCOL="2" \
        bash -c 'source "$1" >/dev/null 2>&1; printf "%s|%s" "${SOFTWARE}" "${VERSION}"' _ "$TRABAJO/bloque.sh"
    )

    local software="${salida%%|*}"
    local version="${salida##*|}"

    if [ "$software" = "$esperado_software" ] && [ "$version" = "$esperado_version" ]; then
        printf '  ok    %-52s -> %s / %s\n' "$nombre" "$software" "$version"
    else
        fallos=$((fallos + 1))
        printf '  FALLA %-52s -> %s / %s   (se esperaba %s / %s)\n' \
            "$nombre" "$software" "$version" "$esperado_software" "$esperado_version"
    fi
}

echo ""
echo "Resolucion de solicitudes del egg"
echo ""

#          nombre                                        version  variable  marcador  nonce   software   version
escenario "Versiones sola"                                si       no        no        no      neoforge   1.21.1
escenario "Versiones + modpack pendiente (EL FALLO)"      si       si        no        no      neoforge   1.21.1
escenario "Versiones + modpack ya consumido (marcador)"   si       si        si        no      neoforge   1.21.1
escenario "Versiones + modpack ya consumido (nonce)"      si       si        no        si      neoforge   1.21.1
escenario "Modpack solo, sin consumir"                    no       si        no        no      none       modpack

# Con la solicitud ya consumida y sin ninguna otra, el egg sale antes de tiempo
# con «no hay una nueva solicitud; se conservan los archivos actuales». No llega
# a fijar SOFTWARE ni VERSION, y eso es lo correcto: no hay nada que instalar.
escenario "Modpack consumido (marcador), sin otra peticion" no      si        si        no      ""         ""
escenario "Modpack consumido (nonce), sin otra peticion"   no       si        no        si      ""         ""

echo ""
if [ "$fallos" -gt 0 ]; then
    echo "$total escenarios, $fallos con el resultado equivocado."
    exit 1
fi
echo "$total escenarios, todos correctos."
