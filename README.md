# Tama

Tamagotchi emulator, Paramix Studio and UART tools for iOS and Android (Flutter).
Bundle ID `com.lightwave.tama`.

## What it does

- **Play** – emulates the first-generation toys (Epson E0C6S46 / E0C6S48): Tamagotchi P1, P2,
  Angel, Mothra, Morino, Umino, Genjintchi, Digital Monster V1–V3 and others, from your own ROM
  (12 KB or 16 KB). Full screen with icons, A/B/C keys, shake sensor, buzzer, save slots, clock
  sync, fast forward.
  - **Runs in the background**: live while the app is in the background (iOS audio session,
    Android foreground service), and with *keep living* the time the app was closed is played
    through on the next start, as on a real toy.
- **Library** – your ROMs: import, export/share, rename, open in the emulator or the Studio. The
  Paradise flash dumps you own are built into the iOS build (see *Built-in ROMs*).
- **Studio** – [Paramix Studio](https://github.com/mameise/paramix-studio) by mameise inside the
  app: open a Paradise ROM, change it, save it, and write it to the device. Its Web Serial calls
  go to the app's UART connection, its downloads come back to the app (library / share).
- **UART** – connects to the dongle or a comm board (P-Com and similar): BLE serial bridges
  (Nordic UART, HM-10), USB serial adapters on Android (CH34x, CP210x, FTDI, PL2303, CDC-ACM via
  usb-serial-for-android), Wi-Fi serial bridges (TCP). Terminal with text/hex.
- **Link** – the emulated toy's contact (P20) as Paramix *plink* `D` frames, so it can meet:
  - a real toy on the UART (a Paradise running V1Emu: Digimon battles), *Emulator ↔ UART*
  - another phone through the internet with a shared code, *Emulator ↔ Tunnel*
  - and two real toys can be relayed phone to phone, *UART ↔ Tunnel*.
  The tunnel is end-to-end encrypted (AES-GCM, key from the code) over a public MQTT relay.

iPhones give apps no access to USB serial adapters; use a BLE or Wi-Fi serial bridge there.
The Paradise itself (Cortex-M3 SoC) is not emulated; its dumps are for the Studio.

## Layout

| Path | What |
| --- | --- |
| `lib/emu/cpu.dart` | E0C6S46/48 CPU: Dart port of TamaLIB with Paramix V1Emu's fixes |
| `lib/emu/hw.dart`, `rom_info.dart`, `rom_db.dart` | LCD wiring per toy, ROM detection, icons (from Paramix) |
| `lib/emu/machine.dart` | the running toy: pacing, sound, keys, clock, saves, link |
| `lib/emu/plink.dart` | Paramix plink frames and edge playback |
| `lib/services/` | library, UART transports, tunnel, link routing, native bridge |
| `lib/ui/` | screens |
| `assets/studio/bridge.js` | Web Serial / download bridge inlined into the Studio |
| `third_party/paramix-studio` | submodule: Paramix Studio (built by `tool/build_studio.sh`) |
| `third_party/tamalib` | submodule: upstream TamaLIB, for reference |
| `tool/difftest/` | runs the Dart core against the C core on random programs (bit-exact) |
| `roms/enc/` | built-in ROMs, encrypted |

## Building

```bash
git submodule update --init --recursive
```

```bash
tool/build_studio.sh
```

```bash
flutter pub get && flutter test && tool/difftest/run.sh
```

```bash
flutter build apk --release
```

## Built-in ROMs

The repository is public, so ROMs are stored encrypted (`roms/enc`, AES-256 with the `ROM_KEY`
secret). The iOS build decrypts them into `assets/roms/` and builds them in; without `ROM_KEY`
it builds without them. The public Android release never contains them. Add one with
`ROM_KEY=… tool/roms.sh add <file> <id> "<name>"`.

## CI

- `.github/workflows/ios-testflight.yml` – archives and uploads to TestFlight. Put `*u` in the
  subject of a commit on `main` to upload (`*b` to archive only), or run it by hand. Needs the
  App Store Connect secrets (`APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`) and
  `ROM_KEY` for the built-in ROMs. The app record for `com.lightwave.tama` must exist in App Store
  Connect (or `APPLE_ID` + `FASTLANE_SESSION` secrets so the workflow can create it).
- `.github/workflows/android-release.yml` – analyze, tests, the core difftest, then a signed APK
  published as a GitHub release on every push to `main` (keystore from the secrets; see the
  workflow header for the accepted secret names).

## Theme

`.claude/skills/vfd-theme/SKILL.md` is the "Amber VFD" dot-matrix theme. Ask for "vfd" to use it.

## Licences

Tama is free software under the GNU GPL v3 (`LICENSE`). It contains a Dart port of TamaLIB
(© Jean-Christophe Rona, GPL-2.0-or-later) with changes by mameise from Paramix Studio
(GPL-3.0), Paramix Studio itself (GPL-3.0) and its menu icons. Tamagotchi and Digital Monster are
trademarks of BANDAI; this project is not affiliated with them. Use only ROMs you own.
