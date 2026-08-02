#
# Multiversion Minecraft image for Pterodactyl (Java 18j9).
#
# Based on the upstream pterodactyl/yolks images, with two additions:
#   - jq and unzip, required by the auto-update logic in the entrypoint
#   - the multiversion entrypoint that detects the installed server software
#
# Build from the parent directory, since the entrypoint lives there:
#   docker buildx build -f java/18j9/Dockerfile -t <image>:java_18j9 .
#
# Licensed MIT, same as the upstream yolks images.
#

FROM        --platform=$TARGETOS/$TARGETARCH ibm-semeru-runtimes:open-18-jdk

LABEL       org.opencontainers.image.licenses=MIT
LABEL       org.opencontainers.image.title="Minecraft Multiversion (Java 18j9)"

RUN         apt-get update -y \
            && apt-get install -y \
                lsof curl ca-certificates openssl git tar sqlite3 fontconfig \
                libfreetype6 tzdata iproute2 libstdc++6 jq unzip zip \
            && rm -rf /var/lib/apt/lists/* \
            && useradd -d /home/container -m container

USER        container
ENV         USER=container HOME=/home/container
WORKDIR     /home/container

COPY        entrypoint.sh /entrypoint.sh
CMD         [ "/bin/bash", "/entrypoint.sh" ]
