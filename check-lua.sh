#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P
)"
cd "${SCRIPT_DIR}"

if ! command -v luajit >/dev/null 2>&1; then
    echo "luajit is required for syntax checks." >&2
    exit 1
fi

if ! command -v luacheck >/dev/null 2>&1; then
    echo "luacheck is required for static checks." >&2
    exit 1
fi

echo "LuaJIT syntax check"
git ls-files -- "*.lua" ":!REFERENCE/**" |
while IFS= read -r path; do
    luajit -b "${path}" /tmp/acsm-koplugin.ljbc >/dev/null
done

echo "Luacheck"
luacheck --codes --no-color --ignore 212 213 241 631 -- \
    _meta.lua \
    main.lua \
    acsm_service.lua \
    libby_client.lua \
    libby_state.lua \
    libby_store.lua \
    libby_ui.lua \
    overdrive_client.lua
