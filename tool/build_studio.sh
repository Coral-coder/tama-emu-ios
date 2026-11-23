#!/bin/sh
# Builds Paramix Studio from its submodule (third_party/paramix-studio, GPL-3.0) and puts it, with
# the app's bridge inlined, into assets/studio/index.html (generated, not committed).
set -e
cd "$(dirname "$0")/.."
[ -f third_party/paramix-studio/build.js ] || git submodule update --init third_party/paramix-studio
(cd third_party/paramix-studio && node build.js)
python3 tool/studio_asset.py
