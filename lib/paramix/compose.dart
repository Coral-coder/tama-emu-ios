// The build of a new ROM, as Paramix Studio's composeRom does it (app.js:2634; the order and the
// messages are in docs/paramix-ui-spec.md, section 3). This file covers the menu and the fields;
// characters, names, emulators and DOOM join as their ports land.
import 'dart:typed_data';

import 'core_more.dart' show textApply, textGet;
import 'feld.dart';
import 'six.dart';

/// The device programs the build installs (assets/paramix/).
class ComposeAssets {
  const ComposeAssets({required this.feld, required this.feldS, required this.stubFeld, required this.stubEmu, required this.six});
  final Uint8List feld, feldS, stubFeld, stubEmu, six;
}

class ComposeOptions {
  const ComposeOptions({
    this.fields = false,
    this.bag = false,
    this.tama = false,
    this.gplay = false,
    this.sixWant = false,
    this.sixOff = false,
    this.sixSource,
    this.sixPlanet = true,
    this.sixMenu = true,
    this.texts = const {},
  });

  /// The settings a ROM already has (to build it again with something else changed).
  factory ComposeOptions.of(Uint8List rom, ComposeAssets a, {Map<int, String> texts = const {}}) {
    final m = feldFind(rom, a.stubFeld);
    final s = sixInfo(rom);
    final f = m?.flags ?? 0;
    return ComposeOptions(
      fields: (f & fFields) != 0,
      bag: (f & fBag) != 0,
      tama: (f & fTama) != 0,
      gplay: (f & fGplay) != 0,
      sixPlanet: s?.planet ?? true,
      sixMenu: s?.fieldMenu ?? true,
      texts: texts,
    );
  }

  /// New names: text number -> name (cleaned with textClean).
  final Map<int, String> texts;

  /// Several saves with field choice; items and Tamapoints; change Tama; play time earns points.
  final bool fields, bag, tama, gplay;

  /// More fields (Tropical / Glacier: all 6 from [sixSource]; Jade Forest: Sky), or take them out.
  final bool sixWant, sixOff;
  final Uint8List? sixSource;
  final bool sixPlanet, sixMenu;

  bool get menuWanted => fields || bag || tama;
}

class ComposeError implements Exception {
  ComposeError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// app.js:481 fieldTexts(rom, six) for the Names list: each field's name and the text numbers
/// that hold it (a base field named LAND / WATER / SKY shares its text with the extra field's).
List<({List<int> idx, String name})> fieldTextRows(Uint8List rom) {
  const lws = ['LAND', 'WATER', 'SKY'];
  final fn = fieldNames(rom).map((s) => s.toUpperCase()).toList();
  final out = <({List<int> idx, String name})>[];
  for (var i = 0; i < fn.length; i++) {
    final k = lws.indexOf(fn[i]), own = i < 3 ? 14 + i : (k >= 0 ? 64 + k : -1);
    if (own < 0) continue;
    final idx = [own];
    if (i < 3 && k >= 0 && textGet(rom, 64 + k) == textGet(rom, own)) idx.add(64 + k);
    out.add((idx: idx, name: textGet(rom, own)));
  }
  return out;
}

/// app.js:481 fieldTexts(rom): the field names as the ROM's text table has them.
List<String> fieldTexts(Uint8List rom) {
  const lws = ['LAND', 'WATER', 'SKY'];
  final fn = fieldNames(rom).map((s) => s.toUpperCase()).toList(), out = <String>[];
  for (var i = 0; i < fn.length; i++) {
    final k = lws.indexOf(fn[i]), own = i < 3 ? 14 + i : (k >= 0 ? 64 + k : -1);
    if (own < 0) continue;
    out.add(textGet(rom, own));
  }
  return out;
}

String _msg(Object e) => e is StateError ? e.message : (e is FormatException ? e.message : '$e');

/// A new ROM from [src] with the menu and fields of [o]. Throws [ComposeError] with the Studio's
/// message when something does not go together.
Uint8List composeRom(Uint8List src, ComposeOptions o, ComposeAssets a) {
  const emu = FeldEmuPort();
  final embOld = FeldEmbedded(stub: a.stubFeld, oldStub: a.stubEmu);
  final old = feldApps(src, a.stubFeld);
  if (old.apps.isNotEmpty) {
    throw ComposeError('This ROM has more programs in its menu. Rebuilding those is not in the app yet.');
  }
  // 5. names (app.js:2664)
  var rom = src;
  if (o.texts.isNotEmpty) {
    try {
      rom = textApply(rom, o.texts);
    } catch (e) {
      throw ComposeError('Too big for the free space. ${_msg(e)}');
    }
  }
  // 6. the saves stored in the menu, then the old menu out (app.js:2665)
  var saved = feldSlots(src, a.stubFeld);
  rom = feldStrip(rom, embOld, emu);

  // 15. six fields (app.js:2713)
  if (o.sixOff && sixInfo(rom) != null) {
    final base = fieldNames(sixStrip(src)), now = fieldNow(src);
    if (!base.contains(now)) throw ComposeError('The device is on $now now. First switch to ${base.join(', ')} in the menu.');
    rom = sixStrip(rom);
    saved = [];
  }
  final needSrc = sixNeedsSource(rom);
  final six = o.sixSource;
  if (o.sixWant && needSrc && six == null && sixInfo(rom) == null) {
    throw ComposeError('All 6 fields still need a Land, Water or Sky ROM.');
  }
  final have = sixInfo(rom);
  bool same(SixInfo s) => s.planet == o.sixPlanet && s.fieldMenu == o.sixMenu;
  final current = have != null && have.version >= sixVersion && same(have) && !sixStale(have);
  if (have != null && !current && needSrc && six == null && !o.sixOff) {
    throw ComposeError('Changing this setting needs your Land, Water or Sky ROM again.');
  }
  if (!o.sixOff && (six != null || (o.sixWant && !needSrc) || (!needSrc && have != null)) && !current) {
    if (appKind(rom) != 0) throw ComposeError('Fields not built in: DOOM and the emulator do not fit with it');
    try {
      rom = sixApply(rom, six, a.six, planet: o.sixPlanet, fieldMenu: o.sixMenu);
    } catch (e) {
      throw ComposeError('Fields not built in: ${_msg(e)}');
    }
  }
  if (sixInfo(rom) != null) {
    rom = sixDna(rom, a.six, true);
    rom = sixHunt(rom);
    rom = sixFix(rom);
  }

  // 17. the menu (app.js:2764); without it the menu stays out
  if (o.menuWanted) {
    final kind = appKind(rom);
    final name0 = kind == 1 ? 'DOOM' : old.name0;
    try {
      rom = feldApply(
        rom,
        FeldOpts(
          fields: o.fields,
          bag: o.bag,
          tama: o.tama,
          gplay: o.gplay,
          saves: true,
          name0: name0,
          mainSrc: old.mainSrc ?? 0,
          auto: old.auto ?? false,
          fieldNames: fieldTexts(rom),
        ),
        saved,
        FeldEmbedded(stub: a.stubFeld, feld: a.feld, feldS: a.feldS),
        emu,
      );
    } catch (e) {
      throw ComposeError('Menu not built in: ${_msg(e)}');
    }
  }
  return rom;
}
