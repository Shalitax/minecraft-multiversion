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
MULTIVERSION_VERSION="1.4.0"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

C_RESET=$'\033[0m'
C_INFO=$'\033[1;36m'
C_WARN=$'\033[1;33m'
C_ERR=$'\033[1;31m'
C_OK=$'\033[1;32m'
C_PROMPT=$'\033[1;33m'

# Startup output is queued and written as a single block right before the server
# takes over, instead of trickling out as each check finishes.
#
# The reason is what happens next: the server's own startup flood arrives
# immediately, and on a modpack that is thousands of lines. Anything printed
# progressively is scrolled out of reach before the customer can read it, which
# is why "the console said something but it scrolled away" is such a common
# ticket. One block, printed last, survives.
MV_LOG_BUFFER=""
MV_BUFFERING=0

# Queues a line, or prints it, depending on the mode.
out() {
    if [ "${MV_BUFFERING}" = "1" ]; then
        MV_LOG_BUFFER="${MV_LOG_BUFFER}$*"$'\n'
    else
        printf '%s\n' "$*"
    fi
}

# Same, for text that already carries its own line breaks.
out_raw() {
    if [ "${MV_BUFFERING}" = "1" ]; then
        MV_LOG_BUFFER="${MV_LOG_BUFFER}$*"
    else
        printf '%s' "$*"
    fi
}

# Writes whatever is queued and empties the queue. Called explicitly before
# exec, and from an EXIT trap so a failure on the way never swallows the very
# message that explains it.
flush_log() {
    if [ -n "${MV_LOG_BUFFER}" ]; then
        printf '%s' "${MV_LOG_BUFFER}"
        MV_LOG_BUFFER=""
    fi
}

log_info()  { out "${C_INFO}[i]${C_RESET} $*"; }
log_warn()  { out "${C_WARN}[!]${C_RESET} $*"; }
log_error() { out "${C_ERR}[x]${C_RESET} $*"; }
log_ok()    { out "${C_OK}[+]${C_RESET} $*"; }

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

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

# Buffering is decided here, before the first log line is produced. The trap
# covers every early exit; it does NOT fire on exec, so the flush before
# handing over to the server has to be explicit.
if is_true "${STARTUP_SUMMARY:-1}"; then
    MV_BUFFERING=1
    trap flush_log EXIT
    # Printed unbuffered on purpose: the checks below make network calls and can
    # take a few seconds, and a console that stays completely blank reads as a
    # server that hung on boot.
    printf '%s\n' "${C_INFO}[i]${C_RESET} Preparando el servidor..."
fi

# Empties the visible console and its scrollback. Only meaningful together with
# the buffered block: on its own it would wipe output already on screen.
console_clear() {
    [ "${MV_BUFFERING}" = "1" ] || return 0
    is_true "${CONSOLE_CLEAR:-1}" || return 0
    # Cursor home, erase screen, erase scrollback. Pterodactyl's console is
    # xterm.js, which honours all three.
    printf '\033[H\033[2J\033[3J'
}

# Holds the finished block on screen before the server's own output buries it.
startup_pause() {
    local secs="${STARTUP_PAUSE:-5}"

    # A non-numeric value falls back to the default rather than aborting: this
    # runs after every check has passed, and refusing to boot over a mistyped
    # cosmetic setting would be absurd.
    case "${secs}" in
        ''|*[!0-9]*) secs=5 ;;
    esac
    [ "${secs}" -eq 0 ] && return 0
    # Capped: this delay is paid on every single restart.
    [ "${secs}" -gt 30 ] && secs=30

    printf '%s\n' "${C_INFO}[i]${C_RESET} Arrancando en ${secs}s..."
    sleep "${secs}"
}

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

# Two profiles on purpose. Everything here runs BEFORE the server starts, so a
# hung upstream API delays the customer's boot for as long as curl waits. A
# metadata call that has not answered in 20 seconds is not going to, and giving
# up costs nothing: the server simply boots on the jar it already has.
# Worst case per endpoint is now ~60s instead of the ~20 minutes the previous
# 300s timeout allowed, which is what an outage at any single project's API
# used to cost every server on the node.
CURL_BASE=(--silent --show-error --location --fail --connect-timeout 10 --retry 2 --retry-delay 2 -A "${USER_AGENT}")
CURL_META=("${CURL_BASE[@]}" --max-time 20)
CURL_OPTS=("${CURL_BASE[@]}" --max-time 600)

# Escapes a string for safe use as a sed replacement. Without this a MOTD
# containing & or | silently produces a corrupted config file, and a | breaks
# the sed expression outright.
#
# Done with parameter expansion rather than a sed pass of its own: escaping
# backslashes with sed needs backslashes, and getting that wrong fails quietly
# in exactly the cases this function exists to handle. Backslash goes first, or
# it would escape the backslashes the later steps add.
sed_escape_replacement() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//&/\\&}
    s=${s//|/\\|}
    printf '%s' "${s}"
}

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
    elif [ -f ".multiversion-software" ] && grep -qE '^(mohist|arclight|velocity|waterfall|bungeecord|nanolimbo)$' .multiversion-software 2>/dev/null; then
        # First boot: the software has not written its config files yet, so fall
        # back to what the installer recorded.
        #
        # Proxies are the case that matters most here. velocity.toml and
        # config.yml only exist after the proxy has run once, so on a brand-new
        # server detection would otherwise fall through to "vanilla" and launch
        # a proxy with 'nogui' as if it were a Minecraft server.
        SERVER_TYPE=$(cat .multiversion-software)
        # Waterfall and BungeeCord share a type: identical on disk, same launch.
        [ "${SERVER_TYPE}" = "waterfall" ] && SERVER_TYPE="bungeecord"
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

    # IS_PROXY really means "does not run Minecraft itself": no EULA, no
    # server.properties, and no 'nogui' argument to reject. NanoLimbo is a limbo
    # server rather than a proxy, but it has exactly that shape.
    case "${SERVER_TYPE}" in
        velocity|bungeecord|waterfall|nanolimbo) IS_PROXY=1 ;;
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
# Properties helpers
# ---------------------------------------------------------------------------

# Sets key=value in a .properties file, replacing the existing line or
# appending a new one. Currently used for the Simple Voice Chat configuration.
properties_set() {
    local file="$1" key="$2" val="$3"
    [ -f "${file}" ] || touch "${file}"

    awk -v k="${key}" -v v="${val}" '
        BEGIN { found = 0 }
        index($0, k "=") == 1 { print k "=" v; found = 1; next }
        { print }
        END { if (!found) print k "=" v }
    ' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
}

# Proxies keep their bind address in their own config file. The allocation is
# still managed automatically because these files do not use server.properties.
apply_proxy_config() {
    # A proxy writes its config on first run, so on a brand-new server there is
    # nothing to patch yet and it will bind to its own default port instead of
    # the allocated one. Saying so out loud turns "nobody can connect to my new
    # proxy" into a one-line answer.
    case "${SERVER_TYPE}" in
        velocity|bungeecord|waterfall)
            if [ ! -f velocity.toml ] && [ ! -f config.yml ]; then
                log_warn "Primer arranque del proxy: aun no existe su archivo de configuracion."
                log_warn "Arrancara en su puerto por defecto. Reinicia una vez y quedara"
                log_warn "configurado en el puerto ${SERVER_PORT} que tiene asignado."
            fi
            ;;
    esac

    case "${SERVER_TYPE}" in
        velocity)
            if [ -f velocity.toml ]; then
                sed -i -E "s|^\s*bind\s*=.*|bind = \"0.0.0.0:${SERVER_PORT}\"|" velocity.toml
                log_info "velocity.toml: bind = 0.0.0.0:${SERVER_PORT}"
            fi
            ;;
        bungeecord|waterfall)
            if [ -f config.yml ]; then
                sed -i -E "s|^(\s*)host:\s*.*|\1host: 0.0.0.0:${SERVER_PORT}|" config.yml
                sed -i -E "s|^(\s*)query_port:\s*.*|\1query_port: ${SERVER_PORT}|" config.yml
                log_info "config.yml: host = 0.0.0.0:${SERVER_PORT}"
            fi
            ;;
        nanolimbo)
            # settings.yml nests the port under bind, and 'port:' also appears
            # elsewhere in that file. yq addresses the exact key, which sed
            # cannot do without guessing at indentation.
            if [ -f settings.yml ]; then
                if yq -i ".bind.port = ${SERVER_PORT} | .bind.ip = \"0.0.0.0\"" settings.yml 2>/dev/null; then
                    log_info "settings.yml: bind = 0.0.0.0:${SERVER_PORT}"
                else
                    log_warn "No se pudo ajustar el puerto en settings.yml. Revisalo a mano."
                fi
            else
                log_warn "Primer arranque de NanoLimbo: aun no existe settings.yml."
                log_warn "Arrancara en su puerto por defecto. Reinicia una vez y quedara"
                log_warn "configurado en el puerto ${SERVER_PORT} que tiene asignado."
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

    # Pure Vanilla and Sponge both detect as "vanilla" exactly like every Paper
    # fork does, but neither will ever create bukkit.yml or spigot.yml. Asking
    # the installer's marker settles it outright, instead of guessing forever.
    if [ -f .multiversion-software ] \
        && grep -qE '^(vanilla|sponge)$' .multiversion-software 2>/dev/null; then
        if [ ! -f "${OPTIMIZE_MARKER}" ]; then
            echo "${OPTIMIZE_PRESET_VERSION}" > "${OPTIMIZE_MARKER}"
            log_info "Configuracion optimizada: este software no usa configs de Bukkit, se omite"
        fi
        return 0
    fi

    # These files only exist after the server has booted at least once.
    if [ ! -f bukkit.yml ] && [ ! -f spigot.yml ]; then
        # Fallback for servers with no marker, e.g. placed by an external
        # installer module. Without this it printed "se aplicara en el proximo
        # arranque" on every single boot, forever, for a promise that could
        # never be kept.
        if [ -f server.properties ] && [ ! -f version_history.json ] && [ ! -d plugins ]; then
            echo "${OPTIMIZE_PRESET_VERSION}" > "${OPTIMIZE_MARKER}"
            log_info "Configuracion optimizada: este servidor no usa configs de Bukkit, no se volvera a comprobar"
            return 0
        fi
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

    # Pure Vanilla, Sponge and NanoLimbo all look like SERVER_TYPE "vanilla" or
    # have no plugin loader Geyser can hook into, so the installer's marker is
    # what settles it. Without this the jar was dropped into plugins/ where
    # nothing ever loaded it, and the customer got no error at all: the option
    # said "activado" and Bedrock players simply could not connect.
    local mv_software=""
    [ -f .multiversion-software ] && mv_software=$(cat .multiversion-software)
    case "${mv_software}" in
        vanilla|sponge|nanolimbo)
            log_warn "Geyser no funciona en '${mv_software}': ese software no carga plugins de Bukkit."
            log_warn "Usa Paper o un fork suyo, o pon un proxy (Velocity) delante y activalo alli."
            return 0 ;;
    esac

    # Each platform needs its own build of the plugin. Geyser ships builds for
    # Fabric and NeoForge as well; Floodgate does not, so those two get Geyser
    # only and an empty fg_variant skips the second download.
    #
    # cfg_dir is tracked separately because on Fabric and NeoForge the jar goes
    # to mods/ but the config lands under config/, not next to the jar.
    local variant plugin_dir fg_variant cfg_dir
    case "${SERVER_TYPE}" in
        velocity)             variant="velocity";   fg_variant="velocity"; plugin_dir="plugins"; cfg_dir="plugins/Geyser-Velocity" ;;
        bungeecord|waterfall) variant="bungeecord"; fg_variant="bungee";   plugin_dir="plugins"; cfg_dir="plugins/Geyser-BungeeCord" ;;
        vanilla|mohist|arclight) variant="spigot";  fg_variant="spigot";   plugin_dir="plugins"; cfg_dir="plugins/Geyser-Spigot" ;;
        fabric)               variant="fabric";     fg_variant="";         plugin_dir="mods";    cfg_dir="config/Geyser-Fabric" ;;
        neoforge)             variant="neoforge";   fg_variant="";         plugin_dir="mods";    cfg_dir="config/Geyser-NeoForge" ;;
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

    if [ -z "${fg_variant}" ]; then
        log_info "Floodgate no publica build para '${SERVER_TYPE}'. Los jugadores de Bedrock"
        log_info "necesitaran una cuenta de Java, o usa un proxy para tener Floodgate."
    elif [ ! -f "${plugin_dir}/floodgate-${fg_variant}.jar" ] || is_true "${GEYSER_AUTO_UPDATE}"; then
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

    configure_geyser_port "${cfg_dir}"
}

# Points Geyser at the UDP port the panel assigned to this server.
#
# The config schema is the same on every platform (bedrock.address and
# bedrock.port, verified against Geyser's own GeyserConfig); only the directory
# it lives in changes, which is what cfg_dir carries.
configure_geyser_port() {
    local dir="$1"
    local port="${GEYSER_PORT:-19132}"

    case "${port}" in
        ''|*[!0-9]*)
            log_warn "'Puerto de Geyser' esperaba un numero y recibio '${port}'. Se deja el que tenga la config."
            return 0 ;;
    esac

    # Located by pattern rather than by the exact path: if Geyser ever renames
    # its folder, a search still finds the file while a hardcoded path would
    # silently start writing a config nobody reads.
    local cfg
    cfg=$(find plugins config -maxdepth 2 -name config.yml -path '*Geyser*' 2>/dev/null | head -1)

    if [ -n "${cfg}" ]; then
        # Re-applied on every boot, so a port change in the panel takes effect
        # on the next restart without anyone editing YAML by hand.
        if yq -i ".bedrock.port = ${port} | .bedrock.address = \"0.0.0.0\"" "${cfg}" 2>/dev/null; then
            log_ok "Geyser escuchara en el puerto UDP ${port}"
        else
            log_warn "No se pudo escribir el puerto en ${cfg}. Revisalo a mano."
        fi
        return 0
    fi

    # First boot: Geyser has not generated its config yet. Writing just these
    # two keys is enough because Geyser fills in every missing option from its
    # own defaults when it loads the file, so Bedrock works on the first try
    # instead of failing to bind 19132 and needing a restart.
    mkdir -p "${dir}"
    printf 'bedrock:\n  address: 0.0.0.0\n  port: %s\n' "${port}" > "${dir}/config.yml"
    log_ok "Geyser configurado en el puerto UDP ${port} (${dir}/config.yml)"
    log_info "El resto de opciones de Geyser se rellenaran solas en este arranque."
}

# ---------------------------------------------------------------------------
# Simple Voice Chat
#
# Voice chat carries audio over UDP on a port of its own, and the resulting
# ticket is always the same shape: players join the game perfectly, the voice
# icon stays red, and nothing anywhere says why.
#
# Unlike Geyser, the port here is invisible to players: the client learns it
# from the server during the handshake, nobody types it. That is what makes it
# safe to set from the panel on every boot, even on a server already running.
# ---------------------------------------------------------------------------

VOICECHAT_FILE="voicechat-server.properties"
VOICECHAT_DEFAULT_PORT="24454"

# "mod" or "plugin", decided by where the jar was found. The two builds keep
# their config in different places and the difference matters: writing to the
# wrong one configures a file nobody reads, which looks exactly like the
# setting doing nothing at all.
VOICECHAT_KIND=""

# Locates the config wherever this build actually keeps it:
#   config/voicechat/   mod builds (Fabric, NeoForge, Forge, Quilt)
#   plugins/voicechat/  Bukkit plugin build
#   voicechat/          older layouts, kept as a fallback
# Searched rather than hardcoded, for the same reason configure_geyser_port
# searches for its own config.yml.
voicechat_find_config() {
    local preferred="" hit
    case "${VOICECHAT_KIND}" in
        mod)    preferred="config" ;;
        plugin) preferred="plugins" ;;
    esac

    # On a hybrid server both trees can exist; the one matching the jar wins.
    if [ -n "${preferred}" ]; then
        hit=$(find "${preferred}" -maxdepth 2 -name "${VOICECHAT_FILE}" 2>/dev/null | head -1)
        [ -n "${hit}" ] && { printf '%s' "${hit}"; return 0; }
    fi

    find config plugins voicechat -maxdepth 2 -name "${VOICECHAT_FILE}" 2>/dev/null | head -1
}

# Where to write when nothing exists yet, which depends on the build.
voicechat_config_target() {
    local existing
    existing=$(voicechat_find_config)
    if [ -n "${existing}" ]; then
        printf '%s' "${existing}"
        return 0
    fi

    if [ "${VOICECHAT_KIND}" = "mod" ]; then
        printf 'config/voicechat/%s' "${VOICECHAT_FILE}"
    else
        printf 'plugins/voicechat/%s' "${VOICECHAT_FILE}"
    fi
}

# Matches the mod and the plugin builds, under any of the spellings the project
# has shipped. Compared in lowercase because customers rename jars.
voicechat_installed() {
    local dir jar base found
    VOICECHAT_KIND=""

    for dir in mods plugins; do
        [ -d "${dir}" ] || continue
        for jar in "${dir}"/*.jar; do
            [ -f "${jar}" ] || continue
            base=$(basename "${jar}" | tr '[:upper:]' '[:lower:]')
            case "${base}" in
                *voicechat*|*voice-chat*|*voice_chat*)
                    if [ "${dir}" = "mods" ]; then VOICECHAT_KIND="mod"; else VOICECHAT_KIND="plugin"; fi
                    return 0 ;;
            esac
        done
    done

    # Present even if the jar was renamed beyond recognition: the mod writes
    # this file itself on first run. The path it sits in reveals the build.
    found=$(voicechat_find_config)
    if [ -n "${found}" ]; then
        case "${found}" in
            plugins/*) VOICECHAT_KIND="plugin" ;;
            *)         VOICECHAT_KIND="mod" ;;
        esac
        return 0
    fi
    return 1
}

# Warns when voice chat and Geyser would end up on the same UDP port. Only one
# of them can have it, and the loser stops working without printing anything at
# all, so the collision is worth naming out loud.
#
# Compared as numbers, not assumed: Geyser is normally on its own 19132 and
# coexists with voice chat perfectly well. Warning unconditionally would be
# noise on the common setup, and noise is what makes real warnings get ignored.
voicechat_check_geyser_clash() {
    local vc_port="$1"
    is_true "${INSTALL_GEYSER}" || return 0

    local geyser_port="${GEYSER_PORT:-19132}"
    [ "${vc_port}" = "${geyser_port}" ] || return 0

    log_warn "CONFLICTO: Geyser y el chat de voz quedarian los dos en ${vc_port}/UDP."
    log_warn "Solo uno puede usarlo, y el otro dejara de funcionar sin dar error."
    log_warn "Cambia 'Puerto de Geyser (Bedrock)' en el panel, o el puerto del chat de voz."
}

# Reads the port currently written in the mod's config. Empty means the file
# does not exist yet, i.e. this is the first boot.
voicechat_config_port() {
    local cfg
    cfg=$(voicechat_find_config)
    [ -n "${cfg}" ] || return 0
    grep -E '^[[:space:]]*port[[:space:]]*=' "${cfg}" 2>/dev/null \
        | head -1 | cut -d= -f2 | tr -d '[:space:]'
}

# Points Simple Voice Chat at the UDP port chosen in the panel.
#
# Mirrors configure_geyser_port, with one difference: the config is a
# .properties file, not YAML, so yq is not involved.
configure_voicechat_port() {
    local port="${VOICECHAT_PORT:-No modificar}"

    # Leaves the file untouched, for anyone managing it by hand.
    if is_auto "${port}"; then
        return 1
    fi

    case "${port}" in
        -1) ;;
        ''|*[!0-9]*)
            log_warn "'Puerto del chat de voz' esperaba un numero o -1, y recibio '${port}'."
            log_warn "Se deja el que tenga la configuracion del mod."
            return 1 ;;
    esac

    # -1 means "reuse the Minecraft server's port", which works because Wings
    # binds UDP on every allocation as well as TCP. The mod's own documentation
    # warns this collides with server query, which uses UDP on that same port,
    # so that case is checked rather than assumed.
    if [ "${port}" = "-1" ] && grep -qE '^enable-query[[:space:]]*=[[:space:]]*true' server.properties 2>/dev/null; then
        log_warn "El chat de voz esta puesto en 'compartir puerto', pero 'query' esta activado"
        log_warn "y ya ocupa ${SERVER_PORT}/UDP. Se deja la configuracion del mod sin tocar."
        log_warn "Asigna un puerto propio al chat de voz, o desactiva query."
        return 1
    fi

    local cfg
    cfg=$(voicechat_config_target)

    # First boot: the mod has not generated its config yet. Writing just this
    # key is enough because it fills in every missing option from its own
    # defaults when it loads the file, so voice works on the first try instead
    # of binding 24454 and needing a restart.
    mkdir -p "$(dirname "${cfg}")"
    properties_set "${cfg}" port "${port}"

    if [ "${port}" = "-1" ]; then
        log_ok "Chat de voz configurado en el puerto del servidor (${SERVER_PORT}/UDP)"
        voicechat_check_geyser_clash "${SERVER_PORT}"
    else
        log_ok "Chat de voz configurado en el puerto UDP ${port}"
        if [ "${port}" != "${SERVER_PORT}" ]; then
            log_warn "Ese puerto tiene que estar asignado al servidor desde el nodo."
        fi
        voicechat_check_geyser_clash "${port}"
    fi
    log_info "Configuracion del chat de voz: ${cfg}"
    return 0
}

check_voicechat() {
    voicechat_installed || return 0

    # When the panel manages the port there is nothing left to advise about.
    configure_voicechat_port && return 0

    local port
    port=$(voicechat_config_port)

    # First boot with the port left on "No modificar": the mod has not written
    # its config yet, so the port it will pick is still its own default.
    if [ -z "${port}" ]; then
        log_warn "Simple Voice Chat detectado, pero aun no ha creado su configuracion."
        log_warn "Al arrancar usara el puerto ${VOICECHAT_DEFAULT_PORT}/UDP, que este servidor no tiene asignado."
        log_warn "Opciones: poner un puerto en 'Puerto del chat de voz' desde el panel,"
        log_warn "o dejarlo en -1 para reutilizar el puerto ${SERVER_PORT} que ya tiene."
        voicechat_check_geyser_clash "${VOICECHAT_DEFAULT_PORT}"
        return 0
    fi

    if [ "${port}" = "-1" ] || [ "${port}" = "${SERVER_PORT}" ]; then
        log_ok "Simple Voice Chat usa el puerto del servidor (${SERVER_PORT}/UDP). No hace falta asignar otro."
        voicechat_check_geyser_clash "${SERVER_PORT}"
        return 0
    fi

    log_warn "Simple Voice Chat esta configurado en el puerto ${port}/UDP."
    log_warn "Ese puerto tiene que estar asignado al servidor desde el nodo, o los"
    log_warn "jugadores entraran al juego pero el chat de voz no conectara."
    log_warn "Alternativa sin puerto extra: poner -1 en 'Puerto del chat de voz'."
    voicechat_check_geyser_clash "${port}"
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
    # Paths of the offending jars, one per line. Reading a mod's metadata costs
    # up to four unzip calls, so the result of this pass is kept instead of
    # being recomputed to move the files: on a 200-mod pack that is the
    # difference between ~800 and ~1600 unzip invocations.
    local offenders=""

    for jar in mods/*.jar; do
        reason=""
        if mod_declares_client "${jar}"; then
            reason="declarado como solo cliente"
        elif mod_name_is_known_client "${jar}"; then
            reason="mod conocido de solo cliente"
        fi

        if [ -n "${reason}" ]; then
            found=$((found + 1))
            offenders="${offenders}${jar}
"
            names="${names}      - $(basename "${jar}") (${reason})
"
        fi
    done

    [ "${found}" -eq 0 ] && return 0

    out ""
    log_warn "Se detectaron ${found} mod(s) que solo funcionan en el cliente:"
    out_raw "${names}"
    log_warn "Estos mods no existen en la version de servidor y suelen impedir que arranque."

    case "${action}" in
        mover*|move*)
            mkdir -p "${DISABLED_MODS_DIR}"
            # read -r without IFS trimming, so a mod whose file name has spaces
            # still moves instead of being silently skipped.
            while IFS= read -r jar; do
                [ -n "${jar}" ] || continue
                mv "${jar}" "${DISABLED_MODS_DIR}/" 2>/dev/null \
                    && log_ok "Movido: $(basename "${jar}")"
            done <<< "${offenders}"
            log_ok "Los mods se movieron a ${DISABLED_MODS_DIR}/. Para recuperarlos, devuelvelos a mods/."
            ;;
        *)
            log_warn "Accion configurada: solo avisar. Borralos o muevelos fuera de mods/ para continuar."
            ;;
    esac
    out ""
}

# ---------------------------------------------------------------------------
# Startup diagnostics
# ---------------------------------------------------------------------------

print_diagnostics() {
    is_true "${SHOW_DIAGNOSTICS}" || return 0

    local plugins=0 mods=0
    [ -d plugins ] && plugins=$(ls -1 plugins/*.jar 2>/dev/null | wc -l)
    [ -d mods ] && mods=$(ls -1 mods/*.jar 2>/dev/null | wc -l)

    out ""
    out "${C_INFO}--- Resumen del servidor ---${C_RESET}"
    out "  Software    : ${SERVER_TYPE}"
    out "  Java        : ${JAVA_RAW} (version ${JAVA_MAJOR})"
    if [ -z "${SERVER_MEMORY}" ] || [ "${SERVER_MEMORY}" = "0" ]; then
        out "  Memoria     : sin limite asignado"
    else
        out "  Memoria     : ${SERVER_MEMORY} MB asignados"
    fi
    [ "${plugins}" -gt 0 ] && out "  Plugins     : ${plugins}"
    [ "${mods}" -gt 0 ] && out "  Mods        : ${mods}"

    local vd=""
    [ -f server.properties ] && vd=$(grep -E '^view-distance=' server.properties 2>/dev/null | cut -d= -f2)
    [ -n "${vd}" ] && out "  Distancia   : ${vd} chunks"

    # --- Memory warnings ---------------------------------------------------
    # Thresholds are deliberately loose: the goal is to catch the obviously
    # broken setups that generate support tickets, not to be precise.
    # Skipped entirely when memory is unlimited (0), where none of them apply.
    if [ -n "${SERVER_MEMORY}" ] && [ "${SERVER_MEMORY}" != "0" ]; then
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
    fi

    out "${C_INFO}----------------------------${C_RESET}"
    out ""
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
        md5)  actual=$(md5sum "${file}" 2>/dev/null | awk '{print $1}') ;;
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
    curl "${CURL_META[@]}" "https://fill.papermc.io/v3/projects/${project}" 2>/dev/null \
        | jq -r '
            [ .versions | to_entries[] | .value[] ] as $all
            | ( [ $all[] | select(test("-(SNAPSHOT|rc|pre)") | not) ][0] // $all[0] // empty )'
}

# Prints "<build id> <download url>" for the newest build on the requested
# channel, falling back to the newest build of any channel.
paper_latest_build() {
    local project="$1" version="$2" channel="$3"
    curl "${CURL_META[@]}" "https://fill.papermc.io/v3/projects/${project}/versions/${version}/builds" 2>/dev/null \
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
        version=$(curl "${CURL_META[@]}" "https://api.purpurmc.org/v2/purpur" 2>/dev/null | jq -r '.metadata.current // .versions[-1] // empty')
        [ -z "${version}" ] && { log_warn "No se pudo determinar la ultima version de Purpur, se omite"; return 1; }
    fi

    local build
    build=$(curl "${CURL_META[@]}" "https://api.purpurmc.org/v2/purpur/${version}" 2>/dev/null | jq -r '.builds.latest // empty')
    [ -z "${build}" ] && { log_warn "No hay builds de Purpur para ${version}, se omite"; return 1; }

    local marker="purpur-${version}-${build}"
    if [ -f "${STATE_FILE}" ] && [ "$(cat "${STATE_FILE}")" = "${marker}" ] && [ -f "${SERVER_JARFILE}" ]; then
        log_ok "Purpur ${version} build ${build} ya esta actualizado"
        return 0
    fi

    # Purpur publishes md5 rather than a sha.
    local sha
    sha=$(curl "${CURL_META[@]}" "https://api.purpurmc.org/v2/purpur/${version}/${build}" 2>/dev/null | jq -r '.md5 // empty')

    log_info "Descargando Purpur ${version} build ${build}"
    if curl "${CURL_OPTS[@]}" -o "${SERVER_JARFILE}.tmp" "https://api.purpurmc.org/v2/purpur/${version}/${build}/download"; then
        if ! verify_checksum "${SERVER_JARFILE}.tmp" "${sha}" md5; then
            rm -f "${SERVER_JARFILE}.tmp"
            return 1
        fi
        mv "${SERVER_JARFILE}.tmp" "${SERVER_JARFILE}"
        echo "${marker}" > "${STATE_FILE}"
        log_ok "Actualizado a Purpur ${version} build ${build}"
    else
        rm -f "${SERVER_JARFILE}.tmp"
        log_error "Fallo la descarga, se mantiene la version actual"
        return 1
    fi
}

# Leaf has its own API, shaped like PaperMC's v2.
update_leaf() {
    local version="$1"

    if is_auto "${version}" || [ "${version}" = "latest" ]; then
        version=$(curl "${CURL_META[@]}" "https://api.leafmc.one/v2/projects/leaf" 2>/dev/null | jq -r '.versions[-1] // empty')
        [ -z "${version}" ] && { log_warn "No se pudo determinar la ultima version de Leaf, se omite"; return 1; }
    fi

    local build
    build=$(curl "${CURL_META[@]}" "https://api.leafmc.one/v2/projects/leaf/versions/${version}" 2>/dev/null | jq -r '.builds[-1] // empty')
    [ -z "${build}" ] && { log_warn "No hay builds de Leaf para ${version}, se omite"; return 1; }

    local marker="leaf-${version}-${build}"
    if [ -f "${STATE_FILE}" ] && [ "$(cat "${STATE_FILE}")" = "${marker}" ] && [ -f "${SERVER_JARFILE}" ]; then
        log_ok "Leaf ${version} build ${build} ya esta actualizado"
        return 0
    fi

    # One request, both fields: the name for the URL and the hash to verify it.
    local meta name sha
    meta=$(curl "${CURL_META[@]}" "https://api.leafmc.one/v2/projects/leaf/versions/${version}/builds/${build}" 2>/dev/null)
    name=$(echo "${meta}" | jq -r '.downloads.primary.name // empty')
    sha=$(echo "${meta}" | jq -r '.downloads.primary.sha256 // empty')
    [ -z "${name}" ] && { log_warn "No se pudo resolver la descarga de Leaf, se omite"; return 1; }

    log_info "Descargando Leaf ${version} build ${build}"
    if curl "${CURL_OPTS[@]}" -o "${SERVER_JARFILE}.tmp" \
        "https://api.leafmc.one/v2/projects/leaf/versions/${version}/builds/${build}/downloads/${name}"; then
        if ! verify_checksum "${SERVER_JARFILE}.tmp" "${sha}" sha256; then
            rm -f "${SERVER_JARFILE}.tmp"
            return 1
        fi
        mv "${SERVER_JARFILE}.tmp" "${SERVER_JARFILE}"
        echo "${marker}" > "${STATE_FILE}"
        log_ok "Actualizado a Leaf ${version} build ${build}"
    else
        rm -f "${SERVER_JARFILE}.tmp"
        log_error "Fallo la descarga, se mantiene el jar actual"
        return 1
    fi
}

# Gale publishes on GitHub, whose API allows 60 unauthenticated requests per
# hour per IP. That budget is shared by every server on the node, so this one
# treats a rate-limit answer as "skip and keep running", never as an error.
update_gale() {
    local version="$1" releases result

    releases=$(curl "${CURL_META[@]}" "https://api.github.com/repos/GaleMC/Gale/releases?per_page=100" 2>/dev/null)
    if [ -z "${releases}" ] || [ "$(echo "${releases}" | jq -r 'type' 2>/dev/null)" != "array" ]; then
        log_warn "No se pudo consultar Gale en GitHub (limite de consultas por IP), se omite"
        return 1
    fi

    local prefix="gale-"
    if ! is_auto "${version}" && [ "${version}" != "latest" ]; then
        prefix="gale-${version}-"
    fi

    result=$(echo "${releases}" | jq -r --arg p "${prefix}" '
        [ .[].assets[] | select(.name | startswith($p)) ][0]
        | if . == null then empty
          else "\(.name) \(.browser_download_url) \((.digest // "") | sub("^sha256:";""))" end')
    [ -z "${result}" ] && { log_warn "No hay builds de Gale para ${version}, se omite"; return 1; }

    local name url sha
    read -r name url sha <<< "${result}"

    # The asset file name carries the build, so it doubles as the state marker.
    local marker="gale-${name}"
    if [ -f "${STATE_FILE}" ] && [ "$(cat "${STATE_FILE}")" = "${marker}" ] && [ -f "${SERVER_JARFILE}" ]; then
        log_ok "Gale ${name} ya esta actualizado"
        return 0
    fi

    log_info "Descargando ${name}"
    if curl "${CURL_OPTS[@]}" -o "${SERVER_JARFILE}.tmp" "${url}"; then
        if ! verify_checksum "${SERVER_JARFILE}.tmp" "${sha}" sha256; then
            rm -f "${SERVER_JARFILE}.tmp"
            return 1
        fi
        mv "${SERVER_JARFILE}.tmp" "${SERVER_JARFILE}"
        echo "${marker}" > "${STATE_FILE}"
        log_ok "Actualizado a ${name}"
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
        job=$(curl "${CURL_META[@]}" "https://ci.pufferfish.host/api/json?tree=jobs%5Bname%5D" 2>/dev/null \
            | jq -r '[.jobs[].name | select(test("^Pufferfish-[0-9]"))] | sort_by(split("-")[1] | split(".") | map(tonumber)) | last // empty')
    else
        job="Pufferfish-$(echo "${version}" | cut -d. -f1,2)"
    fi
    [ -z "${job}" ] && { log_warn "No se pudo determinar el job de Pufferfish, se omite"; return 1; }

    local info build art
    info=$(curl "${CURL_META[@]}" "https://ci.pufferfish.host/job/${job}/lastSuccessfulBuild/api/json?tree=number,artifacts%5BrelativePath%5D" 2>/dev/null)
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

# BungeeCord is a single jar on md-5's Jenkins with no versions to choose from,
# so the build number is the whole story.
update_bungeecord() {
    local info build
    info=$(curl "${CURL_META[@]}" "https://ci.md-5.net/job/BungeeCord/lastSuccessfulBuild/api/json?tree=number" 2>/dev/null)
    build=$(echo "${info}" | jq -r '.number // empty')
    [ -z "${build}" ] && { log_warn "No se pudo consultar el ultimo build de BungeeCord, se omite"; return 1; }

    local marker="bungeecord-${build}"
    if [ -f "${STATE_FILE}" ] && [ "$(cat "${STATE_FILE}")" = "${marker}" ] && [ -f "${SERVER_JARFILE}" ]; then
        log_ok "BungeeCord build ${build} ya esta actualizado"
        return 0
    fi

    log_info "Descargando BungeeCord build ${build}"
    if curl "${CURL_OPTS[@]}" -o "${SERVER_JARFILE}.tmp" \
        "https://ci.md-5.net/job/BungeeCord/lastSuccessfulBuild/artifact/bootstrap/target/BungeeCord.jar"; then
        mv "${SERVER_JARFILE}.tmp" "${SERVER_JARFILE}"
        echo "${marker}" > "${STATE_FILE}"
        log_ok "Actualizado a BungeeCord build ${build}"
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
    json=$(curl "${CURL_META[@]}" "${manifest}" 2>/dev/null)
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
    meta=$(curl "${CURL_META[@]}" "${version_url}" 2>/dev/null)
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
        *leaf*)       echo "leaf" ;;
        *gale*)       echo "gale" ;;
        *folia*)      echo "folia" ;;
        *paper*)      echo "paper" ;;
        *)            return 1 ;;
    esac
}

marker_matches_type() {
    local fork
    case "$1" in
        # Every Paper fork, plus Spigot and Sponge, is a plain jar and detects
        # as "vanilla".
        paper|purpur|pufferfish|leaf|gale|folia|spigot|sponge|vanilla)
            [ "${SERVER_TYPE}" = "vanilla" ] || return 1
            # Same family, but possibly a different fork than the one recorded.
            if fork=$(detect_fork_name); then
                [ "${fork}" = "$1" ] || return 1
            fi
            return 0 ;;
        velocity)   [ "${SERVER_TYPE}" = "velocity" ] ;;
        # Waterfall and BungeeCord are indistinguishable on disk and share a type.
        waterfall|bungeecord) [ "${SERVER_TYPE}" = "bungeecord" ] ;;
        fabric)     [ "${SERVER_TYPE}" = "fabric" ] ;;
        quilt)      [ "${SERVER_TYPE}" = "quilt" ] ;;
        # Pre-1.17 Forge detects as forge-legacy; both come from the same installer.
        forge)      [ "${SERVER_TYPE}" = "forge" ] || [ "${SERVER_TYPE}" = "forge-legacy" ] ;;
        neoforge)   [ "${SERVER_TYPE}" = "neoforge" ] ;;
        mohist)     [ "${SERVER_TYPE}" = "mohist" ] ;;
        arclight)   [ "${SERVER_TYPE}" = "arclight" ] ;;
        nanolimbo)  [ "${SERVER_TYPE}" = "nanolimbo" ] ;;
        *)          return 1 ;;
    esac
}

run_auto_update() {
    is_true "${AUTO_UPDATE}" || return 0

    local project="${UPDATE_PROJECT}" marker=""
    if is_auto "${project}"; then
        # Purpur, Pufferfish and Spigot are all plain jars and all detect as
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
            # Only Velocity is safe to infer: velocity.toml identifies it and
            # nothing else. BungeeCord and Waterfall are byte-identical on disk,
            # so guessing between them would swap one for the other behind the
            # customer's back.
            case "${SERVER_TYPE}" in
                velocity)   project="velocity" ;;
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
        leaf)
            update_leaf "${UPDATE_MC_VERSION}" ;;
        gale)
            update_gale "${UPDATE_MC_VERSION}" ;;
        pufferfish)
            update_pufferfish "${UPDATE_MC_VERSION}" ;;
        vanilla)
            update_vanilla "${UPDATE_MC_VERSION}" ;;
        bungeecord)
            update_bungeecord ;;
        spigot)
            log_warn "Spigot no se puede actualizar solo: hay que recompilarlo con BuildTools."
            log_warn "Reinstala desde el panel para cambiar de version." ;;
        sponge|nanolimbo)
            log_warn "'${project}' no tiene actualizacion automatica en este egg."
            log_warn "Reinstala desde el panel para pasar a una version nueva." ;;
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

    # Pterodactyl uses 0 to mean "no memory limit". Passing that through would
    # produce -Xmx0M, which the JVM rejects outright, so an unlimited-RAM plan
    # could never boot. Sizing from the container is the only correct answer
    # here anyway, since there is no fixed number to pin the heap to.
    if [ -z "${SERVER_MEMORY}" ] || [ "${SERVER_MEMORY}" = "0" ]; then
        JVM_FLAGS+=("-XX:MaxRAMPercentage=${MAX_RAM_PERCENTAGE:-80.0}")
        log_info "Memoria sin limite asignado: se usara hasta ${MAX_RAM_PERCENTAGE:-80.0}% de la disponible"
        return 0
    fi

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
#
# Source of truth when adding a new Minecraft release:
#   https://fill.papermc.io/v3/projects/paper/versions/<version>
# publishes version.java.version.minimum. Checking it beats guessing: the jump
# from 21 to 25 arrived with the 26.x calendar releases and nothing in the
# version number hints at it.
required_java_for() {
    local mc="$1"
    case "${mc}" in
        1.8*|1.9*|1.10*|1.11*|1.12*)   echo 8 ;;
        1.13*|1.14*|1.15*|1.16*)       echo 8 ;;
        1.17*)                         echo 16 ;;
        1.18*|1.19*)                   echo 17 ;;
        # 1.20 through 1.20.4 are Java 17; 1.20.5 raised it to 21. The bare
        # "1.20" needs its own branch or it falls through to the 21 line below.
        1.20|1.20.[0-4]*)              echo 17 ;;
        1.20*|1.21*)                   echo 21 ;;
        # Calendar-versioned releases. 26.x requires Java 25, verified against
        # Paper's own API; anything newer is assumed to need at least as much.
        2[0-5].*)                      echo 21 ;;
        26.*|2[7-9].*|[3-9][0-9].*)    echo 25 ;;
        *)                             echo 0 ;;
    esac
}

# Forge 61.x (1.21.11 y siguientes) dejo de meter el classpath en unix_args.txt
# y lo redujo a un lanzador:
#
#   -Djava.net.preferIPv6Addresses=system -jar forge-1.21.11-61.2.1-shim.jar
#
# Ese '-jar' se resuelve contra el directorio de trabajo, que es la raiz del
# servidor. El instalador oficial de Forge deja ahi el shim; mcjars, que
# normaliza todo a 'server.jar', lo deja solo dentro de libraries/. Con la
# receta de mcjars el arranque muere con:
#
#   Error: Unable to access jarfile forge-<version>-shim.jar
#
# El shim de libraries/ y el server.jar de la raiz son el mismo archivo byte a
# byte, asi que basta con dejarlo tambien con el nombre que el lanzador espera.
# Se repara aqui y no en el instalador a proposito: asi un servidor ya instalado
# arranca en el siguiente intento, sin reinstalar.
#
# NeoForge no esta afectado: su args file usa '-classpath' con rutas relativas.
ensure_args_jar() {
    [ -n "${ARGS_FILE}" ] && [ -f "${ARGS_FILE}" ] || return 0

    local wanted
    wanted=$(tr ' \t' '\n\n' < "${ARGS_FILE}" | grep -A1 -x -- '-jar' | tail -1)
    case "${wanted}" in
        ''|-*|*/*) return 0 ;;
    esac
    [ -f "${wanted}" ] && return 0

    local origen
    for origen in "$(dirname "${ARGS_FILE}")/${wanted}" "${SERVER_JARFILE}" server.jar; do
        if [ -n "${origen}" ] && [ -f "${origen}" ]; then
            if cp -f "${origen}" "${wanted}" 2>/dev/null; then
                log_info "Lanzador de Forge restaurado como '${wanted}'."
                return 0
            fi
            break
        fi
    done

    log_warn "El args file pide '${wanted}' y no esta en la carpeta del servidor."
    log_warn "Reinstala el servidor desde el panel si no arranca."
    return 0
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
    parsed="${STARTUP}"
    parsed="${parsed//\{\{SERVER_MIN_MEMORY\}\}/${SERVER_MIN_MEMORY:-128}}"
    parsed="${parsed//\{\{SERVER_MEMORY\}\}/${SERVER_MEMORY}}"
    parsed="${parsed//\{\{SERVER_JARFILE\}\}/${SERVER_JARFILE}}"

    if echo "${parsed}" | grep -q '{{[^}]*}}'; then
        log_error "El comando manual contiene una variable no permitida o desconocida."
        return 1
    fi

    build_gc_flags
    build_compat_flags

    if [ ${#JVM_FLAGS[@]} -gt 0 ]; then
        local injected
        # Escaped: EXTRA_JAVA_ARGS ends up in here, and a | in a customer's
        # flags would otherwise terminate the sed expression.
        injected=$(sed_escape_replacement "${JVM_FLAGS[*]}")
        # Insert after the heap flag so the arguments stay in a valid order.
        if echo "${parsed}" | grep -qE '\-Xmx[0-9]+[KMG]?'; then
            parsed=$(echo "${parsed}" | sed -E "s|(-Xmx[0-9]+[KMG]?)|\1 ${injected}|")
        else
            # No heap flag to anchor to. Silently dropping the flags here is
            # what made "my Aikar flags do nothing" impossible to diagnose.
            log_warn "El comando de inicio no tiene -Xmx, no se pudieron insertar las flags de la JVM."
            log_warn "Anadelas a mano al comando, o usa el modo de arranque 'auto'."
        fi
    fi

    # Manual mode is an administrator-only compatibility path. Convert the
    # validated command to an argv array instead of evaluating shell code.
    read -r -a MANUAL_CMD <<< "${parsed}"
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

ensure_args_jar
accept_eula
apply_proxy_config
optimize_configs
install_geyser
check_voicechat
scan_client_mods

print_diagnostics

if ! validate; then
    log_error "Las comprobaciones previas fallaron. No se puede arrancar el servidor."
    exit 1
fi

STARTUP_MODE=$(echo "${STARTUP_MODE:-auto}" | tr '[:upper:]' '[:lower:]')

if [ "${STARTUP_MODE}" = "manual" ]; then
    if ! build_command_manual; then
        exit 1
    fi
    out "${C_PROMPT}container@pterodactyl~ ${C_RESET}${MANUAL_CMD[*]}"
else
    build_command
    out "${C_PROMPT}container@pterodactyl~ ${C_RESET}${CMD[*]}"
fi

# Everything above only queued output. This is where it reaches the screen:
# wipe first, then write the whole block, then hold it there long enough to be
# read before the server's own logs start scrolling.
console_clear
flush_log
startup_pause

if [ "${STARTUP_MODE}" = "manual" ]; then
    exec "${MANUAL_CMD[@]}"
fi
exec "${CMD[@]}"
