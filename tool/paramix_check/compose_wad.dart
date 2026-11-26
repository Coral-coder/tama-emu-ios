// Synthetic WADs for tool/paramix_check/compose_check.dart: the generators of tool/paramix_check/doom_check.dart,
// unchanged (seeded xorshift32, with the structure doom.dart reads). compose_wad.js has the same ones.

// ignore_for_file: non_constant_identifier_names, constant_identifier_names

import 'dart:math' as math;
import 'dart:typed_data';

void w16(Uint8List b, int o, int v) {
  b[o] = v & 255;
  b[o + 1] = (v >> 8) & 255;
}

void w32(Uint8List b, int o, int v) {
  b[o] = v & 255;
  b[o + 1] = (v >> 8) & 255;
  b[o + 2] = (v >> 16) & 255;
  b[o + 3] = (v >> 24) & 255;
}

Uint8List sub(Uint8List b, int a, [int? e]) => Uint8List.sublistView(b, math.min(a, b.length), math.max(math.min(a, b.length), math.min(e ?? b.length, b.length)));

// ------------------------------------------------------------ synthetic inputs
int Function() rng(int seed) {
  var x = seed & 0xFFFFFFFF;
  if (x == 0) x = 1;
  return () {
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    return x;
  };
}

Uint8List rnd(int Function() r, int n) {
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = r() & 255;
  }
  return b;
}

Uint8List asc(String s) => Uint8List.fromList([for (final c in s.codeUnits) c & 255]);
void name8(Uint8List b, int o, String s) {
  for (var i = 0; i < 8; i++) {
    b[o + i] = i < s.length ? s.codeUnitAt(i) : 0;
  }
}

Uint8List cat(List<Uint8List> parts) {
  final o = BytesBuilder(copy: false);
  for (final p in parts) {
    o.add(p);
  }
  return o.toBytes();
}

typedef LL = List<(String, Uint8List)>;
final Z = Uint8List(0);

/* a WAD: header, lumps, directory (some with the directory in front of the lumps) */
Uint8List wad(LL L, String ident, [bool dirFirst = false]) {
  var size = 12;
  for (final l in L) {
    size += l.$2.length;
  }
  final o = Uint8List(size + 16 * L.length), dir = dirFirst ? 12 : size;
  var p = dirFirst ? 12 + 16 * L.length : 12;
  o.setAll(0, asc(ident));
  w32(o, 4, L.length);
  w32(o, 8, dir);
  for (var i = 0; i < L.length; i++) {
    final (n, d) = L[i];
    o.setAll(p, d);
    w32(o, dir + 16 * i, p);
    w32(o, dir + 16 * i + 4, d.length);
    name8(o, dir + 16 * i + 8, n);
    p += d.length;
  }
  return o;
}

/* a picture in the patch format: columns of posts (top, length, pad, pixels, pad), 0xFF at the end */
Uint8List patch(int Function() r, int w, int h, [bool holes = false, int lo = 0, int to = 0]) {
  final cols = <List<int>>[];
  for (var x = 0; x < w; x++) {
    final c = <int>[];
    if (!holes) {
      c.addAll([0, h, r() & 255]);
      for (var y = 0; y < h; y++) {
        c.add(r() & 255);
      }
      c.add(r() & 255);
    } else {
      var y = r() % 4;
      while (y < h) {
        final int len = 1 + r() % math.min<int>(12, h - y);
        c.addAll([y, len, r() & 255]);
        for (var k = 0; k < len; k++) {
          c.add(r() & 255);
        }
        c.add(r() & 255);
        y += len + 1 + r() % 5;
      }
    }
    c.add(255);
    cols.add(c);
  }
  var size = 8 + 4 * w;
  for (final c in cols) {
    size += c.length;
  }
  final o = Uint8List(size);
  w16(o, 0, w);
  w16(o, 2, h);
  w16(o, 4, lo);
  w16(o, 6, to);
  var p = 8 + 4 * w;
  for (var x = 0; x < w; x++) {
    w32(o, 8 + 4 * x, p);
    o.setAll(p, cols[x]);
    p += cols[x].length;
  }
  return o;
}

Uint8List mus(int Function() r, int n) {
  final b = rnd(r, 16 + n);
  b.setAll(0, [0x4D, 0x55, 0x53, 0x1A]);
  return b;
}

/* the lumps of one map; tex, flats: names to draw from */
LL mapLumps(int Function() r, String name, List<String> tex, List<String> flats, {int mon = 0, bool emptyVtx = false, bool behavior = false, bool bigThings = false}) {
  int s16r() {
    final v = r() % 8;
    return v == 0 ? const [32767, -32768, 1, -1, 0][r() % 5] : ((r() % 17) - 8) * 64;
  }

  String pick(List<String> a) {
    final s = a[r() % a.length];
    return r() % 7 == 0 ? s.toLowerCase() : s;
  }

  final nv = 8 + r() % 10, nsec = 2 + r() % 3, nside = 6 + r() % 8, nline = 6 + r() % 8, nseg = 8 + r() % 10, nth = 5 + r() % 10;
  final things = Uint8List(10 * nth);
  const TY = [1, 3004, 9, 3001, 3002, 58, 3003, 3005, 3006, 16, 7, 2001, 2011];
  for (var i = 0; i < nth; i++) {
    w16(things, 10 * i, s16r());
    w16(things, 10 * i + 2, s16r());
    w16(things, 10 * i + 4, r() % 360);
    w16(things, 10 * i + 6, TY[mon != 0 ? r() % TY.length : r() % 4]);
    w16(things, 10 * i + 8, r() & 31);
  }
  final lines = Uint8List(14 * nline);
  for (var i = 0; i < nline; i++) {
    w16(lines, 14 * i, r() % nv);
    w16(lines, 14 * i + 2, r() % nv);
    w16(lines, 14 * i + 4, r() & 0x1FF);
    w16(lines, 14 * i + 6, r() % 140);
    w16(lines, 14 * i + 8, r() % 20);
    w16(lines, 14 * i + 10, r() % nside);
    w16(lines, 14 * i + 12, r() % 3 == 0 ? 0xFFFF : r() % nside);
  }
  final sides = Uint8List(30 * nside);
  for (var i = 0; i < nside; i++) {
    w16(sides, 30 * i, r() & 0xFFFF);
    w16(sides, 30 * i + 2, r() & 0xFFFF);
    for (final q in const [4, 12, 20]) {
      name8(sides, 30 * i + q, r() % 3 == 0 ? '-' : pick(tex));
    }
    w16(sides, 30 * i + 28, r() % nsec);
  }
  final vtx = Uint8List(emptyVtx ? 0 : 4 * nv);
  for (var i = 0; i < nv && !emptyVtx; i++) {
    w16(vtx, 4 * i, s16r());
    w16(vtx, 4 * i + 2, s16r());
  }
  final segs = Uint8List(12 * nseg);
  for (var i = 0; i < nseg; i++) {
    w16(segs, 12 * i, r() % nv);
    w16(segs, 12 * i + 2, r() % nv);
    w16(segs, 12 * i + 4, r() & 0xFFFF);
    w16(segs, 12 * i + 6, r() % nline);
    w16(segs, 12 * i + 8, r() & 1);
    w16(segs, 12 * i + 10, r() & 0xFFFF);
  }
  final secs = Uint8List(26 * nsec);
  for (var i = 0; i < nsec; i++) {
    w16(secs, 26 * i, r() % 128);
    w16(secs, 26 * i + 2, 128 + r() % 128);
    name8(secs, 26 * i + 4, pick(flats));
    name8(secs, 26 * i + 12, pick(flats));
    w16(secs, 26 * i + 20, r() & 255);
    w16(secs, 26 * i + 22, r() % 17);
    w16(secs, 26 * i + 24, r() % 20);
  }
  final LL L = [(name, Z)];
  L.add(('THINGS', bigThings ? rnd(r, 9400) : things));
  L.addAll([('LINEDEFS', lines), ('SIDEDEFS', sides), ('VERTEXES', vtx), ('SEGS', segs)]);
  L.add(('SSECTORS', rnd(r, 4 * (3 + r() % 5))));
  L.add(('NODES', rnd(r, 28 * (2 + r() % 4))));
  L.add(('SECTORS', secs));
  L.add(('REJECT', rnd(r, 1 + r() % 9)));
  L.add(('BLOCKMAP', rnd(r, 2 * (8 + r() % 20))));
  if (behavior) L.add(('BEHAVIOR', rnd(r, 16)));
  return L;
}

const PN = ['WALL00', 'WALL01', 'WALL02', 'WALL03', 'WALL04', 'WALL05', 'WALL06', 'WALL07', 'WALL08', 'WALL09', 'WALL10', 'WALL11', 'SKYP1', 'SKYP2', 'SKYP3', 'SKYP4', 'SWP1', 'SWP2', 'NOLUMP', 'wall05'];
const TEX1 = [
  'AASTINKY', 'SKY1', 'SKY2', 'SKY3', 'SKY4', 'SW1BRN', 'SW2BRN', 'BLODGR1', 'BLODGR2', 'BLODGR3', 'BLODGR4', 'SLADRIP1', 'SLADRIP2', 'SLADRIP3', 'FIREWALA', 'FIREWALB', 'FIREWALL', //
  'TEXA00', 'TEXA01', 'TEXA02', 'TEXA03', 'TEXA04', 'TEXA05', 'TEXA06', 'TEXA07', 'TEXA08', 'TEXA09', 'lowtex', 'HOLETEX', 'LOWPTEX',
];
const TEX2 = ['TEXB00', 'TEXB01', 'TEXB02', 'TEXB03', 'TEXB04', 'TEXB05'];
Uint8List texLump(int Function() r, List<String> names, [List<String> extra = const []]) {
  final defs = <Uint8List>[];
  for (final n in [...names, ...extra]) {
    final w = n.startsWith('SKY') ? 32 : 8 + r() % 41, h = n.startsWith('SKY') ? 32 : 16 + r() % 49;
    List<List<int>> ps;
    if (n == 'AASTINKY') {
      ps = [
        [0, 0, 0],
      ];
    } else if (n.startsWith('SKY')) {
      ps = [
        [0, 0, 12 + (n.codeUnitAt(3) - 0x31) % 4],
      ];
    } else if (n == 'SW1BRN') {
      ps = [
        [0, 0, 16],
        [8, 4, 17],
      ];
    } else if (n == 'SW2BRN') {
      ps = [
        [0, -4, 17],
      ];
    } else if (n.startsWith('BLODGR') || n.startsWith('SLADRIP') || n.startsWith('FIREWAL')) {
      ps = [
        [0, 0, 1 + r() % 11],
      ];
    } else if (n == 'HOLETEX') {
      // its second patch has no lump
      ps = [
        [0, 0, 2],
        [4, 0, 18],
        [8, 8, 3],
      ];
    } else if (n == 'LOWPTEX') {
      // its first patch is named in small letters
      ps = [
        [2, 2, 19],
        [0, 0, 4],
      ];
    } else {
      ps = [];
      final k = 1 + r() % 4;
      for (var i = 0; i < k; i++) {
        final a = (r() % (w + 8)) - 8, b = (r() % 25) - 8, c = r() % 12;
        ps.add([a, b, c]);
      }
      if (r() % 5 == 0) {
        ps = [
          [0, 0, r() % 12],
        ];
      }
    }
    final d = Uint8List(22 + 10 * ps.length);
    name8(d, 0, n);
    d.setAll(8, rnd(r, 4));
    w16(d, 12, w);
    w16(d, 14, h);
    d.setAll(16, rnd(r, 4));
    w16(d, 20, ps.length);
    for (var i = 0; i < ps.length; i++) {
      w16(d, 22 + 10 * i, ps[i][0]);
      w16(d, 24 + 10 * i, ps[i][1]);
      w16(d, 26 + 10 * i, ps[i][2]);
      w16(d, 28 + 10 * i, r() & 0xFFFF);
      w16(d, 30 + 10 * i, r() & 0xFFFF);
    }
    defs.add(d);
  }
  final head = Uint8List(4 + 4 * defs.length);
  w32(head, 0, defs.length);
  var p = head.length;
  for (var i = 0; i < defs.length; i++) {
    w32(head, 4 + 4 * i, p);
    p += defs[i].length;
  }
  return cat([head, ...defs]);
}

Uint8List pnames(List<String> names) {
  final b = Uint8List(4 + 8 * names.length);
  w32(b, 0, names.length);
  for (var i = 0; i < names.length; i++) {
    name8(b, 4 + 8 * i, names[i]);
  }
  return b;
}

const FLATS = ['FLOOR4_8', 'SFLR6_1', 'MFLR8_4', 'MFLR8_3', 'NUKAGE1', 'NUKAGE2', 'NUKAGE3', 'FWATER1', 'FWATER2', 'FWATER3', 'FWATER4', 'FLAT01', 'FLAT02', 'FLAT03', 'FLAT04', 'FLAT05', 'FLAT06'];
const D2FL = ['SLIME16', 'RROCK14', 'RROCK07', 'RROCK17', 'RROCK13', 'RROCK19', 'RROCK05', 'RROCK06', 'RROCK08'];
const SPR = ['TROO', 'BAL1', 'POSS', 'SPOS', 'SARG', 'BOSS', 'BAL7', 'HEAD', 'BAL2', 'SKUL', 'CYBR', 'SPID', 'PLAY', 'MISL'];

class BaseOpt {
  BaseOpt(this.seed, {this.eps = '', this.d2 = false, this.perEp = 1, this.tex2 = false, this.emptyVtx = false, this.mon = 0, this.small = false, this.dirFirst = false, this.narrow = false, this.tall = false});
  int seed, perEp, mon;
  String eps;
  bool d2, tex2, emptyVtx, small, dirFirst, narrow, tall;
}

Uint8List baseWad(BaseOpt o) {
  final r = rng(o.seed);
  final LL L = [];
  final FW = o.small ? 32 : 320, FH = o.small ? 20 : 200;
  L.add(('PLAYPAL', rnd(r, 768 * 2)));
  L.add(('COLORMAP', rnd(r, 256 * 3)));
  L.add(('ENDOOM', rnd(r, 200)));
  L.add(('DEMO1', rnd(r, 50)));
  L.add(('DEMO2', rnd(r, 50)));
  L.add(('DEMO3', rnd(r, 50)));
  final maps = <String>[];
  if (o.d2) {
    for (var m = 1; m <= o.perEp; m++) {
      maps.add('MAP${m.toString().padLeft(2, '0')}');
    }
  } else {
    for (final e in o.eps.split('')) {
      for (var m = 1; m <= o.perEp; m++) {
        maps.add('E${e}M$m');
      }
    }
  }
  final tex = [...TEX1, if (o.tex2) ...TEX2, 'NOSUCH'], fl = [...FLATS.sublist(4), if (o.d2) ...D2FL.sublist(6)];
  for (var i = 0; i < maps.length; i++) {
    L.addAll(mapLumps(r, maps[i], tex, fl, mon: o.mon, emptyVtx: o.emptyVtx && i == 1));
  }
  L.add(('TEXTURE1', texLump(r, TEX1)));
  if (o.tex2) L.add(('TEXTURE2', texLump(r, TEX2)));
  L.add(('PNAMES', pnames(PN)));
  L.add(('GENMIDI', rnd(r, 100)));
  L.add(('DMXGUS', rnd(r, 60)));
  for (final n in maps) {
    L.add(('D_$n', mus(r, 40 + r() % 60)));
  }
  for (final n in ['D_INTER', 'D_INTRO', 'D_VICTOR', 'D_INTROA', if (o.d2) ...['D_RUNNIN', 'D_STALKS']]) {
    L.add((n, mus(r, 30)));
  }
  for (final n in const ['DSPISTOL', 'DSSHOTGN', 'DPPISTOL', 'DPSHOTGN']) {
    L.add((n, rnd(r, 40 + r() % 40)));
  }
  // pictures: all in the patch format from here to P_END
  Uint8List full([bool holes = false]) => patch(r, FW, FH, holes);
  if (o.d2) {
    L.add(('HELP', full()));
    L.add(('BOSSBACK', full()));
  } else {
    L.add(('HELP1', full()));
    L.add(('HELP2', full()));
  }
  L.add(('TITLEPIC', full()));
  L.add(('CREDIT', full(true)));
  L.add(('VICTORY2', full()));
  L.add(('PFUB1', full()));
  L.add(('PFUB2', patch(r, 160, 100)));
  L.add(('ENDPIC', full()));
  L.add(('INTERPIC', full()));
  L.add(('END0', full()));
  for (var i = 1; i <= 6; i++) {
    L.add(('END$i', patch(r, 24, 16, true)));
  }
  for (var i = 0; i < 3; i++) {
    L.add(('WIMAP$i', full()));
  }
  L.add(('AMMNUM0', patch(r, 4, 6, true)));
  L.add(('STBAR', patch(r, 320, 32)));
  L.add(('STARMS', patch(r, 40, 32, true)));
  for (var i = 0; i < 10; i++) {
    final a = r() % 3, b = r() % 3;
    L.add(('STTNUM$i', patch(r, o.narrow ? 10 : 14, 16, true, a, b)));
  }
  L.add(('STTPRCNT', patch(r, o.narrow ? 10 : 14, o.tall ? 30 : 16, true)));
  for (var c = 65; c <= 90; c++) {
    final a = 5 + r() % 5, b = 7 + r() % 2;
    L.add(('STCFN0$c', patch(r, a, b, true)));
  }
  L.add(('M_DOOM', patch(r, 30, 12, true)));
  L.add(('M_NEWG', patch(r, 20, 8, true)));
  L.add(('S_START', Z));
  for (final s in SPR) {
    for (final fr in const ['A1', 'B1']) {
      final a = 8 + r() % 17, b = 8 + r() % 25, c = r() % 9, d = r() % 9;
      L.add(('$s$fr', patch(r, a, b, true, c, d)));
    }
  }
  L.addAll([('S_END', Z), ('P_START', Z), ('P1_START', Z)]);
  for (var i = 0; i < 18; i++) {
    if (PN[i].startsWith('SKY')) {
      L.add((PN[i], patch(r, 32, 32)));
    } else {
      final a = 8 + r() % 25, b = 16 + r() % 49;
      L.add((PN[i], patch(r, a, b, i % 3 == 1)));
    }
  }
  L.addAll([('P1_END', Z), ('P_END', Z), ('F_START', Z), ('F1_START', Z)]);
  for (final n in [...FLATS, if (o.d2) ...D2FL]) {
    L.add((n, rnd(r, 4096)));
  }
  L.addAll([('F1_END', Z), ('F_END', Z)]);
  return wad(L, 'IWAD', o.dirFirst);
}

/* extra WADs. kind 'maps': maps that replace or add (names), 'e5': an episode with UMAPINFO, 'e6': one without */
const UMAP = '// made for the check\r\nMAP E5M1\r\n{\r\n\tlevelname = "Baphomet\'s Demesne"\r\n\tlabel = "E5M1"\r\n\tlevelpic = "MYLV0"\r\n\tnext = "E5M2"\r\n\tskytexture = "SKY5X"\r\n\tmusic = "D_E5M1"\r\n'
    '\texitpic = "SIGILINT" // the picture between maps\r\n\tepisode = "M_EPI5", "Sigßil é", "s"\r\n\tpartime = 90\r\n}\r\n'
    'map e5m2 { LevelName = "Sheol é\u0080\u009E"\n music = "D_SIGMUS"\n endpic = "SIGILEND"\n intertext = "line one", "line ütwoß", "µ three"\n nointermission = true\n }\n'
    'MAP E5M9 { levelname = "Realm of Iblis" next = "E5M7" music = D_NOQUOTE \n secret = }\n map 12 { levelname = "Twelve" }\n map 7 { levelname = "Seven"\n episode = clear }\n';

class PwOpt {
  const PwOpt(this.kind, this.seed, this.maps, {this.big = false, this.both = false, this.dirFirst = false});
  final String kind;
  final int seed;
  final List<Object> maps;
  final bool big, both, dirFirst;
}

Uint8List pwad(PwOpt o) {
  final r = rng(o.seed), e = o.kind == 'e5' ? '5' : '6';
  final LL L = [];
  final tex = [...TEX1, 'SKY5X', 'SKY6'], fl = [...FLATS.sublist(4), 'NEWFLAT'];
  void mp(String n, {bool behavior = false, bool bigThings = false}) => L.addAll(mapLumps(r, n, tex, fl, mon: 1, behavior: behavior, bigThings: bigThings));
  if (o.kind == 'maps') {
    L.add(('DEHACKED', rnd(r, 30)));
    L.add(('TITLEPIC', patch(r, 320, 200)));
    for (var i = 0; i < o.maps.length; i++) {
      mp(o.maps[i] as String, behavior: i == 0, bigThings: o.big && i == 1);
    }
    L.add(('D_E1M2', mus(r, 20)));
    L.add(('THING_ZD', rnd(r, 9)));
    L.add(('M_DOOM', patch(r, 31, 13, true)));
    L.add(('NEWLUMP', rnd(r, 77)));
    L.add(('PLAYPAL', rnd(r, 768)));
  } else {
    if (o.kind == 'e5') L.add(('UMAPINFO', asc(UMAP)));
    for (final m in o.maps) {
      mp('E${e}M$m');
    }
    if (o.both) mp('E6M1');
    if (o.kind == 'e5') {
      L.add(('MYLV0', patch(r, 40, 10, true)));
      L.add(('WILV41', patch(r, 41, 10, true)));
      L.add(('WILV48', patch(r, 48, 10, true)));
      L.add(('D_E5M1', midi(0x900 + o.seed)));
      L.add(('D_SIGMUS', mus(r, 50)));
      L.add(('D_E5M9', midi(0x901, div: 0xE728)));
      L.add(('SIGILINT', patch(r, 320, 200)));
      L.add(('SIGILEND', patch(r, 320, 200)));
      L.add(('SIGILTTL', patch(r, 320, 200)));
      L.add(('SMALLPIC', patch(r, 64, 20)));
    } else {
      L.add(('WILV50', patch(r, 50, 10, true)));
      L.add(('WILV52', patch(r, 52, 10, true)));
      L.add(('D_E6M1', mus(r, 44)));
      L.add(('D_E6M3', midi(0x902)));
      L.add(('D_E6M4', asc('junk')));
      L.add(('E6TEXT', asc('You made it\r\nthrough éßµÿ\u009C\r\nthe end.')));
    }
    L.add(('M_EPI$e', patch(r, 60, 12, true)));
    L.add(('CREDIT', patch(r, 320, 200)));
    L.add(('TEXTURE1', texLump(r, TEX1, const ['SKY5X', 'SKY6'])));
    L.add(('PNAMES', pnames(PN)));
    L.add(('E${e}TEXTX', rnd(r, 5)));
  }
  L.add(('FF_START', Z));
  L.add(('FLAT02', rnd(r, 4096)));
  L.add(('NEWFLAT', rnd(r, 4096)));
  L.add(('FF_END', Z));
  L.add(('AFTERF', rnd(r, 11)));
  L.add(('SS_START', Z));
  L.add(('TROOA1', patch(r, 12, 12, true)));
  L.add(('NEWSA0', patch(r, 9, 9, true)));
  L.add(('S_END', Z));
  L.add(('PP_START', Z));
  L.add(('NEWPAT', patch(r, 16, 16)));
  L.add(('PP_END', Z));
  return wad(L, 'PWAD', o.dirFirst);
}

/* a MIDI file. div, cut (bytes dropped at the end), notes (a long first track), ntrMore, noEnd */
List<int> vlq(int v) {
  final b = <int>[v & 127];
  v >>= 7;
  while (v != 0) {
    b.insert(0, 0x80 | (v & 127));
    v >>= 7;
  }
  return b;
}

Uint8List midi(int seed, {int? div, int cut = 0, int notes = 0, int ntrMore = 0, bool noEnd = false}) {
  final r = rng(seed), ntr = notes != 0 ? 1 : 1 + r() % 4, dv = div ?? const [96, 480, 120, 1024][r() % 4], parts = <Uint8List>[];
  const CT = [0, 1, 7, 10, 11, 91, 93, 64, 67, 120, 123, 126, 127, 121, 5, 99];
  final head = Uint8List(14);
  head.setAll(0, asc('MThd'));
  w32(head, 4, 0x06000000);
  head[9] = 1;
  head[10] = (ntr + ntrMore) >> 8;
  head[11] = (ntr + ntrMore) & 255;
  head[12] = dv >> 8;
  head[13] = dv & 255;
  parts.add(head);
  for (var t = 0; t < ntr; t++) {
    final ev = <int>[];
    final n = notes != 0 ? notes : 20 + r() % 60;
    final c0 = r() % 16, c1 = r() % 16, c2 = r() % 16;
    final chans = [c0, c1, c2, 9, (t * 5 + 1) % 16, (t * 5 + 2) % 16, (t * 5 + 3) % 16, (t * 5 + 4) % 16];
    var run = -1;
    for (var i = 0; i < n; i++) {
      ev.addAll(vlq(r() % 4 == 0 ? r() % 3000 : r() % 60));
      final ty = notes != 0 ? r() % 8 : r() % 16, ch = chans[r() % chans.length];
      void st(int s) {
        if (s != run || r() % 2 != 0) ev.add(s);
        run = s;
      }

      if (ty < 6) {
        st(0x90 | ch);
        ev.add(r() & 127);
        ev.add(r() % 5 == 0 ? 0 : r() & 127);
      } else if (ty < 8) {
        st(0x80 | ch);
        ev.add(r() & 127);
        ev.add(r() & 127);
      } else if (ty == 8) {
        st(0xC0 | ch);
        ev.add(r() & 127);
      } else if (ty == 9) {
        st(0xB0 | ch);
        ev.add(CT[r() % CT.length]);
        ev.add(r() & 127);
      } else if (ty == 10) {
        st(0xE0 | ch);
        ev.add(r() & 127);
        ev.add(r() & 127);
      } else if (ty == 11) {
        st(0xD0 | ch);
        ev.add(r() & 127);
      } else if (ty == 12) {
        st(0xA0 | ch);
        ev.add(r() & 127);
        ev.add(r() & 127);
      } else if (ty == 13) {
        final us = 200000 + r() % 600000;
        ev.addAll([0xFF, 0x51, 3, us >> 16, (us >> 8) & 255, us & 255]);
      } else if (ty == 14) {
        final k = r() % 9;
        ev.addAll([0xFF, 1 + r() % 5, k]);
        for (var q = 0; q < k; q++) {
          ev.add(0x41 + r() % 26);
        }
      } else {
        final k = 1 + r() % 6;
        ev.addAll([0xF0, k]);
        for (var q = 0; q < k - 1; q++) {
          ev.add(r() & 127);
        }
        ev.add(0xF7);
      }
    }
    if (!noEnd) ev.addAll([0, 0xFF, 0x2F, 0]);
    final th = Uint8List(8);
    th.setAll(0, asc('MTrk'));
    th[4] = ev.length >> 24;
    th[5] = (ev.length >> 16) & 255;
    th[6] = (ev.length >> 8) & 255;
    th[7] = ev.length & 255;
    parts.add(th);
    parts.add(Uint8List.fromList(ev));
  }
  final all = cat(parts);
  return cut != 0 ? sub(all, 0, all.length - cut) : all;
}

// ------------------------------------------------------------ the cases
