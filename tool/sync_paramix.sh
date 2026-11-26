#!/bin/sh
# Copies the device programs Paramix Studio ships (built from its sources in the submodule) into
# assets/paramix/, where the app's native Paramix port loads them:
#   flashapp.bin   the flash app that reads/writes the Paradise over the UART (flash/src)
#   emu.bin, stub_tpl.bin, v1.bin, v3.bin, t7.bin, t7x.bin, t18.bin, t18x.bin ... emulators for the ROM
set -e
cd "$(dirname "$0")/.."
P=third_party/paramix-studio
[ -f $P/build.js ] || git submodule update --init $P
mkdir -p assets/paramix
cp $P/flash/flashapp.bin assets/paramix/
for f in emu/emu.bin emu/stub_tpl.bin v1/v1.bin v3/v3.bin t7/t7.bin t7/t7x.bin t18/t18.bin t18/t18x.bin feld/feld.bin feld/stub_feld_tpl.bin feld/feldc.bin feld/feld_s.bin feld/feldc_s.bin six/six.bin gb/gb.bin gb/gbc.bin sms/sms.bin pm/pm.bin ab/ab.bin wolf/wolf.bin wolf/wolfsod.bin doom/doomf_app.bin doom/doomf_xip.bin; do
  [ -f $P/$f ] && cp $P/$f assets/paramix/
done
ls assets/paramix
