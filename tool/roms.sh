#!/bin/bash
# Built-in ROMs. The repository is public, so the ROMs are kept encrypted (AES-256, key in the
# ROM_KEY secret); the build decrypts them into assets/roms/ (which is not committed).
#   tool/roms.sh add <file> <id> "<name>"   encrypt one ROM into roms/enc/ (needs ROM_KEY)
#   tool/roms.sh decrypt                    roms/enc -> assets/roms (skipped without ROM_KEY)
set -euo pipefail
cd "$(dirname "$0")/.."
ENC=roms/enc
case "${1:-}" in
  add)
    f="$2"; id="$3"; name="$4"
    : "${ROM_KEY:?set ROM_KEY}"
    size=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f")
    kind=other; [ "$size" = 16777216 ] && kind=paradise
    if [ "$size" = 12288 ] || [ "$size" = 16384 ]; then kind=e0c6s4x; fi
    gzip -9 -n -c "$f" | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass env:ROM_KEY -out "$ENC/$id.bin.gz.enc"
    python3 - "$ENC/index.json" "$id" "$name" "$kind" "$size" <<'PY'
import json, sys, os
p, i, n, k, s = sys.argv[1:]
idx = json.load(open(p)) if os.path.exists(p) else []
idx = [e for e in idx if e['id'] != i] + [{'id': i, 'name': n, 'kind': k, 'size': int(s), 'file': i + '.bin.gz', 'note': 'your ROM'}]
json.dump(sorted(idx, key=lambda e: e['name']), open(p, 'w'), indent=1)
PY
    echo "added $id ($kind, $size bytes)";;
  decrypt)
    if [ -z "${ROM_KEY:-}" ]; then echo "ROM_KEY not set: building without the built-in ROMs"; exit 0; fi
    mkdir -p assets/roms
    for e in "$ENC"/*.bin.gz.enc; do
      out="assets/roms/$(basename "$e" .enc)"
      openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:ROM_KEY -in "$e" -out "$out"
    done
    cp "$ENC/index.json" assets/roms/index.json
    # the device keys of the built-in dumps (keys.json.enc: {"<id>": "<8 hex digits>"}) go into the index
    if [ -f "$ENC/keys.json.enc" ]; then
      openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:ROM_KEY -in "$ENC/keys.json.enc" -out assets/roms/keys.json
      python3 - <<'PY'
import json
idx = json.load(open('assets/roms/index.json')); keys = json.load(open('assets/roms/keys.json'))
for e in idx:
    if e['id'] in keys: e['key'] = keys[e['id']]
json.dump(idx, open('assets/roms/index.json', 'w'), indent=1)
PY
      rm assets/roms/keys.json
    fi
    echo "decrypted $(ls "$ENC"/*.bin.gz.enc | wc -l) ROMs into assets/roms";;
  *) echo "usage: $0 add <file> <id> <name> | decrypt"; exit 1;;
esac
