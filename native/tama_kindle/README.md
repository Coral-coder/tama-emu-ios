# Tama on a Kindle

Tamagotchi Paradise on a jailbroken Kindle with root over ssh. Written for the Paperwhite 3
(DP75SDI); other i.MX6 Kindles with an 8 bit grey framebuffer should behave the same.

The game's screen is drawn in grey, seven times as large; A, B and C are fields on the
touchscreen; the cross at the top right ends the program and writes the save. The game's
clock follows the Kindle's. There is no sound (the Paperwhite has no speaker).

## Build

    rustup target add armv7-unknown-linux-musleabihf
    cargo build --release --target armv7-unknown-linux-musleabihf

Add `--features aot` when `../tama_core/src/aot_gen/blocks.rs` exists (made from your own
dumps by `tool/aot_gen.sh`, never part of the repository): the game then runs faster.
The result is one static program, `target/armv7-unknown-linux-musleabihf/release/tama_kindle`.

## Run

Copy the program and your own dump to the Kindle, then over ssh:

    stop lab126_gui                      # the Kindle's own interface, so it does not draw over the game
    /mnt/us/tama/tama_kindle /mnt/us/tama/neon.bin
    start lab126_gui                     # afterwards

The save lies next to the dump (`neon.bin.tamasave`, the app's format). `TAMA_KEY=<hex>` gives
another device key, `TAMA_FPS=<n>` another limit of screen refreshes per second (default 4).

Without a Kindle: `TAMA_FAKE=out.pgm TAMA_SECONDS=20 tama_kindle dump.bin` runs the game on a
screen in memory and writes the picture at the end.
