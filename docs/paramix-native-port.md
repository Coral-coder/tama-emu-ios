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

## The build pipeline (app.js)

The glue code of the page (third_party/paramix-studio/src/app.js) is specified in
docs/paramix-ui-spec.md. Its logic is in three files (pure Dart, names as in app.js):

- lib/paramix/build_state.dart: `BuildState`, the `state` object of the page with the same field
  names. `BuildState.load(rom, assets)` is loadRom (detection, reading back an already modified
  ROM). Its methods do what the page's handlers do, with the same messages (collected in
  `messages`): `chooseFirmware`, `addExtra`, `addArduboy`, `addWolf`, `addFigures`, `makeMain`,
  `mainChecked`, `pick`, `removeExtra`, `removeMain`, `undoMain`, `doomOut`, `doomBack`, `doomOff`,
  `setDoom`, `setLaunch`, `setClean`, `setSixOn`, `setSixSource`, `setName`, the setters of the
  rows, `roomTry` / `roomFit`, `plan()` (the "Your new ROM" box), `packedTamas`.
- lib/paramix/compose_full.dart: `composeFull(state)` is composeRom / composeClean (spec section
  3). It returns the ROM, the file name, the ranges that come from the image even with "Keep
  saves" and the messages; where the page stops with an error toast it throws `ComposeError` with
  the same English text.
- lib/paramix/doom_port.dart: the key layout as the state keeps it, DOOM into the ROM, and
  `DoomPort`, the WAD conversion the pipeline calls (wadEpisodes, wadMerge, wadSub, gbaExtras,
  convert). `DoomDartPort` (the default of `BuildAssets.doomPort`) is doom.dart.
  `BuildState.chooseWad(wad)` is the page's WAD dialog: `doomCompute` (app.js) and `setDoom`.
  `BuildState.chooseWolf(files)` builds the Wolf3D pack with wolf.dart and adds it (`addWolf`).

Check: tool/paramix_check/compose.js loads the page as built (dist/ParamixStudio.html) under jsdom
and drives it through its own handlers; tool/paramix_check/compose_check.dart does the same steps
with `BuildState`. The cases are in compose_cases.json (written by compose_cases_gen.js), the
steps are explained in compose_cases.md. flash.dart's withRescue differs from flash.js (it takes
the battery picture from the image); the build uses its own port of the Studio's in
compose_full.dart.

    npm install --prefix <scratch> jsdom
    DUMPS=<dumps> JSDOM=<scratch>/node_modules/jsdom OUT=<scratch> sh tool/paramix_check/compose_run.sh

Assets needed in addition (BuildAssets): doom/doom_app.bin and doom/doom_xip.bin (DOOM next to
the Paradise, at its fixed place).

## DOOM, Wolf3D, simulated visit (doom.js, wolf.js, visit.js)

- lib/paramix/doom.dart: all of doom.js except `embedded()`. `convert` is the WAD converter itself,
  ported from its C source (third_party/paramix-studio/doom/src/wasm, MCUDoomWadUtil, GPL-2.0),
  so no WebAssembly is needed: `convert(sub, extras)` is synchronous and gives the same bytes as
  doom/mcuwad.wasm. `doomBuild(rom, wad, emb, episode:, music:, keys:)` is the whole path.
- lib/paramix/wolf.dart: pickSet, build, readGraph, NEED.
- lib/paramix/visit.dart: `Visitor` / `createVisitor` (feed(bytes) in, send(bytes) out, or
  `listen(stream)`), parseKey, crypt, crc16, ED. The link key is `linkKey` of flash.dart.

Checks (the WADs, game files and the Paradise side of a visit are synthetic and made the same way
on both sides; only doom needs the dumps):

    DUMPS=<dumps> node tool/paramix_check/doom.js  > a; DUMPS=<dumps> dart run tool/paramix_check/doom_check.dart  > b; cmp a b
    node tool/paramix_check/wolf.js  > a; dart run tool/paramix_check/wolf_check.dart  > b; cmp a b
    node tool/paramix_check/visit.js > a; dart run tool/paramix_check/visit_check.dart > b; cmp a b

Assets needed: doom.dart takes doom/doom_app.bin and doom/doom_xip.bin (or doomf_app.bin and
doomf_xip.bin) and emu/stub_tpl.bin as `DoomEmb`; doom/mcuwad.wasm is not needed. wolf.dart and
visit.dart need none (wolf/wolf.bin and wolf/wolfsod.bin are for emu_build.dart).

## Save tab and the device panel's save buttons (Paradise save)

- lib/paramix/save_flow.dart: the handlers of app.js for the Paradise save without their page glue
  (spec section 5): `devSaveRead` ("Back up save"), `devSaveCheck` / `devSaveWrite` ("Save to
  device"), `slotWriteCheck` / `slotWrite` / `slotClear` (slots of the menu on the device),
  `romSave`, `romSlotSave`, `romSaveExport`, `petOpen`, `petChars`, `petNow`, `petChange`,
  `petApply`, `petSaveRom`, `petSaveFile`, the texts (`saveTexts`, `t`, `saveMsg`). The device is
  `SaveDevice` (`ParadiseSaveDevice` for flash.dart's `Paradise`); `usedSectors`, `changed` and
  `writeSectors` (with the rescue guard) are flash.js' own, over that interface. Not in the
  Studio: `romSaveWrite` (any save into a ROM, with the checks of "Save to device"), `gameSave`
  (the save of a game of the app, through the image), `charLooks` (names and pictures).
- The emulator saves of the Save tab ("Programs") and of "Back up save" (TamaEmu, T7Emu) are not
  ported here.
- Screen: lib/ui/saves_screen.dart, backups in lib/services/save_backups.dart.

Check (the handlers need the DOM, so saveflow.js restates their bodies over saves.js, feld.js and
flash.js' Paradise object on a flash in memory; texts are read out of app.js) and the simulated toy:

    DUMPS=<dumps> node tool/paramix_check/saveflow.js > a; DUMPS=<dumps> dart run tool/paramix_check/saveflow_check.dart > b; cmp a b
    flutter test test/flash_sim_test.dart
