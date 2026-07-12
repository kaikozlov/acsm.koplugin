# justfile for acsm.koplugin
#
# Shared recipes come from a sibling checkout of koplugin-dev.
# No local toolchain required — just Docker (and `just`).
#
# Quick start:
#   just setup     # install git hooks and pull the image (one-time)
#   just test      # run all tests (quiet; V=1 for verbose)
#   just build     # build a release zip (versioned from _meta.lua)
#   just shell     # drop into the container

plugin_name := "acsm"
koplugin_dev_version := "v2026.03_4"
plugin_path := "/opt/plugin"
spec_dir := "spec"
lua_paths := "adobe spec main.lua _meta.lua"
has_go := "0"
go_integration_packages := ""
exclude_tags := "e2e"

# Version is read from _meta.lua so there is a single source of truth.
version := `sed -n 's/.*version *= *"\([^"]*\)".*/\1/p' _meta.lua`

import "../koplugin-dev/shared.just"

# =============================================================================
# Build (product-specific)
# =============================================================================

# Build a distributable zip (versioned from _meta.lua)
# Produces build/acsm-koplugin-<version>.zip
[group('build')]
build:
    #!/usr/bin/env bash
    set -euo pipefail
    version="{{ version }}"
    echo "Building acsm.koplugin ${version}..."
    rm -rf build
    mkdir -p build
    tmpdir="$(mktemp -d)"
    mkdir "$tmpdir/acsm.koplugin"
    cp -r adobe dependencies *.lua LICENSE README.md "$tmpdir/acsm.koplugin/"
    (cd "$tmpdir" && zip -rq - .) > "build/acsm-koplugin-${version}.zip"
    rm -rf "$tmpdir"
    echo "Built: build/acsm-koplugin-${version}.zip"
