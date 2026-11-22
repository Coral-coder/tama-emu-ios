# Tama

Tamagotchi emulator, Paramix Studio and UART tools for iOS and Android (Flutter).
Bundle ID `com.lightwave.tama`.

## What it does

Everything is native (Flutter + Rust), no web views.

- **Play** – a cover grid of your games. Paradise dumps show their own edition's field as cover
  (taken from the ROM's graphics); first-generation toy ROMs show their egg.
  - **Tamagotchi Paradise**: [Capybara](https://github.com/infinition/capybara) (infinition,
    GPL-3.0), an ARMv7-M + Sonix SNC73410 emulator that runs the real firmware of your dump, built
    into the app as a Rust library (`native/tama_core`). Colour screen, A/B/C, the dial, sound, the
    game's own save. Each dump needs its device key (typed in, or searched on the phone).
  - **First toys** (E0C6S46/48: P1, P2, Angel, Mothra, Digital Monster V1–V3 …): a Dart port of
    TamaLIB with Paramix V1Emu's fixes, checked bit-exact against the C core.
  - Both keep running in the background (iOS audio session, Android foreground service).
- **Device** – Paramix Studio's device tab, ported natively (`lib/paramix/flash.dart`): over a USB
  serial adapter on USB OTG (any adapter: CH34x, CP210x, FTDI, PL2303, CDC-ACM, unknown ones tried
  as CDC-ACM) the app loads Paramix's flash app from the download screen, reads the 16 MB flash
  into the library, and writes a ROM back: only changed sectors, keeping the saves, with the
  rescue start. Checked against Paramix's own bytes and a simulated device (`test/`).
- **Studio** – the ROMs: details (edition, fields, pictures decoded from the ROM), play, export,
  write to the device. More of Paramix (saves, emulator installs, characters, fields) is being
  ported.
- **Link** – emulator ↔ UART ↔ internet tunnel (plink frames, AES-GCM tunnel with a code).

iPhones give apps no access to USB serial adapters (Android does); on an iPhone use a BLE or Wi-Fi
serial bridge (connections page under Device).

## Layout

| Path | What |
| --- | --- |
| `native/tama_core` | Rust: the Capybara emulator core with a C ABI (`tool/build_native.sh`) |
| `lib/paradise/` | Dart FFI binding and the running Paradise |
| `lib/paramix/` | native ports of Paramix Studio: device protocol, editions, ROM assets / sprites |
| `lib/emu/` | first-generation toy emulator (TamaLIB port), plink |
| `lib/services/`, `lib/ui/` | library, UART transports, tunnel; screens |
| `third_party/capybara` | submodule: Capybara (Paradise emulator) |
| `third_party/paramix-studio` | submodule: Paramix Studio (reference and its device programs, `tool/sync_paramix.sh`) |
| `third_party/tamalib` | submodule: upstream TamaLIB |
| `roms/enc/` | built-in ROMs, encrypted |

## Building

```bash
git submodule update --init --recursive
```

```bash
tool/sync_paramix.sh && tool/build_native.sh android   # or ios / host
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

Tama is free software under the GNU GPL v3 (`LICENSE`). It contains Capybara (© infinition, GPL-3.0) as a library, a Dart port of TamaLIB
(© Jean-Christophe Rona, GPL-2.0-or-later) with changes by mameise from Paramix Studio
(GPL-3.0), native ports of Paramix Studio (GPL-3.0) with its device programs and menu icons. Tamagotchi and Digital Monster are
trademarks of BANDAI; this project is not affiliated with them. Use only ROMs you own.
