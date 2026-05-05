# Docker test environment for acsm.koplugin
#
# Runs busted tests against a real KOReader Linux release (headless).
# Uses Ubuntu's apt-packaged `lua-busted` (which includes all deps:
# luassert, say, mediator, cliargs, dkjson, penlight, term) so we never
# touch luarocks at runtime.
#
# The image only contains the slow-to-install stuff (Ubuntu packages,
# KOReader release, busted wrapper). Plugin source is mounted at runtime
# via `docker run -v`, so you never need to rebuild just because code changed.
#
# Usage:
#   make docker-test     (builds image if needed, then runs tests)

ARG KOREADER_VERSION=v2026.03
# Architecture: x86_64 (Intel/AMD) or arm64 (Apple Silicon / Graviton)
ARG ARCH=arm64

FROM ubuntu:22.04

ARG KOREADER_VERSION
ARG ARCH

ENV DEBIAN_FRONTEND=noninteractive

# System deps:
#   - ca-certificates / curl / xz-utils → fetch + extract KOReader release
#   - libc6-dev / libssl3 → KOReader's bundled binaries link against these
#   - lua-busted → busted + all transitive Lua deps (in /usr/share/lua/5.1/)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    xz-utils \
    libc6-dev \
    libssl3 \
    lua-busted \
    && rm -rf /var/lib/apt/lists/*

# Download and extract the official KOReader Linux release
RUN mkdir -p /opt && \
    curl -fSL -o /tmp/koreader.tar.xz \
      "https://github.com/koreader/koreader/releases/download/${KOREADER_VERSION}/koreader-linux-${ARCH}-${KOREADER_VERSION}.tar.xz" && \
    tar xf /tmp/koreader.tar.xz -C /opt/ && \
    rm /tmp/koreader.tar.xz && \
    /opt/lib/koreader/luajit -v

ENV KOREADER_DIR=/opt/lib/koreader

# Make KOReader's bundled luajit find busted's Lua files (installed by apt
# under /usr/share/lua/5.1/) and KOReader's own modules.
# busted itself is pure Lua so KOReader's luajit can run it directly.
ENV LUA_PATH="/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;${KOREADER_DIR}/common/?.lua;${KOREADER_DIR}/frontend/?.lua;${KOREADER_DIR}/?.lua;;"
ENV LUA_CPATH="/usr/lib/aarch64-linux-gnu/lua/5.1/?.so;/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;${KOREADER_DIR}/common/?.so;;"

# Install a `busted` wrapper that invokes KOReader's luajit with the
# already-installed busted Lua sources. This is what `make docker-test` runs.
RUN printf '#!/bin/sh\nexec %s /usr/bin/busted "$@"\n' "${KOREADER_DIR}/luajit" \
      > /usr/local/bin/busted-koreader && \
    chmod +x /usr/local/bin/busted-koreader && \
    # Sanity check: busted reports its version
    cd "${KOREADER_DIR}" && /usr/local/bin/busted-koreader --version

# Create the symlink mount point. The Makefile mounts plugin source here
# at runtime via `docker run -v`. This keeps the image stable — no rebuilds
# needed when plugin code changes.
RUN ln -sf /opt/acsm.koplugin /opt/lib/koreader/plugins/acsm.koplugin

WORKDIR /opt/lib/koreader

CMD ["busted-koreader", "--verbose", \
     "--helper=/opt/acsm.koplugin/spec/commonrequire.lua", \
     "--pattern=_spec", \
     "--exclude-tags=e2e", \
     "/opt/acsm.koplugin/spec/integration/"]

