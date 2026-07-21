# justfile for acsm.koplugin
#
# Shared recipes are vendored from koplugin-dev (just/shared.just).
# No local toolchain required — just Docker (and `just`).
#
# Quick start:
#   just setup     # install git hooks and pull the image (one-time)
#   just verify    # read-only formatting, lint, and all non-e2e tests
#   just test      # run all tests (quiet; V=1 for verbose)
#   just build     # build a release zip (versioned from _meta.lua)
#   just shell     # drop into the container
#
# When shared recipes change upstream:
#   just sync-shared   # refresh just/shared.just (then commit)

plugin_name := "acsm"
koplugin_dev_version := "v2026.03_7"
# Git ref used by `just sync-shared` (recipe source). Independent of the image pin.
koplugin_dev_ref := env("KOPLUGIN_DEV_REF", "main")
plugin_path := "/opt/plugin"
spec_dir := "spec"
lua_paths := "adobe spec main.lua _meta.lua"
has_go := "0"
go_integration_packages := ""
exclude_tags := "e2e"

# Version is read from _meta.lua so there is a single source of truth.
version := `sed -n 's/.*version *= *"\([^"]*\)".*/\1/p' _meta.lua`

import "./just/shared.just"

# =============================================================================
# Canonical verification
# =============================================================================

# Read-only static checks suitable for pre-commit.
[group('lint')]
verify-static: fmt-check lint

# Definitive local/CI verification. Networked e2e tests remain explicit.
[group('test')]
verify: verify-static test

# =============================================================================
# Setup (plugin-local)
# =============================================================================

# Refresh just/shared.just from upstream koplugin-dev
[group('setup')]
sync-shared:
    #!/usr/bin/env bash
    set -euo pipefail
    ref="{{ koplugin_dev_ref }}"
    mkdir -p just
    tmp="$(mktemp)"
    url="https://raw.githubusercontent.com/kaikozlov/koplugin-dev/${ref}/shared.just"
    echo "Fetching ${url}"
    curl -fsSL "$url" -o "$tmp"
    {
        echo "# Vendored from https://github.com/kaikozlov/koplugin-dev"
        echo "# Ref: ${ref}"
        echo "# Refresh with: just sync-shared"
        echo
        cat "$tmp"
    } > just/shared.just
    rm -f "$tmp"
    echo "Updated just/shared.just from koplugin-dev@${ref}"

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
    cp -r adobe dependencies patches *.lua LICENSE README.md "$tmpdir/acsm.koplugin/"
    (cd "$tmpdir" && zip -rq - .) > "build/acsm-koplugin-${version}.zip"
    rm -rf "$tmpdir"
    echo "Built: build/acsm-koplugin-${version}.zip"
