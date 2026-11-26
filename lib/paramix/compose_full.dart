// The build of a new ROM: Paramix Studio's composeRom (app.js:2634) and composeClean (app.js:2580)
// (third_party/paramix-studio/src/app.js, mameise, GPL-3.0-or-later), step by step as
// docs/paramix-ui-spec.md, section 3 lists them, with the helpers that only the build uses
// (currentDataPack, keptT18Ranges, t18Fresh, dlStrip).
//
// composeFull(state) returns the new ROM, its file name and the messages; what the page shows as
// an error toast and stops at is a ComposeError with the same English text. The build changes the
// state as the page's does (spec 3: extrasDedupe, paraMainSync / doomFreeSync, the keys and data of
// DOOM entries, lastRoom / lastFree).

// ignore_for_file: library_prefixes, non_constant_identifier_names

import 'dart:convert';
import 'dart:typed_data';

import 'build_state.dart';
import 'core_more.dart' as C;
import 'doom_port.dart' as D;
import 'emu_build.dart' as E;
import 'feld.dart' as F;
import 'flash.dart' as FL;
import 'saves.dart' as SV;
import 'six.dart' as S6;

/// What a build gives: the new ROM, its file name, the sprite rebuild (null without one: `res.free` is the room
/// left for characters), the ranges that must come from the image even with "Keep saves" (imported saves), and
/// the messages. [same]: nothing was changed, [rom] is the loaded ROM ("Nothing changed yet.").
class ComposeResult {
  ComposeResult(this.rom, this.name, {this.res, List<(int, int)>? fresh, this.same = false}) : fresh = fresh ?? [];
  final Uint8List rom;
  final String name;
  final C.BuiltRom? res;
  final List<(int, int)> fresh;
  final bool same;
  List<BuildMessage> messages = const [];
}

/// The new ROM from the loaded one and everything chosen in [s]. Throws [ComposeError] with the Studio's message
/// when something does not go together.
Future<ComposeResult> composeFull(BuildState s) async {
  E.emuBinaries = s.assets.emu;
  final n0 = s.messages.length;
  s.lastError = null;
  final c = await composeRaw(s);
  if (c == null) throw ComposeError(s.lastError ?? '?');
  c.messages = s.messages.sublist(n0);
  return c;
}

int half(int v) => v.sign * (v.abs() / 2).round(); // symmetric: -1 and 1 both move one pixel

/// Data pack with the eye layer placed for every inserted character still changed (app.js:887): the mouth and eye
/// shifts of the drawer and the single poses. Null when nothing is moved. (The eye-layer way of inserting card
/// characters, state.eyeOffsets, is switched off in the page and not part of the state here.)
Uint8List? currentDataPack(BuildState s) {
  var dp = s.ctx!.files[0];
  var any = false;
  // 1.6.8: eyes moved in the drawer (small figure: half the way)
  for (final e in s.mouthShift.entries) {
    final g = e.key;
    final (dx, dy) = e.value; // mouth: the same way as the eyes
    dp = C.shiftEyes(dp, g, g + 2, dx, dy).dataPack;
    dp = C.shiftEyes(dp, g + 3, g + 5, half(dx), half(dy)).dataPack;
    any = true;
  }
  for (final m in s.poseAdj.values) {
    if (m.isNotEmpty) {
      dp = C.layersMove(dp, m.values.toList()); // single poses
      any = true;
    }
  }
  for (final e in s.eyeShift.entries) {
    final g = e.key;
    final (dx, dy) = e.value;
    dp = C.shiftEyes(dp, g, g + 1, dx, dy).dataPack;
    dp = C.shiftEyes(dp, g + 3, g + 4, half(dx), half(dy)).dataPack;
    any = true;
  }
  return any ? dp : null;
}

/// test5: the flash of a further T18Emu that stays in place (its blocks, spares, program and save)
List<(int, int)> keptT18Ranges(List<E.Extra> xs, Uint8List rom) {
  final r = <(int, int)>[];
  for (final x in xs) {
    if (x.kind != 't18' || x.keepOff == null) continue;
    final c = E.t18Cfg(rom, x.keepOff!);
    if (c == null) continue;
    for (final b in [...c.map, ...c.spare]) {
      if (b != 0xFFFF) r.add((b << 16, (b + 1) << 16));
    }
    r.add((x.keepOff!, x.keepOff! + 0x10000));
  }
  return r;
}

/// test3: items or Tamapoints changed: with "keep saves" the device would bring back its own T18 save (session,
/// sector tables, spare blocks) over the changed one. The whole T18 save comes from the image then.
void t18Fresh(Uint8List rom, int off, List<(int, int)> fresh) {
  final c = E.extraCfg(rom, off);
  if (c == null || c.kind != 't18') return;
  fresh.add((c.saveOff, c.saveOff + 0x24000));
  for (final b in c.spare) {
    if (b != 0xFFFF) fresh.add((b << 16, (b + 1) << 16));
  }
}

void _copyRange(Uint8List dst, Uint8List src, int a, int b) {
  final z = b < src.length ? b : src.length;
  if (a < z) dst.setRange(a, z, src, a);
}

/// test20 DL_RESCUE: in the start device DOWNLOAD starts the flash app of the write protection (0xFF0000) instead
/// of a copy of its own (64 KB less). dlStrip: the copy an earlier write placed stayed in the flash every time;
/// copies of it are emptied before placing anew.
Uint8List dlStrip(BuildState s, Uint8List rom) {
  final fe = s.fe!, src = s.rom, fa = F.feldApps(src, fe.stub);
  final pats = <Uint8List>[];
  final dl = fa.dl ?? 0;
  if (dl != 0 && dl != DL_AT) {
    final o = dl - 0x10000000 + 0x11000;
    if (o >= 0x100000 && o + 0x10000 <= 0xFF0000) pats.add(Uint8List.sublistView(src, o, o + 0x10000));
  }
  if (src.length >= 0x1000000 && String.fromCharCodes(src, 0xFF0000 + 0xE000, 0xFF0000 + 0xE008) == 'SONIXDEV') {
    final b = Uint8List(0x10000);
    var n = 0xE000;
    while (n > 0 && src[0xFF0000 + n - 1] == 0xFF) {
      n--;
    }
    b.setRange(0, n, src, 0xFF0000);
    pats.add(b);
  }
  // 1.7.2 DL_SIG: copies of older flash app versions differ from both patterns; they all start with the same 64 bytes
  final flash = s.assets.flash;
  final sig = flash != null ? Uint8List.sublistView(flash, 0, flash.length < 64 ? flash.length : 64) : null;
  if (pats.isEmpty && sig == null) return rom;
  var out = rom;
  for (var o = 0x100000; o < 0xFF0000; o += 0x10000) {
    var hit = false;
    for (final p in pats) {
      var eq = true;
      for (var i = 0; i < 0x10000; i++) {
        if (out[o + i] != p[i]) {
          eq = false;
          break;
        }
      }
      if (eq) {
        hit = true;
        break;
      }
    }
    if (!hit && sig != null) {
      hit = true;
      for (var i = 0; i < sig.length; i++) {
        if (out[o + i] != sig[i]) {
          hit = false;
          break;
        }
      }
    }
    if (hit) {
      if (identical(out, rom)) out = Uint8List.fromList(rom);
      out.fillRange(o, o + 0x10000, 0xFF);
    }
  }
  return out;
}

// ------------------------------------------------------------------ from flash.js: withRescue
// (flash.dart has rescueBlock and a withRescue that takes the picture from the image; the Studio's makes the
// "battery empty" picture of the image's edition, or the text for a ROM without the Paradise.)
const Map<String, int> _batPicIdx = {'Land': 53, 'Water': 53, 'Sky': 53, 'Jade Forest': 54, 'Tropical': 56, 'Glacier': 56};

/// test23 BAT_PIC: the Paradise's "battery empty" picture in the last sector of the rescue block (0xFFF000), for the
/// emulators to show before they switch off on empty batteries: "BAT1", byte count, 16 colours (RGB565), then one byte
/// per run (colour << 4 | length - 1), 128 x 128 row by row. The sprite's number differs by edition.
Uint8List? _batPic(Uint8List img) {
  try {
    final ctx = C.openRom(img), i = _batPicIdx[ctx.edition];
    if (i == null || i >= ctx.entries.length) return null;
    final s = C.spriteDecodeAll(ctx.entries[i]).subs[0];
    if (s.w != 128 || s.h != 128) return null;
    final pal = <int>[], px = Uint8List(128 * 128), d = s.data;
    for (var k = 0; k < px.length; k++) {
      final c = d[4 * k + 3] != 0 ? (((d[4 * k] * 31 + 127) ~/ 255) << 11) | (((d[4 * k + 1] * 63 + 127) ~/ 255) << 5) | ((d[4 * k + 2] * 31 + 127) ~/ 255) : 0xFFFF;
      var j = pal.indexOf(c);
      if (j < 0) {
        if (pal.length >= 16) return null;
        pal.add(c);
        j = pal.length - 1;
      }
      px[k] = j;
    }
    final out = Uint8List(FL.sector)..fillRange(0, FL.sector, 0xFF);
    var n = 0;
    for (var k = 0; k < px.length;) {
      var r = 1;
      while (r < 16 && k + r < px.length && px[k + r] == px[k]) {
        r++;
      }
      if (40 + n >= FL.sector) return null;
      out[40 + n++] = (px[k] << 4) | (r - 1);
      k += r;
    }
    _batHead(out, n, pal);
    return out;
  } catch (_) {
    return null;
  }
}

void _batHead(Uint8List out, int n, List<int> pal) {
  out.setAll(0, [0x42, 0x41, 0x54, 0x31, n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255]); // "BAT1", count
  for (var j = 0; j < 16; j++) {
    final c = j < pal.length ? pal[j] : 0;
    out[8 + 2 * j] = c & 255;
    out[9 + 2 * j] = c >> 8;
  }
}

/* 1.7.2: a ROM without the Paradise has no picture of its own: the same sector with our text instead (white on black,
 * "BATTERY EMPTY, SHUTTING DOWN", own 5 x 7 letters at twice the size) */
const Map<String, String> _batFont = {
  'A': '01110100011000111111100011000110001', 'B': '11110100011000111110100011000111110', 'D': '11110100011000110001100011000111110', //
  'E': '11111100001000011110100001000011111', 'G': '01110100011000010111100011000101111', 'H': '10001100011000111111100011000110001', //
  'I': '01110001000010000100001000010001110', 'M': '10001110111010110101100011000110001', 'N': '10001110011010110011100011000110001', //
  'O': '01110100011000110001100011000101110', 'P': '11110100011000111110100001000010000', 'R': '11110100011000111110101001001010001', //
  'S': '01111100001000001110000010000111110', 'T': '11111001000010000100001000010000100', 'U': '10001100011000110001100011000101110', //
  'W': '10001100011000110101101011010101010', 'Y': '10001100010101000100001000010000100',
};
Uint8List _batText() {
  final px = Uint8List(128 * 128);
  const lines = ['BATTERY', 'EMPTY', 'SHUTTING', 'DOWN'];
  for (var li = 0; li < lines.length; li++) {
    final ln = lines[li], w = ln.length * 12 - 2, x0 = (128 - w) >> 1, y0 = 22 + li * 22;
    for (var c = 0; c < ln.length; c++) {
      final g = _batFont[ln[c]];
      if (g == null) continue;
      for (var y = 0; y < 7; y++) {
        for (var x = 0; x < 5; x++) {
          if (g[y * 5 + x] != '1') continue;
          for (var dy = 0; dy < 2; dy++) {
            for (var dx = 0; dx < 2; dx++) {
              px[(y0 + 2 * y + dy) * 128 + x0 + c * 12 + 2 * x + dx] = li < 2 ? 1 : 2;
            }
          }
        }
      }
    }
  }
  final out = Uint8List(FL.sector)..fillRange(0, FL.sector, 0xFF);
  var n = 0;
  for (var k = 0; k < px.length;) {
    var r = 1;
    while (r < 16 && k + r < px.length && px[k + r] == px[k]) {
      r++;
    }
    out[40 + n++] = (px[k] << 4) | (r - 1);
    k += r;
  }
  _batHead(out, n, const [0x0000, 0xFFFF, 0xA514]);
  return out;
}

/// The image with the rescue start, or null when 0xFF0000 holds something else (flash.js withRescue).
Uint8List? withRescue(Uint8List img, Uint8List app) {
  final rb = FL.rescueBlock(app, Uint8List.sublistView(img, 0, FL.sector), F.isClean(img) ? _batText() : _batPic(img));
  if (rb == null) return null;
  var same = true, free = true;
  for (var i = 0; i < FL.block64; i++) {
    if (img[FL.rescueOff + i] != rb[i]) same = false;
    if (img[FL.rescueOff + i] != 0xFF) free = false;
  }
  if (same) return img;
  if (!free && !FL.isRescue(img, FL.rescueOff)) return null; // test18 RESCUE_OLD: one of an earlier Studio is renewed
  final out = Uint8List.fromList(img);
  out.setAll(FL.rescueOff, rb);
  return out;
}

List<F.FeldApp> _feldApps(List<E.AppEntry> apps) => [for (final a in apps) F.FeldApp(a.src, a.name ?? '')];

E.EmuApps _progs(BuildState s, {required bool doom}) {
  final de = s.assets.doom;
  return E.EmuApps(
      t7: E.t7Embedded(),
      tama: E.embedded()?.app,
      t18: E.t18Embedded(),
      v1: E.v1Embedded(),
      v3: E.v3Embedded(),
      gb: E.gbEmbedded(),
      gbc: E.gbcEmbedded(),
      sms: E.smsEmbedded(),
      pm: E.pmEmbedded(),
      ab: E.abEmbedded(),
      wolf: E.wolfEmbedded(),
      wolfsod: E.wolfSodEmbedded(),
      doom: doom && de != null && de.appF != null ? E.DoomApp(de.appF!, de.xipF!) : null);
}

String _roomMsg(E.EmuError e) =>
    '${e.frag ? 'Does not fit together: there would be enough room in total, but not in one piece (the DOOM WAD needs one big piece). Remove a program or build DOOM without music.' : 'Not enough room: about ${e.missing} KB missing. Remove a program. (The top 64 KB stay free for the write protection.)'}${e.packHint ? ' Tip: "Pack the firmware" for TamaEmu saves room.' : ''}';

/// The keys and the data of the DOOM entries before placing. False (with the toast) when something is missing.
bool _doomReady(BuildState s, Iterable<E.Extra> dxs) {
  final de = s.assets.doom;
  for (final x in dxs) {
    if (de == null || de.appF == null) {
      s.toast('This build does not contain the DOOM program.', true);
      return false;
    }
    if (s.doomKeys != null) x.keyMap = {...s.doomKeys!};
    final err = x.keyMap != null ? D.doomKeysCheck(x.keyMap!) : '';
    if (err.isNotEmpty) {
      s.toast(em(err), true);
      return false;
    }
    if (x.wadSrc != null) {
      final m = s.doomMcuOf(x);
      if (m == null) {
        s.toast('No episode of this WAD fits into the ROM.', true);
        return false;
      }
      x.mcu = m;
    }
  }
  return true;
}

/// CLEAN_ROM: the programs placed from 0x10000, then the menu, the restart routine and the load table; the device's
/// ID page stays (edition), DOWNLOAD starts the flash app of the rescue start (app.js composeClean).
Future<ComposeResult?> composeClean(BuildState s) async {
  final fe = s.fe, emb = s.assets.flash, src = s.rom;
  if (fe == null || emb == null || !s.cleanCan()) {
    s.toast('This build does not contain the emulator program.', true);
    return null;
  }
  // test3 DOOM_FREE: DOOM is a program of the list like the others (no fixed places, any program can be the main one)
  await s.paraMainSync();
  s.doomFreeSync();
  final dxs = s.doomXs();
  final keysDirty = s.doomKeys != null && dxs.any((x) => jsonEncode(s.doomKeys) != (x.keys0 ?? jsonEncode(x.keyMap)));
  final emuUp = !s.ctxClean && s.emuUpPending();
  if (s.ctxClean && s.emu == null && s.doom == null && !keysDirty && !s.extrasDirty && !s.mainDirty && s.extrasUp == null && !s.feldStale && s.t7saveX == null && s.saveIn == null && s.exitKey == s.exitKeyInit && !emuUp) {
    return ComposeResult(src, s.name, same: true);
  }
  E.Extra? mainX;
  if (s.emu != null) {
    mainX = BuildState.emuX(s.emu);
  } else if (!s.ctxClean && s.emuInstalled() && !s.emuRemove && !s.paraMainTaken) {
    mainX = await s.installedX(src);
  }
  if (mainX != null) {
    mainX
      ..clock = s.emuClock
      ..nfc = s.emuNfc
      ..opt = s.emuOpt
      ..sess = s.emuSess;
  }
  s.extrasDedupe(mainX);
  final extrasL = mainX != null ? [mainX, ...s.extras] : s.extras;
  if (extrasL.isEmpty) {
    s.toast('A start device needs at least one program (emulator or DOOM).', true);
    return null;
  }
  if (E.t7Embedded() == null) {
    s.toast('This build does not contain the emulator program.', true);
    return null;
  }
  if (F.edition(src) == null) {
    s.toast('Edition not recognised.', true);
    return null;
  }
  final fresh = <(int, int)>[];
  var rom = F.cleanBase(src);
  var apps = <E.AppEntry>[];
  if (!_doomReady(s, dxs)) return null;
  // a T18Emu that stays where it is keeps its blocks, spares and save (as in the start device with the Paradise)
  if (s.ctxClean) {
    for (final (a, b) in keptT18Ranges(extrasL, src)) {
      _copyRange(rom, src, a, b);
    }
  }
  try {
    final r = E.appsPlace(rom, extrasL, _progs(s, doom: true),
        lang: s.lang, clock: s.emuClock, nfc: s.emuNfc, launch: true, clean: true, noClock: s.clockOff(), txSpare: s.t18Few ? 0x40000 : null, keep: [for (final k in F.cleanReserved()) (k[0], k[1])], dlApp: null);
    rom = r.rom;
    apps = r.list;
    s.lastFree = r.freeKB;
    E.AppEntry? at(int k) {
      final i = k + (mainX != null ? 1 : 0);
      return i >= 0 && i < apps.length ? apps[i] : null;
    }

    final tx = s.t7saveX;
    if (tx != null && at(tx.i) != null) rom = SV.t7SaveIn(rom, tx.save, at(tx.i)!.off + 0x10000);
    final si = s.saveIn;
    final int? sk = si == null ? null : (si.key == 'm' ? (mainX != null ? -1 : null) : si.key as int);
    if (sk != null) {
      final a = sk == -1 ? (apps.isNotEmpty ? apps[0] : null) : at(sk);
      if (a != null) {
        final cx = E.extraCfg(rom, a.off);
        if (si!.kind == 'v1' && cx != null) {
          rom = Uint8List.fromList(rom);
          rom.setAll(cx.saveOff, si.data!);
          fresh.add((cx.saveOff, cx.saveOff + 0x2000));
        }
        if (si.kind == 'tama' && cx != null) fresh.addAll([(cx.saveOff, cx.saveOff + 0x50000), (cx.guestOff, cx.spareEnd)]);
      }
    }
    for (var i = 0; i < extrasL.length; i++) {
      if (extrasL[i].carry && i < apps.length) {
        final cx = E.extraCfg(rom, apps[i].off);
        if (cx != null && cx.kind == 'tama') fresh.addAll([(cx.saveOff, cx.saveOff + 0x50000), (cx.guestOff, cx.spareEnd)]);
      }
    }
    for (final x in extrasL) {
      if (x.kind == 't18' && x.items && x.keepOff != null) {
        final k = extrasL.indexOf(x);
        if (k < apps.length) t18Fresh(rom, apps[k].off, fresh);
      }
    }
  } catch (e) {
    final room = e is E.EmuError && e.room;
    s.lastRoom = room ? (e.missing ?? 0) : 0;
    s.toast(room ? _roomMsg(e) : 'More emulators: ${em(e)}', true);
    return null;
  }
  // the main program: the one chosen with the star, or the main program of the Paradise taken along
  final mp = s.mainPick;
  final k = mp == BuildState.pickEmu ? (mainX != null ? 0 : -1) : (mp != null ? extrasL.indexOf(mp as E.Extra) : (mainX != null && !s.ctxClean ? 0 : -1));
  final mainSrc = k >= 0 && k < apps.length ? apps[k].src : 0;
  try {
    rom = F.cleanApply(rom, F.FeldOpts(apps: _feldApps(apps), dl: DL_AT, mainSrc: mainSrc, auto: s.emuAuto && mainSrc != 0, noClock: s.cleanClock == false), fe.forClean());
  } catch (e) {
    s.toast('Menu not built in: ${em(e)}', true);
    return null;
  }
  {
    final w = withRescue(rom, emb);
    if (w == null) {
      s.toast('Menu not built in: rescue', true);
      return null;
    }
    rom = w;
  }
  if (s.exitKey != 0 || exitGet(rom, fe) != 0) rom = exitSet(rom, s.exitKey, fe);
  return ComposeResult(rom, '${s.baseName()}${s.doom != null ? '_doom_E${s.doomEp}' : ''}_clean.bin', fresh: fresh);
}

/// app.js composeRom: null when the build stops (the reason is the last error toast of [s]).
Future<ComposeResult?> composeRaw(BuildState s) async {
  if (s.clean) return composeClean(s);
  final src = s.rom, fe = s.fe;
  const fem = F.FeldEmuPort();
  final dk0 = D.doomKeysGet(src);
  final keysDirty = s.doom == null && s.doomInstalled() && s.doomKeys != null && dk0 != null && jsonEncode(s.doomKeys) != jsonEncode(dk0);
  final si0 = S6.sixInfo(src);
  bool sixSame(S6.SixInfo? si) => si != null && si.planet == s.sixPlanet && si.fieldMenu == s.sixMenu;
  // 1.7.2: DNA per field comes to every ROM with six fields (no Land ROM needed)
  bool sixDnaUp(S6.SixInfo? si) => S6.sixDnaSwitch && si != null && !si.dna && si.version >= 7 && !s.sixOff && S6.sixDnaCan(src);
  final sixUp = (si0 != null && (si0.version < S6.sixVersion || !sixSame(si0)) && !S6.sixNeedsSource(src)) || sixDnaUp(si0);
  final emuUp = s.emuUpPending();
  if (s.changed.isEmpty &&
      s.t7save == null &&
      s.emu == null &&
      !s.emuRemove &&
      s.doom == null &&
      !keysDirty &&
      !emuUp &&
      !s.emuAutoDirty() &&
      s.six == null &&
      !sixUp &&
      !(s.sixWant && S6.sixInfo(src) == null) &&
      s.feld == s.feldInit &&
      s.bag == s.bagInit &&
      s.tama == s.tamaInit &&
      s.gplay == s.gplayInit &&
      s.saves == s.savesInit &&
      s.launch == s.launchInit &&
      s.exitKey == s.exitKeyInit &&
      !s.feldStale &&
      !s.extrasDirty &&
      !s.mainDirty &&
      s.extrasUp == null &&
      s.t7saveX == null &&
      s.saveIn == null &&
      !s.sixOff &&
      !s.petDirty &&
      !s.t18Dirty &&
      !s.t18PicsDirty &&
      s.texts.isEmpty &&
      s.eyeShift.isEmpty &&
      s.mouthShift.isEmpty &&
      s.poseAdj.isEmpty) {
    return ComposeResult(src, s.name, same: true);
  }
  var feldSaved = fe != null ? F.feldSlots(src, fe.stub) : <F.FeldSlot>[];
  // start device with DOOM (1.6.8): DOOM is the program at 0x0A0000, the emulator of the Emulator tab goes along as a further program
  final doomL = s.launch && (s.doom != null || (s.doomInstalled() && !s.emuRemove));
  E.Extra? mainX;
  if (doomL && s.emu != null) {
    mainX = BuildState.emuX(s.emu);
  } else if (doomL && s.doom != null && s.emuInstalled()) {
    mainX = await s.installedX(src);
  }
  // 1.6.8: an extra that is the same firmware as the main emulator only once (a start device read back shows its
  // emulator as a further program; choosing it again in the Emulator tab must not put it in twice)
  if (mainX != null) {
    mainX
      ..clock = s.emuClock
      ..nfc = s.emuNfc
      ..opt = s.emuOpt
      ..sess = s.emuSess;
  }
  s.extrasDedupe(mainX);
  final extrasL = mainX != null ? [mainX, ...s.extras] : s.extras;
  if (s.emu != null && s.doom != null && !doomL) {
    s.toast('Emulator and DOOM do not fit into one ROM together. Please choose only one.', true);
    return null;
  }
  if (s.doom != null && s.doomKeys != null && D.doomKeysCheck(s.doomKeys!).isNotEmpty) {
    s.toast(em(D.doomKeysCheck(s.doomKeys!)), true);
    return null;
  }
  var rom = src;
  C.BuiltRom? res;
  final fresh = <(int, int)>[]; // 1.6.8: ranges taken from the image even with "keep saves" (imported saves)
  if (s.launch && s.assets.flash == null) {
    s.toast('This build does not contain the emulator program.', true);
    return null;
  }
  if (s.launch && !(s.emu != null || s.doom != null || s.extras.isNotEmpty || (s.appInstalled() != 0 && !s.emuRemove))) {
    s.toast('A start device needs at least one program (emulator or DOOM).', true);
    return null;
  }
  final lmap = s.launch ? s.launchMapGet() : null;
  if (s.changed.isNotEmpty || (lmap != null && lmap.isNotEmpty) || s.eyeShift.isNotEmpty || s.mouthShift.isNotEmpty || s.poseAdj.isNotEmpty) {
    final all = lmap != null ? {...lmap, ...s.changed} : s.changed;
    try {
      res = C.buildRomCtx(s.ctx!, all, currentDataPack(s));
      rom = res.rom;
    } catch (e) {
      s.toast('Too big for the free space. ${em(e)}', true);
      return null;
    }
  }
  // 1.6.8: names of fields, Tamas and items (text tables)
  if (s.texts.isNotEmpty) {
    try {
      rom = C.textApply(rom, s.texts);
    } catch (e) {
      s.toast('Too big for the free space. ${em(e)}', true);
      return null;
    }
  }
  if (fe != null) rom = F.feldStrip(rom, F.FeldEmbedded(stub: fe.stub, oldStub: E.embedded()?.stub), fem);
  // Emulator instead of installed DOOM: remove DOOM completely first (program part, WAD), then install the emulator
  // test5: a further T18Emu that stays where it is (start device) has blocks in the area the main program's removal
  // empties (0x830000..0xD48000): they are put back; a new main program must not take them
  // test6 APPS_CLEAR_FIRST: the further programs of the old ROM go before the main program is built in (they are
  // placed again afterwards); before, a new main program (T18Emu needs 91 blocks) only saw the room they left
  if (fe != null) {
    final old = romExtras(src, fe);
    if (old.isNotEmpty) rom = E.appsClear(rom, [for (final o in old) if (!extrasL.any((x) => x.kind == 't18' && x.keepOff == o.off)) o.off]);
  }
  // test25 HI_ORPHAN: start device: what removed programs left behind the Paradise's save becomes free (see E.hiFree)
  if (fe != null && s.launch) {
    final ff = F.feldFind(rom, fe.stub);
    rom = E.hiFree(rom, [for (final x in extrasL) if (x.kind == 't18' && x.keepOff != null) x.keepOff!], ff != null ? ff.off : 0);
  }
  final t18Keep = keptT18Ranges(extrasL, rom);
  Uint8List t18Back(Uint8List r, Uint8List from) {
    for (final (a, b) in t18Keep) {
      _copyRange(r, from, a, b);
    }
    return r;
  }

  final romMain0 = rom;
  if (s.emu != null && s.doomInstalled() && !doomL) {
    try {
      rom = t18Back(E.emuRemove(rom), rom);
    } catch (e) {
      s.toast('Emulator not built in: ${em(e)}', true);
      return null;
    }
  }
  if ((s.emu != null && !doomL) || s.emuRemove) {
    final emb = E.embedded(), emu = s.emu;
    const missing = 'This build does not contain the emulator program.';
    try {
      if (emu != null && doomL) {
        /* goes along as a further program */
      } else if (emu != null && emu.v1) {
        if (emb == null || E.v1Embedded() == null) throw StateError(missing);
        rom = E.v1Patch(rom, emu.rom!, E.v1Embedded(), emb.stub, lang: s.lang, clock: s.emuClock);
      } else if (emu != null && emu.t7) {
        if (emb == null || E.t7Embedded() == null) throw StateError(missing);
        rom = E.t7Patch(rom, emu.rom!, emu.figs, E.t7Embedded()!, emb.stub, lang: s.lang);
      } else if (emu != null && emu.t18) {
        if (emb == null || E.t18Embedded() == null) throw StateError(missing);
        rom = E.t18Patch(rom, emu.rom!, E.t18Embedded()!, emb.stub, lang: s.lang, launch: s.launch, spares: s.t18Few ? T18_FEW_N : null, holes: s.t18Few).rom;
      } else if (emu != null) {
        if (emb == null) throw StateError(missing);
        rom = E.emuPatch(rom, emu.guest!, emb.app, emb.stub, lang: s.lang, pack: s.emuPack).rom;
      } else {
        rom = t18Back(E.emuRemove(rom), rom);
      }
    } catch (e) {
      s.toast(e is E.EmuError && e.needPack ? 'This firmware only fits here packed: switch on "Pack the firmware" in the row of TamaEmu.' : 'Emulator not built in: ${em(e)}', true);
      return null;
    }
    for (final (a, b) in t18Keep) {
      for (var i = a; i < b && i < rom.length; i++) {
        if (rom[i] != romMain0[i]) {
          s.toast('Emulator not built in: the main program would need the room of Tama Meets. Remove Tama Meets first.', true);
          return null;
        }
      }
    }
  }
  if (s.t7save != null && F.emuType(rom) == 't7' && !doomL) rom = SV.t7SaveIn(rom, s.t7save);
  final sin = s.saveIn;
  if (sin != null && sin.key == 'm' && !doomL) {
    if (sin.kind == 'v1' && F.emuType(rom) == 'v1') {
      rom = Uint8List.fromList(rom);
      rom.setAll(0xC0000, sin.data!);
      fresh.add((0xC0000, 0xC2000));
    }
    if (sin.kind == 'tama' && F.emuType(rom) == 'tama') {
      final g0 = rd32(rom, 0xA0148), se = rd32(rom, 0xA0144) >= 3 ? rd32(rom, 0xA0140 + 152) : g0 + rd32(rom, 0xA014C);
      fresh.addAll([(0xC0000, 0x110000), (g0, se)]);
    }
  }
  // newer emulator program: only the program changes, the Tamagotchi's save stays
  if (emuUp && F.appKind(rom) == 2) {
    final ty = F.emuType(rom);
    final u = ty == 'v1'
        ? E.v1Upgrade(rom, E.v1Embedded())
        : ty == 't7'
            ? E.t7Upgrade(rom, E.t7Embedded()!)
            : ty == 't18'
                ? E.t18Upgrade(rom, E.t18Embedded()!, E.embedded()?.stub)
                : E.emuUpgrade(rom, E.embedded()!.app);
    if (u != null) rom = u;
  }
  if (s.t18Dirty && s.t18Main != null && s.emu == null && !s.emuRemove && F.emuType(rom) == 't18') {
    // test47: items
    try {
      rom = E.t18RomWriteGuest(rom, s.t18Main!);
      t18Fresh(rom, 0xA0000, fresh);
    } catch (e) {
      s.toast('Emulator not built in: ${em(e)}', true);
      return null;
    }
  }
  if (F.emuType(rom) == 't18' && s.t18Pics != null && (s.t18Pics!.isNotEmpty || s.t18PicsDirty)) rom = E.t18PicsWrite(rom, s.t18Pics!); // test47: grow-up pictures
  final doom = s.doom;
  if (doom != null && doom.ok.isEmpty && !(doom.fit['all']?.plain ?? false)) {
    s.toast('No episode of this WAD fits into the ROM.', true);
    return null;
  }
  if (doom != null && !s.doomFree()) {
    // DOOM_LAUNCH: otherwise DOOM is a program of the menu (below)
    final emb = s.assets.doom, embE = E.embedded();
    try {
      if (emb == null || embE == null) throw StateError('This build does not contain the DOOM program.');
      final keys = s.doomKeys ?? D.KEYS_DEFAULT, port = s.assets.doomPort;
      Uint8List inst(Uint8List r, Uint8List app, Uint8List stub) => E.installApp(r, app, stub);
      if (port != null) {
        rom = await D.doomBuild(rom, doom.wadM ?? doom.wad, port, emb, embE.stub, inst, episode: s.doomEp, music: s.doomMusic, keys: keys);
      } else {
        // without the converter: the conversion of doomCompute for this episode, where it is the one doomBuild makes
        // (with music: mcuM; without: mcuP, which only is the conversion without music when the one with did not fit)
        final f = doom.fit[s.doomEp.isNotEmpty ? s.doomEp : '1'];
        final mcu = f == null ? null : (s.doomMusic ? f.mcuM : (!f.music ? f.mcuP : null));
        if (mcu == null) throw StateError('the WAD converter is not part of this app (this episode without its music needs it)');
        rom = D.doomBuilt(rom, mcu, emb, embE.stub, inst, keys: keys);
      }
    } catch (e) {
      s.toast('DOOM not built in: ${em(e)}', true);
      return null;
    }
  }
  // Change the keys of an already installed DOOM
  if (doom == null && s.doomInstalled() && !s.emuRemove && s.doomKeys != null && D.doomKeysGet(rom) != null) {
    final k = s.doomKeys!, err = D.doomKeysCheck(k);
    if (err.isNotEmpty) {
      s.toast(em(err), true);
      return null;
    }
    rom = D.doomKeysSet(rom, k);
  }
  // 1.6.8: extra fields out again (several saves with the edition's own fields only)
  if (s.sixOff && S6.sixInfo(rom) != null) {
    final base = F.fieldNames(S6.sixStrip(src)), now = F.fieldNow(src);
    if (now.isNotEmpty && base.isNotEmpty && !base.contains(now)) {
      s.toast('The device is on $now now. First switch to ${base.join(', ')} in the menu.', true);
      return null;
    }
    if (feldSaved.isNotEmpty && !(s.confirm?.call('The saves stored in the menu are deleted. Continue?') ?? true)) return null;
    rom = S6.sixStrip(rom);
    feldSaved = [];
  }
  final needSrc = S6.sixNeedsSource(rom);
  if (s.sixWant && needSrc && s.six == null && S6.sixInfo(rom) == null) {
    s.toast('All 6 fields still need a Land, Water or Sky ROM.', true);
    return null;
  }
  final sixHave = S6.sixInfo(rom);
  if (sixHave != null && needSrc && s.six == null && sixHave.version >= S6.sixVersion && !sixSame(sixHave)) {
    s.toast('Changing this setting needs your Land, Water or Sky ROM again.', true);
    return null;
  }
  if ((s.six != null || (s.sixWant && !needSrc) || (!needSrc && sixHave != null)) && !(sixHave != null && sixHave.version >= S6.sixVersion && sixSame(sixHave) && !S6.sixStale(sixHave))) {
    if (s.doom != null || s.doomInstalled() || s.emu != null) {
      s.toast('Fields not built in: DOOM and the emulator do not fit with it', true);
      return null;
    }
    if (s.extras.isNotEmpty) {
      s.toast('Six fields do not go together with more emulators.', true);
      return null;
    }
    try {
      rom = S6.sixApply(rom, s.six, s.assets.six, planet: s.sixPlanet, fieldMenu: s.sixMenu);
    } catch (e) {
      s.toast('Fields not built in: ${em(e)}', true);
      return null;
    }
  }
  if (S6.sixDnaSwitch && S6.sixInfo(rom) != null) rom = S6.sixDna(rom, s.assets.six, true);
  if (S6.sixHuntSwitch && S6.sixInfo(rom) != null) rom = S6.sixHunt(rom); // 1.7.3 test23: egg hunt per field
  if (S6.sixInfo(rom) != null) rom = S6.sixFix(rom); // the archive may have moved: rain pictures point to 0xF00000
  // more emulators (1.6.0): the old blocks go, the list is placed again from the top of the emulator area
  var apps = <E.AppEntry>[];
  var appsLow = 0, dl = 0;
  if (extrasL.isNotEmpty || s.launch) {
    if (fe == null || !s.menuWanted()) {
      s.toast('More emulators start from the menu: switch on the field switch or items in the Menu tab.', true);
      return null;
    }
    if (E.t7Embedded() == null) {
      s.toast('This build does not contain the emulator program.', true);
      return null;
    }
    final df = s.doomFree();
    if (df) {
      // 1.7.6: DOOM in the menu of a start device (as in the ROM without the Paradise)
      if (!_doomReady(s, extrasL.where((y) => y.kind == 'doom'))) return null;
    }
    var dlRes = false;
    if (s.launch) {
      rom = dlStrip(s, rom);
      final fl = s.assets.flash;
      if (fl != null) {
        final w = withRescue(rom, fl);
        if (w != null) {
          rom = w;
          dlRes = true;
        }
      }
    }
    try {
      final r = E.appsPlace(rom, extrasL, _progs(s, doom: df),
          lang: s.lang,
          clock: s.emuClock,
          nfc: s.emuNfc,
          launch: s.launch,
          txSpare: s.t18Few ? 0x40000 : null,
          keep: F.appKind(rom) == 1 ? [(0x830000, 0xD48000)] : [],
          dlApp: s.launch && !dlRes ? s.assets.flash : null);
      rom = r.rom;
      apps = r.list;
      appsLow = r.low;
      dl = dlRes ? DL_AT : r.dl;
      s.lastFree = r.freeKB;
      final sh = mainX != null ? 1 : 0;
      for (final x in extrasL) {
        if (x.kind == 't18' && x.items && x.keepOff != null) t18Fresh(rom, x.keepOff!, fresh); // test3
      }
      final tx = s.t7saveX;
      if (tx != null && tx.i + sh < apps.length) rom = SV.t7SaveIn(rom, tx.save, apps[tx.i + sh].off + 0x10000);
      if (sin != null && sin.key is int && (sin.key as int) + sh < apps.length) {
        final at = apps[(sin.key as int) + sh].off, cx = E.extraCfg(rom, at);
        if (sin.kind == 'v1' && cx != null) {
          rom = Uint8List.fromList(rom);
          rom.setAll(cx.saveOff, sin.data!);
          fresh.add((cx.saveOff, cx.saveOff + 0x2000));
        }
        if (sin.kind == 'tama' && cx != null) fresh.addAll([(cx.saveOff, cx.saveOff + 0x50000), (cx.guestOff, cx.spareEnd)]); // the imported pet: no run state of the device
      }
      for (var i = 0; i < extrasL.length; i++) {
        // test26: a save taken along from the device
        if (!extrasL[i].carry || i + sh >= apps.length) continue;
        final cx = E.extraCfg(rom, apps[i + sh].off);
        if (cx != null && cx.kind == 'tama') fresh.addAll([(cx.saveOff, cx.saveOff + 0x50000), (cx.guestOff, cx.spareEnd)]);
      }
    } catch (e) {
      final room = e is E.EmuError && e.room;
      s.lastRoom = room ? (e.missing ?? 0) : 0;
      s.toast(room ? _roomMsg(e) : 'More emulators: ${em(e)}', true);
      return null;
    }
  }
  // 1.6.8: always the firmware's name (TAMA-GO, FRIENDS, ID L, 4U+ ...), not the emulator's
  // 1.6.9 test13: the chosen main program's place in the list (0 = the program at 0x0A0000)
  int mainSrcOf() {
    final mp = s.mainPick;
    if (!s.launch || mp == null || !doomL) return 0;
    final k = mp == BuildState.pickEmu ? (mainX != null ? 0 : -1) : extrasL.indexOf(mp as E.Extra);
    return k >= 0 && k < apps.length ? apps[k].src : 0;
  }

  String name0;
  if (F.appKind(rom) == 1) {
    name0 = 'DOOM';
  } else if (s.emu != null && s.emu!.guest != null) {
    name0 = E.tamaName(s.emu!.guest, s.emu!.dev);
  } else {
    final keep = s.emu == null && !s.emuRemove && fe != null && F.appKind(src) == F.appKind(rom) ? F.feldApps(src, fe.stub).name0 : '';
    name0 = keep.isNotEmpty ? keep : mainName(rom);
  }
  if (fe != null && s.menuWanted()) {
    try {
      rom = F.feldApply(
          rom,
          F.FeldOpts(
              fields: s.feld,
              bag: s.bag,
              tama: s.tama,
              gplay: s.gplay && !s.clean,
              saves: s.saves,
              launch: s.launch,
              apps: _feldApps(apps),
              name0: name0,
              appsLow: appsLow,
              dl: dl,
              mainSrc: mainSrcOf(),
              auto: s.emuAuto,
              fieldNames: [for (final x in fieldTextsOf(rom)) x.name]),
          feldSaved,
          F.FeldEmbedded(stub: fe.stub, feld: fe.feld, feldS: fe.feldS),
          fem);
    } catch (e) {
      s.toast('Menu not built in: ${em(e)}', true);
      return null;
    }
  }
  // autostart of the emulator (the stubs above were written with it off), clock switch (1.5.1)
  if (F.appKind(rom) == 2) rom = E.emuSessSet(E.emuOptSet(E.emuNfcSet(E.emuClockSet(rom, s.emuClock), s.emuNfc), s.emuOpt), s.emuSess);
  if (F.appKind(rom) == 2 || (F.appKind(rom) == 1 && !s.launch)) {
    // 1.6.8: DOOM as the main program can start right away too
    var a = E.autoSet(rom, stubList(rom, fe), s.emuAuto);
    // stub of an older Studio (no switch): put in the current one
    if (a == null && s.emuAuto && E.embedded() != null && !(fe != null && F.feldFind(rom, fe.stub) != null)) {
      try {
        rom = E.installApp(rom, Uint8List.fromList(rom.sublist(0xA0000, 0xB0000)), E.embedded()!.stub);
        a = E.autoSet(rom, stubList(rom, fe), true);
      } catch (_) {
        a = null;
      }
    }
    if (a != null) rom = a;
  }
  if (s.exitKey != 0 || exitGet(rom, fe) != 0) rom = exitSet(rom, s.exitKey, fe);
  final emu = s.emu;
  final name = '${s.baseName()}${s.changed.isNotEmpty ? '_paramix' : ''}'
      '${emu != null ? (emu.v1 ? '_v1' : (emu.t7 ? '_t7' : (emu.t18 ? '_t18' : '_emu'))) : ''}'
      '${s.doom != null ? '_doom_E${s.doomEp}' : ''}'
      '${S6.sixInfo(rom) != null ? (S6.kindOf(rom) == 'jade' ? '_4fields' : '_6fields') : (s.feld ? '_fields' : '')}'
      '${s.bag ? '_items' : ''}${s.launch ? '_start' : ''}.bin';
  return ComposeResult(rom, name, res: res, fresh: fresh);
}
