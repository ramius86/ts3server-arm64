ARG DEBIAN_DIGEST=sha256:ba2cad883e2f99ecb98e6787b8af96504565bd42579a587286417a58d2df457f

# ============================================================
# Stage 1 — downloader
# Downloads and verifies the TS3 server tarball at build time.
# None of these tools (wget, bzip2) appear in the final image.
# ============================================================
FROM arm64v8/debian@${DEBIAN_DIGEST} AS downloader

# These values are the source of truth for the bundled TS3 version.
# DO NOT edit manually — check-ts-version.yml patches them automatically
# via `sed` whenever a new release is detected on teamspeak.com/versions/server.json,
# opening a PR (branch bump/ts3-X.X.X) with the updated values.
ARG TS_VERSION=3.13.7
ARG TS_CHECKSUM=775a5731a9809801e4c8f9066cd9bc562a1b368553139c1249f2a0740d50041e

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        wget bzip2 ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /download

RUN wget -q -O ts.tar.bz2 \
      "https://files.teamspeak-services.com/releases/server/${TS_VERSION}/teamspeak3-server_linux_amd64-${TS_VERSION}.tar.bz2" && \
    echo "${TS_CHECKSUM}  ts.tar.bz2" | sha256sum -c - && \
    mkdir /ts-extracted && \
    tar xf ts.tar.bz2 --strip-components=1 -C /ts-extracted && \
    # Remove files not needed at runtime
    rm -f ts.tar.bz2 \
          /ts-extracted/ts3server_minimal_runscript.sh \
          /ts-extracted/ts3server_startscript.sh \
          /ts-extracted/LICENSE \
          /ts-extracted/CHANGELOG \
          /ts-extracted/libts3db_mariadb.so && \
    rm -rf /ts-extracted/doc \
           /ts-extracted/redist \
           /ts-extracted/serverquerydocs

# ============================================================
# Stage 2 — runtime
# Minimal image: only what ts3server actually needs at runtime.
# No wget, curl, jq, bzip2, libdigest-sha-perl.
# ============================================================
FROM arm64v8/debian@${DEBIAN_DIGEST}

# Redeclared to make TS_VERSION available in this stage (ARG scope resets after FROM).
# Value is inherited from the build-arg passed by docker-publish.yml at build time.
ARG TS_VERSION=3.13.7

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Runtime dependencies only:
#   box64      - x86_64 emulation layer for ts3server binary
#   tini       - PID 1: signal forwarding + zombie reaping
#   gosu       - privilege drop from root to ts user
#   tzdata     - timezone support (configurable via TIME_ZONE env)
#   locales    - en_US.UTF-8 locale for ts3server
#   procps     - pkill used in entrypoint signal handling
#   ca-certificates - TLS verification
#   netcat-openbsd  - used for healthchecks
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        procps ca-certificates locales \
        box64 tzdata tini gosu netcat-openbsd && \

    mkdir -p /teamspeak /teamspeak_cached && \
    sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    dpkg-reconfigure --frontend=noninteractive locales && \
    update-locale LANG=en_US.UTF-8 && \
    ln -fs /usr/share/zoneinfo/UTC /etc/localtime && \
    echo "UTC" > /etc/timezone && \
    dpkg-reconfigure -f noninteractive tzdata && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8

# Runtime environment
# PUID/PGID: user/group ID for the ts3server process (avoids clash with bash $UID builtin)
ENV TIME_ZONE=UTC
ENV PUID=1000
ENV PGID=1000
ENV INIFILE=0
ENV DEBUG=0
ENV TS3SERVER_LICENSE=accept
# Baked version — informational, used by startup.sh to write /teamspeak/version
ENV TS_VERSION=${TS_VERSION}

LABEL org.opencontainers.image.title="TeamSpeak 3 Server (ARM64)"
LABEL org.opencontainers.image.description="Unofficial TeamSpeak 3 server Docker image for ARM64, running the x86_64 binary via box64 emulation on arm64v8/debian:trixie-slim."
LABEL org.opencontainers.image.version=${TS_VERSION}
LABEL org.opencontainers.image.url="https://github.com/ramius86/ts3server-arm64"
LABEL org.opencontainers.image.source="https://github.com/ramius86/ts3server-arm64"
LABEL org.opencontainers.image.licenses="MIT"

# Copy extracted TS3 binaries from downloader stage
COPY --from=downloader /ts-extracted/ /teamspeak/

# Copy shell scripts directly into /teamspeak/
COPY --chmod=755 entrypoint.sh startup.sh /teamspeak/

WORKDIR /teamspeak

# tini as PID 1 (signal forwarding + zombie reaping)
# entrypoint.sh handles privilege drop via gosu
ENTRYPOINT ["/usr/bin/tini", "--", "/teamspeak/entrypoint.sh"]

HEALTHCHECK --interval=1m --timeout=5s --start-period=2m --retries=3 \
    CMD nc -z 127.0.0.1 10011 || exit 1
