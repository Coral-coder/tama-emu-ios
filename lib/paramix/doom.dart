// Install DOOM into the Paradise ROM: a native Dart port of Paramix Studio's src/doom.js
// (mameise, GPL-3.0-or-later) and of its WAD converter (doom/src/wasm: MCUDoomWadUtil by Nicola
// Wrachien, based on doomhack's GBAWadUtil, GPL-2.0; in the Studio it runs as WebAssembly).
//
// The user supplies the WAD (DOOM.WAD); it never leaves the device. Nothing in here is game data.
//
// Flow: partial WAD (one episode) -> extra lumps from the same WAD -> converter -> into the ROM.
// Layout in the Paradise flash:
//   0x0A0000  DOOM program (PRAM part, loaded by the stub)
//   0x0B0000  stub and home screen hook (hold A+C), same as the emulator
//   0x0B1000  DOOM program (part in the flash window)
//   0x10E000  settings and save (2 x 4 KB)
//   0x830000  converted WAD (preceded by 4-byte length), 0xCA0000 region for precomputed data
//
// Differences to the JS, all on purpose:
//  - the embedded binaries (doom_app.bin, doom_xip.bin, doomf_app.bin, doomf_xip.bin, the stub) are
//    arguments ([DoomEmb]); `embedded()` is not ported
//  - [convert] is the C converter ported to Dart, so it is synchronous and needs no WebAssembly. Where
//    the C code reads outside a lump (a broken WAD; in the browser that reads whatever is in the
//    WebAssembly memory), the port throws a RangeError or a StateError instead
//  - reading outside the WAD gives 0 as in JS (undefined in bit operations); the few places where JS
//    would loop for ever on a cut-off lump (patch columns without their end mark) throw instead

import 'dart:typed_data';

import 'emu_build.dart' show installApp;

// ignore_for_file: constant_identifier_names, non_constant_identifier_names

const int CODE_OFF = 0xB1000, SAVE_OFF = 0x10E000, SAVE_END = 0x110000;
const int WAD_OFF = 0x830000, REGION_OFF = 0xCA0000, REGION_END = 0xD48000;
const int _PW = 128, _PH = 128;

int _g(Uint8List b, int i) => (i >= 0 && i < b.length) ? b[i] : 0;
int _u16(Uint8List b, int o) => _g(b, o) | (_g(b, o + 1) << 8);
int _s16(Uint8List b, int o) {
  final v = _u16(b, o);
  return v > 32767 ? v - 65536 : v;
}

int _u32(Uint8List b, int o) => (_g(b, o) | (_g(b, o + 1) << 8) | (_g(b, o + 2) << 16) | (_g(b, o + 3) << 24)) & 0xFFFFFFFF;
void _w16(Uint8List b, int o, int v) {
  b[o] = v & 255;
  b[o + 1] = (v >> 8) & 255;
}

void _w32(Uint8List b, int o, int v) {
  b[o] = v & 255;
  b[o + 1] = (v >> 8) & 255;
  b[o + 2] = (v >> 16) & 255;
  b[o + 3] = (v >> 24) & 255;
}

/// The name of a lump: 8 bytes, zeros at the end dropped (bytes outside the file count as a character 0, as in JS).
String _name8(Uint8List b, int o) {
  var e = o + 8;
  while (e > o && e - 1 >= 0 && e - 1 < b.length && b[e - 1] == 0) {
    e--;
  }
  final s = StringBuffer();
  for (var i = o; i < e; i++) {
    s.writeCharCode(_g(b, i));
  }
  return s.toString();
}

/// JS TypedArray.subarray (a view, the ends clamped).
Uint8List _sub(Uint8List d, int a, [int? b]) {
  final n = d.length;
  var s = a < 0 ? (n + a < 0 ? 0 : n + a) : (a > n ? n : a);
  var e = b == null ? n : (b < 0 ? (n + b < 0 ? 0 : n + b) : (b > n ? n : b));
  if (e < s) e = s;
  return Uint8List.sublistView(d, s, e);
}

/// JS Array.slice.
List<T> _slice<T>(List<T> l, int a, [int? b]) {
  final n = l.length;
  final s = a < 0 ? (n + a < 0 ? 0 : n + a) : (a > n ? n : a);
  var e = b == null ? n : (b < 0 ? (n + b < 0 ? 0 : n + b) : (b > n ? n : b));
  if (e < s) e = s;
  return l.sublist(s, e);
}

/// JS String.toUpperCase for the texts met here (Dart leaves the sharp s alone).
String _upper(String s) => s.replaceAll('ß', 'SS').toUpperCase();

bool _jsSpace(int c) =>
    (c >= 9 && c <= 13) || c == 0x20 || c == 0xA0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000 || c == 0xFEFF;

/// JS String.trim (Dart also trims U+0085).
String _trim(String s) {
  var a = 0, b = s.length;
  while (a < b && _jsSpace(s.codeUnitAt(a))) {
    a++;
  }
  while (b > a && _jsSpace(s.codeUnitAt(b - 1))) {
    b--;
  }
  return s.substring(a, b);
}

const List<int> _cp1252 = [
  0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F, //
  0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
];

/// new TextDecoder('latin1').decode: the label latin1 means windows-1252.
String _latin1(Uint8List b) {
  final s = StringBuffer();
  for (final c in b) {
    s.writeCharCode(c >= 0x80 && c < 0xA0 ? _cp1252[c - 0x80] : c);
  }
  return s.toString();
}

class WadLump {
  WadLump(this.name, this.data);
  final String name;
  final Uint8List data;
}

// ------------------------------------------------------------------ WAD
List<WadLump> readWad(Uint8List d) {
  final id = String.fromCharCodes([_g(d, 0), _g(d, 1), _g(d, 2), _g(d, 3)]);
  if (id != 'IWAD' && id != 'PWAD') throw const FormatException('not a WAD file');
  final n = _u32(d, 4), off = _u32(d, 8), L = <WadLump>[];
  for (var i = 0; i < n; i++) {
    final o = _u32(d, off + 16 * i), s = _u32(d, off + 16 * i + 4);
    L.add(WadLump(_name8(d, off + 16 * i + 8), _sub(d, o, o + s)));
  }
  return L;
}

/// Like wadsub.py: header, data in one piece, directory at the end.
Uint8List writeWad(List<WadLump> L, String ident) {
  var size = 12;
  for (final l in L) {
    size += l.data.length;
  }
  final out = Uint8List(size + 16 * L.length);
  for (var i = 0; i < ident.length; i++) {
    out[i] = ident.codeUnitAt(i) & 255;
  }
  _w32(out, 4, L.length);
  _w32(out, 8, size);
  var p = 12, q = size;
  for (final l in L) {
    out.setRange(p, p + l.data.length, l.data);
    _w32(out, q, p);
    _w32(out, q + 4, l.data.length);
    for (var k = 0; k < 8 && k < l.name.length; k++) {
      out[q + 8 + k] = l.name.codeUnitAt(k) & 255;
    }
    p += l.data.length;
    q += 16;
  }
  return out;
}

final RegExp _reEM = RegExp(r'^E(\d)M\d$'), _reMAP = RegExp(r'^MAP\d\d$');

/// Which episodes does the WAD have? E.g. ['1'] (Shareware), ['1','2','3'] (DOOM), or also '4' (Ultimate).
List<String> wadEpisodes(Uint8List d) {
  final eps = <String>{};
  var d2 = 0;
  for (final l in readWad(d)) {
    final m = _reEM.firstMatch(l.name);
    if (m != null) eps.add(m.group(1)!);
    if (_reMAP.hasMatch(l.name)) d2++;
  }
  if (eps.isEmpty && _D2 && d2 != 0) return ['M']; // 1.7.3 test15: DOOM II (all maps MAP01..MAP32 as one "episode" M)
  if (eps.isEmpty) throw const FormatException('no DOOM maps in the WAD (DOOM 2 is not supported)');
  return eps.toList()..sort();
}

// ------------------------------------------------------------ partial WAD (wadsub.py)
const Set<String> _MAPL = {'THINGS', 'LINEDEFS', 'SIDEDEFS', 'VERTEXES', 'SEGS', 'SSECTORS', 'NODES', 'SECTORS', 'REJECT', 'BLOCKMAP'};
const List<List<String>> _ANIMS = [
  ['NUKAGE3', 'NUKAGE1'], ['FWATER4', 'FWATER1'], ['SWATER4', 'SWATER1'], ['LAVA4', 'LAVA1'], ['BLOOD3', 'BLOOD1'], //
  ['RROCK08', 'RROCK05'], ['SLIME04', 'SLIME01'], ['SLIME08', 'SLIME05'], ['SLIME12', 'SLIME09'],
];
const List<List<String>> _TANIMS = [
  ['BLODGR4', 'BLODGR1'], ['SLADRIP3', 'SLADRIP1'], ['BLODRIP4', 'BLODRIP1'], ['FIREWALL', 'FIREWALA'], ['GSTFONT3', 'GSTFONT1'], //
  ['FIRELAVA', 'FIRELAV3'], ['FIREMAG3', 'FIREMAG1'], ['FIREBLU2', 'FIREBLU1'], ['ROCKRED3', 'ROCKRED1'], ['BFALL4', 'BFALL1'], //
  ['SFALL4', 'SFALL1'], ['WFALL4', 'WFALL1'], ['DBRAIN4', 'DBRAIN1'],
];
const Map<int, List<String>> _MON = {
  3004: ['POSS'], 9: ['SPOS'], 3001: ['TROO', 'BAL1'], 3002: ['SARG'], 58: ['SARG'], 3003: ['BOSS', 'BAL7'], //
  3005: ['HEAD', 'BAL2'], 3006: ['SKUL'], 16: ['CYBR'], 7: ['SPID'],
};
/* 1.7.3 test14 E4: Ultimate DOOM. Its end picture ENDPIC (full screen, only in the WAD with E4) and the flat behind each
 * episode's end text are kept. */
const bool _E4 = true;
const Map<String, String> _END_FLAT = {'1': 'FLOOR4_8', '2': 'SFLR6_1', '3': 'MFLR8_4', '4': 'MFLR8_3'};
/* 1.7.3 test15 D2: DOOM II (and WADs like it with MAP01..): every map, the three skies, all music, the flats behind the
 * texts between maps and the big picture behind the cast at the end */
const bool _D2 = true;
const List<String> _D2_FLATS = ['SLIME16', 'RROCK14', 'RROCK07', 'RROCK17', 'RROCK13', 'RROCK19'];
final Set<String> _FULL = {
  'TITLEPIC', 'HELP1', 'HELP2', 'CREDIT', 'VICTORY2', 'PFUB1', 'PFUB2', 'INTERPIC', //
  if (_E4) 'ENDPIC', if (_D2) 'BOSSBACK', if (_D2) 'HELP',
};
String _upName(Uint8List b, int o) => _upper(_name8(b, o));

class _Tex {
  _Tex(this.name, this.raw);
  final String name;
  final Uint8List raw;
}

List<_Tex> _readTex(Uint8List dd) {
  final cnt = _u32(dd, 0), res = <_Tex>[];
  for (var i = 0; i < cnt; i++) {
    final o = _u32(dd, 4 + 4 * i);
    final pc = _u16(dd, o + 20);
    res.add(_Tex(_upName(dd, o), _sub(dd, o, o + 22 + 10 * pc)));
  }
  return res;
}

class _Pic {
  _Pic(this.w, this.h, this.img);
  final int w, h;
  final Uint8List img;
}

_Pic _patchDecode(Uint8List dd) {
  final w = _s16(dd, 0), h = _s16(dd, 2);
  if (w <= 0 || h <= 0) throw const FormatException('no picture');
  final img = Uint8List(w * h);
  for (var x = 0; x < w; x++) {
    var p = _u32(dd, 8 + 4 * x);
    while (_g(dd, p) != 0xFF) {
      if (p >= dd.length) throw const FormatException('broken');
      if (p + 1 >= dd.length) throw const FormatException('broken'); // (JS: loops for ever)
      final top = dd[p], ln = dd[p + 1];
      for (var k = 0; k < ln; k++) {
        final y = top + k;
        if (y < h) img[y * w + x] = _g(dd, p + 3 + k);
      }
      p += ln + 4;
    }
  }
  return _Pic(w, h, img);
}

Uint8List _fullEncode(Uint8List img, int w, int h) {
  final colLen = 3 + h + 2, out = Uint8List(8 + 4 * w + colLen * w);
  _w16(out, 0, w);
  _w16(out, 2, h);
  for (var x = 0; x < w; x++) {
    final o = 8 + 4 * w + colLen * x;
    _w32(out, 8 + 4 * x, o);
    out[o] = 0;
    out[o + 1] = h;
    out[o + 2] = 0;
    for (var y = 0; y < h; y++) {
      out[o + 3 + y] = img[y * w + x];
    }
    out[o + 3 + h] = 0;
    out[o + 4 + h] = 0xFF;
  }
  return out;
}

/// Average per target cell, then nearest palette color (same as wadsub.py).
Uint8List _shrink(Uint8List img, int w, int h, Uint8List pal) {
  final near = <int, int>{}, res = Uint8List(_PW * _PH);
  int nearest(int r, int g, int b) {
    final key = (r << 16) | (g << 8) | b;
    var v = near[key];
    if (v == null) {
      var best = 1 << 30;
      v = 0;
      for (var i = 0; i < 256; i++) {
        final dr = _g(pal, 3 * i) - r, dg = _g(pal, 3 * i + 1) - g, db = _g(pal, 3 * i + 2) - b, e = dr * dr + dg * dg + db * db;
        if (e < best) {
          best = e;
          v = i;
        }
      }
      near[key] = v!;
    }
    return v;
  }

  for (var ty = 0; ty < _PH; ty++) {
    final y0 = ty * h ~/ _PH;
    var y1 = (ty + 1) * h ~/ _PH;
    if (y1 < y0 + 1) y1 = y0 + 1;
    for (var tx = 0; tx < _PW; tx++) {
      final x0 = tx * w ~/ _PW;
      var x1 = (tx + 1) * w ~/ _PW;
      if (x1 < x0 + 1) x1 = x0 + 1;
      var sr = 0, sg = 0, sb = 0, n = 0;
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final c = img[y * w + x];
          sr += _g(pal, 3 * c);
          sg += _g(pal, 3 * c + 1);
          sb += _g(pal, 3 * c + 2);
          n++;
        }
      }
      res[ty * _PW + tx] = nearest((sr + (n >> 1)) ~/ n, (sg + (n >> 1)) ~/ n, (sb + (n >> 1)) ~/ n);
    }
  }
  return res;
}

/// Partial WAD: only episode eps (e.g. '1'), only used textures, flats and monsters, full-screen pictures 128x128.
/// only (1.7.3 test17): Set of the map names to keep (a map pack alone).
Uint8List wadSub(Uint8List src, String eps, bool music, [Set<String>? only]) {
  final L = readWad(src);
  var out = <WadLump>[];
  final usedtex = <String>{}, usedflat = <String>{}, usedthings = <int>{};
  var i = 0;
  final musRe = RegExp('^D_E[$eps]M\\d\$');
  final epsChars = eps.runes.map(String.fromCharCode).toList();
  while (i < L.length) {
    final nm = L[i].name;
    final em = _reEM.firstMatch(nm);
    final String? m1 = em != null ? em.group(1) : (_D2 && eps == 'M' && _reMAP.hasMatch(nm) ? 'M' : null);
    if (m1 != null) {
      final keep = eps.contains(m1) && (only == null || only.contains(nm));
      var j = i + 1;
      while (j < L.length && _MAPL.contains(L[j].name)) {
        j++;
      }
      if (keep) {
        for (var k = i; k < j; k++) {
          out.add(L[k]);
          final n2 = L[k].name, dd = L[k].data;
          if (n2 == 'SIDEDEFS') {
            for (var q = 0; q + 30 <= dd.length; q += 30) {
              for (final o in const [4, 12, 20]) {
                usedtex.add(_upName(dd, q + o));
              }
            }
          }
          if (n2 == 'THINGS') {
            for (var q = 0; q + 10 <= dd.length; q += 10) {
              usedthings.add(_u16(dd, q + 6));
            }
          }
          if (n2 == 'SECTORS') {
            for (var q = 0; q + 26 <= dd.length; q += 26) {
              for (final o in const [4, 12]) {
                usedflat.add(_upName(dd, q + o));
              }
            }
          }
        }
      }
      i = j;
      continue;
    }
    if (nm.startsWith('D_') && music && (musRe.hasMatch(nm) || const ['D_INTER', 'D_INTRO', 'D_INTROA', 'D_VICTOR'].contains(nm) || (_D2 && eps == 'M'))) {
      out.add(L[i]);
      i++;
      continue;
    }
    if (nm.startsWith('DS') || nm.startsWith('D_') || const ['ENDOOM', 'GENMIDI', 'DMXGUS'].contains(nm) || RegExp(r'^DEMO\d$').hasMatch(nm)) {
      i++;
      continue;
    }
    out.add(L[i]);
    i++;
  }
  if (_D2 && eps == 'M') {
    usedtex.addAll(const ['SKY1', 'SKY2', 'SKY3']);
    usedflat.addAll(_D2_FLATS);
  } else {
    for (final e in epsChars) {
      usedtex.add('SKY$e');
    }
  }
  if (_E4) {
    for (final e in epsChars) {
      final f = _END_FLAT[e];
      if (f != null) usedflat.add(f);
    }
  }
  for (final t in usedtex.toList()) {
    if (t.startsWith('SW1')) usedtex.add('SW2${t.substring(3)}');
    if (t.startsWith('SW2')) usedtex.add('SW1${t.substring(3)}');
  }
  var names = out.map((x) => x.name).toList();
  var fs = names.indexOf('F_START'), fe = names.indexOf('F_END');
  final flats = _slice(names, fs + 1, fe);
  for (final ab in _ANIMS) {
    final a = ab[0], b = ab[1];
    if (flats.contains(a) && flats.contains(b)) {
      final rng = _slice(flats, flats.indexOf(b), flats.indexOf(a) + 1);
      if (rng.any(usedflat.contains)) usedflat.addAll(rng);
    }
  }
  final need = <String>{}, allmon = <String>{};
  _MON.forEach((t, sp) {
    allmon.addAll(sp);
    if (usedthings.contains(t)) need.addAll(sp);
  });
  final drop = allmon.where((x) => !need.contains(x)).toSet();
  final ss = names.indexOf('S_START'), se = names.indexOf('S_END');
  var j = 0;
  out = [
    for (j = 0; j < out.length; j++)
      if (!(ss < j && j < se && drop.contains(out[j].name.length > 4 ? out[j].name.substring(0, 4) : out[j].name))) out[j],
  ];
  names = out.map((x) => x.name).toList();
  fs = names.indexOf('F_START');
  fe = names.indexOf('F_END');
  final alltex = <String>[];
  for (final k in const ['TEXTURE1', 'TEXTURE2']) {
    if (names.contains(k)) {
      for (final t in _readTex(out[names.indexOf(k)].data)) {
        alltex.add(t.name);
      }
    }
  }
  for (final ab in _TANIMS) {
    final a = ab[0], b = ab[1];
    if (alltex.contains(a) && alltex.contains(b)) {
      final rng = _slice(alltex, alltex.indexOf(b), alltex.indexOf(a) + 1);
      if (rng.any(usedtex.contains)) usedtex.addAll(rng);
    }
  }
  for (final k in const ['TEXTURE1', 'TEXTURE2']) {
    if (!names.contains(k)) continue;
    final idx = names.indexOf(k);
    final all = _readTex(out[idx].data), keep = <_Tex>[];
    for (var t = 0; t < all.length; t++) {
      if ((k == 'TEXTURE1' && t == 0) || usedtex.contains(all[t].name)) keep.add(all[t]);
    }
    var size = 4 + 4 * keep.length;
    for (final t in keep) {
      size += t.raw.length;
    }
    final d = Uint8List(size);
    _w32(d, 0, keep.length);
    var pos = 4 + 4 * keep.length;
    for (var t = 0; t < keep.length; t++) {
      _w32(d, 4 + 4 * t, pos);
      d.setRange(pos, pos + keep[t].raw.length, keep[t].raw);
      pos += keep[t].raw.length;
    }
    out[idx] = WadLump(k, d);
  }
  out = [
    for (j = 0; j < out.length; j++)
      if (!(fs < j && j < fe && !usedflat.contains(out[j].name) && !out[j].name.endsWith('_START') && !out[j].name.endsWith('_END'))) out[j],
  ];
  final dropfull = <String>{'WIMAP0', 'WIMAP1', 'WIMAP2', 'VICTORY2', 'PFUB1', 'PFUB2'};
  if (_E4) dropfull.add('ENDPIC');
  for (final e in epsChars) {
    final c = e.codeUnitAt(0);
    if (e.length == 1 && c >= 0x30 && c <= 0x39) dropfull.remove('WIMAP${c - 0x30 - 1}');
    if (e == '2') dropfull.remove('VICTORY2');
    if (e == '4') dropfull.remove('ENDPIC');
    if (e == '3') {
      dropfull.remove('PFUB1');
      dropfull.remove('PFUB2');
    }
  }
  out = out.where((x) => !dropfull.contains(x.name)).toList();
  names = out.map((x) => x.name).toList();
  final pal = _sub(out[names.indexOf('PLAYPAL')].data, 0, 768);
  for (var k = 0; k < out.length; k++) {
    final nm = out[k].name;
    if (!(_FULL.contains(nm) || nm.startsWith('WIMAP') || (nm.startsWith('END') && nm.length == 4))) continue;
    _Pic p;
    try {
      p = _patchDecode(out[k].data);
    } catch (e) {
      continue;
    }
    if (p.w != 320 || p.h != 200) continue;
    out[k] = WadLump(nm, _fullEncode(_shrink(p.img, p.w, p.h, pal), _PW, _PH));
  }
  return writeWad(out, 'IWAD');
}

// ------------------------------------------------- extra WADs (PWAD): Sigil, map packs (1.7.3 test17)
/* PWAD = true: an extra WAD the user brings. Two kinds:
 *  - maps that replace maps of the base WAD (same names, e.g. MAP01 of a DOOM II map pack)
 *  - its own episode E5..E9 (Sigil E5, Sigil II E6): the engine knows four episodes, so it goes into the place of E4
 *    (maps E4M1..E4M9, its sky as SKY4, its pictures, names, end text and songs; UMAPINFO says which ones). */
const bool PWAD = true;
final RegExp _MARKERS = RegExp(r'^(P|PP|P1|P2|P3|F|FF|F1|F2|F3|S|SS)_(START|END)$');
const Set<String> _PWAD_DROP = {
  'DEHACKED', 'MAPINFO', 'UMAPINFO', 'ZMAPINFO', 'EMAPINFO', 'LANGUAGE', 'GAMEINFO', 'EMENUS', 'DD_DEFNS', //
  'CHNGLG', 'OPTIONS', 'ANIMATED', 'SWITCHES', 'TITLEPIC', 'HELP1', 'HELP2', 'D_INTER', 'D_INTRO', 'D_INTROA', 'D_VICTOR', 'DEMO1', //
  'DEMO2', 'DEMO3', 'DEMO4', 'GENMIDI', 'DMXGUS', 'ENDOOM', 'SNDINFO', 'SNDSEQ', 'MUSINFO', 'DECORATE', 'ZSCRIPT', 'TEXTURES', //
  'KEYCONF', 'MENUDEF', 'SBARINFO', 'COLORMAP', 'PLAYPAL',
};

final RegExp _reQuoted = RegExp(r'"([^"]*)"');

/// The keys of a JS object in the order JS lists them: whole numbers first (ascending), then the others as added.
Map<String, V> _jsOrder<V>(Map<String, V> m) {
  bool isIndex(String k) {
    if (k.isEmpty || k.length > 10 || (k.length > 1 && k.codeUnitAt(0) == 0x30)) return false;
    for (var i = 0; i < k.length; i++) {
      final c = k.codeUnitAt(i);
      if (c < 0x30 || c > 0x39) return false;
    }
    return int.parse(k) <= 4294967294;
  }

  final idx = m.keys.where(isIndex).toList()..sort((a, b) => int.parse(a).compareTo(int.parse(b)));
  if (idx.isEmpty) return m;
  return {for (final k in idx) k: m[k] as V, for (final k in m.keys.where((k) => !isIndex(k))) k: m[k] as V};
}

/// UMAPINFO: { E5M1: { levelname, levelpic, music, skytexture, exitpic, endpic, intertext, next, nextsecret, episode } }
Map<String, Map<String, String>> umapinfo(String txt) {
  final out = <String, Map<String, String>>{};
  final re = RegExp(r'map\s+(\w+)\s*\{([^}]*)\}', caseSensitive: false);
  final kv = RegExp(r'(\w+)\s*=\s*((?:"[^"]*"\s*,?\s*)+|[^\n]+)');
  for (final m in re.allMatches(txt)) {
    final o = <String, String>{}, body = m.group(2)!.replaceAll(RegExp(r'//[^\n]*'), '');
    for (final k in kv.allMatches(body)) {
      final key = k.group(1)!.toLowerCase(), strs = _reQuoted.allMatches(k.group(2)!).map((x) => x.group(1)!).toList();
      if (key == '__proto__') continue; // (a JS object does not take a text there)
      o[key] = strs.isNotEmpty ? (key == 'intertext' ? strs.join('\n') : strs[0]) : _trim(k.group(2)!);
    }
    out[m.group(1)!.toUpperCase()] = o;
  }
  return _jsOrder(out);
}

/// What an extra WAD holds: eps (own episodes 5..9), maps (names that replace maps), big (maps that probably need
/// more RAM than the Paradise has), title.
class PwadInfo {
  PwadInfo(this.eps, this.maps, this.big, this.title);
  final List<String> eps, maps, big;
  final String title;
}

PwadInfo pwadInfo(Uint8List d, [String? fileName]) {
  final L = readWad(d), eps = <String>{}, maps = <String>[];
  for (final l in L) {
    final nm = l.name, m = _reEM.firstMatch(nm);
    if (m != null) {
      final e = m.group(1)!;
      if (e.codeUnitAt(0) - 0x30 >= 5) {
        eps.add(e);
      } else {
        maps.add(nm);
      }
    } else if (_reMAP.hasMatch(nm)) {
      maps.add(nm);
    }
  }
  if (eps.isEmpty && maps.isEmpty) throw const FormatException('no maps in the extra WAD');
  final ui = _find(L, 'UMAPINFO'), info = ui != null ? umapinfo(_latin1(ui)) : const <String, Map<String, String>>{};
  var title = '';
  for (final v in info.values) {
    final ep = v['episode'];
    if (ep != null && ep.isNotEmpty) {
      final q = _reQuoted.allMatches(ep).toList();
      title = q.length > 1 ? q[1].group(1)! : '';
    }
  }
  if (title.isEmpty && fileName != null && fileName.isNotEmpty) {
    title = fileName.replaceFirst(RegExp(r'\.wad$', caseSensitive: false), '').replaceFirst(RegExp(r'[_-]?v\d.*$', caseSensitive: false), '').replaceAll('_', ' ');
  }
  // maps that probably need more RAM than the Paradise has (about 74 KB for a map): lines, sides, sectors, things
  final big = <String>[];
  final reAny = RegExp(r'^(E\dM\d|MAP\d\d)$');
  for (var i = 0; i < L.length; i++) {
    final nm = L[i].name;
    if (!reAny.hasMatch(nm)) continue;
    int g(String n) {
      for (final z in _slice(L, i + 1, i + 12)) {
        if (z.name == n) return z.data.length;
      }
      return 0;
    }

    if (g('LINEDEFS') / 14 * 6 + g('SIDEDEFS') / 30 + g('SECTORS') / 26 * 44 + g('THINGS') / 10 * 92 > 85000) big.add(nm);
  }
  final t = _upper(title.isEmpty ? 'EXTRA' : title);
  return PwadInfo(eps.toList()..sort(), maps, big, t.length > 16 ? t.substring(0, 16) : t);
}

Uint8List? _find(List<WadLump> L, String name) {
  for (final l in L) {
    if (l.name == name) return l.data;
  }
  return null;
}

// MIDI (MThd) -> MUS: the DOOM program plays MUS only. 140 ticks per second, channel 10 of MIDI is 15 of MUS.
const Map<int, int> _MUS_CTRL = {0: 1, 1: 2, 7: 3, 10: 4, 11: 5, 91: 6, 93: 7, 64: 8, 67: 9}, _MUS_SYS = {120: 10, 123: 11, 126: 12, 127: 13, 121: 14};

/// JS Math.round (half up); x is finite.
double _round(double x) {
  final f = x.floorToDouble();
  return x - f >= 0.5 ? f + 1 : f;
}

class _Ev {
  _Ev(this.tick, this.n, this.hi, this.ch, this.a, this.c);
  final int tick, n, hi, ch;
  final int? a, c; // null: behind the end of the file (JS undefined)
}

Uint8List? mid2mus(Uint8List mid) {
  int r32(int o) => ((_g(mid, o) << 24) | (_g(mid, o + 1) << 16) | (_g(mid, o + 2) << 8) | _g(mid, o + 3)) & 0xFFFFFFFF;
  int r16(int o) => (_g(mid, o) << 8) | _g(mid, o + 1);
  if (!(_g(mid, 0) == 0x4D && _g(mid, 1) == 0x54 && _g(mid, 2) == 0x68 && _g(mid, 3) == 0x64)) return null;
  final ntr = r16(10), div = r16(12);
  if ((div & 0x8000) != 0) return null;
  final ev = <_Ev>[], tempos = <List<int>>[
    [0, 500000, 0],
  ];
  var p = 8 + r32(4);
  for (var t = 0; t < ntr && p + 8 <= mid.length; t++) {
    final len = r32(p + 4);
    var q = p + 8;
    final end = q + len;
    var tick = 0, run = 0;
    while (q < end) {
      var d = 0, b = 0;
      do {
        b = _g(mid, q++);
        d = ((d << 7) | (b & 127)).toSigned(32);
      } while ((b & 128) != 0);
      tick += d;
      var st = _g(mid, q);
      if ((st & 128) != 0) {
        q++;
      } else {
        st = run;
      }
      if (st == 0xFF) {
        final ty = q < mid.length ? mid[q] : -1;
        q++;
        var l = 0;
        do {
          b = _g(mid, q++);
          l = ((l << 7) | (b & 127)).toSigned(32);
        } while ((b & 128) != 0);
        if (ty == 0x51) tempos.add([tick, (_g(mid, q) << 16) | (_g(mid, q + 1) << 8) | _g(mid, q + 2), tempos.length]);
        q += l;
        continue;
      }
      if (st == 0xF0 || st == 0xF7) {
        var l = 0;
        do {
          b = _g(mid, q++);
          l = ((l << 7) | (b & 127)).toSigned(32);
        } while ((b & 128) != 0);
        q += l;
        continue;
      }
      run = st;
      final hi = st & 0xF0, ch = st & 15;
      final int? a = (q >= 0 && q < mid.length) ? mid[q] : null;
      q++;
      int? c = 0;
      if (!(hi == 0xC0 || hi == 0xD0)) {
        c = (q >= 0 && q < mid.length) ? mid[q] : null;
        q++;
      }
      ev.add(_Ev(tick, ev.length, hi, ch, a, c));
    }
    p = end;
  }
  tempos.sort((x, y) => x[0] != y[0] ? x[0].compareTo(y[0]) : x[2].compareTo(y[2]));
  ev.sort((x, y) => x.tick != y.tick ? x.tick.compareTo(y.tick) : x.n.compareTo(y.n));
  double sec(int tick) {
    var s = 0.0;
    var t0 = 0, us = 500000;
    for (final tu in tempos) {
      final tt = tu[0];
      if (tt >= tick) break;
      s += (tt - t0).toDouble() * us / div / 1e6;
      t0 = tt;
      us = tu[1];
    }
    return s + (tick - t0).toDouble() * us / div / 1e6;
  }

  final chMap = <int, int>{}, vol = List<int>.filled(16, -1), out = <int>[];
  int musCh(int ch) {
    if (ch == 9) return 15;
    if (!chMap.containsKey(ch)) {
      if (chMap.length >= 15) return -1;
      chMap[ch] = chMap.length;
    }
    return chMap[ch]!;
  }

  var last = -1;
  var tPrev = 0.0;
  void put(List<int> bytes, double t) {
    if (last >= 0) {
      final x = (t - tPrev) * 140;
      // Math.max(0, Math.round(x)): NaN stays NaN (and counts as 0), Infinity is "not 0" but 0 as a 32-bit number
      if (!x.isNaN) {
        final dd = x.isInfinite ? (x > 0 ? double.infinity : 0.0) : (_round(x) < 0 ? 0.0 : _round(x));
        if (dd != 0) {
          var d = dd.isInfinite ? 0 : dd.toInt().toSigned(32);
          if (d < 0) throw StateError('MIDI: pause too long'); // (JS: loops for ever)
          out[last] |= 0x80;
          final v = <int>[d & 127];
          d >>= 7;
          while (d != 0) {
            v.insert(0, 0x80 | (d & 127));
            d >>= 7;
          }
          out.addAll(v);
          final y = t * 140;
          tPrev = (y.isNaN || y.isInfinite ? y : _round(y)) / 140;
        }
      }
    }
    last = out.length;
    out.addAll(bytes);
  }

  for (final e in ev) {
    final m = musCh(e.ch);
    if (m < 0) continue;
    final t = sec(e.tick), hi = e.hi, a = e.a, c = e.c;
    if (hi == 0x90 && c != null && c > 0) {
      if (vol[m] != c) {
        vol[m] = c;
        put([0x10 | m, 0x80 | (a ?? 0), c], t);
      } else {
        put([0x10 | m, a ?? 0], t);
      }
    } else if (hi == 0x80 || hi == 0x90) {
      put([0x00 | m, a ?? 0], t);
    } else if (hi == 0xE0) {
      put([0x20 | m, c == null ? 0 : (c * 2 + ((a ?? 0) >> 6)) & 255], t);
    } else if (hi == 0xC0) {
      put([0x40 | m, 0, a ?? 0], t);
    } else if (hi == 0xB0) {
      if (a != null && _MUS_SYS[a] != null) {
        put([0x30 | m, _MUS_SYS[a]!], t);
      } else if (a != null && _MUS_CTRL[a] != null) {
        put([0x40 | m, _MUS_CTRL[a]!, (c ?? 0) & 127], t);
      }
    }
  }
  put([0x60], ev.isNotEmpty ? sec(ev.last.tick) : 0);
  const head = 16;
  final score = out.length, res = Uint8List(head + score);
  res.setAll(0, const [0x4D, 0x55, 0x53, 0x1A]);
  _w16(res, 4, score);
  _w16(res, 6, head);
  _w16(res, 8, chMap.length);
  _w16(res, 10, 0);
  _w16(res, 12, 0);
  _w16(res, 14, 0);
  for (var i = 0; i < score; i++) {
    res[head + i] = out[i] & 255;
  }
  return score <= 0xFFFF ? res : null;
}

/// An extra WAD for [wadMerge]. slot true = its own episode goes into the place of E4.
class Pwad {
  Pwad(this.data, {this.slot = false});
  final Uint8List data;
  final bool slot;
}

Uint8List _encText(String s) {
  final o = <int>[];
  for (final r in s.replaceAll('\r', '').runes) {
    o.add((r > 0xFFFF ? 0xD800 + ((r - 0x10000) >> 10) : r) & 255);
  }
  o.add(0);
  return Uint8List.fromList(o);
}

/// Base IWAD + extra WADs. As in the Studio, the sky texture names inside the data of a PWAD with slot are renamed
/// in place (the PWAD's own bytes change).
Uint8List wadMerge(Uint8List base, List<Pwad> pw) {
  final L = readWad(base);
  const MAPL2 = {'THINGS', 'LINEDEFS', 'SIDEDEFS', 'VERTEXES', 'SEGS', 'SSECTORS', 'NODES', 'SECTORS', 'REJECT', 'BLOCKMAP', 'BEHAVIOR'};
  bool isMap(String n) => _reEM.hasMatch(n) || _reMAP.hasMatch(n);
  void set(String name, Uint8List data) {
    final i = L.indexWhere((x) => x.name == name);
    if (i >= 0) {
      L[i] = WadLump(name, data);
    } else {
      L.add(WadLump(name, data));
    }
  }

  for (final pwad in pw) {
    final data = pwad.data;
    final P = readWad(data), info = pwadInfo(data);
    final String? e = pwad.slot && info.eps.isNotEmpty ? info.eps[0] : null;
    final ui = _find(P, 'UMAPINFO'), um = ui != null ? umapinfo(_latin1(ui)) : const <String, Map<String, String>>{};
    Uint8List? get(String n) => _find(P, n);
    String? tr(String? s) => (s == null || s.isEmpty) ? null : s; // JS truthiness of a text
    final ren = <String, String?>{}; // lumps of the PWAD under a new name (into the place of E4)
    if (e != null) {
      final en = e.codeUnitAt(0) - 0x30;
      final names = <String>[], txt = <String>[];
      var back = '';
      for (var k = 1; k <= 9; k++) {
        final u = um['E${e}M$k'] ?? const <String, String>{};
        names.add(_upper('E${e}M$k: ${u['levelname'] ?? ''}'));
        final pic = tr(u['levelpic']) ?? 'WILV${en - 1}${k - 1}';
        if (get(pic) != null) ren[pic] = 'WILV3${k - 1}';
        final mus = get(tr(u['music']) ?? 'D_E${e}M$k');
        if (mus != null) {
          final mm = _g(mus, 0) == 0x4D && _g(mus, 1) == 0x55 && _g(mus, 2) == 0x53 ? mus : mid2mus(mus);
          if (mm != null) set('D_E4M$k', mm);
        }
        final xp = tr(u['exitpic']), np = tr(u['endpic']), it = tr(u['intertext']), nx = tr(u['next']), ep = tr(u['episode']);
        if (xp != null && get(xp) != null) ren[xp] = 'INTERPIC';
        if (np != null && get(np) != null) ren[np] = 'ENDPIC';
        if (it != null) txt.add(it);
        if (k == 9 && nx != null) {
          final m = RegExp(r'M(\d)$').firstMatch(nx);
          if (m != null) back = m.group(1)!;
        }
        if (k == 1 && ep != null) {
          final q = RegExp(r'"?(\w+)"?').firstMatch(ep);
          if (q != null && get(q.group(1)!) != null) ren[q.group(1)!] = 'M_EPI4';
        }
      }
      if (um['E${e}M1'] == null && get('M_EPI$e') != null) ren['M_EPI$e'] = 'M_EPI4';
      final et = txt.isNotEmpty ? txt.last : (get('E${e}TEXT') != null ? _latin1(get('E${e}TEXT')!) : '');
      set('PDMHU4', _encText(names.join('\n')));
      if (et.isNotEmpty) set('PDMTXT4', _encText(_upper(et)));
      if (back.isNotEmpty) set('PDMNXT4', _encText(back));
      ren['CREDIT'] = tr(ren['CREDIT']); // its own title pictures stay out (the base keeps its own)
      // the sky: the texture of its maps becomes SKY4 (the engine takes SKY4 for E4)
      final sky = tr((um['E${e}M1'] ?? const <String, String>{})['skytexture']) ?? 'SKY$e';
      for (final tn in const ['TEXTURE1', 'TEXTURE2']) {
        final td = get(tn);
        if (td == null) continue;
        final cnt = _u32(td, 0);
        for (var i = 0; i < cnt; i++) {
          final o = _u32(td, 4 + 4 * i), nm = _upName(td, o);
          void put(String s) {
            for (var q = 0; q < 8; q++) {
              if (o + q < td.length) td[o + q] = q < s.length ? s.codeUnitAt(q) : 0;
            }
          }

          if (nm == 'SKY4') {
            put('SKY4OLD');
          } else if (nm == sky) {
            put('SKY4');
          }
        }
      }
    }
    // maps: a map of the PWAD replaces the one of the same name (E5M3 becomes E4M3 in the place of E4)
    final outMaps = <(String, List<WadLump>)>[], flats = <WadLump>[], sprites = <WadLump>[], rest = <WadLump>[];
    var sect = '';
    final reOwn = e != null ? RegExp('^(WILV${e.codeUnitAt(0) - 0x30 - 1}\\d|M_EPI$e|E${e}TEXT|CREDIT)\$') : null;
    for (var i = 0; i < P.length; i++) {
      final n = P[i].name, d = P[i].data;
      if (_MARKERS.hasMatch(n)) {
        sect = n.endsWith('_START') ? n[0] : '';
        continue;
      }
      if (isMap(n)) {
        var j = i + 1;
        while (j < P.length && MAPL2.contains(P[j].name)) {
          j++;
        }
        final nn = e != null && n.startsWith('E${e}M') ? 'E4M${n[3]}' : n;
        outMaps.add((nn, P.sublist(i + 1, j)));
        i = j - 1;
        continue;
      }
      if (sect == 'F') {
        flats.add(P[i]);
        continue;
      }
      if (sect == 'S') {
        sprites.add(P[i]);
        continue;
      }
      if (_PWAD_DROP.contains(n) || RegExp(r'^D_E\dM\d$').hasMatch(n) || RegExp(r'_ZD$').hasMatch(n)) continue;
      if (ren.containsKey(n)) {
        final to = ren[n];
        if (to != null) rest.add(WadLump(to, d));
        continue;
      }
      if (reOwn != null && reOwn.hasMatch(n)) continue;
      if (e != null && d.length > 8 && _s16(d, 0) == 320 && _s16(d, 2) == 200) continue; // its other full pictures (title, end) are not used
      rest.add(P[i]);
    }
    for (final (nm, lumps) in outMaps) {
      final i = L.indexWhere((x) => x.name == nm);
      if (i >= 0) {
        var j = i + 1;
        while (j < L.length && MAPL2.contains(L[j].name)) {
          j++;
        }
        L.replaceRange(i, j, [WadLump(nm, Uint8List(0)), ...lumps]);
      } else {
        var k = -1;
        for (var q = 0; q < L.length; q++) {
          if (isMap(L[q].name)) k = q;
        }
        var j = k + 1;
        while (j < L.length && MAPL2.contains(L[j].name)) {
          j++;
        }
        L.insertAll(j, [WadLump(nm, Uint8List(0)), ...lumps]);
      }
    }
    void into(String endName, List<WadLump> items) {
      for (final it in items) {
        final i = L.indexWhere((x) => x.name == it.name);
        if (i >= 0) {
          L[i] = it;
        } else {
          final k = L.indexWhere((x) => x.name == endName);
          if (k >= 0) {
            L.insert(k, it);
          } else {
            L.add(it);
          }
        }
      }
    }

    into('F_END', flats);
    into('S_END', sprites);
    for (final r in rest) {
      set(r.name, r.data);
    }
  }
  return writeWad(L, 'IWAD');
}

// ------------------------------------------------- extra lumps (gbaextras.py)
const int _none = -1; // a transparent pixel (JS null)

class _Patch {
  _Patch(this.w, this.h, this.lo, this.to, this.px);
  final int w, h, lo, to;
  final List<List<int>> px; // columns
}

Uint8List _need(Map<String, Uint8List> L, String n) {
  final d = L[n];
  if (d == null) throw ArgumentError('lump $n missing in the WAD'); // (JS: a TypeError)
  return d;
}

_Patch _patchRead(Uint8List b) {
  final w = _s16(b, 0), h = _s16(b, 2), lo = _s16(b, 4), to = _s16(b, 6);
  final px = <List<int>>[];
  for (var x = 0; x < w; x++) {
    px.add(List<int>.filled(h, _none));
  }
  for (var x = 0; x < w; x++) {
    var c = _u32(b, 8 + 4 * x);
    for (;;) {
      if (c + 1 >= b.length && !(c < b.length && b[c] == 255)) throw RangeError('patch column without end'); // (JS: loops for ever)
      if (b[c] == 255) break;
      final y0 = b[c], ln = b[c + 1];
      for (var t = 0; t < ln; t++) {
        if (y0 + t < h) px[x][y0 + t] = _g(b, c + 3 + t);
      }
      c += ln + 4;
    }
  }
  return _Patch(w, h, lo, to, px);
}

Uint8List _patchWrite(int w, int h, int lo, int to, List<List<int>> px) {
  final cols = <List<int>>[];
  for (var x = 0; x < w; x++) {
    final col = <int>[];
    var y = 0;
    while (y < h) {
      if (px[x][y] == _none) {
        y++;
        continue;
      }
      final y0 = y, run = <int>[];
      while (y < h && px[x][y] != _none && run.length < 128) {
        run.add(px[x][y]);
        y++;
      }
      col
        ..add(y0)
        ..add(run.length)
        ..add(run[0])
        ..addAll(run)
        ..add(run[run.length - 1]);
    }
    col.add(255);
    cols.add(col);
  }
  var size = 8 + 4 * w;
  for (final c in cols) {
    size += c.length;
  }
  final out = Uint8List(size);
  _w16(out, 0, w);
  _w16(out, 2, h);
  _w16(out, 4, lo);
  _w16(out, 6, to);
  var off = 8 + 4 * w;
  for (var x = 0; x < cols.length; x++) {
    _w32(out, 8 + 4 * x, off);
    for (var i = 0; i < cols[x].length; i++) {
      out[off + i] = cols[x][i] & 255;
    }
    off += cols[x].length;
  }
  return out;
}

List<List<int>> _squeeze(List<List<int>> px, int w, int nw) {
  if (nw == w) return px;
  return [
    for (var x = 0; x < nw; x++) px[(x * w + (w >> 1)) ~/ nw < w - 1 ? (x * w + (w >> 1)) ~/ nw : w - 1],
  ];
}

Uint8List _textPatch(Map<String, Uint8List> L, String txt, [int scale = 2]) {
  final glyphs = <_Patch?>[
    for (final ch in txt.runes) ch == 0x20 ? null : _patchRead(_need(L, 'STCFN${(ch > 0xFFFF ? 0xD800 + ((ch - 0x10000) >> 10) : ch).toString().padLeft(3, '0')}')),
  ];
  var hm = 0;
  for (final g in glyphs) {
    if (g != null && g.h > hm) hm = g.h;
  }
  final H = hm * scale, cols = <List<int>>[];
  List<int> empty() => List<int>.filled(H, _none);
  for (final g in glyphs) {
    if (g == null) {
      for (var k = 0; k < 4 * scale; k++) {
        cols.add(empty());
      }
      continue;
    }
    for (var x = 0; x < g.w; x++) {
      final col = empty();
      for (var y = 0; y < g.h; y++) {
        final v = g.px[x][y];
        if (v != _none) {
          for (var sy = 0; sy < scale; sy++) {
            col[(H - g.h * scale) + y * scale + sy] = v;
          }
        }
      }
      for (var k = 0; k < scale; k++) {
        cols.add(col);
      }
    }
    for (var k = 0; k < scale; k++) {
      cols.add(empty());
    }
  }
  return _patchWrite(cols.length, H, 0, 0, cols);
}

const List<List<int>> _SEGS = [
  [0, 48, 0, 34], [48, 104, 34, 78], [104, 143, 78, 107], [143, 178, 107, 135], [178, 236, 135, 177], [236, 249, 177, 187], [249, 320, 187, 240], //
];
Uint8List _stbarGba(Map<String, Uint8List> L) {
  final B = _patchRead(_need(L, 'STBAR')), A = _patchRead(_need(L, 'STARMS'));
  final W = B.w;
  // (a JS array grows when written behind its end and gives undefined when read there: columns long enough for both)
  final hh = [B.h, A.h, 32].reduce((a, b) => a > b ? a : b);
  final bar = <List<int>>[
    for (final c in B.px) List<int>.filled(hh, _none)..setRange(0, c.length, c),
  ];
  for (var x = 0; x < A.w; x++) {
    for (var y = 0; y < A.h; y++) {
      if (A.px[x][y] != _none && 104 + x < W) bar[104 + x][y] = A.px[x][y];
    }
  }
  final out = <List<int>>[for (var x = 0; x < 240; x++) List<int>.filled(32, 0)];
  for (final s in _SEGS) {
    final s0 = s[0], s1 = s[1], d0 = s[2], d1 = s[3];
    for (var x = d0; x < d1; x++) {
      final sx = s0 + ((x - d0) * (s1 - s0) + ((s1 - s0) >> 1)) ~/ (d1 - d0);
      for (var y = 0; y < 32; y++) {
        final v = bar[sx < W - 1 ? sx : W - 1][y];
        out[x][y] = v != _none ? v : 0;
      }
    }
  }
  final P = _patchRead(_need(L, 'STTPRCNT')), pc = _squeeze(P.px, P.w, 10);
  for (final px0 in const [68, 168]) {
    for (var x = 0; x < 10; x++) {
      for (var y = 0; y < P.h; y++) {
        final v = pc[x][y];
        if (v != _none && px0 + x < 240 && 6 + y < 32) out[px0 + x][6 + y] = v;
      }
    }
  }
  final r = Uint8List(240 * 32);
  for (var y = 0; y < 32; y++) {
    for (var x = 0; x < 240; x++) {
      r[y * 240 + x] = out[x][y];
    }
  }
  return r;
}

/// Replacement for gbadoom.wad, built only from the user's own WAD.
Uint8List gbaExtras(Uint8List wad) {
  final L = <String, Uint8List>{for (final l in readWad(wad)) l.name: l.data};
  final lumps = <WadLump>[
    WadLump('CREDITS', _patchWrite(1, 1, 0, 0, [
      [_none],
    ])),
    WadLump('M_ARUN', _textPatch(L, 'ALWAYS RUN')),
    WadLump('M_GAMMA', _textPatch(L, 'GAMMA')),
  ];
  for (var i = 0; i < 10; i++) {
    final p = _patchRead(_need(L, 'STTNUM$i'));
    lumps.add(WadLump('STGANUM$i', _patchWrite(10, p.h, p.lo, p.to, _squeeze(p.px, p.w, 10))));
  }
  for (var i = 1; i <= 5; i++) {
    lumps.add(WadLump('PLAYPAL$i', _need(L, 'PLAYPAL')));
  }
  lumps.add(WadLump('STBARGBA', _stbarGba(L)));
  return writeWad(lumps, 'PWAD');
}

// --------------------------------------------------------- converter
// MCUDoomWadUtil (doom/src/wasm: conv.c, wadfile.c, wadprocessor.c, doomtypes.h; built with -DKEEP_DP -DKEEP_MUS),
// in the Studio the WebAssembly module doom/mcuwad.wasm. A pure computation on the two WADs:
//   1. the lumps of the extras are appended to the partial WAD (mergeWadFile)
//   2. GENMIDI is removed (removeUnusedLumps; sounds, PC speaker sounds and music stay)
//   3. every texture of more than one patch, or of one patch with an offset, is drawn into one new patch SPTExxxx
//      (xxxx: number of the texture, hex), added in front of the lump before P_END and to PNAMES
//   4. patches of PNAMES that are the first patch of no texture are removed
//   5. in every lump from HELP1 (or HELP) to P_END, and from M_ARUN to STGANUM9, the top byte of each column offset
//      gets the length of the column (rounded up to 4)
//   6. the maps (MAP01..MAP32 if MAP01 is there, else E1M1..E4M9): VERTEXES as 16.16 fixed point, LINEDEFS and SEGS
//      as the structures of the engine (line_t 56 bytes, seg_t 32 bytes), SIDEDEFS with texture numbers (12 bytes),
//      PNAMES in capitals
//   7. written as an IWAD: header, directory, then the lumps, each padded to 4 bytes
// The memory of the module starts as zeros and nothing is freed, so every malloc gives zeros: Uint8List(n) here.

class _CL {
  _CL(this.name, this.size, this.data);
  Uint8List name; // 8 bytes
  int size;
  Uint8List data; // may be longer than size (the padding read from the file)
}

int _cs16(Uint8List b, int o) {
  final v = b[o] | (b[o + 1] << 8);
  return v > 32767 ? v - 65536 : v;
}

int _cu16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int _cu32(Uint8List b, int o) => (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) & 0xFFFFFFFF;
int _cs32(Uint8List b, int o) => _cu32(b, o).toSigned(32);

Uint8List _cname(String s) {
  final b = Uint8List(8);
  for (var i = 0; i < s.length && i < 8; i++) {
    b[i] = s.codeUnitAt(i);
  }
  return b;
}

/// strncmp(a, b, 8) == 0 (bytes behind the end of a buffer count as 0).
bool _nameEq(Uint8List a, int ao, Uint8List b, int bo) {
  for (var i = 0; i < 8; i++) {
    final ca = ao + i < a.length ? a[ao + i] : 0, cb = bo + i < b.length ? b[bo + i] : 0;
    if (ca != cb) return false;
    if (ca == 0) return true;
  }
  return true;
}

class _CWad {
  final List<_CL> lumps = [];

  static _CWad? load(Uint8List src) {
    final w = _CWad();
    // (the module gets 8 zero bytes behind the file)
    final buf = src.length >= 12 ? src : (Uint8List(src.length + 8)..setRange(0, src.length, src));
    if (buf.length < 12) return null;
    if (!(buf[1] == 0x57 && buf[2] == 0x41 && buf[3] == 0x44) || (buf[0] != 0x49 && buf[0] != 0x50)) return null;
    final n = _cs32(buf, 4), dir = _cs32(buf, 8);
    for (var i = 0; i < n; i++) {
      final e = dir + 16 * i;
      final pos = _cu32(buf, e), size = _cs32(buf, e + 4);
      if (size < 0) throw RangeError('lump size');
      final lumpSize = (size + 3) & ~3;
      final data = Uint8List(lumpSize);
      final avail = pos < buf.length ? buf.length - pos : 0;
      final c = lumpSize < avail ? lumpSize : avail;
      data.setRange(0, c, buf, pos);
      w.lumps.add(_CL(Uint8List.fromList(buf.sublist(e + 8, e + 16)), size, data));
    }
    return w;
  }

  int num(Uint8List name, [int off = 0]) {
    for (var i = 0; i < lumps.length; i++) {
      if (_nameEq(lumps[i].name, 0, name, off)) return i;
    }
    return -1;
  }

  int numS(String name) => num(_cname(name));

  /// getLumpByNum for a lump the C code uses without a check: a missing one is undefined behaviour there.
  _CL must(int n, String what) {
    if (n < 0 || n >= lumps.length) throw StateError('WAD conversion failed ($what missing)');
    return lumps[n];
  }

  void insert(_CL l, int index) {
    if (index > lumps.length) index = lumps.length;
    if (index < 0) index = 0;
    lumps.insert(index, l);
  }

  Uint8List save(int type) {
    var total = 12 + 16 * lumps.length;
    for (final l in lumps) {
      total += (l.size + 3) & ~3;
    }
    final out = Uint8List(total);
    out[0] = type;
    out[1] = 0x57;
    out[2] = 0x41;
    out[3] = 0x44;
    _w32(out, 4, lumps.length);
    _w32(out, 8, 12);
    var ptr = 12 + 16 * lumps.length, p = 12;
    for (final l in lumps) {
      _w32(out, p, ptr);
      _w32(out, p + 4, l.size);
      out.setRange(p + 8, p + 16, l.name);
      p += 16;
      ptr += (l.size + 3) & ~3;
    }
    for (final l in lumps) {
      out.setRange(p, p + l.size, l.data);
      p += (l.size + 3) & ~3;
    }
    return out;
  }
}

/// The two texture lumps as the C code walks them: number of textures and where each one starts.
class _CTex {
  _CTex(_CWad w) {
    final t1 = w.must(w.numS('TEXTURE1'), 'TEXTURE1').data;
    final n2i = w.numS('TEXTURE2');
    final t2 = n2i != -1 ? w.lumps[n2i].data : null;
    final n1 = _cs32(t1, 0), n2 = t2 != null ? _cs32(t2, 0) : 0;
    for (var i = 0; i < n1 + n2; i++) {
      if (i < n1) {
        buf.add(t1);
        off.add(_cs32(t1, 4 + 4 * i));
      } else {
        buf.add(t2!);
        off.add(_cs32(t2, 4 + 4 * (i - n1)));
      }
    }
  }
  final List<Uint8List> buf = [];
  final List<int> off = [];
  int get count => buf.length;
}

void _convertCompositeTextures(_CWad w) {
  if (w.numS('PNAMES') == -1) return;
  final tx = _CTex(w);
  final pEnd = _cname('P_END'), pnamesName = _cname('PNAMES');
  for (var t = 0; t < tx.count; t++) {
    final b = tx.buf[t], o = tx.off[t];
    final pc = _cs16(b, o + 20);
    if (pc < 2 && _cs16(b, o + 22) == 0 && _cs16(b, o + 24) == 0) continue; // we are interested only in composite textures
    if (pc < 0) throw StateError('WAD conversion failed (texture $t)');
    final width = _cs16(b, o + 12), height = _cs16(b, o + 14);
    if (width < 0 || height < 0) throw StateError('WAD conversion failed (texture $t)');
    final texbuf = Uint8List(height * width); // x and y swapped
    // R_ComposeColumn: the patches in order; a patch whose lump is missing ends the column
    final pn = w.lumps[w.num(pnamesName)].data;
    final np = pc < 1 ? 1 : pc;
    final pl = <Uint8List?>[];
    for (var i = 0; i < np; i++) {
      final k = w.num(pn, 4 + _cs16(b, o + 22 + 10 * i + 4) * 8);
      pl.add(k == -1 ? null : w.lumps[k].data);
      if (k == -1) break;
    }
    for (var x = 0; x < width; x++) {
      final cache = height * x;
      for (var i = 0; i < np; i++) {
        final real = pl[i];
        if (real == null) break;
        final po = o + 22 + 10 * i;
        final x1 = _cs16(b, po);
        if (x < x1) continue;
        final x2 = x1 + _cs16(real, 0);
        if (x < x2) {
          // R_DrawColumnInCache
          var p = _cu32(real, 8 + 4 * (x - x1)) & 0xFFFFFF;
          final originy = _cs16(b, po + 2);
          while (real[p] != 0xff) {
            final len = real[p + 1];
            var count = len, position = originy + real[p];
            if (position < 0) {
              count += position;
              position = 0;
            }
            if (position + count > height) count = height - position;
            if (count > 0) texbuf.setRange(cache + position, cache + position + count, real, p + 3);
            p += len + 4;
          }
        }
      }
    }
    // convertRectangularBitmapToPatch
    final size = 8 + 4 * width + (height + 5) * width;
    final pd = Uint8List(size);
    _w16(pd, 0, width);
    _w16(pd, 2, height);
    for (var i = 0; i < width; i++) {
      final co = 8 + 4 * width + (height + 5) * i;
      _w32(pd, 8 + 4 * i, co);
      pd[co] = 0; // top delta
      pd[co + 1] = height & 255; // post length
      pd[co + 2] = 0; // pad
      pd.setRange(co + 3, co + 3 + height, texbuf, i * height);
      pd[co + 3 + height] = 0; // pad
      pd[co + 4 + height] = 0xFF; // last top delta
    }
    final hx = t.toRadixString(16).toUpperCase().padLeft(4, '0');
    final nl = _CL(_cname('SPTE$hx'), size, pd);
    w.insert(nl, w.num(pEnd) - 1);
    // addPatchToPnames
    final pi = w.num(pnamesName);
    final old = w.lumps[pi];
    final nd = Uint8List(old.size + 8);
    nd.setRange(0, old.size, old.data);
    final count = _cu32(old.data, 0);
    _w32(nd, 0, count + 1);
    nd.setRange(4 + count * 8, 4 + count * 8 + 8, nl.name);
    w.lumps[pi] = _CL(old.name, old.size + 8, nd);
    // now change texture data
    _w16(b, o + 20, 1);
    _w16(b, o + 22, 0);
    _w16(b, o + 24, 0);
    _w16(b, o + 26, count);
  }
}

void _removeUnusedPatches(_CWad w) {
  final li = w.numS('PNAMES');
  if (li == -1) return;
  final pn = w.lumps[li].data;
  final count = _cu32(pn, 0);
  final tx = _CTex(w);
  final used = <int>{};
  for (var t = 0; t < tx.count; t++) {
    used.add(_cs16(tx.buf[t], tx.off[t] + 26));
  }
  for (var i = 0; i < count; i++) {
    if (used.contains(i)) continue;
    final k = w.num(pn, 4 + 8 * i);
    if (k != -1) w.lumps.removeAt(k);
  }
}

void _processPatches(_CWad w, int first, int last) {
  // (the C loop counts unsigned: without the first lump nothing is done, with last == -1 it runs to the end)
  if (first < 0) return;
  final end = (last < 0 || last > w.lumps.length) ? w.lumps.length : last;
  for (var n = first; n < end; n++) {
    final l = w.lumps[n];
    if (l.size == 0) continue; // sprites and texture patches are separated by 0-length markers
    final np = Uint8List.fromList(l.data.sublist(0, l.size));
    final width = _cs16(np, 0);
    for (var c = 0; c < width; c++) {
      final base = _cu32(np, 8 + 4 * c);
      // getColumnLength
      var k = 1, col = base;
      while (np[col] != 0xff) {
        k = (k + 1 + np[col + 1] + 3) & 0xFFFF;
        col = base + k - 1;
      }
      np[8 + 4 * c + 3] = ((k + 3) & ~3) & 255;
    }
    w.lumps[n] = _CL(l.name, l.size, np);
  }
}

int _fixedSign(int a, int b) {
  // FixedDiv(a, b) > 0 ?
  int abs32(int x) {
    final s = x >> 31;
    return ((x ^ s) - s) & 0xFFFFFFFF;
  }

  final r = (abs32(a) >> 14) >= abs32(b) ? ((a ^ b) >> 31) ^ 0x7FFFFFFF : ((a << 16) ~/ b).toSigned(32);
  return r.toSigned(32);
}

void _processLevel(_CWad w, int n) {
  const mlLines = 2, mlSides = 3, mlVtx = 4, mlSegs = 5;
  _CL? at(int k) => n + k < w.lumps.length ? w.lumps[n + k] : null;
  // processVertexes
  () {
    final vxl = at(mlVtx);
    if (vxl == null || vxl.size == 0) return;
    final cnt = vxl.size ~/ 4, nv = Uint8List(cnt * 8);
    for (var i = 0; i < cnt; i++) {
      _w32(nv, 8 * i, _cs16(vxl.data, 4 * i) << 16);
      _w32(nv, 8 * i + 4, _cs16(vxl.data, 4 * i + 2) << 16);
    }
    w.lumps[n + mlVtx] = _CL(vxl.name, cnt * 8, nv);
  }();
  // processLines
  () {
    final lines = at(mlLines);
    if (lines == null || lines.size == 0) return;
    final cnt = lines.size ~/ 14, o = lines.data;
    final vxl = at(mlVtx);
    if (vxl == null || vxl.size == 0) return;
    final vtx = vxl.data, nl = Uint8List(cnt * 56);
    for (var i = 0; i < cnt; i++) {
      final a = _cu16(o, 14 * i), b = _cu16(o, 14 * i + 2), q = 56 * i;
      final v1x = _cs32(vtx, 8 * a), v1y = _cs32(vtx, 8 * a + 4), v2x = _cs32(vtx, 8 * b), v2y = _cs32(vtx, 8 * b + 4);
      final dx = (v2x - v1x).toSigned(32), dy = (v2y - v1y).toSigned(32);
      _w32(nl, q, v1x);
      _w32(nl, q + 4, v1y);
      _w32(nl, q + 8, v2x);
      _w32(nl, q + 12, v2y);
      _w32(nl, q + 16, i); // lineno
      _w32(nl, q + 20, dx);
      _w32(nl, q + 24, dy);
      _w16(nl, q + 28, _cu16(o, 14 * i + 10)); // sidenum
      _w16(nl, q + 30, _cu16(o, 14 * i + 12));
      _w32(nl, q + 32, v1y < v2y ? v2y : v1y); // bbox: top, bottom, left, right
      _w32(nl, q + 36, v1y < v2y ? v1y : v2y);
      _w32(nl, q + 40, v1x < v2x ? v1x : v2x);
      _w32(nl, q + 44, v1x < v2x ? v2x : v1x);
      _w16(nl, q + 48, _cu16(o, 14 * i + 4)); // flags
      _w16(nl, q + 50, _cu16(o, 14 * i + 6)); // special
      _w16(nl, q + 52, _cu16(o, 14 * i + 8)); // tag
      // slopetype: ST_HORIZONTAL 0, ST_VERTICAL 1, ST_POSITIVE 2, ST_NEGATIVE 3
      _w16(nl, q + 54, dx == 0 ? 1 : (dy == 0 ? 0 : (_fixedSign(dy, dx) > 0 ? 2 : 3)));
    }
    w.lumps[n + mlLines] = _CL(lines.name, cnt * 56, nl);
  }();
  // processSegs
  () {
    final segs = at(mlSegs);
    if (segs == null || segs.size == 0) return;
    final cnt = segs.size ~/ 12, o = segs.data;
    final vxl = at(mlVtx);
    if (vxl == null || vxl.size == 0) return;
    final lxl = at(mlLines);
    if (lxl == null || lxl.size == 0) return;
    final sxl = at(mlSides);
    if (sxl == null || sxl.size == 0) return;
    final vtx = vxl.data, lines = lxl.data, sides = sxl.data, ns = Uint8List(cnt * 32);
    for (var i = 0; i < cnt; i++) {
      final a = _cu16(o, 12 * i), b = _cu16(o, 12 * i + 2), q = 32 * i;
      _w32(ns, q, _cs32(vtx, 8 * a));
      _w32(ns, q + 4, _cs32(vtx, 8 * a + 4));
      _w32(ns, q + 8, _cs32(vtx, 8 * b));
      _w32(ns, q + 12, _cs32(vtx, 8 * b + 4));
      _w32(ns, q + 16, _cs16(o, 12 * i + 10) << 16); // offset
      _w32(ns, q + 20, _cs16(o, 12 * i + 4) << 16); // angle
      final linenum = _cu16(o, 12 * i + 6), ld = 56 * linenum, side = _cs16(o, 12 * i + 8);
      final sidenum = _cu16(lines, ld + 28 + 2 * side);
      _w16(ns, q + 24, sidenum);
      _w16(ns, q + 26, linenum);
      _w16(ns, q + 28, sidenum != 0xFFFF ? _cu16(sides, 30 * sidenum + 28) : 0xFFFF); // front sector
      var back = 0xFFFF;
      if ((_cu16(lines, ld + 48) & 4) != 0) {
        // ML_TWOSIDED
        final other = _cu16(lines, ld + 28 + 2 * (side ^ 1));
        if (other != 0xFFFF) back = _cu16(sides, 30 * other + 28);
      }
      _w16(ns, q + 30, back);
    }
    w.lumps[n + mlSegs] = _CL(segs.name, cnt * 32, ns);
  }();
  // processSides
  () {
    final sides = at(mlSides);
    if (sides == null || sides.size == 0) return;
    final cnt = sides.size ~/ 30, o = sides.data, ns = Uint8List(cnt * 12);
    // getTextureNumForName: the first texture of that name (capitals; the names in the lump as they are), else 0
    Map<String, int>? byName;
    int tex(int off) {
      if (byName == null) {
        final tx = _CTex(w);
        byName = {};
        for (var t = 0; t < tx.count; t++) {
          final s = StringBuffer();
          for (var k = 0; k < 8; k++) {
            final c = tx.buf[t][tx.off[t] + k];
            if (c == 0) break;
            s.writeCharCode(c);
          }
          byName!.putIfAbsent(s.toString(), () => t);
        }
      }
      final s = StringBuffer();
      for (var k = 0; k < 8; k++) {
        var c = o[off + k];
        if (c == 0) break;
        if (c >= 0x61 && c <= 0x7A) c -= 32;
        s.writeCharCode(c);
      }
      return byName![s.toString()] ?? 0;
    }

    for (var i = 0; i < cnt; i++) {
      final q = 30 * i, d = 12 * i;
      _w16(ns, d, _cu16(o, q));
      _w16(ns, d + 2, _cu16(o, q + 2));
      _w16(ns, d + 4, tex(q + 4)); // top
      _w16(ns, d + 6, tex(q + 12)); // bottom
      _w16(ns, d + 8, tex(q + 20)); // mid
      _w16(ns, d + 10, _cu16(o, q + 28));
    }
    w.lumps[n + mlSides] = _CL(sides.name, cnt * 12, ns);
  }();
  // processPNames: capitals, zeros behind the first zero
  final pi = w.numS('PNAMES');
  if (pi == -1) return;
  final pn = w.lumps[pi].data, count = _cu32(pn, 0);
  for (var i = 0; i < count; i++) {
    var nul = false;
    for (var j = 0; j < 8; j++) {
      var c = nul ? 0 : pn[4 + i * 8 + j];
      if (c >= 0x61 && c <= 0x7A) c -= 32;
      pn[4 + i * 8 + j] = c;
      if (c == 0) nul = true;
    }
  }
}

/// The WAD converter: sub (partial WAD of [wadSub]) and extras (of [gbaExtras]) to the WAD the program reads.
/// Same bytes as the Studio's WebAssembly converter (`convert(sub, extras, wasm)` there).
Uint8List convert(Uint8List sub, Uint8List extras) {
  final g = _CWad.load(extras);
  final w = g == null ? null : _CWad.load(sub);
  if (g == null || w == null) throw StateError('WAD conversion failed');
  for (final l in g.lumps) {
    w.insert(l, 0xFFFF); // mergeWadFile
  }
  // processWad(removeSound false, convertPatches true): removeUnusedLumps
  final gen = _cname('GENMIDI');
  w.lumps.removeWhere((l) {
    for (var i = 0; i < 7; i++) {
      if (l.name[i] != gen[i]) return false;
    }
    return true;
  });
  _convertCompositeTextures(w);
  _removeUnusedPatches(w);
  var first = w.numS('HELP1');
  if (first == -1) first = w.numS('HELP'); // for DOOM2
  _processPatches(w, first, w.numS('P_END'));
  // process gba specific patches, added at the end
  _processPatches(w, w.numS('M_ARUN'), w.numS('STGANUM9') + 1);
  if (w.numS('MAP01') != -1) {
    for (var m = 1; m <= 32; m++) {
      final n = w.numS('MAP${m.toString().padLeft(2, '0')}');
      if (n != -1) _processLevel(w, n);
    }
  } else {
    var any = w.numS('E1M1');
    /* v0.3.1: a partial WAD with only one episode (e.g. E2) has no E1M1 */
    for (var e = 2; e <= 4 && any == -1; e++) {
      any = w.numS('E${e}M1');
    }
    if (any == -1) throw StateError('WAD conversion failed'); // no maps found
    for (var e = 1; e <= 4; e++) {
      for (var m = 1; m <= 9; m++) {
        final n = w.numS('E${e}M$m');
        if (n != -1) _processLevel(w, n);
      }
    }
  }
  return w.save(0x49);
}

/// A converter with the interface of [convert], for an app that wants to run another one (e.g. the WebAssembly module).
typedef WadConverter = Uint8List Function(Uint8List sub, Uint8List extras);

// ------------------------------------------------------------- into the ROM
/// The embedded binaries: app (doom_app.bin), xip (doom_xip.bin), stub (emu/stub_tpl.bin).
class DoomEmb {
  DoomEmb({required this.app, required this.xip, required this.stub});
  final Uint8List app, xip, stub;
}

class DoomPatchResult {
  DoomPatchResult(this.rom, this.free);
  Uint8List rom;
  final int free;
}

/// Install DOOM. rom: 16 MB Paradise image, mcu: converted WAD, emb: the embedded binaries. Returns rom and free.
DoomPatchResult doomPatch(Uint8List rom, Uint8List mcu, DoomEmb emb) {
  if (rom.length != 0x1000000) throw StateError('the Paradise image must be 16 MB');
  final assetEnd = 0x111000 + 16 + _u32(rom, 0x111000 + 8);
  if (assetEnd > WAD_OFF) throw StateError('the character data reaches 0x${assetEnd.toRadixString(16)}, DOOM needs 0x830000 onwards');
  if (CODE_OFF + emb.xip.length > SAVE_OFF) throw StateError('DOOM program too big');
  final free = REGION_OFF - WAD_OFF - 4 - mcu.length;
  if (free < 0) throw StateError('WAD too big: ${mcu.length >> 10} KB, room ${(REGION_OFF - WAD_OFF - 4) >> 10} KB (try without music)');
  // Program and stub as for the emulator (shared stub, A+C), but without color Tama firmware
  final out = installApp(rom, emb.app, emb.stub);
  out.fillRange(CODE_OFF, SAVE_END, 0xFF);
  out.setRange(CODE_OFF, CODE_OFF + emb.xip.length, emb.xip);
  out.fillRange(WAD_OFF, REGION_END, 0xFF);
  _w32(out, WAD_OFF, mcu.length);
  out.setRange(WAD_OFF + 4, WAD_OFF + 4 + mcu.length, mcu);
  return DoomPatchResult(out, free);
}

// ------------------------------------------------------------- buttons
/*
 * Button mapping in the program's PDMC settings block (from DOOM v0.4.0, version 2):
 * button masks A 1, B 2, C 4, wheel press 8. Fixed: A+C menu, B+C map,
 * wheel for 2 s returns to the Paradise.
 */
class DoomKeys {
  const DoomKeys({this.fire = 1, this.fwd = 2, this.back = 4, this.use = 8, this.mod = 4, this.run = true, this.invert = true});
  final int fire, fwd, back, use, mod;
  final bool run, invert;
}

const DoomKeys KEYS_DEFAULT = DoomKeys();

int _pdmcAt(Uint8List rom) {
  for (var i = 0xA0000; i < 0xA0400; i += 4) {
    if (_u32(rom, i) == 0x434D4450) return i;
  }
  return -1;
}

/// Button mapping of a ROM with DOOM, or null (no DOOM, or an old version without mapping).
DoomKeys? doomKeysGet(Uint8List rom) {
  final i = _pdmcAt(rom);
  if (i < 0 || _u32(rom, i + 4) < 2) return null;
  return DoomKeys(
    fire: _u32(rom, i + 48),
    fwd: _u32(rom, i + 52),
    back: _u32(rom, i + 56),
    use: _u32(rom, i + 60),
    mod: _u32(rom, i + 64),
    run: _u32(rom, i + 68) != 0,
    invert: _u32(rom, i + 44) != 0,
  );
}

/// Check a mapping: returns an error text or ''.
String doomKeysCheck(DoomKeys k) {
  if (k.fire == k.fwd || k.fire == k.back || k.fwd == k.back) return 'fire, forward and back need three different buttons';
  if (k.use != 8 && [k.fire, k.fwd, k.back].contains(k.use)) return 'use needs its own button or the wheel';
  return '';
}

/// Write a mapping into a ROM with DOOM (new image).
Uint8List doomKeysSet(Uint8List rom, DoomKeys k) {
  final out = Uint8List.fromList(rom);
  final i = _pdmcAt(out);
  if (i < 0 || _u32(out, i + 4) < 2) throw StateError('this DOOM has no key layout of its own yet');
  final err = doomKeysCheck(k);
  if (err.isNotEmpty) throw StateError(err);
  _w32(out, i + 44, k.invert ? 1 : 0);
  _w32(out, i + 48, k.fire);
  _w32(out, i + 52, k.fwd);
  _w32(out, i + 56, k.back);
  _w32(out, i + 60, k.use);
  _w32(out, i + 64, k.mod);
  _w32(out, i + 68, k.run ? 1 : 0);
  return out;
}

/// Full path from the user's own WAD to the ROM. episode: '1' if null or empty; converter: [convert] if null.
DoomPatchResult doomBuild(Uint8List rom, Uint8List wad, DoomEmb emb, {String? episode, bool music = true, DoomKeys? keys, WadConverter? converter}) {
  final eps = (episode == null || episode.isEmpty) ? '1' : episode;
  final sub = wadSub(wad, eps, music);
  final mcu = (converter ?? convert)(sub, gbaExtras(sub));
  final r = doomPatch(rom, mcu, emb);
  if (keys != null) r.rom = doomKeysSet(r.rom, keys);
  return r;
}
