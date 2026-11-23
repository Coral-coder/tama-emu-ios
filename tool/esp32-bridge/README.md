# Tama serial bridge (ESP32)

Connects a Tamagotchi's link port to the Tama app on an iPhone (which cannot use USB serial
adapters), over **Bluetooth LE** or **Wi-Fi**. Any ESP32 board works; the pins below are for the
**LilyGO TTGO T-LoRa (LoRa32) v1.3**.

## Boards

Any ESP32 with Bluetooth LE: the original ESP32 (T-LoRa, DevKit), **ESP32-C3** or **ESP32-S3**.
Not the ESP32-S2 (no Bluetooth). The program picks the pins for the chip it is built for:

| Chip | RX (from toy TX) | TX (to toy RX) |
|---|---|---|
| ESP32 (T-LoRa v1.3, DevKit) | GPIO 34 | GPIO 13 |
| ESP32-C3 (SuperMini, XIAO C3) | GPIO 20 | GPIO 21 |
| ESP32-S3 (XIAO S3) | GPIO 44 | GPIO 43 |

For the smallest build use an ESP32-C3 SuperMini (about 22 x 18 mm) or a Seeed XIAO ESP32-C3 /
S3 (21 x 17.5 mm). Pick the board in the Arduino IDE (e.g. *ESP32C3 Dev Module* with
*USB CDC On Boot* enabled, or *XIAO_ESP32C3*).

## Wiring

| ESP32 (T-LoRa v1.3) | Toy link port |
|---|---|
| GPIO 13 (TX) | RX |
| GPIO 34 (RX) | TX |
| GND | GND |

Three wires only: **do not connect the toy's power pin**. The line is 3.3 V, like the ESP32.
If the bridge hears nothing, swap TX and RX.

## Putting the program on the board

1. Install the Arduino IDE, then in *Settings → Additional boards manager URLs* add
   `https://espressif.github.io/arduino-esp32/package_esp32_index.json`, and in the
   *Boards Manager* install **esp32 by Espressif**.
2. Open `esp32-bridge.ino`. Board: **ESP32 Dev Module** (or *TTGO LoRa32-OLED*),
   Partition scheme: **Huge APP**.
3. Plug the board in with USB, pick its port, **Upload**. The serial monitor (115200) then shows
   `Tama Bridge: ...`.

Or with `arduino-cli`:

```
arduino-cli core install esp32:esp32
arduino-cli compile --fqbn esp32:esp32:esp32:PartitionScheme=huge_app tool/esp32-bridge
arduino-cli upload --fqbn esp32:esp32:esp32 -p /dev/cu.usbserial-XXXX tool/esp32-bridge
```

## Using it with the app

Power the board (USB power bank or charger). In Tama: **Tools → Hardware**.

* **Bluetooth:** *Scan for bridges*, tap **Tama Bridge**.
* **Wi-Fi:** join the Wi-Fi network **Tama-Bridge** (password `tamagotchi`) in the phone's
  Settings, then in Tama connect to `192.168.4.1` port `23`. Faster than Bluetooth: better for
  writing a whole ROM with Paramix.

The blue LED lights while the app is connected. Then link a game with **⋯ → Link with my real
unit**, or use Paramix's Device page.

The line runs at 460800 baud (the Paradise). For a first-generation toy's comm board, change
`BAUD` at the top of the program.
