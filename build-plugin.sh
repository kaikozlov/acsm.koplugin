#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P
)"
cd "${SCRIPT_DIR}"

if ! command -v git >/dev/null 2>&1; then
    echo "git is required to build the plugin package." >&2
    exit 1
fi

if ! command -v zip >/dev/null 2>&1; then
    echo "zip is required to build the plugin package." >&2
    exit 1
fi

PLUGIN_NAME="$(
    sed -nE "s/.*name[[:space:]]*=[[:space:]]*[\"']([^\"']+)[\"'].*/\\1/p" _meta.lua | head -n 1
)"

if [[ -z "${PLUGIN_NAME}" ]]; then
    echo "Could not determine plugin name from _meta.lua." >&2
    exit 1
fi

PLUGIN_DIRNAME="${PLUGIN_NAME}.koplugin"
OUTPUT_DIR="${1:-dist}"
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(
    cd "${OUTPUT_DIR}" && pwd -P
)"
ARCHIVE_PATH="${OUTPUT_DIR}/${PLUGIN_DIRNAME}.zip"

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${PLUGIN_NAME}.build.XXXXXX")"
trap 'rm -rf "${STAGING_DIR}"' EXIT
FILE_LIST="${STAGING_DIR}/lua-files.txt"

git ls-files -- "*.lua" | grep -Ev '^(REFERENCE|dist)/' > "${FILE_LIST}" || true

if [[ ! -s "${FILE_LIST}" ]]; then
    echo "No Lua files found to package." >&2
    exit 1
fi

while IFS= read -r path; do
    mkdir -p "${STAGING_DIR}/${PLUGIN_DIRNAME}/$(dirname "${path}")"
    install -m 0644 "${path}" "${STAGING_DIR}/${PLUGIN_DIRNAME}/${path}"
done < "${FILE_LIST}"

rm -f "${ARCHIVE_PATH}"
(
    cd "${STAGING_DIR}"
    zip -qr "${ARCHIVE_PATH}" "${PLUGIN_DIRNAME}"
)

echo "Built ${ARCHIVE_PATH}"
