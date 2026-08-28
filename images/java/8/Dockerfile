#
# Multiversion Minecraft image for Pterodactyl (Java 8).
#
# Based on the upstream pterodactyl/yolks images, plus:
#   - jq and unzip, used by the download and auto-update logic
#   - yq, used to edit the server's YAML configs safely
#   - the multiversion entrypoint that detects the installed server software
#
# Build from the parent directory, since the entrypoint lives there:
#   docker buildx build -f java/8/Dockerfile -t <image>:java_8 .
#
# Licensed MIT, same as the upstream yolks images.
#

FROM        --platform=$TARGETOS/$TARGETARCH eclipse-temurin:8-jdk-jammy

LABEL       org.opencontainers.image.licenses=MIT
LABEL       org.opencontainers.image.title="Minecraft Multiversion (Java 8)"

RUN         apt-get update -y \
            && apt-get install -y \
                lsof curl ca-certificates openssl git tar sqlite3 fontconfig \
                libfreetype6 tzdata iproute2 libstdc++6 jq unzip \
            && rm -rf /var/lib/apt/lists/* \
            && useradd -d /home/container -m container

# yq edits YAML by structure instead of by regex. Editing spigot.yml or
# paper-world-defaults.yml with sed breaks as soon as a key name repeats under
# a different parent, which in those files it does.
# TARGETARCH is amd64/arm64, matching yq's own release naming.
ARG         TARGETARCH
ARG         YQ_VERSION=4.53.6
RUN         case "${TARGETARCH}" in amd64) YQ_SHA256=c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385 ;; arm64) YQ_SHA256=88a1016bc1d657375a35864e4f44b6f333df8ff97b559f51bba0adcb2169df09 ;; *) exit 1 ;; esac \
            && curl -fsSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${TARGETARCH}" -o /usr/bin/yq \
            && echo "${YQ_SHA256}  /usr/bin/yq" | sha256sum -c - \
            && chmod +x /usr/bin/yq \
            && yq --version

USER        container
ENV         USER=container HOME=/home/container
WORKDIR     /home/container

# Baked in at build time so a running container can identify itself in a
# support ticket, even when the tag has not changed and Wings served a cached
# image. Placed just before COPY so edits to the entrypoint do not invalidate
# the apt layer above.
ARG         BUILD_DATE=desconocida
ARG         BUILD_REF=local
ENV         MV_BUILD_DATE=${BUILD_DATE} MV_BUILD_REF=${BUILD_REF}

COPY        entrypoint.sh /entrypoint.sh
CMD         [ "/bin/bash", "/entrypoint.sh" ]
