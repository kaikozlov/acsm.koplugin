# justfile for acsm.koplugin
#
# Uses the koplugin-dev Docker image from GHCR for a unified test environment.
# No local toolchain required — just Docker (and `just`).
#
# Quick start:
#   just setup     # pull the image (one-time)
#   just test      # run all tests
#   just build     # build a release zip (versioned from _meta.lua)
#   just shell     # drop into the container

plugin_name          := "acsm"
koplugin_dev_version := "v2026.03_2"
image                := "ghcr.io/kaikozlov/koplugin-dev:" + koplugin_dev_version

# Version is read from _meta.lua so there is a single source of truth.
version := `sed -n 's/.*version *= *"\([^"]*\)".*/\1/p' _meta.lua`

# SDL dummy driver for headless KOReader
sdl_env := "-e SDL_VIDEODRIVER=dummy"

# Mount the repo as /opt/plugin (recipe cwd is always the justfile dir)
mount := "-v " + justfile_directory() + ":/opt/plugin -e PLUGIN_NAME=" + plugin_name

# Standard run (no network)
run          := "docker run --rm "       + sdl_env + " " + mount + " " + image
# Network-enabled run (for e2e tests that hit real servers)
run_network  := "docker run --rm --network=host " + sdl_env + " " + mount + " " + image
# Interactive run
run_it       := "docker run --rm -it "   + sdl_env + " " + mount + " " + image

# =============================================================================
# Default
# =============================================================================

[private]
[group('default')]
default:
    @just --list

# =============================================================================
# Setup
# =============================================================================

# Pull the koplugin-dev image
[group('setup')]
setup:
    docker pull {{image}}

# =============================================================================
# Testing
# =============================================================================

# Run all tests (excludes e2e)
[group('test')]
test:
    {{run}} busted-koreader --verbose \
        --helper=/opt/koplugin-dev/commonrequire.lua \
        --exclude-tags=e2e \
        /opt/plugin/spec/

# Run e2e tests only (requires network — hits real Adobe servers)
[group('test')]
test-e2e:
    {{run_network}} busted-koreader --verbose \
        --helper=/opt/koplugin-dev/commonrequire.lua \
        --filter=e2e \
        /opt/plugin/spec/

# Run all tests including e2e (requires network)
[group('test')]
test-all:
    {{run_network}} busted-koreader --verbose \
        --helper=/opt/koplugin-dev/commonrequire.lua \
        /opt/plugin/spec/

# Run tests matching a pattern, e.g. `just test-filter Crypto`
[group('test')]
test-filter filter:
    {{run}} busted-koreader --verbose \
        --helper=/opt/koplugin-dev/commonrequire.lua \
        --filter="{{filter}}" \
        /opt/plugin/spec/

# =============================================================================
# Linting
# =============================================================================

# Run luacheck inside the container
[group('lint')]
lint:
    {{run}} luacheck /opt/plugin

# =============================================================================
# Build
# =============================================================================

# Build a distributable zip (versioned from _meta.lua)
# Produces build/acsm.koplugin-<version>.zip
[group('build')]
build:
    #!/usr/bin/env bash
    set -euo pipefail
    version="{{version}}"
    echo "Building acsm.koplugin ${version}..."
    rm -rf build
    mkdir -p build
    tmpdir="$(mktemp -d)"
    mkdir "$tmpdir/acsm.koplugin"
    cp -r adobe dependencies *.lua LICENSE README.md "$tmpdir/acsm.koplugin/"
    (cd "$tmpdir" && zip -rq - .) > "build/acsm.koplugin-${version}.zip"
    rm -rf "$tmpdir"
    echo "Built: build/acsm.koplugin-${version}.zip"

# =============================================================================
# Interactive
# =============================================================================

# Drop into a shell in the dev container
[group('interactive')]
shell:
    {{run_it}} /bin/bash

# Start KOReader's LuaJIT REPL
[group('interactive')]
lua:
    {{run_it}} /opt/lib/koreader/luajit

# =============================================================================
# Cleanup
# =============================================================================

# Remove build artifacts
[group('default')]
clean:
    rm -rf build
    rm -f test-results.xml
