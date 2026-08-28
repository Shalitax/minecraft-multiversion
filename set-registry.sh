#!/usr/bin/env bash
#
# Points the egg and the local build script at your registry.
#
# The workflow does not need this: it derives the namespace from the repository
# owner. This is for the egg JSON, which has to carry a literal image path.
#
# Usage:
#   ./set-registry.sh ghcr.io/mi-usuario/minecraft-multiversion
#
set -euo pipefail

cd "$(dirname "$0")"

REGISTRY="${1:-}"
if [ -z "${REGISTRY}" ]; then
    echo "Usage: $0 <registry>" >&2
    echo "Example: $0 ghcr.io/mi-usuario/minecraft-multiversion" >&2
    exit 1
fi

# Strip a trailing tag if one was pasted in by accident.
REGISTRY="$(echo "${REGISTRY}" | sed 's|:java_.*$||')"

# Docker repository names must be lowercase, and a GitHub username often is not.
case "${REGISTRY}" in
    *[A-Z]*)
        echo "ERROR: el nombre del registro debe ir en minusculas: ${REGISTRY}" >&2
        echo "Prueba con: $(echo "${REGISTRY}" | tr '[:upper:]' '[:lower:]')" >&2
        exit 1
        ;;
esac

EGG="egg-minecraft-multiversion.json"

# Read the current namespace out of the egg instead of assuming it is still the
# original placeholder. Hardcoding CHANGEME meant this script worked exactly
# once and then refused to run again, which is the opposite of what someone
# moving their images to a different registry needs.
OLD=$(node -e '
const fs = require("fs");
const egg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const images = Object.values(egg.docker_images).map((i) => i.replace(/:[^:]*$/, ""));
const unique = [...new Set(images)];
if (unique.length !== 1) {
    console.error("El egg apunta a varios registros distintos: " + unique.join(", "));
    process.exit(1);
}
process.stdout.write(unique[0]);
' "${EGG}")

if [ "${OLD}" = "${REGISTRY}" ]; then
    echo "El egg ya apunta a ${REGISTRY}. No hay nada que cambiar."
    exit 0
fi

echo "Cambiando ${OLD} -> ${REGISTRY}"

sed -i "s|${OLD}|${REGISTRY}|g" "${EGG}"
sed -i "s|${OLD}|${REGISTRY}|g" images/build.sh

echo
echo "Verificando que el egg sigue siendo JSON valido..."
node -e '
const egg = require("./egg-minecraft-multiversion.json");
const images = Object.values(egg.docker_images);
const bad = images.filter((i) => i.includes("CHANGEME") || /[A-Z]/.test(i));
if (bad.length) {
    console.error("Imagenes invalidas:", bad.join(", "));
    process.exit(1);
}
console.log("OK: " + images.length + " imagenes -> " + images[0]);
'
