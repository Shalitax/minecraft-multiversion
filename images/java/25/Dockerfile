#
# Multiversion Minecraft image for Pterodactyl (Java 25).
#
# Based on the upstream pterodactyl/yolks images, plus:
#   - jq and unzip, used by the download and auto-update logic
#   - yq, used to edit the server's YAML configs safely
#   - the multiversion entrypoint that detects the installed server software
#
# Build from the parent directory, since the entrypoint lives there:
#   docker buildx build -f java/25/Dockerfile -t <image>:java_25 .
#
# Licensed MIT, same as the upstream yolks images.
#

FROM        --platform=$TARGETOS/$TARGETARCH eclipse-temurin:25-jdk

LABEL       org.opencontainers.image.licenses=MIT
LABEL       org.opencontainers.image.title="Minecraft Multiversion (Java 25)"

RUN         apt-get update -y \
            && apt-get install -y \
                lsof curl ca-certificates openssl git tar sqlite3 fontconfig \
                libfreetype6 tzdata iproute2 libstdc++6 jq unzip zip \
            && rm -rf /var/lib/apt/lists/* \
            && useradd -d /home/container -m container

# yq edits YAML by structure instead of by regex. Editing spigot.yml or
# paper-world-defaults.yml with sed breaks as soon as a key name repeats under
# a different parent, which in those files it does.
# TARGETARCH is amd64/arm64, matching yq's own release naming.
ARG         TARGETARCH
RUN         curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${TARGETARCH}" -o /usr/bin/yq \
            && chmod +x /usr/bin/yq \
            && yq --version

USER        container
ENV         USER=container HOME=/home/container
WORKDIR     /home/container

COPY        entrypoint.sh /entrypoint.sh
CMD         [ "/bin/bash", "/entrypoint.sh" ]
