# Paramix tools as native code (port in progress)

Goal: every Paramix Studio tool in the app with native screens and no web view. The Studio's logic
(third_party/paramix-studio/src/*.js, GPL-3.0, DOM-free modules) is ported to Dart in
lib/paramix/, module by module, and each port is checked byte for byte against the JavaScript
original run in Node on real dumps.

## Rules for a module port

- One Dart file per JS module: lib/paramix/<module>.dart (feld.dart, six.dart, emu_build.dart,
  saves.dart, core_more.dart). Pure Dart: only dart:typed_data / dart:convert / dart:math and
  other files in lib/paramix (bytes.dart, edition.dart, sprites.dart, sprite_edit.dart). No
  Flutter imports (the checks run with `dart run`).
- Same function names as the JS (camelCase), same behaviour, same error cases (throw
  FormatException / StateError with the JS message in English). Keep JS comments that explain
  offsets. JS numbers: mind `>>> 0`, `|0`, 32-bit wraparound, Math.imul; use `& 0xFFFFFFFF`.
- Helpers a module needs from core.js that are not yet in lib/paramix go into your own file as
  private functions (leading underscore), with a `// from core.js: <name>` comment, so parallel
  ports do not edit the same file. Do not edit files owned by other ports or existing files
  except to add a missing export you need from bytes.dart (append only).
- Embedded binaries (feld.bin, six.bin, emu.bin, ... which the JS gets as Base64 placeholders
  filled in by build.js) are passed in as Uint8List arguments; the app loads them from
  assets/paramix/ (same files as third_party/paramix-studio/<dir>/*.bin; add missing ones to
  the list in docs under "assets needed", do not copy binaries yourself unless they are already
  in third_party/paramix-studio).
- Check: tool/paramix_check/<module>.js (Node, requires the JS sources from third_party; for
  embedded binaries read how build.js fills the placeholders and do the same in the check) and
  tool/paramix_check/<module>_check.dart (run with `dart run tool/paramix_check/<module>_check.dart`).
  Both take the dumps folder from the environment variable DUMPS (files water.bin, land.bin,
  sky.bin, jade.bin, tropical.bin, glacier.bin, neon.bin: 16 MB Paradise flash dumps), run the
  same list of cases (every public function with representative options, on every edition it
  applies to) and print one line per case: `<case name> <sha256 or value>`. The port is done when
  the two outputs are identical. Outputs contain only hashes, sizes and offsets.
- The dumps are private: never copy them or bytes from them into the repository, a test
  fixture, a log or your report. Do not commit or push; leave the files in the working tree.
- Report: files written, the functions ported, the exact check commands and their result
  (how many cases, all identical or which differ), anything not ported and why.

## Assets needed

emu_build.dart (EmuBinaries / EmuApps; same files as third_party/paramix-studio/<dir>/):

- already in assets/paramix/: emu.bin, stub_tpl.bin, t7.bin, t7x.bin, t18.bin, t18x.bin, v1.bin, v3.bin
- still to add: gb/gb.bin, gb/gbc.bin, sms/sms.bin, pm/pm.bin, ab/ab.bin, wolf/wolf.bin,
  wolf/wolfsod.bin, and for DOOM in the menu doom/doomf_app.bin, doom/doomf_xip.bin (DoomApp)
