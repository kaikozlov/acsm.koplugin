#!/bin/bash
set -e

rm -rf ./build/

mkdir -p build
cd "$(dirname "$0")"

# Create a temp dir with the desired top-level folder structure
tmpdir=$(mktemp -d)
mkdir "$tmpdir/acsm.koplugin"
cp -r adobe/ dependencies/ *.lua LICENSE README.md "$tmpdir/acsm.koplugin/"

# Zip from inside the temp dir so paths start with acsm.koplugin/
(cd "$tmpdir" && zip -r - .) > build/acsm.koplugin.zip

rm -rf "$tmpdir"
echo "Built: build/acsm.koplugin.zip"
