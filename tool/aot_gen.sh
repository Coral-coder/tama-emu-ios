#!/bin/sh
# Natively compiles the built-in Paradise ROMs (see docs/recompiler.md): plays each decrypted dump
# in assets/roms/ for a while and writes the code it ran most as Rust functions into
# native/tama_core/src/aot_gen/blocks.rs. That file is made from the dumps, so it is ignored by
# git and must never be committed or put into a public build; tool/build_native.sh compiles it
# in when it is there. Without ROMs (no ROM_KEY) nothing is made and the app uses the runtime
# recompiler alone.
#   tool/aot_gen.sh                 from assets/roms/*.bin.gz (after tool/roms.sh decrypt)
#   tool/aot_gen.sh <dump.bin>...   from your own dumps (for a local build)
set -e
cd "$(dirname "$0")/.."
out=native/tama_core/src/aot_gen/blocks.rs
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [ $# -gt 0 ]; then
  set -- "$@"
else
  set --
  for g in assets/roms/paradise-*.bin.gz; do
    [ -f "$g" ] || continue
    b="$tmp/$(basename "$g" .gz)"
    gunzip -c "$g" > "$b"
    set -- "$@" "$b"
  done
fi
if [ $# -eq 0 ]; then
  echo "aot_gen: no Paradise dumps, no native blocks (the runtime recompiler is used)"
  rm -f "$out"
  exit 0
fi
case "$(pwd)" in /*) ;; esac
abs=""
for f in "$@"; do abs="$abs $(cd "$(dirname "$f")" && pwd)/$(basename "$f")"; done
(cd native/tama_core && cargo run --release --quiet --example aot_gen -- "src/aot_gen/blocks.rs" $abs)
