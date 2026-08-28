#!/usr/bin/env bash
#
# Copies install.sh into the egg's embedded installation script.
#
# The egg carries its own copy of the installer, and THAT copy is the one
# Pterodactyl runs. Editing install.sh alone changes nothing in production, so
# run this after every change to it. CI fails the build if the two diverge.
#
# Usage:
#   ./sync-egg.sh            update the egg from install.sh
#   ./sync-egg.sh --check    only report whether they match (exit 1 if not)
#
set -euo pipefail

cd "$(dirname "$0")"

EGG="egg-minecraft-multiversion.json"
SRC="install.sh"

[ -f "${EGG}" ] || { echo "No se encuentra ${EGG}" >&2; exit 1; }
[ -f "${SRC}" ] || { echo "No se encuentra ${SRC}" >&2; exit 1; }

MODE="${1:-write}"

node -e '
const fs = require("fs");
const [egg_path, src_path, mode] = process.argv.slice(1);

const egg = JSON.parse(fs.readFileSync(egg_path, "utf8"));
// Normalised: a CRLF checkout would otherwise ship a script the shebang line
// alone is enough to break inside the container.
const disk = fs.readFileSync(src_path, "utf8").replace(/\r\n/g, "\n");

if (egg.scripts.installation.script === disk) {
    console.log("Ya estaban sincronizados (" + disk.length + " caracteres).");
    process.exit(0);
}

if (mode === "--check") {
    console.error("El egg y " + src_path + " NO coinciden. Ejecuta ./sync-egg.sh");
    process.exit(1);
}

egg.scripts.installation.script = disk;
egg.exported_at = new Date().toISOString();
// 4 spaces plus a trailing newline is what the panel itself exports.
fs.writeFileSync(egg_path, JSON.stringify(egg, null, 4) + "\n");
console.log("Egg actualizado desde " + src_path + " (" + disk.length + " caracteres).");
' "${EGG}" "${SRC}" "${MODE}"
