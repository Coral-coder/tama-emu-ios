// DOOM for the build pipeline: the parts of Paramix Studio's src/doom.js (mameise, GPL-3.0-or-later)
// that only move bytes (the program into the ROM, the key layout), and the interface for the parts
// that are not ported: the WAD conversion (wadSub, gbaExtras and convert, which runs the WebAssembly
// module doom/mcuwad.wasm).
//
// Names as in doom.js.

// ignore_for_file: constant_identifier_names, non_constant_identifier_names

import 'dart:typed_data';

import 'bytes.dart';

const int CODE_OFF = 0xB1000, SAVE_OFF = 0x10E000, SAVE_END = 0x110000;
const int WAD_OFF = 0x830000, REGION_OFF = 0xCA0000, REGION_END = 0xD48000;

/// doom.js embedded(): doom_app.bin and doom_xip.bin (DOOM at its fixed place next to the Paradise),
/// doomf_app.bin and doomf_xip.bin (DOOM as a program of the menu).
class DoomEmbedded {
  const DoomEmbedded({required this.app, required this.xip, this.appF, this.xipF});
  final Uint8List app, xip;
  final Uint8List? appF, xipF;
}

/// The functions of doom.js that a later port has to bring (or a bridge to the JavaScript ones):
/// what [doomBuild] needs to get from the user's WAD to the data the DOOM program reads.
abstract class DoomPort {
  /// doom.js `wadEpisodes(d)`: the episodes of a WAD ('1'..'4', 'M' for DOOM II).
  List<String> wadEpisodes(Uint8List wad);

  /// doom.js `wadMerge(base, [{ data, slot }])`: extra WADs merged into the base (slot: an own episode into the
  /// place of E4).
  Uint8List wadMerge(Uint8List base, List<({Uint8List data, bool slot})> pw);

  /// doom.js `wadSub(src, eps, music, only)`: the WAD cut down to the episodes [eps] ('1', '123', 'M'),
  /// with or without its music; only: the map names to keep (a map pack alone).
  Uint8List wadSub(Uint8List src, String eps, bool music, [Set<String>? only]);

  /// doom.js `gbaExtras(wad)`: the replacement for gbadoom.wad, built from the user's own WAD.
  Uint8List gbaExtras(Uint8List wad);

  /// doom.js `convert(sub, extras, wasm)`: the converter (WebAssembly in the Studio).
  Future<Uint8List> convert(Uint8List sub, Uint8List extras);
}

/// The functions of emu.js that doom.js calls on its `E` argument.
typedef DoomInstallApp = Uint8List Function(Uint8List rom, Uint8List app, Uint8List stubTpl);

/// Button mapping in the program's PDMC settings block (from DOOM v0.4.0, version 2):
/// button masks A 1, B 2, C 4, wheel press 8. Fixed: A+C menu, B+C map,
/// wheel for 2 s returns to the Paradise.
Map<String, Object> get KEYS_DEFAULT => {'fire': 1, 'fwd': 2, 'back': 4, 'use': 8, 'mod': 4, 'run': true, 'invert': true};

int _u32(Uint8List b, int o) => o >= 0 && o + 4 <= b.length ? u32(b, o) : 0;

int _pdmcAt(Uint8List rom) {
  for (var i = 0xA0000; i < 0xA0400; i += 4) {
    if (_u32(rom, i) == 0x434D4450) return i;
  }
  return -1;
}

/// Button mapping of a ROM with DOOM, or null (no DOOM, or an old version without mapping).
Map<String, Object>? doomKeysGet(Uint8List rom) {
  final i = _pdmcAt(rom);
  if (i < 0 || _u32(rom, i + 4) < 2) return null;
  return {
    'fire': _u32(rom, i + 48),
    'fwd': _u32(rom, i + 52),
    'back': _u32(rom, i + 56),
    'use': _u32(rom, i + 60),
    'mod': _u32(rom, i + 64),
    'run': _u32(rom, i + 68) != 0,
    'invert': _u32(rom, i + 44) != 0,
  };
}

/// Check a mapping: returns an error text or ''.
String doomKeysCheck(Map<String, Object> k) {
  if (k['fire'] == k['fwd'] || k['fire'] == k['back'] || k['fwd'] == k['back']) return 'fire, forward and back need three different buttons';
  if (k['use'] != 8 && [k['fire'], k['fwd'], k['back']].contains(k['use'])) return 'use needs its own button or the wheel';
  return '';
}

bool _on(Object? v) => v == true || (v is num && v != 0);
int _num(Object? v) => v is int ? v : (v is num ? v.toInt() : (v == true ? 1 : 0));

/// Write a mapping into a ROM with DOOM (new image).
Uint8List doomKeysSet(Uint8List rom, Map<String, Object> k) {
  final out = Uint8List.fromList(rom);
  final i = _pdmcAt(out);
  if (i < 0 || _u32(out, i + 4) < 2) throw StateError('this DOOM has no key layout of its own yet');
  final err = doomKeysCheck(k);
  if (err.isNotEmpty) throw StateError(err);
  w32(out, i + 44, _on(k['invert']) ? 1 : 0);
  w32(out, i + 48, _num(k['fire']));
  w32(out, i + 52, _num(k['fwd']));
  w32(out, i + 56, _num(k['back']));
  w32(out, i + 60, _num(k['use']));
  w32(out, i + 64, _num(k['mod']));
  w32(out, i + 68, _on(k['run']) ? 1 : 0);
  return out;
}

/// Install DOOM. rom: 16 MB Paradise image, mcu: converted WAD, app/xip: doom_app.bin and doom_xip.bin,
/// stub: emu/stub_tpl.bin, installApp: emu.js installApp. Returns the new image.
Uint8List doomPatch(Uint8List rom, Uint8List mcu, DoomEmbedded emb, Uint8List stub, DoomInstallApp installApp) {
  if (rom.length != 0x1000000) throw StateError('the Paradise image must be 16 MB');
  final assetEnd = 0x111000 + 16 + u32(rom, 0x111000 + 8);
  if (assetEnd > WAD_OFF) throw StateError('the character data reaches 0x${assetEnd.toRadixString(16)}, DOOM needs 0x830000 onwards');
  if (CODE_OFF + emb.xip.length > SAVE_OFF) throw StateError('DOOM program too big');
  final free = REGION_OFF - WAD_OFF - 4 - mcu.length;
  if (free < 0) throw StateError('WAD too big: ${mcu.length >> 10} KB, room ${(REGION_OFF - WAD_OFF - 4) >> 10} KB (try without music)');
  // Program and stub as for the emulator (shared stub, A+C), but without color Tama firmware
  final out = installApp(rom, emb.app, stub);
  out.fillRange(CODE_OFF, SAVE_END, 0xFF);
  out.setAll(CODE_OFF, emb.xip);
  out.fillRange(WAD_OFF, REGION_END, 0xFF);
  w32(out, WAD_OFF, mcu.length);
  out.setAll(WAD_OFF + 4, mcu);
  return out;
}

/// Full path from the user's own WAD to the ROM (doom.js doomBuild). The conversion is [port]'s.
Future<Uint8List> doomBuild(Uint8List rom, Uint8List wad, DoomPort port, DoomEmbedded emb, Uint8List stub, DoomInstallApp installApp,
    {String? episode, bool music = true, Map<String, Object>? keys}) async {
  final eps = episode != null && episode.isNotEmpty ? episode : '1';
  final sub = port.wadSub(wad, eps, music);
  final mcu = await port.convert(sub, port.gbaExtras(sub));
  return doomBuilt(rom, mcu, emb, stub, installApp, keys: keys);
}

/// The second half of doomBuild, for a WAD that is already converted.
Uint8List doomBuilt(Uint8List rom, Uint8List mcu, DoomEmbedded emb, Uint8List stub, DoomInstallApp installApp, {Map<String, Object>? keys}) {
  final r = doomPatch(rom, mcu, emb, stub, installApp);
  return keys != null ? doomKeysSet(r, keys) : r;
}
