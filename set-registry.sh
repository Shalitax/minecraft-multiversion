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
REGISTRY="${REGISTRY%%:*}${REGISTRY#"${REGISTRY%%:*}"}"
REGISTRY="$(echo "${REGISTRY}" | sed 's|:java_.*$||')"

EGG="egg-minecraft-multiversion.json"
OLD="ghcr.io/CHANGEME/minecraft-multiversion"

count=$(grep -c "${OLD}" "${EGG}" || true)
if [ "${count}" = "0" ]; then
    echo "No placeholder found in ${EGG}. Already configured?" >&2
    grep -o '"ghcr.io[^"]*"' "${EGG}" | head -1
    exit 1
fi

sed -i "s|${OLD}|${REGISTRY}|g" "${EGG}"
sed -i "s|${OLD}|${REGISTRY}|g" images/build.sh

echo "Updated ${count} image references to ${REGISTRY}"
echo
echo "Verifying the egg is still valid JSON..."
node -e "
const e = require('./${EGG}');
const imgs = Object.values(e.docker_images);
const bad = imgs.filter(i => i.includes('CHANGEME'));
if (bad.length) { console.error('Placeholder still present in', bad.length, 'images'); process.exit(1); }
console.log('OK:', imgs.length, 'images ->', imgs[0]);
"
