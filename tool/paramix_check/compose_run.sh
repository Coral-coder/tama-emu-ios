#!/bin/sh
# Runs both checks in N parallel parts and compares them.
#   DUMPS=<dumps> JSDOM=<scratch>/node_modules/jsdom OUT=<scratch folder> [N=4] [ONLY=<regex>] sh tool/paramix_check/compose_run.sh
# Needs node and dart on the PATH. Leaves $OUT/compose_js.txt and $OUT/compose_dart.txt.
set -e
N=${N:-4}
cd "$(dirname "$0")/../.."
[ -d third_party/paramix-studio/dist ] || (cd third_party/paramix-studio && node build.js)
dart compile exe tool/paramix_check/compose_check.dart -o "$OUT/compose_check.exe" >/dev/null
i=0
while [ $i -lt $N ]; do
  node tool/paramix_check/compose.js $i/$N > "$OUT/compose_js.$i" 2> "$OUT/compose_js.$i.err" &
  "$OUT/compose_check.exe" $i/$N > "$OUT/compose_dart.$i" 2> "$OUT/compose_dart.$i.err" &
  i=$((i + 1))
done
wait
: > "$OUT/compose_js.txt"; : > "$OUT/compose_dart.txt"
i=0
while [ $i -lt $N ]; do cat "$OUT/compose_js.$i" >> "$OUT/compose_js.txt"; cat "$OUT/compose_dart.$i" >> "$OUT/compose_dart.txt"; i=$((i + 1)); done
echo "lines: $(wc -l < "$OUT/compose_js.txt") (page) $(wc -l < "$OUT/compose_dart.txt") (Dart)"
if cmp -s "$OUT/compose_js.txt" "$OUT/compose_dart.txt"; then echo identical; else echo DIFFERENT; diff "$OUT/compose_js.txt" "$OUT/compose_dart.txt" | head -40 | cut -c1-400; exit 1; fi
