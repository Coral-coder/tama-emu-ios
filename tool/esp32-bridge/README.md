# Tama Bridge (ESP32)

A small ESP32 between a Tamagotchi's link port and the Tama app: for an iPhone (which cannot use
USB serial adapters), over **Bluetooth LE** or **Wi-Fi**, and between two real toys directly
(two bridges talking Bluetooth: a playdate with no phone).

## Getting the firmware on the board

**Windows (easiest):** Releases page of this repository → the newest `esp32-bridge-…` →
download `Tama-Bridge-Windows-flasher.zip`, unzip it, plug the ESP32 in with USB and
double-click **flash.bat**. It finds the board, recognises its chip and writes the right firmware.
If the board is not found: install its USB driver (CP210x or CH340), or hold **BOOT** while
plugging it in.

**Other systems:** write the `.bin` for your chip at address `0x0` with esptool, or in Chrome at
https://espressif.github.io/esptool-js/.

**From the source:** Arduino IDE with *esp32 by Espressif* and the library *ArduinoJson*; open
`esp32-bridge.ino`, partition scheme *Huge APP*, upload.

## Boards and wiring

Any ESP32 with Bluetooth LE. Not the ESP32-S2 (no Bluetooth).

| Chip | Bridge RX (from toy TX) | Bridge TX (to toy RX) |
|---|---|---|
| ESP32 (T-LoRa v1.3, DevKit) | GPIO 34 | GPIO 13 |
| ESP32-C3 (SuperMini, XIAO C3) | GPIO 20 | GPIO 21 |
| ESP32-S3 (XIAO S3) | GPIO 44 | GPIO 43 |
| ESP32-C6 (XIAO C6, DevKit) | GPIO 17 | GPIO 16 |

Plus **GND to GND**. Three wires only: do not connect the toy's power. The line is 3.3 V.
If nothing comes through, swap TX and RX. Smallest boards: ESP32-C3 SuperMini (about 22 × 18 mm),
Seeed XIAO (21 × 17.5 mm).

## Using it with the app

* **Tools → Dongle:** finds the bridge over Bluetooth and shows its settings: its name, the line
  speed, Wi-Fi (its own network, or join yours), and the link to another bridge.
* **Tools → Hardware:** connect to it for play: *Scan for bridges* (Bluetooth), or Wi-Fi to
  `192.168.4.1` port 23 (its own network **Tama-Bridge**, password `tamagotchi`) or to the address
  the Dongle page shows when it has joined your network (also `tama-bridge.local`).
* Then in a game: **⋯ → Link with my real unit**, or Paramix's Device page.

## Two real toys, no phone

Each toy gets a bridge. In **Tools → Dongle**, connected to one of them: **Link to another
bridge** → pick the other → on. The two bridges keep the link (also after a restart); start the
playdate on both toys. Turn the link on in one bridge only.

The line runs at 460800 baud (the Paradise); for a first-generation toy's comm board, change it in
the Dongle page.
