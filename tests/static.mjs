import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const install = readFileSync(resolve(root, 'install.sh'), 'utf8').replace(/\r\n/g, '\n');
const egg = JSON.parse(readFileSync(resolve(root, 'egg-minecraft-multiversion.json'), 'utf8'));
const imageWorkflow = readFileSync(resolve(root, '.github/workflows/build-images.yml'), 'utf8').replace(/\r\n/g, '\n');

assert.equal(egg.scripts.installation.script, install, 'El instalador embebido debe coincidir byte a byte.');
assert.match(install, /jq -n[\s\S]*?> \.hexminecraftversion-installed\.json/);
assert.doesNotMatch(install, /printf[^\n]*hexminecraftversion-installed/);
for (const field of ['protocol: 1', 'software: $software', 'release: $release', 'installed_at: $installed_at']) {
    assert.ok(install.includes(field), `Falta el campo seguro ${field}.`);
}
assert.match(install, /\$build_id \| tonumber/);
assert.match(install, /\$java \| tonumber/);
assert.deepEqual(
    Object.keys(egg.docker_images).sort(),
    ['Java 11', 'Java 16', 'Java 17', 'Java 17 (OpenJ9)', 'Java 21', 'Java 25', 'Java 8', 'Java 8 (OpenJ9)'].sort(),
);
assert.match(imageWorkflow, /Build immutable production egg/);
assert.match(imageWorkflow, /summary:[\s\S]*docker\/setup-buildx-action@v3[\s\S]*Record immutable image digests/);
assert.match(imageWorkflow, /dist\/images-manifest\.json/);
assert.match(imageWorkflow, /digest: \$digest/);
assert.match(imageWorkflow, /java_\$t-\$\{\{ needs\.prepare\.outputs\.version \}\}/);

console.log('OK: egg embebido, marcador jq, ocho imágenes y release inmutable verificados.');
