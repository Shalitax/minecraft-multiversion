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

# Treat "1", "true", "yes" and "on" as enabled so the egg can use either
# boolean style without surprising anyone.
is_true() {
    case "$(echo "${1}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on|enabled) return 0 ;;
        *) return 1 ;;
    esac
}

# "auto" and empty mean "leave whatever is already in the file alone".
is_auto() {
    [ -z "${1}" ] && return 0
    case "$(echo "${1}" | tr '[:upper:]' '[:lower:]')" in
        auto|default|unset) return 0 ;;
        *) return 1 ;;
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

log_info "Java ${JAVA_RAW} (feature version ${JAVA_MAJOR}) | TZ ${TZ} | IP ${INTERNAL_IP}"

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
        log_info "Server type forced to '${SERVER_TYPE}' by the panel"
    elif [ -f "velocity.toml" ]; then
        SERVER_TYPE="velocity"
    elif [ -f "config.yml" ] && grep -qE '^\s*listeners:' config.yml 2>/dev/null; then
        # Waterfall and BungeeCord are indistinguishable on disk and start the
        # same way, so they share a type.
        SERVER_TYPE="bungeecord"
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

apply_properties() {
    [ "${IS_PROXY}" = "1" ] && return 0

    set_prop "online-mode"            "${MC_ONLINE_MODE}"
    set_prop "difficulty"             "${MC_DIFFICULTY}"
    set_prop "gamemode"               "${MC_GAMEMODE}"
    set_prop "pvp"                    "${MC_PVP}"
    set_prop "hardcore"               "${MC_HARDCORE}"
    set_prop "max-players"            "${MC_MAX_PLAYERS}"
    set_prop "view-distance"          "${MC_VIEW_DISTANCE}"
    set_prop "simulation-distance"    "${MC_SIMULATION_DISTANCE}"
    set_prop "max-tick-time"          "${MC_MAX_TICK_TIME}"
    set_prop "motd"                   "${MC_MOTD}"
    set_prop "white-list"             "${MC_WHITELIST}"
    set_prop "enforce-secure-profile" "${MC_ENFORCE_SECURE_PROFILE}"
    set_prop "level-seed"             "${MC_LEVEL_SEED}"
    set_prop "level-type"             "${MC_LEVEL_TYPE}"
}

# Proxies keep their bind address in their own config file. The panel's
# server.properties parser cannot reach these, so they are handled here.
apply_proxy_config() {
    case "${SERVER_TYPE}" in
        velocity)
            if [ -f velocity.toml ]; then
                sed -i -E "s|^\s*bind\s*=.*|bind = \"0.0.0.0:${SERVER_PORT}\"|" velocity.toml
                log_info "velocity.toml: bind = 0.0.0.0:${SERVER_PORT}"
                if ! is_auto "${MC_ONLINE_MODE}"; then
                    sed -i -E "s|^\s*online-mode\s*=.*|online-mode = ${MC_ONLINE_MODE}|" velocity.toml
                    log_info "velocity.toml: online-mode = ${MC_ONLINE_MODE}"
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
                if ! is_auto "${MC_ONLINE_MODE}"; then
                    sed -i -E "s|^(\s*)online_mode:\s*.*|\1online_mode: ${MC_ONLINE_MODE}|" config.yml
                    log_info "config.yml: online_mode = ${MC_ONLINE_MODE}"
                fi
            fi
            ;;
    esac
}

accept_eula() {
    [ "${IS_PROXY}" = "1" ] && return 0
    if is_true "${EULA}"; then
        if [ ! -f eula.txt ] || ! grep -q '^eula=true' eula.txt 2>/dev/null; then
            echo "eula=true" > eula.txt
            log_ok "Minecraft EULA accepted (eula.txt written)"
        fi
    fi
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
              else "\($b.id) \($b.downloads["server:default"].url)"
              end'
}

update_paper_family() {
    local project="$1" version="$2" channel="$3"

    if is_auto "${version}" || [ "${version}" = "latest" ]; then
        version=$(paper_latest_version "${project}")
        [ -z "${version}" ] && { log_warn "Could not resolve the latest ${project} version, skipping update"; return 1; }
    fi

    local result build url
    result=$(paper_latest_build "${project}" "${version}" "${channel}")
    [ -z "${result}" ] && { log_warn "No ${project} builds found for ${version}, skipping update"; return 1; }

    build=${result%% *}
    url=${result#* }

    local marker="${project}-${version}-${build}"
    if [ -f "${STATE_FILE}" ] && [ "$(cat "${STATE_FILE}")" = "${marker}" ] && [ -f "${SERVER_JARFILE}" ]; then
        log_ok "${project} ${version} build ${build} is already up to date"
        return 0
    fi

    log_info "Downloading ${project} ${version} build ${build}"
    if curl "${CURL_OPTS[@]}" -o "${SERVER_JARFILE}.tmp" "${url}"; then
        mv "${SERVER_JARFILE}.tmp" "${SERVER_JARFILE}"
        echo "${marker}" > "${STATE_FILE}"
        log_ok "Updated to ${project} ${version} build ${build}"
    else
        rm -f "${SERVER_JARFILE}.tmp"
        log_error "Download failed, keeping the current jar"
        return 1
    fi
}

update_purpur() {
    local version="$1"

    if is_auto "${version}" || [ "${version}" = "latest" ]; then
        version=$(curl "${CURL_OPTS[@]}" "https://api.purpurmc.org/v2/purpur" 2>/dev/null | jq -r '.metadata.current // .versions[-1] // empty')
        [ -z "${version}" ] && { log_warn "Could not resolve the latest Purpur version, skipping update"; return 1; }
    fi

    local build
    build=$(curl "${CURL_OPTS[@]}" "https://api.purpurmc.org/v2/purpur/${version}" 2>/dev/null | jq -r '.builds.latest // empty')
    [ -z "${build}" ] && { log_warn "No Purpur builds found for ${version}, skipping update"; return 1; }

    local marker="purpur-${version}-${build}"
    if [ -f "${STATE_FILE}" ] && [ "$(cat "${STATE_FILE}")" = "${marker}" ] && [ -f "${SERVER_JARFILE}" ]; then
        log_ok "Purpur ${version} build ${build} is already up to date"
        return 0
    fi

    log_info "Downloading Purpur ${version} build ${build}"
    if curl "${CURL_OPTS[@]}" -o "${SERVER_JARFILE}.tmp" "https://api.purpurmc.org/v2/purpur/${version}/${build}/download"; then
        mv "${SERVER_JARFILE}.tmp" "${SERVER_JARFILE}"
        echo "${marker}" > "${STATE_FILE}"
        log_ok "Updated to Purpur ${version} build ${build}"
    else
        rm -f "${SERVER_JARFILE}.tmp"
        log_error "Download failed, keeping the current jar"
        return 1
    fi
}

update_vanilla() {
    local version="$1"
    local manifest="https://launchermeta.mojang.com/mc/game/version_manifest.json"
    local json
    json=$(curl "${CURL_OPTS[@]}" "${manifest}" 2>/dev/null)
    [ -z "${json}" ] && { log_warn "Could not reach the Mojang manifest, skipping update"; return 1; }

    if is_auto "${version}" || [ "${version}" = "latest" ]; then
        version=$(echo "${json}" | jq -r '.latest.release')
    elif [ "${version}" = "snapshot" ]; then
        version=$(echo "${json}" | jq -r '.latest.snapshot')
    fi

    local marker="vanilla-${version}"
    if [ -f "${STATE_FILE}" ] && [ "$(cat "${STATE_FILE}")" = "${marker}" ] && [ -f "${SERVER_JARFILE}" ]; then
        log_ok "Vanilla ${version} is already up to date"
        return 0
    fi

    local version_url download_url
    version_url=$(echo "${json}" | jq -r --arg v "${version}" '.versions[] | select(.id == $v) | .url')
    [ -z "${version_url}" ] && { log_warn "Vanilla version ${version} not found, skipping update"; return 1; }

    download_url=$(curl "${CURL_OPTS[@]}" "${version_url}" 2>/dev/null | jq -r '.downloads.server.url // empty')
    [ -z "${download_url}" ] && { log_warn "Vanilla ${version} has no server jar, skipping update"; return 1; }

    log_info "Downloading Vanilla ${version}"
    if curl "${CURL_OPTS[@]}" -o "${SERVER_JARFILE}.tmp" "${download_url}"; then
        mv "${SERVER_JARFILE}.tmp" "${SERVER_JARFILE}"
        echo "${marker}" > "${STATE_FILE}"
        log_ok "Updated to Vanilla ${version}"
    else
        rm -f "${SERVER_JARFILE}.tmp"
        log_error "Download failed, keeping the current jar"
        return 1
    fi
}

run_auto_update() {
    is_true "${AUTO_UPDATE}" || return 0

    local project="${UPDATE_PROJECT}"
    if is_auto "${project}"; then
        # Map the detected type onto an updatable project where one exists.
        case "${SERVER_TYPE}" in
            velocity)   project="velocity" ;;
            bungeecord) project="waterfall" ;;
            vanilla)    project="paper" ;;
            *)          project="" ;;
        esac
    fi

    if [ -z "${project}" ]; then
        log_warn "Auto-update is on but '${SERVER_TYPE}' has no safe update path. Reinstall from the panel to change versions."
        return 0
    fi

    log_info "Auto-update: checking ${project}"
    case "${project}" in
        paper|folia|velocity|waterfall)
            update_paper_family "${project}" "${UPDATE_MC_VERSION}" "${UPDATE_CHANNEL:-STABLE}" ;;
        purpur)
            update_purpur "${UPDATE_MC_VERSION}" ;;
        vanilla)
            update_vanilla "${UPDATE_MC_VERSION}" ;;
        *)
            log_warn "Unknown update project '${project}', skipping" ;;
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
        log_info "Heap: MaxRAMPercentage=${MAX_RAM_PERCENTAGE:-80.0} (Xmx disabled)"
    else
        JVM_FLAGS+=("-Xms${xms}M" "-Xmx${SERVER_MEMORY}M")
        log_info "Heap: -Xms${xms}M -Xmx${SERVER_MEMORY}M"
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
        log_ok "Aikar's flags enabled"
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
        log_ok "Velocity recommended flags enabled"
        return 0
    fi

    case "${gc}" in
        g1)
            JVM_FLAGS+=(-XX:+UseG1GC)
            log_info "GC: G1" ;;
        zgc)
            if [ "${JAVA_MAJOR}" -ge 15 ]; then
                JVM_FLAGS+=(-XX:+UseZGC)
                log_info "GC: ZGC"
            else
                log_warn "ZGC needs Java 15+, falling back to the JVM default"
            fi ;;
        zgc-gen|generational-zgc)
            if [ "${JAVA_MAJOR}" -ge 24 ]; then
                # Generational mode is the default from 24 onwards and the
                # explicit flag was removed, so passing it aborts the JVM.
                JVM_FLAGS+=(-XX:+UseZGC)
                log_info "GC: Generational ZGC (default on Java ${JAVA_MAJOR})"
            elif [ "${JAVA_MAJOR}" -ge 21 ]; then
                JVM_FLAGS+=(-XX:+UseZGC -XX:+ZGenerational)
                log_info "GC: Generational ZGC"
            else
                log_warn "Generational ZGC needs Java 21+, falling back to the JVM default"
            fi ;;
        shenandoah)
            JVM_FLAGS+=(-XX:+UnlockExperimentalVMOptions -XX:+UseShenandoahGC)
            log_info "GC: Shenandoah (only available on some JVM builds)" ;;
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
        log_warn "Log4j2 mitigation enabled. This is not a substitute for running a patched build."
    fi

    if is_true "${SIMD_OPERATIONS}"; then
        if [ "${JAVA_MAJOR}" -ge 16 ]; then
            JVM_FLAGS+=(--add-modules=jdk.incubator.vector)
            log_info "SIMD (incubator vector module) enabled"
        else
            log_warn "SIMD needs Java 16+, skipping"
        fi
    fi

    JVM_FLAGS+=("-Duser.timezone=${TZ}")

    if [ -n "${EXTRA_JAVA_ARGS}" ]; then
        # Deliberately unquoted: the user is supplying a flag list.
        # shellcheck disable=SC2206
        JVM_FLAGS+=(${EXTRA_JAVA_ARGS})
        log_info "Extra JVM args: ${EXTRA_JAVA_ARGS}"
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
            log_error "Args file '${ARGS_FILE}' is missing. Reinstall the server from the panel."
            return 1
        fi
    elif [ ! -f "${SERVER_JARFILE}" ]; then
        log_error "Server jar '${SERVER_JARFILE}' not found in /home/container."
        log_error "Check the 'Server Jar File' variable, or reinstall the server."
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
                log_warn "Minecraft ${mc} needs Java ${need}+, but this image has Java ${JAVA_MAJOR}."
                log_warn "Change the Docker image in the panel or the server will fail to start."
            fi
        fi
    fi

    if [ "${IS_PROXY}" != "1" ] && ! grep -q '^eula=true' eula.txt 2>/dev/null; then
        log_warn "The EULA has not been accepted. The server will shut down immediately."
        log_warn "Set the EULA variable to true, or edit eula.txt."
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
            log_warn "Args file '${ARGS_FILE}' disappeared, falling back to -jar ${SERVER_JARFILE}"
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
log_ok "Detected server software: ${SERVER_TYPE}$([ -n "${ARGS_FILE}" ] && echo " (args: ${ARGS_FILE})")"

run_auto_update

# Detection runs again after an update: a jar swap can change the software.
if is_true "${AUTO_UPDATE}"; then
    ARGS_FILE=""
    detect_server_type
fi

accept_eula
apply_properties
apply_proxy_config

if ! validate; then
    log_error "Pre-flight validation failed. Aborting startup."
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
