#!/bin/sh
# Differential test of the Dart CPU core (lib/emu/cpu.dart) against the C core it was ported from
# (Paramix V1Emu's TamaLIB, third_party/paramix-studio/v1/src/core): random programs, the same
# key presses, and the registers, memory, LCD and buzzer events compared every 1000 steps.
set -e
cd "$(dirname "$0")/../.."
C=third_party/paramix-studio/v1/src/core
T=${TMPDIR:-/tmp}/tama-difftest; mkdir -p "$T"
cc -O1 -w -DV1_LINK -I$C tool/difftest/harness.c $C/cpu.c $C/hw.c $C/tamalib.c -o "$T/harness"
dart compile exe test/difftest_main.dart -o "$T/dt" >/dev/null
fail=0
for seed in 1 2 3 4 5 6 7 8; do
  python3 tool/difftest/gen.py $seed "$T/r$seed.bin"
  "$T/harness" "$T/r$seed.bin" 200000 > "$T/c$seed.txt"
  "$T/dt" "$T/r$seed.bin" 200000 > "$T/d$seed.txt"
  if cmp -s "$T/c$seed.txt" "$T/d$seed.txt"; then echo "seed $seed: same"; else echo "seed $seed: DIFFERENT"; diff "$T/c$seed.txt" "$T/d$seed.txt" | head -5; fail=1; fi
done
exit $fail
