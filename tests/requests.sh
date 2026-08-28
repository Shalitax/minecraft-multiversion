#!/bin/bash
#
# Regresion: como resuelve el egg una solicitud de instalacion.
#
# Ejecuta EL BLOQUE REAL de resolucion de solicitudes de install.sh —desde el
# principio hasta justo antes del borrado opcional— y comprueba con que SOFTWARE
# y VERSION se queda el instalador en cada escenario.
#
# Este banco nacio cubriendo el choque entre DOS protocolos: el de Hex Minecraft
# Versions, que entregaba su orden en el archivo .hexminecraftversion-request, y
# el de Hex Minecraft Modpacks. Cuatro de sus siete escenarios eran de ese
# choque. Aquel protocolo se retiro: desde la 2.0.0 el modulo de versiones
# instala el, por la API de archivos de Wings, y no escribe el archivo nunca.
#
# De ahi los dos escenarios nuevos del final. El archivo lo puede escribir
# cualquier cliente desde su gestor de archivos —no esta en el file_denylist— y
# mientras el egg lo leyera, mandaba sobre todo lo demas. Ahora tiene que ser
# exactamente tan inerte como cualquier otro archivo suelto en la raiz, y eso
# es lo que se comprueba aqui.
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

# Si el bloque volviera a mirar el archivo de solicitud, el banco tiene que
# enterarse en vez de probar una ruta que ya no existe.
if grep -q 'hexminecraftversion-request' "$TRABAJO/bloque.sh"; then
    echo "El instalador vuelve a leer .hexminecraftversion-request; este banco esta desfasado." >&2
    exit 2
fi

NONCE="0123456789abcdef0123456789abcdef"

payload_modpack() {
    printf '{"protocol":2,"nonce":"%s","provider":"curseforge","modpack_id":"1","modpack_name":"Pack","modpack_version_id":"2","modpack_version_name":"v2","minecraft_version":"modpack","mode":"preserve","eula":1}' "$NONCE" | base64 -w0
}

fallos=0
total=0

escenario() {
    local nombre="$1" variable_modpack="$2" marcador="$3" nonce_aparte="$4" rezagado="$5"
    local esperado_software="$6" esperado_version="$7"

    total=$((total + 1))

    local raiz="$TRABAJO/caso$total"
    mkdir -p "$raiz"

    if [ "$marcador" = "si" ]; then
        printf '{"protocol":2,"request_nonce":"%s"}' "$NONCE" > "$raiz/.hexminecraftmodpacks-installed.json"
    fi
    if [ "$nonce_aparte" = "si" ]; then
        printf '%s\n' "$NONCE" > "$raiz/.multiversion-consumed-nonce"
    fi
    if [ "$rezagado" = "si" ]; then
        printf 'protocol=1\nsoftware=neoforge\nrelease=1.21.1\nmode=wipe\neula=1\nloader=forge\n' \
            > "$raiz/.hexminecraftversion-request"
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

#          nombre                                          variable  marcador  nonce  rezagado  software  version
escenario "Modpack solo, sin consumir"                      si        no        no     no        none      modpack

# Con la solicitud ya consumida y sin ninguna otra, el egg sale antes de tiempo
# con «no hay una nueva solicitud; se conservan los archivos actuales». No llega
# a fijar SOFTWARE ni VERSION, y eso es lo correcto: no hay nada que instalar.
escenario "Modpack consumido (marcador), sin otra peticion" si        si        no     no        ""        ""
escenario "Modpack consumido (nonce), sin otra peticion"    si        no        si     no        ""        ""

# El protocolo retirado. Un archivo rezagado —o escrito a mano por el cliente—
# no puede cambiar nada: ni imponer su software, ni desviar la instalacion del
# modpack que si esta pedida.
escenario "Archivo de solicitud rezagado, sin nada mas"     no        no        no     si        none      latest
escenario "Archivo rezagado + modpack pendiente"            si        no        no     si        none      modpack

echo ""
if [ "$fallos" -gt 0 ]; then
    echo "$total escenarios, $fallos con el resultado equivocado."
    exit 1
fi
echo "$total escenarios, todos correctos."
