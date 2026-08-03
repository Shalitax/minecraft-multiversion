#!/usr/bin/env bash
#
# Builds and optionally pushes every Java image variant.
#
# The Dockerfiles reference ../entrypoint.sh, so the build context must be this
# directory, not the per-version folder. That is why every build passes
# `-f java/<tag>/Dockerfile .` from here.
#
# Usage:
#   ./build.sh                      build every tag locally
#   ./build.sh 21 17                build only the listed tags
#   PUSH=1 ./build.sh               build and push
#   REGISTRY=ghcr.io/me/mc ./build.sh
#
set -euo pipefail

cd "$(dirname "$0")"

# CHANGE THIS to your own registry namespace before pushing.
REGISTRY="${REGISTRY:-ghcr.io/shalitax/minecraft-multiversion}"
PUSH="${PUSH:-0}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"

ALL_TAGS=(8 8j9 11 11j9 16 16j9 17 17j9 18 18j9 19 19j9 20 21 22 23 24 25)

# The IBM Semeru base images have no arm64 build, so those tags stay amd64-only.
amd64_only() {
    case "$1" in
        *j9) return 0 ;;
        *)   return 1 ;;
    esac
}

TAGS=("$@")
[ ${#TAGS[@]} -eq 0 ] && TAGS=("${ALL_TAGS[@]}")

# Matches the placeholder by substring, so that set-registry.sh rewriting the
# default above does not turn this guard against a real registry.
case "${REGISTRY}" in
    *CHANGEME*)
        echo "WARNING: REGISTRY is still the placeholder. Set it before pushing." >&2
        [ "${PUSH}" = "1" ] && { echo "Refusing to push to a placeholder registry." >&2; exit 1; }
        ;;
esac

# Docker repository names must be lowercase.
case "${REGISTRY}" in
    *[A-Z]*)
        echo "ERROR: registry name must be lowercase: ${REGISTRY}" >&2
        echo "Try: $(echo "${REGISTRY}" | tr '[:upper:]' '[:lower:]')" >&2
        exit 1
        ;;
esac

for tag in "${TAGS[@]}"; do
    if [ ! -f "java/${tag}/Dockerfile" ]; then
        echo "Skipping unknown tag '${tag}'" >&2
        continue
    fi

    image="${REGISTRY}:java_${tag}"
    platforms="${PLATFORMS}"
    amd64_only "${tag}" && platforms="linux/amd64"

    echo "==> Building ${image} (${platforms})"

    if [ "${PUSH}" = "1" ]; then
        docker buildx build \
            --platform "${platforms}" \
            -f "java/${tag}/Dockerfile" \
            -t "${image}" \
            --push \
            .
    else
        # buildx cannot load a multi-platform result into the local daemon, so
        # local builds are restricted to the host architecture.
        docker buildx build \
            -f "java/${tag}/Dockerfile" \
            -t "${image}" \
            --load \
            .
    fi
done

echo "Done."
