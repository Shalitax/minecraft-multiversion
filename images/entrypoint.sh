#!/bin/bash
#
# Multiversion Minecraft entrypoint for Pterodactyl.
#
# Detects the installed server software at boot and builds an appropriate
# startup command, so a single egg works for Vanilla, Paper, Purpur, Spigot,
# Forge, NeoForge, Fabric, Quilt, Velocity, BungeeCord and Waterfall.
#
# Nothing here depends on which installer put the files in place: detection is
# based purely on what exists on disk.
#

cd /home/container || exit 1

# Bumped by hand when this file changes in a way worth telling apart in a
# support ticket. MV_BUILD_* are baked in by the Dockerfile at build time, so
# a cached image can be identified even when the tag has not changed.
MULTIVERSION_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

C_RESET=$'\033[0m'
C_INFO=$'\033[1;36m'
C_WARN=$'\033[1;33m'
C_ERR=$'\033[1;31m'
C_OK=$'\033[1;32m'
C_PROMPT=$'\033[1;33m'

log_info()  { echo "${C_INFO}[i]${C_RESET} $*"; }
log_warn()  { echo "${C_WARN}[!]${C_RESET} $*"; }
log_error() { echo "${C_ERR}[x]${C_RESET} $*"; }
log_ok()    { echo "${C_OK}[+]${C_RESET} $*"; }

# Lowercases and strips Spanish accents, so a panel label can be written with
# or without them and still match. A mojibaked value simply fails to match and
# is skipped, rather than being written into server.properties.
#
# Literal byte-sequence replacements rather than character classes: a class
# like [Áá] is matched byte by byte outside a UTF-8 locale and silently fails,
# which is exactly the kind of bug that only shows up in production.
normalize_value() {
    echo "${1}" \
        | sed -e 's/Á/A/g' -e 's/á/a/g' \
              -e 's/É/E/g' -e 's/é/e/g' \
              -e 's/Í/I/g' -e 's/í/i/g' \
              -e 's/Ó/O/g' -e 's/ó/o/g' \
              -e 's/Ú/U/g' -e 's/ú/u/g' \
              -e 's/Ü/U/g' -e 's/ü/u/g' \
              -e 's/Ñ/N/g' -e 's/ñ/n/g' \
        | tr '[:upper:]' '[:lower:]'
}

# Accepts the Spanish panel labels as well as the raw boolean styles, so eggs
# and servers created before the labels existed keep working unchanged.
is_true() {
    case "$(normalize_value "${1}")" in
        1|true|yes|on|enabled|si|activado|activada) return 0 ;;
        *) return 1 ;;
    esac
}

# Empty and the various "leave it alone" labels mean: do not touch the file.
is_auto() {
    [ -z "${1}" ] && return 0
    case "$(normalize_value "${1}")" in
        auto|automatico|default|unset|"no modificar"|"sin cambios") return 0 ;;
        *) return 1 ;;
    esac
}

# The panel shows friendly Spanish labels, but server.properties only accepts
# the literal values below. These map one onto the other, accepting the raw
# English values too so existing servers keep working.
# An empty result means "not recognised": the caller warns and skips.
map_bool() {
    case "$(normalize_value "${1}")" in
        activado|activada|true|1|si|yes|on|enabled)      echo "true" ;;
        desactivado|desactivada|false|0|no|off|disabled) echo "false" ;;
        *)                                               echo "" ;;
    esac
}

map_difficulty() {
    case "$(normalize_value "${1}")" in
        pacifico|peaceful) echo "peaceful" ;;
        facil|easy)        echo "easy" ;;
        normal)            echo "normal" ;;
        dificil|hard)      echo "hard" ;;
        *)                 echo "" ;;
    esac
}

map_gamemode() {
    case "$(normalize_value "${1}")" in
        supervivencia|survival) echo "survival" ;;
        creativo|creative)      echo "creative" ;;
        aventura|adventure)     echo "adventure" ;;
        espectador|spectator)   echo "spectator" ;;
        *)                      echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

TZ=${TZ:-UTC}
export TZ

INTERNAL_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
export INTERNAL_IP

SERVER_JARFILE=${SERVER_JARFILE:-server.jar}
SERVER_MEMORY=${SERVER_MEMORY:-1024}
SERVER_PORT=${SERVER_PORT:-25565}

# Java feature version: strips the legacy "1." prefix (1.8 -> 8) and any
# minor/patch component (17.0.9 -> 17).
JAVA_RAW=$(java -version 2>&1 | head -1 | cut -d'"' -f2)
JAVA_MAJOR=$(echo "${JAVA_RAW}" | sed -e 's/^1\.//' -e 's/[.+-].*//')
[ -z "${JAVA_MAJOR}" ] && JAVA_MAJOR=0

log_info "Java ${JAVA_RAW} (version ${JAVA_MAJOR}) | Zona horaria ${TZ} | IP ${INTERNAL_IP}"
log_info "Egg Multiversion v${MULTIVERSION_VERSION} | imagen ${MV_BUILD_DATE:-desconocida} ${MV_BUILD_REF:+(${MV_BUILD_REF})}"

# HTTP client defaults. Fill v3 rejects requests without a descriptive
# User-Agent, so every curl call in this script goes through these.
USER_AGENT=${UPDATE_USER_AGENT:-"pterodactyl-mc-multiversion/1.0 (+https://pterodactyl.io)"}
CURL_OPTS=(--silent --show-error --location --fail --retry 3 --retry-delay 2 --max-time 300 -A "${USER_AGENT}")

# ---------------------------------------------------------------------------
# Software detection
#
# Order matters: proxies first (they have no server.properties), then modloaders
# that ship an args file, then plain jars.
# ---------------------------------------------------------------------------

SERVER_TYPE=""
IS_PROXY=0
ARGS_FILE=""

# Finds libraries/<path>/<version>/unix_args.txt for Forge and NeoForge. Both
# generate this file from 1.17 onwards and it holds the full classpath.
find_args_file() {
    local base="$1"
    [ -d "${base}" ] || return 1
    local candidate
    # Newest directory first, so a leftover old version does not win.
    for candidate in $(ls -1t "${base}" 2>/dev/null); do
        if [ -f "${base}/${candidate}/unix_args.txt" ]; then
            printf '%s' "${base}/${candidate}/unix_args.txt"
            return 0
        fi
    done
    return 1
}

detect_server_type() {
    # Explicit override from the panel wins over detection.
    if ! is_auto "${SERVER_TYPE_OVERRIDE}"; then
        SERVER_TYPE=$(echo "${SERVER_TYPE_OVERRIDE}" | tr '[:upper:]' '[:lower:]')
        log_info "Tipo de servidor forzado desde el panel: '${SERVER_TYPE}'"
    elif [ -f "velocity.toml" ]; then
        SERVER_TYPE="velocity"
    elif [ -f "config.yml" ] && grep -qE '^\s*listeners:' config.yml 2>/dev/null; then
        # Waterfall and BungeeCord are indistinguishable on disk and start the
        # same way, so they share a type.
        SERVER_TYPE="bungeecord"
    elif [ -f "mohist.yml" ] || [ -d "mohist_config" ]; then
        # Hybrids must be checked before Forge: they ship a Forge library tree,
        # and launching them from Forge's args file would skip the Bukkit side.
        SERVER_TYPE="mohist"
    elif [ -f "arclight.conf" ] || [ -d "arclight" ]; then
        SERVER_TYPE="arclight"
    elif [ -f ".multiversion-software" ] && grep -qE '^(mohist|arclight)$' .multiversion-software 2>/dev/null; then
        # First boot: the hybrid has not written its config files yet, so fall
        # back to what the installer recorded.
        SERVER_TYPE=$(cat .multiversion-software)
    elif ARGS_FILE=$(find_args_file "libraries/net/neoforged/neoforge"); then
        SERVER_TYPE="neoforge"
    elif ARGS_FILE=$(find_args_file "libraries/net/minecraftforge/forge"); then
        SERVER_TYPE="forge"
    elif [ -f "unix_args.txt" ]; then
        # Some installers drop the args file in the root instead.
        SERVER_TYPE="forge"
        ARGS_FILE="unix_args.txt"
    elif [ -f "quilt-server-launch.jar" ]; then
        SERVER_TYPE="quilt"
    elif [ -f "fabric-server-launch.jar" ]; then
        SERVER_TYPE="fabric"
    elif ls forge-*-universal.jar >/dev/null 2>&1 || ls forge-*-shim.jar >/dev/null 2>&1; then
        # Pre-1.17 Forge: a single runnable jar, no args file.
        SERVER_TYPE="forge-legacy"
    else
        SERVER_TYPE="vanilla"
    fi

    case "${SERVER_TYPE}" in
        velocity|bungeecord|waterfall) IS_PROXY=1 ;;
        *) IS_PROXY=0 ;;
    esac

    # A forced forge/neoforge type still needs its args file located.
    if [ -z "${ARGS_FILE}" ]; then
        case "${SERVER_TYPE}" in
            neoforge) ARGS_FILE=$(find_args_file "libraries/net/neoforged/neoforge") || ARGS_FILE="" ;;
            forge)    ARGS_FILE=$(find_args_file "libraries/net/minecraftforge/forge") || ARGS_FILE="" ;;
        esac
    fi
}

# ---------------------------------------------------------------------------
# server.properties management
# ---------------------------------------------------------------------------

# Sets key=value in server.properties, replacing an existing line or appending
# a new one. Skipped entirely when the value is "auto", which is what lets a
# user manage a setting by hand without the panel overwriting it every boot.
set_prop() {
    local key="$1" val="$2"
    is_auto "${val}" && return 0
    [ -f server.properties ] || touch server.properties

    awk -v k="${key}" -v v="${val}" '
        BEGIN { found = 0 }
        index($0, k "=") == 1 { print k "=" v; found = 1; next }
        { print }
        END { if (!found) print k "=" v }
    ' server.properties > server.properties.tmp && mv server.properties.tmp server.properties

    log_info "server.properties: ${key}=${val}"
}

# Typed setters. Each one refuses to write a value it does not understand,
# because a bad value in server.properties stops the server from booting and
# the panel label is the only thing most users ever see.
set_prop_mapped() {
    local key="$1" raw="$2" mapper="$3" val
    is_auto "${raw}" && return 0

    val=$(${mapper} "${raw}")
    if [ -z "${val}" ]; then
        log_warn "Valor no reconocido para '${key}': '${raw}'. No se modifica server.properties."
        return 0
    fi
    set_prop "${key}" "${val}"
}

set_prop_num() {
    local key="$1" raw="$2"
    is_auto "${raw}" && return 0

    case "${raw}" in
        ''|*[!0-9]*)
            log_warn "'${key}' esperaba un numero y recibio '${raw}'. No se modifica server.properties."
            return 0 ;;
    esac
    set_prop "${key}" "${raw}"
}

apply_properties() {
    [ "${IS_PROXY}" = "1" ] && return 0

    set_prop_mapped "online-mode" "${MC_ONLINE_MODE}" map_bool
    set_prop_mapped "difficulty"  "${MC_DIFFICULTY}"  map_difficulty
    set_prop_mapped "gamemode"    "${MC_GAMEMODE}"    map_gamemode
    set_prop_mapped "pvp"         "${MC_PVP}"         map_bool
    set_prop_mapped "white-list"  "${MC_WHITELIST}"   map_bool

    set_prop_num "max-players"   "${MC_MAX_PLAYERS}"
    set_prop_num "view-distance" "${MC_VIEW_DISTANCE}"

    # Free text: whatever the user typed goes in as-is.
    set_prop "motd"       "${MC_MOTD}"
    set_prop "level-name" "${MC_LEVEL_NAME}"
    set_prop "level-seed" "${MC_LEVEL_SEED}"
}

# Proxies keep their bind address in their own config file. The panel's
# server.properties parser cannot reach these, so they are handled here.
apply_proxy_config() {
    # Proxy configs are TOML/YAML, so the panel label has to be mapped to a
    # real boolean here too. Empty means unrecognised, and is skipped.
    local online=""
    is_auto "${MC_ONLINE_MODE}" || online=$(map_bool "${MC_ONLINE_MODE}")

    case "${SERVER_TYPE}" in
        velocity)
            if [ -f velocity.toml ]; then
                sed -i -E "s|^\s*bind\s*=.*|bind = \"0.0.0.0:${SERVER_PORT}\"|" velocity.toml
                log_info "velocity.toml: bind = 0.0.0.0:${SERVER_PORT}"
                if [ -n "${online}" ]; then
                    sed -i -E "s|^\s*online-mode\s*=.*|online-mode = ${online}|" velocity.toml
                    log_info "velocity.toml: online-mode = ${online}"
                fi
                if ! is_auto "${MC_MOTD}"; then
                    sed -i -E "s|^\s*motd\s*=.*|motd = \"${MC_MOTD}\"|" velocity.toml
                    log_info "velocity.toml: motd updated"
                fi
            fi
            ;;
        bungeecord|waterfall)
            if [ -f config.yml ]; then
                sed -i -E "s|^(\s*)host:\s*.*|\1host: 0.0.0.0:${SERVER_PORT}|" config.yml
                sed -i -E "s|^(\s*)query_port:\s*.*|\1query_port: ${SERVER_PORT}|" config.yml
                log_info "config.yml: host = 0.0.0.0:${SERVER_PORT}"
                if [ -n "${online}" ]; then
                    sed -i -E "s|^(\s*)online_mode:\s*.*|\1online_mode: ${online}|" config.yml
                    log_info "config.yml: online_mode = ${online}"
                fi
            fi
            ;;
    esac
}

accept_eula() {
    # Proxies have no EULA.
    [ "${IS_PROXY}" = "1" ] && return 0

    # An unset value counts as accepted. Without this, a server whose egg
    # predates the EULA variable would refuse to boot with an error most
    # customers cannot interpret, which is the single most common ticket.
    if [ -n "${EULA}" ] && ! is_true "${EULA}"; then
        log_warn "La aceptacion automatica del EULA esta desactivada."
        log_warn "El servidor no arrancara hasta que eula.txt diga eula=true."
        return 0
    fi

    if [ ! -f eula.txt ] || ! grep -q '^eula=true' eula.txt 2>/dev/null; then
        echo "eula=true" > eula.txt
        log_ok "EULA de Minecraft aceptado automaticamente (https://aka.ms/MinecraftEULA)"
    fi
}

# ---------------------------------------------------------------------------
# Optimised server configs
#
# Applied once, not on every boot: after the first pass the user owns these
# files. Re-applying would silently undo their tuning every restart.
# ---------------------------------------------------------------------------

OPTIMIZE_MARKER=".multiversion-optimized"
# Bump when the preset below changes, so existing servers pick up the new values.
OPTIMIZE_PRESET_VERSION="1"

# Sets a YAML key only when it already exists. yq would happily create it, but
# inventing keys in a config the server did not write is how you end up with
# settings that do nothing and confuse whoever reads the file later.
yq_set() {
    local file="$1" path="$2" value="$3" current

    [ -f "${file}" ] || return 1
    current=$(yq "${path}" "${file}" 2>/dev/null) || return 1
    [ "${current}" = "null" ] && return 1

    if yq -i "${path} = ${value}" "${file}" 2>/dev/null; then
        OPTIMIZED_COUNT=$((OPTIMIZED_COUNT + 1))
        return 0
    fi
    log_warn "No se pudo aplicar ${path} en ${file}"
    return 1
}

optimize_configs() {
    is_true "${OPTIMIZE_CONFIGS}" || return 0

    # Only Bukkit-based software has these files. Proxies, and pure Forge,
    # NeoForge, Fabric or Quilt servers, have nothing to tune here.
    case "${SERVER_TYPE}" in
        vanilla|mohist|arclight) ;;
        *) log_info "Configuracion optimizada: no aplica a '${SERVER_TYPE}', se omite"; return 0 ;;
    esac

    if [ -f "${OPTIMIZE_MARKER}" ] && [ "$(cat "${OPTIMIZE_MARKER}")" = "${OPTIMIZE_PRESET_VERSION}" ]; then
        return 0
    fi

    # These files only exist after the server has booted at least once.
    if [ ! -f bukkit.yml ] && [ ! -f spigot.yml ]; then
        log_info "Configuracion optimizada: los archivos aun no existen, se aplicara en el proximo arranque"
        return 0
    fi

    OPTIMIZED_COUNT=0
    log_info "Aplicando configuracion optimizada (una sola vez)..."

    # --- bukkit.yml: fewer mobs alive at once, cheaper autosave -----------
    yq_set bukkit.yml '.spawn-limits.monsters'       '50'
    yq_set bukkit.yml '.spawn-limits.animals'        '10'
    yq_set bukkit.yml '.spawn-limits.water-animals'  '5'
    yq_set bukkit.yml '.spawn-limits.water-ambient'  '5'
    yq_set bukkit.yml '.spawn-limits.ambient'        '1'
    yq_set bukkit.yml '.ticks-per.monster-spawns'    '4'
    yq_set bukkit.yml '.ticks-per.autosave'          '6000'
    yq_set bukkit.yml '.chunk-gc.period-in-ticks'    '400'

    # --- spigot.yml: shrink activation ranges, merge dropped items --------
    yq_set spigot.yml '.world-settings.default.mob-spawn-range'                '6'
    yq_set spigot.yml '.world-settings.default.entity-activation-range.animals'  '16'
    yq_set spigot.yml '.world-settings.default.entity-activation-range.monsters' '24'
    yq_set spigot.yml '.world-settings.default.entity-activation-range.misc'     '8'
    yq_set spigot.yml '.world-settings.default.merge-radius.item'              '3.5'
    yq_set spigot.yml '.world-settings.default.merge-radius.exp'               '4.0'
    yq_set spigot.yml '.world-settings.default.max-entity-collisions'          '2'

    # --- Paper 1.19+ (config/) --------------------------------------------
    # ALTERNATE_CURRENT is a redstone implementation that is much cheaper and
    # behaviour-compatible for anything that is not a timing-exact contraption.
    yq_set config/paper-world-defaults.yml '.chunks.max-auto-save-chunks-per-tick'          '8'
    yq_set config/paper-world-defaults.yml '.environment.optimize-explosions'               'true'
    yq_set config/paper-world-defaults.yml '.misc.redstone-implementation'                  '"ALTERNATE_CURRENT"'
    yq_set config/paper-world-defaults.yml '.entities.spawning.despawn-ranges.monster.soft' '28'
    yq_set config/paper-world-defaults.yml '.entities.spawning.despawn-ranges.monster.hard' '96'
    yq_set config/paper-world-defaults.yml '.tick-rates.mob-spawner'                        '2'
    yq_set config/paper-global.yml         '.misc.region-file-cache-size'                   '256'

    # --- Paper before 1.19 (single paper.yml) ------------------------------
    yq_set paper.yml '.world-settings.default.max-auto-save-chunks-per-tick' '8'
    yq_set paper.yml '.world-settings.default.optimize-explosions'           'true'

    echo "${OPTIMIZE_PRESET_VERSION}" > "${OPTIMIZE_MARKER}"
    log_ok "Configuracion optimizada aplicada: ${OPTIMIZED_COUNT} ajustes"
    log_info "A partir de ahora estos archivos son tuyos: no se volveran a tocar."
}

# ---------------------------------------------------------------------------
# Geyser and Floodgate (Bedrock players)
# ---------------------------------------------------------------------------

install_geyser() {
    is_true "${INSTALL_GEYSER}" || return 0

    # Each platform needs its own build of the plugin.
    local variant plugin_dir fg_variant
    case "${SERVER_TYPE}" in
        velocity)             variant="velocity";   fg_variant="velocity"; plugin_dir="plugins" ;;
        bungeecord|waterfall) variant="bungeecord"; fg_variant="bungee";   plugin_dir="plugins" ;;
        vanilla|mohist|arclight) variant="spigot";  fg_variant="spigot";   plugin_dir="plugins" ;;
        *)
            log_warn "Geyser no es compatible con '${SERVER_TYPE}', se omite"
            return 0 ;;
    esac

    mkdir -p "${plugin_dir}"
    local base="https://download.geysermc.org/v2/projects"

    if [ ! -f "${plugin_dir}/Geyser-${variant}.jar" ] || is_true "${GEYSER_AUTO_UPDATE}"; then
        log_info "Descargando Geyser (${variant})..."
        if curl "${CURL_OPTS[@]}" -o "${plugin_dir}/Geyser-${variant}.jar.tmp" \
            "${base}/geyser/versions/latest/builds/latest/downloads/${variant}"; then
            mv "${plugin_dir}/Geyser-${variant}.jar.tmp" "${plugin_dir}/Geyser-${variant}.jar"
            log_ok "Geyser instalado"
        else
            rm -f "${plugin_dir}/Geyser-${variant}.jar.tmp"
            log_error "No se pudo descargar Geyser"
        fi
    fi

    if [ ! -f "${plugin_dir}/floodgate-${fg_variant}.jar" ] || is_true "${GEYSER_AUTO_UPDATE}"; then
        log_info "Descargando Floodgate (${fg_variant})..."
        if curl "${CURL_OPTS[@]}" -o "${plugin_dir}/floodgate-${fg_variant}.jar.tmp" \
            "${base}/floodgate/versions/latest/builds/latest/downloads/${fg_variant}"; then
            mv "${plugin_dir}/floodgate-${fg_variant}.jar.tmp" "${plugin_dir}/floodgate-${fg_variant}.jar"
            log_ok "Floodgate instalado"
        else
            rm -f "${plugin_dir}/floodgate-${fg_variant}.jar.tmp"
            log_error "No se pudo descargar Floodgate"
        fi
    fi

    log_warn "Geyser necesita un puerto UDP propio (por defecto 19132)."
    log_warn "Asignalo en el nodo y configuralo en plugins/Geyser-Spigot/config.yml"
}

# ---------------------------------------------------------------------------
# Client-only mod detection
#
# The usual reason a modpack refuses to start on a server is a client-only mod
# referencing net.minecraft.client.* classes that simply do not exist in the
# server jar. No display trick fixes that: the client code is not there.
#
# Fabric and Quilt mods declare their side explicitly, so those are detected
# with certainty. Forge has no standard equivalent field, so known offenders
# are matched by file name as a fallback.
# ---------------------------------------------------------------------------

DISABLED_MODS_DIR="mods-desactivados"

# Fallback list for Forge, where the side is not declared. Kept conservative on
# purpose: only mods that are unambiguously client-side. Anything with a real
# server component is left out, because a false positive silently removes
# content the pack needed and is harder to debug than the original crash.
CLIENT_ONLY_NAMES="optifine optifabric oculus iris rubidium embeddium sodium
    reeses-sodium sodium-extra indium controllable mousetweaks mouse-tweaks
    betterf3 better-f3 zoomify litematica replaymod distanthorizons
    distant-horizons entityculling entity-culling shouldersurfing
    firstperson first-person notenoughanimations ambientsounds soundphysics
    sound-physics dynamicsurroundings itemphysic xaeros"

# Extracts one file from a jar, stripping a UTF-8 BOM if present. jq chokes on
# a BOM, and some mods do ship their metadata with one.
mod_file() {
    unzip -p "$1" "$2" 2>/dev/null | sed '1s/^\xEF\xBB\xBF//'
}

# True when the mod itself declares that it only runs on the client.
mod_declares_client() {
    local jar="$1" env

    # Fabric: "environment": "client" | "server" | "*"
    env=$(mod_file "${jar}" fabric.mod.json | jq -r '.environment // empty' 2>/dev/null)
    [ "${env}" = "client" ] && return 0

    # Quilt: minecraft.environment, same meaning.
    env=$(mod_file "${jar}" quilt.mod.json | jq -r '.minecraft.environment // empty' 2>/dev/null)
    [ "${env}" = "client" ] && return 0

    # Forge/NeoForge only sometimes declare this, and when they do the same
    # "side" key also appears inside [[dependencies.*]] blocks, where it
    # describes the dependency and not this mod. Matching those would disable
    # perfectly good universal mods, so only side declarations outside a
    # dependencies block count.
    #
    # Queried one file at a time: passing both names to unzip makes it fail
    # outright when one of them is absent, which is the normal case.
    local toml
    for toml in META-INF/neoforge.mods.toml META-INF/mods.toml; do
        if mod_file "${jar}" "${toml}" | awk '
            /^[[:space:]]*\[\[?dependencies/ { in_deps = 1; next }
            /^[[:space:]]*\[\[mods\]\]/      { in_deps = 0; next }
            /^[[:space:]]*\[/                { if ($0 !~ /dependencies/) in_deps = 0 }
            !in_deps && tolower($0) ~ /^[[:space:]]*side[[:space:]]*=[[:space:]]*"?client"?/ { found = 1 }
            END { exit !found }
        '; then
            return 0
        fi
    done

    return 1
}

mod_name_is_known_client() {
    local base pattern
    base=$(basename "$1" | tr '[:upper:]' '[:lower:]')
    for pattern in ${CLIENT_ONLY_NAMES}; do
        case "${base}" in
            *"${pattern}"*) return 0 ;;
        esac
    done
    return 1
}

scan_client_mods() {
    local action
    action=$(normalize_value "${CLIENT_MODS_ACTION:-avisar}")
    case "${action}" in
        "no revisar"|ignorar|off|0|no) return 0 ;;
    esac

    [ -d mods ] || return 0
    ls mods/*.jar >/dev/null 2>&1 || return 0

    local jar found=0 reason
    local names=""

    for jar in mods/*.jar; do
        reason=""
        if mod_declares_client "${jar}"; then
            reason="declarado como solo cliente"
        elif mod_name_is_known_client "${jar}"; then
            reason="mod conocido de solo cliente"
        fi

        if [ -n "${reason}" ]; then
            found=$((found + 1))
            names="${names}      - $(basename "${jar}") (${reason})
"
        fi
    done

    [ "${found}" -eq 0 ] && return 0

    echo
    log_warn "Se detectaron ${found} mod(s) que solo funcionan en el cliente:"
    printf '%s' "${names}"
    log_warn "Estos mods no existen en la version de servidor y suelen impedir que arranque."

    case "${action}" in
        mover*|move*)
            mkdir -p "${DISABLED_MODS_DIR}"
            for jar in mods/*.jar; do
                if mod_declares_client "${jar}" || mod_name_is_known_client "${jar}"; then
                    mv "${jar}" "${DISABLED_MODS_DIR}/" 2>/dev/null \
                        && log_ok "Movido: $(basename "${jar}")"
                fi
            done
            log_ok "Los mods se movieron a ${DISABLED_MODS_DIR}/. Para recuperarlos, devuelvelos a mods/."
            ;;
        *)
            log_warn "Accion configurada: solo avisar. Borralos o muevelos fuera de mods/ para continuar."
            ;;
    esac
    echo
}

# ---------------------------------------------------------------------------
# Startup diagnostics
# ---------------------------------------------------------------------------

print_diagnostics() {
    is_true "${SHOW_DIAGNOSTICS}" || return 0

    local plugins=0 mods=0
    [ -d plugins ] && plugins=$(ls -1 plugins/*.jar 2>/dev/null | wc -l)
    [ -d mods ] && mods=$(ls -1 mods/*.jar 2>/dev/null | wc -l)

    echo
    echo "${C_INFO}--- Resumen del servidor ---${C_RESET}"
    printf '  Software    : %s\n' "${SERVER_TYPE}"
    printf '  Java        : %s (version %s)\n' "${JAVA_RAW}" "${JAVA_MAJOR}"
    printf '  Memoria     : %s MB asignados\n' "${SERVER_MEMORY}"
    [ "${plugins}" -gt 0 ] && printf '  Plugins     : %s\n' "${plugins}"
    [ "${mods}" -gt 0 ] && printf '  Mods        : %s\n' "${mods}"

    local vd=""
    [ -f server.properties ] && vd=$(grep -E '^view-distance=' server.properties 2>/dev/null | cut -d= -f2)
    [ -n "${vd}" ] && printf '  Distancia   : %s chunks\n' "${vd}"

    # --- Memory warnings ---------------------------------------------------
    # Thresholds are deliberately loose: the goal is to catch the obviously
    # broken setups that generate support tickets, not to be precise.
    if [ "${SERVER_MEMORY}" -lt 1024 ]; then
        log_warn "Menos de 1 GB de RAM. Minecraft moderno necesita 2 GB o mas para funcionar bien."
    fi
    if [ "${mods}" -gt 50 ] && [ "${SERVER_MEMORY}" -lt 4096 ]; then
        log_warn "${mods} mods con solo ${SERVER_MEMORY} MB. Un modpack de este tamano suele necesitar 4-6 GB."
    fi
    if [ -n "${vd}" ] && [ "${vd}" -gt 12 ] 2>/dev/null && [ "${SERVER_MEMORY}" -lt 4096 ]; then
        log_warn "Distancia de renderizado ${vd} con ${SERVER_MEMORY} MB. Bajarla a 8 mejoraria bastante el rendimiento."
    fi

    # The JVM cannot grow past the container limit, so an Xmx at 100% of the
    # allocation leaves nothing for the JVM's own non-heap memory and gets the
    # container OOM-killed rather than throwing a Java error.
    if ! is_true "${LOWER_XMX}" && [ "${SERVER_MEMORY}" -ge 4096 ]; then
        log_info "Con esta memoria, activar 'Reservar memoria para el sistema' suele evitar cierres inesperados."
    fi

    echo "${C_INFO}----------------------------${C_RESET}"
    echo
}

# ---------------------------------------------------------------------------
# Auto-update
#
# Scope note: only plain-jar software is updated. Forge, NeoForge, Fabric and
# Quilt are deliberately excluded because updating them means regenerating the
# whole libraries/ tree, which cannot be done safely from here without risking
# an unbootable server. Reinstall those through the panel instead.
# ---------------------------------------------------------------------------

STATE_FILE=".multiversion-update"

# Checks a download against the hash the API published for it. A truncated or
# corrupted jar otherwise fails later as an unreadable Java error, which is far
# harder to diagnose than "the download does not match".
# No hash available means no check: not every project publishes one.
verify_checksum() {
    local file="$1" expected="$2" algo="${3:-sha256}" actual

    [ -z "${expected}" ] && return 0
    [ "${expected}" = "null" ] && return 0

    case "${algo}" in
        sha1) actual=$(sha1sum "${file}" 2>/dev/null | awk '{print $1}') ;;
        *)    actual=$(sha256sum "${file}" 2>/dev/null | awk '{print $1}') ;;
    esac

    if [ -z "${actual}" ]; then
        log_warn "No se pudo calcular el hash de la descarga, se omite la comprobacion"
        return 0
    fi

    if [ "${actual}" != "${expected}" ]; then
        log_error "La descarga esta corrupta: el hash no coincide con el publicado."
        log_error "Se conserva la version anterior."
        return 1
    fi

    log_info "Integridad de la descarga verificada (${algo})"
    return 0
}

# Resolves the newest Minecraft version for a PaperMC project. The v3 endpoint
# returns versions grouped by family, newest family first.
#
# Released versions are preferred over in-development ones: Velocity's newest
# entry is a -SNAPSHOT branch, and "latest" should not put anyone on that.
# Filtering by build channel does not help, because snapshot versions still
# publish their builds under the STABLE channel.
paper_latest_version() {
    local project="$1"
    curl "${CURL_OPTS[@]}" "https://fill.papermc.io/v3/projects/${project}" 2>/dev/null \
        | jq -r '
            [ .versions | to_entries[] | .value[] ] as $all
            | ( [ $all[] | select(test("-(SNAPSHOT|rc|pre)") | not) ][0] // $all[0] // empty )'
}

# Prints "<build id> <download url>" for the newest build on the requested
# channel, falling back to the newest build of any channel.
paper_latest_build() {
    local project="$1" version="$2" channel="$3"
    curl "${CURL_OPTS[@]}" "https://fill.papermc.io/v3/projects/${project}/versions/${version}/builds" 2>/dev/null \
        | jq -r --arg ch "${channel}" '
            ( [ .[] | select(.channel == $ch) ][0] // .[0] ) as $b
            | if $b == null then empty
              else "\($b.id) \($b.downloads["server:default"].url) \($b.downloads["server:default"].checksums.sha256 // "")"
              end'
}

update_paper_family() {
    local project="$1" version="$2" channel="$3"

    if is_auto "${version}" || [ "${version}" = "latest" ]; then
        version=$(paper_latest_version "${project}")
        [ -z "${version}" ] && { log_warn "No se pudo determinar la ultima version de ${project}, se omite"; return 1; }
    fi

    local result build url
    result=$(paper_latest_build "${project}" "${version}" "${channel}")
    [ -z "${result}" ] && { log_warn "No hay builds de ${project} para ${version}, se omite"; return 1; }

    read -r build url sha <<< "${result}"

    local marker="${project}-${version}-${build}"
    if [ -f "${STATE_FILE}" ] && [ "$(cat "${STATE_FILE}")" = "${marker}" ] && [ -f "${SERVER_JARFILE}" ]; then
        log_ok "${project} ${version} build ${build} ya esta actualizado"
        return 0
    fi

    log_info "Descargando ${project} ${version} build ${build}"
    if curl "${CURL_OPTS[@]}" -o "${SERVER_JARFILE}.tmp" "${url}"; then
        if ! verify_checksum "${SERVER_JARFILE}.tmp" "${sha}" sha256; then
            rm -f "${SERVER_JARFILE}.tmp"
            return 1
        fi
        mv "${SERVER_JARFILE}.tmp" "${SERVER_JARFILE}"
        echo "${marker}" > "${STATE_FILE}"
        log_ok "Actualizado a ${project} ${version} build ${build}"
    else
        rm -f "${SERVER_JARFILE}.tmp"
        log_error "Fallo la descarga, se mantiene la version actual"
        return 1
    fi
}

update_purpur() {
    local version="$1"

    if is_auto "${version}" || [ "${version}" = "latest" ]; then
        version=$(curl "${CURL_OPTS[@]}" "https://api.purpurmc.org/v2/purpur" 2>/dev/null | jq -r '.metadata.current // .versions[-1] // empty')
        [ -z "${version}" ] && { log_warn "No se pudo determinar la ultima version de Purpur, se omite"; return 1; }
    fi

    local build
    build=$(curl "${CURL_OPTS[@]}" "https://api.purpurmc.org/v2/purpur/${version}" 2>/dev/null | jq -r '.builds.latest // empty')
    [ -z "${build}" ] && { log_warn "No hay builds de Purpur para ${version}, se omite"; return 1; }

    local marker="purpur-${version}-${build}"
    if [ -f "${STATE_FILE}" ] && [ "$(cat "${STATE_FILE}")" = "${marker}" ] && [ -f "${SERVER_JARFILE}" ]; then
        log_ok "Purpur ${version} build ${build} ya esta actualizado"
        return 0
    fi

    log_info "Descargando Purpur ${version} build ${build}"
    if curl "${CURL_OPTS[@]}" -o "${SERVER_JARFILE}.tmp" "https://api.purpurmc.org/v2/purpur/${version}/${build}/download"; then
        mv "${SERVER_JARFILE}.tmp" "${SERVER_JARFILE}"
        echo "${marker}" > "${STATE_FILE}"
        log_ok "Actualizado a Purpur ${version} build ${build}"
    else
        rm -f "${SERVER_JARFILE}.tmp"
        log_error "Fallo la descarga, se mantiene la version actual"
        return 1
    fi
}

update_leaves() {
    local version="$1"

    if is_auto "${version}" || [ "${version}" = "latest" ]; then
        version=$(curl "${CURL_OPTS[@]}" "https://api.leavesmc.org/v2/projects/leaves" 2>/dev/null | jq -r '.versions[-1] // empty')
        [ -z "${version}" ] && { log_warn "No se pudo determinar la ultima version de Leaves, se omite"; return 1; }
    fi

    local build
    build=$(curl "${CURL_OPTS[@]}" "https://api.leavesmc.org/v2/projects/leaves/versions/${version}" 2>/dev/null | jq -r '.builds[-1] // empty')
    [ -z "${build}" ] && { log_warn "No hay builds de Leaves para ${version}, se omite"; return 1; }

    local marker="leaves-${version}-${build}"
    if [ -f "${STATE_FILE}" ] && [ "$(cat "${STATE_FILE}")" = "${marker}" ] && [ -f "${SERVER_JARFILE}" ]; then
        log_ok "Leaves ${version} build ${build} ya esta actualizado"
        return 0
    fi

    # One request, both fields: the name for the URL and the hash to verify it.
    local meta name sha
    meta=$(curl "${CURL_OPTS[@]}" "https://api.leavesmc.org/v2/projects/leaves/versions/${version}/builds/${build}" 2>/dev/null)
    name=$(echo "${meta}" | jq -r '.downloads.application.name // empty')
    sha=$(echo "${meta}" | jq -r '.downloads.application.sha256 // empty')
    [ -z "${name}" ] && { log_warn "No se pudo resolver la descarga de Leaves, se omite"; return 1; }

    log_info "Descargando Leaves ${version} build ${build}"
    if curl "${CURL_OPTS[@]}" -o "${SERVER_JARFILE}.tmp" \
        "https://api.leavesmc.org/v2/projects/leaves/versions/${version}/builds/${build}/downloads/${name}"; then
        if ! verify_checksum "${SERVER_JARFILE}.tmp" "${sha}" sha256; then
            rm -f "${SERVER_JARFILE}.tmp"
            return 1
        fi
        mv "${SERVER_JARFILE}.tmp" "${SERVER_JARFILE}"
        echo "${marker}" > "${STATE_FILE}"
        log_ok "Actualizado a Leaves ${version} build ${build}"
    else
        rm -f "${SERVER_JARFILE}.tmp"
        log_error "Fallo la descarga, se mantiene el jar actual"
        return 1
    fi
}

# Pufferfish publishes on Jenkins, one job per Minecraft minor.
update_pufferfish() {
    local version="$1" job

    if is_auto "${version}" || [ "${version}" = "latest" ]; then
        job=$(curl "${CURL_OPTS[@]}" "https://ci.pufferfish.host/api/json?tree=jobs[name]" 2>/dev/null \
            | jq -r '[.jobs[].name | select(test("^Pufferfish-[0-9]"))] | sort_by(split("-")[1] | split(".") | map(tonumber)) | last // empty')
    else
        job="Pufferfish-$(echo "${version}" | cut -d. -f1,2)"
    fi
    [ -z "${job}" ] && { log_warn "No se pudo determinar el job de Pufferfish, se omite"; return 1; }

    local info build art
    info=$(curl "${CURL_OPTS[@]}" "https://ci.pufferfish.host/job/${job}/lastSuccessfulBuild/api/json?tree=number,artifacts[relativePath]" 2>/dev/null)
    build=$(echo "${info}" | jq -r '.number // empty')
    art=$(echo "${info}" | jq -r '.artifacts[0].relativePath // empty')
    [ -z "${art}" ] && { log_warn "No se encontro artefacto en ${job}, se omite"; return 1; }

    local marker="pufferfish-${job}-${build}"
    if [ -f "${STATE_FILE}" ] && [ "$(cat "${STATE_FILE}")" = "${marker}" ] && [ -f "${SERVER_JARFILE}" ]; then
        log_ok "Pufferfish ${job} build ${build} ya esta actualizado"
        return 0
    fi

    log_info "Descargando Pufferfish ${job} build ${build}"
    if curl "${CURL_OPTS[@]}" -o "${SERVER_JARFILE}.tmp" \
        "https://ci.pufferfish.host/job/${job}/lastSuccessfulBuild/artifact/${art}"; then
        mv "${SERVER_JARFILE}.tmp" "${SERVER_JARFILE}"
        echo "${marker}" > "${STATE_FILE}"
        log_ok "Actualizado a Pufferfish ${job} build ${build}"
    else
        rm -f "${SERVER_JARFILE}.tmp"
        log_error "Fallo la descarga, se mantiene el jar actual"
        return 1
    fi
}

update_vanilla() {
    local version="$1"
    local manifest="https://launchermeta.mojang.com/mc/game/version_manifest.json"
    local json
    json=$(curl "${CURL_OPTS[@]}" "${manifest}" 2>/dev/null)
    [ -z "${json}" ] && { log_warn "No se pudo contactar con el servidor de Mojang, se omite"; return 1; }

    if is_auto "${version}" || [ "${version}" = "latest" ]; then
        version=$(echo "${json}" | jq -r '.latest.release')
    elif [ "${version}" = "snapshot" ]; then
        version=$(echo "${json}" | jq -r '.latest.snapshot')
    fi

    local marker="vanilla-${version}"
    if [ -f "${STATE_FILE}" ] && [ "$(cat "${STATE_FILE}")" = "${marker}" ] && [ -f "${SERVER_JARFILE}" ]; then
        log_ok "Vanilla ${version} ya esta actualizado"
        return 0
    fi

    local version_url download_url
    version_url=$(echo "${json}" | jq -r --arg v "${version}" '.versions[] | select(.id == $v) | .url')
    [ -z "${version_url}" ] && { log_warn "No existe la version de Vanilla ${version}, se omite"; return 1; }

    # One request, both fields. Mojang publishes sha1 rather than sha256.
    local meta sha
    meta=$(curl "${CURL_OPTS[@]}" "${version_url}" 2>/dev/null)
    download_url=$(echo "${meta}" | jq -r '.downloads.server.url // empty')
    sha=$(echo "${meta}" | jq -r '.downloads.server.sha1 // empty')
    [ -z "${download_url}" ] && { log_warn "Vanilla ${version} no tiene archivo de servidor, se omite"; return 1; }

    log_info "Descargando Vanilla ${version}"
    if curl "${CURL_OPTS[@]}" -o "${SERVER_JARFILE}.tmp" "${download_url}"; then
        if ! verify_checksum "${SERVER_JARFILE}.tmp" "${sha}" sha1; then
            rm -f "${SERVER_JARFILE}.tmp"
            return 1
        fi
        mv "${SERVER_JARFILE}.tmp" "${SERVER_JARFILE}"
        echo "${marker}" > "${STATE_FILE}"
        log_ok "Actualizado a Vanilla ${version}"
    else
        rm -f "${SERVER_JARFILE}.tmp"
        log_error "Fallo la descarga, se mantiene la version actual"
        return 1
    fi
}

# The installer's marker records what IT put on disk, but a version-manager
# addon can replace the software afterwards without ever touching the marker.
# So the marker is only trusted while it still agrees with what is actually
# installed right now.
# Paper forks all look identical from the outside: a plain jar detected as
# "vanilla". They do record their own name in version_history.json once they
# have booted, which is the only way to tell Purpur from Paper on disk.
# Returns nothing when the file is absent, i.e. before the first boot.
detect_fork_name() {
    [ -f version_history.json ] || return 1
    local current
    current=$(jq -r '.currentVersion // empty' version_history.json 2>/dev/null | tr '[:upper:]' '[:lower:]')
    case "${current}" in
        *purpur*)     echo "purpur" ;;
        *pufferfish*) echo "pufferfish" ;;
        *leaves*)     echo "leaves" ;;
        *folia*)      echo "folia" ;;
        *paper*)      echo "paper" ;;
        *)            return 1 ;;
    esac
}

marker_matches_type() {
    local fork
    case "$1" in
        # Every Paper fork is a plain jar and detects as "vanilla".
        paper|purpur|pufferfish|leaves|folia|vanilla)
            [ "${SERVER_TYPE}" = "vanilla" ] || return 1
            # Same family, but possibly a different fork than the one recorded.
            if fork=$(detect_fork_name); then
                [ "${fork}" = "$1" ] || return 1
            fi
            return 0 ;;
        velocity)  [ "${SERVER_TYPE}" = "velocity" ] ;;
        waterfall) [ "${SERVER_TYPE}" = "bungeecord" ] ;;
        fabric)    [ "${SERVER_TYPE}" = "fabric" ] ;;
        mohist)    [ "${SERVER_TYPE}" = "mohist" ] ;;
        arclight)  [ "${SERVER_TYPE}" = "arclight" ] ;;
        *)         return 1 ;;
    esac
}

run_auto_update() {
    is_true "${AUTO_UPDATE}" || return 0

    local project="${UPDATE_PROJECT}" marker=""
    if is_auto "${project}"; then
        # Purpur, Leaves and Pufferfish are all plain jars and all detect as
        # "vanilla", so guessing the project from the detected type would
        # quietly replace the customer's server software with Paper. What the
        # installer recorded is the only reliable source here.
        if [ -f .multiversion-software ]; then
            marker=$(cat .multiversion-software)
            if marker_matches_type "${marker}"; then
                project="${marker}"
            else
                log_warn "El software instalado ahora es '${SERVER_TYPE}', pero el egg registro '${marker}'."
                log_warn "Seguramente se cambio desde el gestor de versiones. No se actualizara nada."
                log_warn "Si quieres actualizaciones automaticas, elige el software a mano en 'Que actualizar'."
                return 0
            fi
        else
            case "${SERVER_TYPE}" in
                velocity)   project="velocity" ;;
                bungeecord) project="waterfall" ;;
                *)          project="" ;;
            esac
        fi
    fi

    if [ -z "${project}" ] || [ "${project}" = "none" ]; then
        log_warn "La actualizacion automatica esta activada pero no se pudo determinar que software actualizar."
        log_warn "Elige uno en 'Que actualizar', o reinstala desde el panel para cambiar de version."
        return 0
    fi

    log_info "Actualizacion automatica: comprobando ${project}"
    case "${project}" in
        paper|folia|velocity|waterfall)
            update_paper_family "${project}" "${UPDATE_MC_VERSION}" "${UPDATE_CHANNEL:-STABLE}" ;;
        purpur)
            update_purpur "${UPDATE_MC_VERSION}" ;;
        leaves)
            update_leaves "${UPDATE_MC_VERSION}" ;;
        pufferfish)
            update_pufferfish "${UPDATE_MC_VERSION}" ;;
        vanilla)
            update_vanilla "${UPDATE_MC_VERSION}" ;;
        mohist|arclight|fabric|quilt|forge|neoforge)
            log_warn "'${project}' no se puede actualizar solo: hay que regenerar sus librerias."
            log_warn "Reinstala desde el panel para cambiar de version." ;;
        *)
            log_warn "Proyecto de actualizacion desconocido: '${project}'. Se omite." ;;
    esac
}

# ---------------------------------------------------------------------------
# JVM flags
# ---------------------------------------------------------------------------

JVM_FLAGS=()

build_memory_flags() {
    local xms="${SERVER_MIN_MEMORY:-128}"

    if is_true "${LOWER_XMX}"; then
        # Let the JVM size the heap from the container limit instead of pinning
        # Xmx to the full allocation, which leaves headroom for native memory.
        JVM_FLAGS+=("-XX:MaxRAMPercentage=${MAX_RAM_PERCENTAGE:-80.0}")
        log_info "Memoria: hasta ${MAX_RAM_PERCENTAGE:-80.0}% del total (reserva para el sistema activada)"
    else
        JVM_FLAGS+=("-Xms${xms}M" "-Xmx${SERVER_MEMORY}M")
        log_info "Memoria: ${xms} MB minimo, ${SERVER_MEMORY} MB maximo"
    fi
}

build_gc_flags() {
    local gc
    gc=$(echo "${GC_TYPE:-auto}" | tr '[:upper:]' '[:lower:]')

    # Aikar's flags are a complete G1 tuning set; they conflict with picking a
    # different collector, so they take precedence and short-circuit.
    if is_true "${AIKAR_FLAGS}" && [ "${IS_PROXY}" != "1" ]; then
        JVM_FLAGS+=(
            -XX:+UseG1GC
            -XX:+ParallelRefProcEnabled
            -XX:MaxGCPauseMillis=200
            -XX:+UnlockExperimentalVMOptions
            -XX:+DisableExplicitGC
            -XX:+AlwaysPreTouch
            -XX:G1NewSizePercent=30
            -XX:G1MaxNewSizePercent=40
            -XX:G1HeapRegionSize=8M
            -XX:G1ReservePercent=20
            -XX:G1HeapWastePercent=5
            -XX:G1MixedGCCountTarget=4
            -XX:InitiatingHeapOccupancyPercent=15
            -XX:G1MixedGCLiveThresholdPercent=90
            -XX:G1RSetUpdatingPauseTimePercent=5
            -XX:SurvivorRatio=32
            -XX:+PerfDisableSharedMem
            -XX:MaxTenuringThreshold=1
            -Dusing.aikars.flags=https://mcflags.emc.gs
            -Daikars.new.flags=true
        )
        log_ok "Optimizaciones de Aikar activadas"
        return 0
    fi

    # Velocity's documented flag set, which is not the same as Aikar's.
    if [ "${SERVER_TYPE}" = "velocity" ] && is_true "${AIKAR_FLAGS}"; then
        JVM_FLAGS+=(
            -XX:+UseG1GC
            -XX:G1HeapRegionSize=4M
            -XX:+UnlockExperimentalVMOptions
            -XX:+ParallelRefProcEnabled
            -XX:+AlwaysPreTouch
            -XX:MaxInlineLevel=15
        )
        log_ok "Optimizaciones recomendadas de Velocity activadas"
        return 0
    fi

    case "${gc}" in
        g1)
            JVM_FLAGS+=(-XX:+UseG1GC)
            log_info "Recolector de memoria: G1" ;;
        zgc)
            if [ "${JAVA_MAJOR}" -ge 15 ]; then
                JVM_FLAGS+=(-XX:+UseZGC)
                log_info "Recolector de memoria: ZGC"
            else
                log_warn "ZGC necesita Java 15 o superior. Se usa el recolector por defecto."
            fi ;;
        zgc-gen|generational-zgc)
            if [ "${JAVA_MAJOR}" -ge 24 ]; then
                # Generational mode is the default from 24 onwards and the
                # explicit flag was removed, so passing it aborts the JVM.
                JVM_FLAGS+=(-XX:+UseZGC)
                log_info "Recolector de memoria: ZGC generacional (por defecto en Java ${JAVA_MAJOR})"
            elif [ "${JAVA_MAJOR}" -ge 21 ]; then
                JVM_FLAGS+=(-XX:+UseZGC -XX:+ZGenerational)
                log_info "Recolector de memoria: ZGC generacional"
            else
                log_warn "ZGC generacional necesita Java 21 o superior. Se usa el recolector por defecto."
            fi ;;
        shenandoah)
            JVM_FLAGS+=(-XX:+UnlockExperimentalVMOptions -XX:+UseShenandoahGC)
            log_info "Recolector de memoria: Shenandoah (no disponible en todas las imagenes)" ;;
        *)
            : ;;
    esac
}

build_compat_flags() {
    # Pterodactyl's console is not a TTY; without these the server prints
    # escape garbage or swallows output entirely.
    JVM_FLAGS+=(-Dterminal.jline=false -Dterminal.ansi=true)

    if is_true "${LOG4J2_VULN_WORKAROUND}"; then
        JVM_FLAGS+=(-Dlog4j2.formatMsgNoLookups=true)
        log_warn "Proteccion Log4j2 activada. No sustituye a actualizar el servidor a una version parcheada."
    fi

    if is_true "${SIMD_OPERATIONS}"; then
        if [ "${JAVA_MAJOR}" -ge 16 ]; then
            JVM_FLAGS+=(--add-modules=jdk.incubator.vector)
            log_info "Operaciones SIMD activadas"
        else
            log_warn "Las operaciones SIMD necesitan Java 16 o superior, se omiten"
        fi
    fi

    JVM_FLAGS+=("-Duser.timezone=${TZ}")

    if [ -n "${EXTRA_JAVA_ARGS}" ]; then
        # Deliberately unquoted: the user is supplying a flag list.
        # shellcheck disable=SC2206
        JVM_FLAGS+=(${EXTRA_JAVA_ARGS})
        log_info "Argumentos Java adicionales: ${EXTRA_JAVA_ARGS}"
    fi
}

# ---------------------------------------------------------------------------
# Pre-flight validation
# ---------------------------------------------------------------------------

# Minimum Java feature version required by each Minecraft release, used to warn
# before the JVM produces an UnsupportedClassVersionError nobody can read.
required_java_for() {
    local mc="$1"
    case "${mc}" in
        1.8*|1.9*|1.10*|1.11*|1.12*)   echo 8 ;;
        1.13*|1.14*|1.15*|1.16*)       echo 8 ;;
        1.17*)                         echo 16 ;;
        1.18*|1.19*|1.20.[0-4]*)       echo 17 ;;
        1.20*|1.21*)                   echo 21 ;;
        # Calendar-versioned releases (25.x, 26.x and later) are all Java 21+.
        2[0-9].*)                      echo 21 ;;
        *)                             echo 0 ;;
    esac
}

validate() {
    is_true "${VALIDATE_STARTUP}" || return 0

    # The launch target must actually exist.
    if [ -n "${ARGS_FILE}" ]; then
        if [ ! -f "${ARGS_FILE}" ]; then
            log_error "Falta el archivo de argumentos '${ARGS_FILE}'. Reinstala el servidor desde el panel."
            return 1
        fi
    elif [ ! -f "${SERVER_JARFILE}" ]; then
        log_error "No se encuentra el archivo '${SERVER_JARFILE}' en la carpeta del servidor."
        log_error "Revisa la opcion 'Archivo JAR del servidor', o reinstala el servidor."
        return 1
    fi

    # Warn when the image's Java is too old for the installed game version.
    if [ -f server.properties ] || [ -n "${MC_VERSION_HINT}" ]; then
        local mc="${MC_VERSION_HINT}"
        if [ -z "${mc}" ] && [ -f version_history.json ]; then
            mc=$(jq -r '.currentVersion // empty' version_history.json 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
        fi
        if [ -n "${mc}" ]; then
            local need
            need=$(required_java_for "${mc}")
            if [ "${need}" -gt 0 ] && [ "${JAVA_MAJOR}" -lt "${need}" ]; then
                log_warn "Minecraft ${mc} necesita Java ${need} o superior, y esta imagen tiene Java ${JAVA_MAJOR}."
                log_warn "Cambia la version de Java en el panel o el servidor no arrancara."
            fi
        fi
    fi

    if [ "${IS_PROXY}" != "1" ] && ! grep -q '^eula=true' eula.txt 2>/dev/null; then
        log_warn "El EULA no esta aceptado. El servidor se cerrara nada mas arrancar."
        log_warn "Activa la opcion 'Aceptar el EULA de Minecraft' o edita el archivo eula.txt."
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Startup command assembly
# ---------------------------------------------------------------------------

build_command() {
    CMD=(java)
    build_memory_flags
    build_gc_flags
    build_compat_flags
    CMD+=("${JVM_FLAGS[@]}")

    if [ -n "${ARGS_FILE}" ] && [ -f "${ARGS_FILE}" ]; then
        # Forge/NeoForge 1.17+: the args file carries the classpath and main class.
        CMD+=("@${ARGS_FILE}" nogui)
    else
        if [ -n "${ARGS_FILE}" ]; then
            log_warn "El archivo de argumentos '${ARGS_FILE}' ya no existe. Se arranca con ${SERVER_JARFILE}."
        fi
        CMD+=(-jar "${SERVER_JARFILE}")
        # Proxies have no GUI to disable and will reject the argument.
        [ "${IS_PROXY}" = "1" ] || CMD+=(nogui)
    fi
}

# Legacy path: honour the panel's startup string verbatim and only patch flags
# into it, the way the previous egg behaved.
build_command_manual() {
    local parsed
    parsed=$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g' | eval echo "$(cat -)")

    build_gc_flags
    build_compat_flags

    if [ ${#JVM_FLAGS[@]} -gt 0 ]; then
        local injected="${JVM_FLAGS[*]}"
        # Insert after the heap flag so the arguments stay in a valid order.
        parsed=$(echo "${parsed}" | sed -E "s|(-Xmx[0-9]+[KMG]?)|\1 ${injected}|")
    fi

    MANUAL_CMD="${parsed}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

detect_server_type
log_ok "Software detectado: ${SERVER_TYPE}$([ -n "${ARGS_FILE}" ] && echo " (args: ${ARGS_FILE})")"

run_auto_update

# Detection runs again after an update: a jar swap can change the software.
if is_true "${AUTO_UPDATE}"; then
    ARGS_FILE=""
    detect_server_type
fi

accept_eula
apply_properties
apply_proxy_config
optimize_configs
install_geyser
scan_client_mods

print_diagnostics

if ! validate; then
    log_error "Las comprobaciones previas fallaron. No se puede arrancar el servidor."
    exit 1
fi

STARTUP_MODE=$(echo "${STARTUP_MODE:-auto}" | tr '[:upper:]' '[:lower:]')

if [ "${STARTUP_MODE}" = "manual" ]; then
    build_command_manual
    printf '%s~ %s%s\n' "${C_PROMPT}container@pterodactyl" "${C_RESET}" "${MANUAL_CMD}"
    # shellcheck disable=SC2086
    exec env ${MANUAL_CMD}
else
    build_command
    printf '%s~ %s%s\n' "${C_PROMPT}container@pterodactyl" "${C_RESET}" "${CMD[*]}"
    exec "${CMD[@]}"
fi
