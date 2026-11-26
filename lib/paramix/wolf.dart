// Wolfenstein 3D for the Paradise, the data pack: a native Dart port of Paramix Studio's src/wolf.js
// (mameise, GPL-3.0-or-later).
//
// The user brings the game files (shareware .WL1 or full version .WL6); they never leave the device.
// This only reads them and puts what the program needs into one pack for the flash.
//
// Pack "W3DP" (little endian, offsets from the start of the pack):
//   0  'W3DP'  4 version (1)  8 flags (bit 0 shareware)  12 total length
//  16  pages: count, first sprite, table offset   (table: offset u32, length u32; walls 64x64 by columns, sprites as in VSWAP)
//  28  maps:  count, RLEW tag, table offset       (table: offset u32 or 0; map header 38 bytes as in GAMEMAPS, plane starts
//                                                  relative to the pack, planes Carmack + RLEW packed as in GAMEMAPS)
//  40  sounds: count, table offset                (PC speaker sounds: offset u32, length u32; data = u32 length, u16 priority, bytes)
//  48  pics:  count, table offset                 (table: offset u32, width u16, height u16; 8-bit, rows from the top)
//  56  reserved                                  60 episodes
// Pics: the range L_COLONPIC .. GETPSYCHEDPIC of the game (91 pics, same order in all versions; TITLEPIC is pic 43).
// Spear of Destiny (.SOD, flags bit 1): the same 91 places taken from its own chunks (title from its two halves), then
// its faces GODMODEFACE1..3, BJWAITING1..2, BJOUCH (pics 91..96). One episode of 21 floors.
//
// Reading outside a file gives 0, as in JS (undefined in bit operations). Where JS would loop for ever (a broken
// Huffman dictionary) the port throws a RangeError.

import 'dart:convert';
import 'dart:typed_data';

// ignore_for_file: constant_identifier_names, non_constant_identifier_names

int _g(Uint8List b, int i) => (i >= 0 && i < b.length) ? b[i] : 0;
int _u16(Uint8List b, int o) => _g(b, o) | (_g(b, o + 1) << 8);
int _s32(Uint8List b, int o) => (_g(b, o) | (_g(b, o + 1) << 8) | (_g(b, o + 2) << 16) | (_g(b, o + 3) << 24)).toSigned(32);
int _u32(Uint8List b, int o) => _s32(b, o) & 0xFFFFFFFF;
int _u24(Uint8List b, int o) => _g(b, o) | (_g(b, o + 1) << 8) | (_g(b, o + 2) << 16);
int _s16v(Uint8List b, int o) {
  final v = _u16(b, o);
  return v > 32767 ? v - 65536 : v;
}

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

/// JS TypedArray.subarray (a view, the ends clamped).
Uint8List _sub(Uint8List d, int a, int b) {
  final n = d.length;
  final s = a < 0 ? (n + a < 0 ? 0 : n + a) : (a > n ? n : a);
  var e = b < 0 ? (n + b < 0 ? 0 : n + b) : (b > n ? n : b);
  if (e < s) e = s;
  return Uint8List.sublistView(d, s, e);
}

const int _NUMSOUNDS = 87; // audiowl6.h LASTSOUND (shareware and full version)
const int _NUMSOUNDS_SOD = 81; // audiosod.h
// Spear of Destiny 1.4 (170 chunks): its chunk for each of the 91 places (gfxv_sod.h); TITLE (43) = TITLE1 above TITLE2
// the game palette of SOD (sodpal.inc of Wolf4SDL, 6-bit RGB): its title has a palette of its own (TITLEPALETTE, chunk
// 153), the program shows every pic with the game palette, so the title is taken to the nearest colours
const String _SOD_PAL_B64 =
    'AAAAAAAqACoAACoqKgAAKgAqKhUAKioqFRUVFRU/FT8VFT8/PxUVPxU/Pz8VPz8/Ozs7Nzc3NDQ0MDAwLS0tKioqJiYmIyMjHx8fHBwcGRkZFRUVEhISDg4OCwsLCAgIPwAAOwAAOAAANQAAMgAALwAALAAAKQAAJgAAIgAAHwAAHAAAGQAAFgAAEwAAEAAAPzY2Py4uPycnPx8fPxcXPxAQPwgIPwAAPyoXPyYQPyIIPx4AORsAMxgALRUAJxMAPz82Pz8uPz8nPz8fPz4XPz0QPz0IPz0AOTYAMzEALSsAJycAISEAHBsAFhUAEBAAND8XMT8QLT8IKD8AJDkAIDMAHS0AGCcANj82Lz8uJz8nID8fGD8XED8QCD8IAD8AAD8AADsAADgAADUAATIAAS8AASwAASkAASYAASIAAR8AARwAARkAARYAARMAARAANj8/Lj8/Jz8/Hz8+Fz8/ED8/CD8/AD8/ADk5ADMzAC0tACcnACEhABwcABYWABAQFy8/ECw/CCo/ACc/ACM5AB8zABstABcnNjY/Li8/Jyc/HyA/Fxg/EBA/CAk/AAE/AAA/AAA7AAA4AAA1AAAyAAAvAAAsAAApAAAmAAAiAAAfAAAcAAAZAAAWAAATAAAQCgoKPzgNPzUJPzMGPzACPy0AAA4AAAoAJgA5IAAzHQAtGAAnFAAhEQAcDQAWCgAQPzY/Py4/Pyc/Px8/Pxc/PxA/Pwg/PwA/OAA5MgAzLQAtJwAnIQAhGwAcFgAWEAAQPzo3Pzg0PzYxPzUvPzMsPzEpPy8nPy4kPywgPykcPycYPCUXOiMWNyIVNCAUMh8TLx4SLRwRKhoQKBkPJxgOJBcNIhYMIBQLHRMKGxIJFxAIFQ8HEg4GEAwGDgsFCggDGAAZABkZABgYAAAHAAALDAkEEgASFAAUAAANBwcHExMTFxcXEBAQDAwMDQ0NNj09Ljo6Jzc3HTIyEjAwCC0tCCwsACkpACYmACMjACEhAB8fAB4eAB0dABwcABsbJgAi';
Uint8List _toGamePal(Uint8List px, Uint8List pal) {
  final gp = base64.decode(_SOD_PAL_B64), map = Uint8List(256);
  for (var c = 0; c < 256; c++) {
    var best = 0, bd = 1000000000;
    for (var j = 0; j < 256; j++) {
      final dr = _g(pal, 3 * c) - gp[3 * j], dg = _g(pal, 3 * c + 1) - gp[3 * j + 1], db = _g(pal, 3 * c + 2) - gp[3 * j + 2], d = 3 * dr * dr + 4 * dg * dg + 2 * db * db;
      if (d < bd) {
        bd = d;
        best = j;
      }
    }
    map[c] = best;
  }
  final o = Uint8List(px.length);
  for (var i = 0; i < px.length; i++) {
    o[i] = map[px[i]];
  }
  return o;
}

int? _sodChunk(int k) {
  if (k <= 41) return 37 + k; // L_COLONPIC .. L_BJWINSPIC
  if (k >= 47 && k <= 87) return 54 + k; // KNIFEPIC .. GOTGATLINGPIC
  if (k >= 91) return 51 + k; // GODMODEFACE1PIC .. BJOUCHPIC
  return const {42: 90, 43: 79, 44: 91, 45: 92, 46: 29, 88: 142, 89: 148, 90: 149}[k];
}

const Map<int, int> _PIC_FIRST = {150: 44, 157: 56}; // chunk of L_COLONPIC by number of chunks (Activision/GT 1.4, Apogee 1.4)
const int _PIC_COUNT = 91; // L_COLONPIC .. GETPSYCHEDPIC
// used by the program: STATUSBAR (42, its colour), TITLE (43), weapons, keys, digits, faces, PAUSED, GETPSYCHED (47..90)
bool _PIC_USED(int k) => k == 42 || k == 43 || k >= 47;

const List<String> NEED = ['VSWAP', 'MAPHEAD', 'GAMEMAPS', 'AUDIOHED', 'AUDIOT', 'VGAHEAD', 'VGADICT', 'VGAGRAPH'];

/// One complete set of game files: ext 'WL1', 'WL6' or 'SOD', files by their name in capitals without the ending.
class WolfSet {
  WolfSet(this.ext, this.files);
  final String ext;
  final Map<String, Uint8List> files;
}

/// files: { 'VSWAP.WL1': bytes, ... } (any case, a path in front is fine). Returns one complete set or throws.
WolfSet pickSet(Map<String, Uint8List> files) {
  final by = <String, Map<String, Uint8List>>{};
  final re = RegExp(r'^([A-Za-z]+)\.(WL1|WL6|SOD)$', caseSensitive: false);
  for (final n in files.keys) {
    final m = re.firstMatch(n.replaceFirst(RegExp(r'^.*[\\/]'), ''));
    if (m != null) (by[m.group(2)!.toUpperCase()] ??= {})[m.group(1)!.toUpperCase()] = files[n]!;
  }
  for (final ext in const ['WL6', 'SOD', 'WL1']) {
    final s = by[ext];
    if (s == null) continue;
    if (NEED.every(s.containsKey)) return WolfSet(ext, s);
  }
  if (by.isEmpty) throw const FormatException('no Wolfenstein 3D files (.WL1, .WL6 or .SOD)');
  final ext = by.containsKey('WL6') ? 'WL6' : (by.containsKey('SOD') ? 'SOD' : 'WL1');
  throw FormatException('missing: ${NEED.where((k) => !by[ext]!.containsKey(k)).map((k) => '$k.$ext').join(', ')}');
}

Uint8List _huffExpand(Uint8List src, int so, int len, Uint16List nodes) {
  final out = Uint8List(len);
  var o = 0, n = 254, i = so, val = _g(src, i++), mask = 1;
  while (o < len) {
    final v = (val & mask) != 0 ? nodes[2 * n + 1] : nodes[2 * n];
    if (mask == 0x80) {
      val = _g(src, i++);
      mask = 1;
    } else {
      mask <<= 1;
    }
    if (v < 256) {
      out[o++] = v;
      n = 254;
    } else {
      n = v - 256;
    }
  }
  return out;
}

/// The graphics file: nchunks and chunk(c) (unpacked, null if the chunk is not there; explicit: its length, for chunks
/// without a length in front).
class WolfGraph {
  WolfGraph._(this.nchunks, this._head, this._graph, this._nodes);
  final int nchunks;
  final Uint8List _head, _graph;
  final Uint16List _nodes;

  int _pos(int c) {
    final v = _u24(_head, 3 * c);
    return v == 0xFFFFFF ? -1 : v;
  }

  Uint8List? chunk(int c, [int? explicit]) {
    final p = _pos(c);
    if (p < 0) return null;
    final len = explicit ?? _s32(_graph, p);
    return _huffExpand(_graph, explicit != null ? p : p + 4, len, _nodes);
  }
}

WolfGraph readGraph(Uint8List head, Uint8List dict, Uint8List graph) {
  final nchunks = head.length ~/ 3;
  final nodes = Uint16List(255 * 2);
  for (var i = 0; i < 510; i++) {
    nodes[i] = _u16(dict, 2 * i);
  }
  return WolfGraph._(nchunks, head, graph, nodes);
}

Uint8List _deplane(Uint8List d, int w, int h) {
  final out = Uint8List(w * h), pw = w >> 2;
  var s = 0;
  for (var p = 0; p < 4; p++) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < pw; x++) {
        out[y * w + (x << 2) + p] = d[s++];
      }
    }
  }
  return out;
}

class _Pic {
  _Pic(this.w, this.h, this.px);
  int w, h;
  Uint8List px;
}

class WolfPack {
  WolfPack(this.pack, this.ext, this.maps, this.episodes, this.sod);
  final Uint8List pack;
  final String ext;
  final int maps, episodes;
  final bool sod;
}

/// Build the pack. files: complete set (see pickSet).
WolfPack build(Map<String, Uint8List> files) {
  final set = pickSet(files);
  final ext = set.ext, f = set.files;
  final sod = ext == 'SOD', nsnd = sod ? _NUMSOUNDS_SOD : _NUMSOUNDS;
  final parts = <(int, Uint8List)>[];
  var size = 64;
  int add(Uint8List b) {
    final o = size;
    parts.add((o, b));
    size += b.length;
    size = (size + 3) & ~3;
    return o;
  }

  final hdr = Uint8List(64);
  // pages (walls and sprites, no digitized sounds)
  final vs = f['VSWAP']!, nch = _u16(vs, 0), spr = _u16(vs, 2), snd = _u16(vs, 4);
  // walls are 64 x 64 (4096 bytes); modified games (MacenWolf: 128 x 128) do not run with this program
  for (var i = 0; i < spr; i++) {
    final len = _u16(vs, 6 + 4 * nch + 2 * i);
    if (len != 0 && len != 4096) throw FormatException('VSWAP.$ext: walls not 64 x 64 (a modified game?), version 1.4 needed');
  }
  final npages = snd, ptab = Uint8List(npages * 8);
  for (var i = 0; i < npages; i++) {
    final off = _u32(vs, 6 + 4 * i), len = _u16(vs, 6 + 4 * nch + 2 * i);
    if (off == 0 || len == 0 || off + len > vs.length) continue;
    _w32(ptab, 8 * i, add(_sub(vs, off, off + len)));
    _w32(ptab, 8 * i + 4, len);
  }
  _w32(hdr, 16, npages);
  _w32(hdr, 20, spr);
  _w32(hdr, 24, add(ptab));
  // maps
  final mh = f['MAPHEAD']!, gm = f['GAMEMAPS']!, tag = _u16(mh, 0);
  var nmaps = 0;
  final moff = <int>[];
  for (var i = 0; 2 + 4 * i + 4 <= mh.length && i < 100; i++) {
    final o = _s32(mh, 2 + 4 * i);
    moff.add(o > 0 && o + 38 <= gm.length ? o : 0);
    if (moff[i] != 0) nmaps = i + 1;
  }
  final mtab = Uint8List(nmaps * 4);
  for (var i = 0; i < nmaps; i++) {
    final o = moff[i];
    if (o == 0) continue;
    final h = Uint8List.fromList(_sub(gm, o, o + 38));
    final at = add(h);
    for (var p = 0; p < 3; p++) {
      final ps = _s32(gm, o + 4 * p), pl = _u16(gm, o + 12 + 2 * p);
      _w32(h, 4 * p, ps > 0 && pl != 0 ? add(_sub(gm, ps, ps + pl)) : 0);
    }
    _w32(mtab, 4 * i, at);
  }
  _w32(hdr, 28, nmaps);
  _w32(hdr, 32, tag);
  _w32(hdr, 36, add(mtab));
  // PC speaker sounds
  final ah = f['AUDIOHED']!, at = f['AUDIOT']!, stab = Uint8List(nsnd * 8);
  for (var i = 0; i < nsnd && 4 * i + 8 <= ah.length; i++) {
    final a = _u32(ah, 4 * i), b = _u32(ah, 4 * i + 4);
    if (b > a && b <= at.length) {
      _w32(stab, 8 * i, add(_sub(at, a, b)));
      _w32(stab, 8 * i + 4, b - a);
    }
  }
  _w32(hdr, 40, nsnd);
  _w32(hdr, 44, add(stab));
  // pictures
  final g = readGraph(f['VGAHEAD']!, f['VGADICT']!, f['VGAGRAPH']!);
  final int? first = sod ? (g.nchunks == 170 ? 0 : null) : _PIC_FIRST[g.nchunks];
  if (first == null) throw FormatException('unknown version of VGAHEAD (${g.nchunks} chunks)');
  final st = g.chunk(0); // STRUCTPIC: width, height of every pic from chunk 3
  if (st == null) throw ArgumentError('VGAGRAPH: no picture table'); // (JS: a TypeError)
  final pics = <int>[for (var k = 0; k < _PIC_COUNT + (sod ? 6 : 0); k++) sod ? _sodChunk(k)! : first + k]; // TITLEPIC is pic 43
  _Pic? pic(int c) {
    final w = _s16v(st, 4 * (c - 3)), h = _s16v(st, 4 * (c - 3) + 2), d = g.chunk(c);
    if (d == null || w <= 0 || h <= 0 || (w & 3) != 0 || d.length < w * h) return null;
    return _Pic(w, h, _deplane(d, w, h));
  }

  final xtab = Uint8List(pics.length * 8);
  for (var k = 0; k < pics.length; k++) {
    final c = pics[k];
    if (!_PIC_USED(k)) continue; // pictures the program never shows stay out (flash)
    var p = pic(c);
    if (p != null && sod && k == 43) {
      // the title of SOD comes in two halves
      final q = pic(c + 1);
      if (q != null && q.w == p.w) {
        final px = Uint8List(p.w * (p.h + q.h));
        px.setRange(0, p.px.length, p.px);
        px.setRange(p.w * p.h, p.w * p.h + q.px.length, q.px);
        p = _Pic(p.w, p.h + q.h, px);
      }
      final tp = g.chunk(153); // TITLEPALETTE
      if (tp != null && tp.length >= 768) p.px = _toGamePal(p.px, tp);
    }
    if (p == null) continue;
    _w32(xtab, 8 * k, add(p.px));
    _w16(xtab, 8 * k + 4, p.w);
    _w16(xtab, 8 * k + 6, p.h);
  }
  _w32(hdr, 48, pics.length);
  _w32(hdr, 52, add(xtab));
  final episodes = sod ? 1 : (nmaps ~/ 10 < 1 ? 1 : nmaps ~/ 10);
  _w32(hdr, 60, episodes);
  hdr.setAll(0, const [0x57, 0x33, 0x44, 0x50]);
  _w32(hdr, 4, 1);
  _w32(hdr, 8, (ext == 'WL1' ? 1 : 0) | (sod ? 2 : 0));
  _w32(hdr, 12, size);
  final out = Uint8List(size);
  out.setAll(0, hdr);
  for (final (o, b) in parts) {
    out.setRange(o, o + b.length, b);
  }
  return WolfPack(out, ext, nmaps, episodes, sod);
}
