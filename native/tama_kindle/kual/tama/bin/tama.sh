#!/bin/sh
# KUAL starts and stops Tama. The dump is the first .bin in /mnt/us/tama (your own file); the
# save and a log lie next to it.
HERE="$(cd "$(dirname "$0")" && pwd)"
DATA=/mnt/us/tama
LOG="$DATA/tama.log"

if [ "$1" = "stop" ]; then
	killall tama_kindle 2>/dev/null
	exit 0
fi

# started by KUAL: carry on without it, so closing its menu does not end the game
if [ "$1" != "run" ]; then
	mkdir -p "$DATA"
	if command -v setsid >/dev/null 2>&1; then
		setsid "$0" run >/dev/null 2>&1 &
	else
		nohup "$0" run >/dev/null 2>&1 &
	fi
	exit 0
fi

sleep 1
DUMP="$(ls "$DATA"/*.bin 2>/dev/null | head -n 1)"
if [ -z "$DUMP" ]; then
	eips 2 2 "Tama: put your dump (a .bin file) into the tama folder" 2>/dev/null
	echo "no .bin in $DATA" >"$LOG"
	exit 1
fi
if pidof tama_kindle >/dev/null 2>&1; then
	exit 0
fi

# the Kindle's window manager rests meanwhile, so it does not draw over the game
killall -STOP awesome 2>/dev/null
chmod +x "$HERE/tama_kindle" 2>/dev/null
"$HERE/tama_kindle" "$DUMP" >"$LOG" 2>&1
killall -CONT awesome 2>/dev/null
# the page that was there comes back
eips -f '' >/dev/null 2>&1
lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home 2>/dev/null
exit 0
