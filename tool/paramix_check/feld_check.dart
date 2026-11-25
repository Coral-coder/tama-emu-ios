// Check of lib/paramix/feld.dart against third_party/paramix-studio/src/feld.js.
// DUMPS=<folder with water.bin, land.bin, ...> dart run tool/paramix_check/feld_check.dart
// Prints one line per case: "<case name> <sha256 or value>". Same cases as feld.js in this folder.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tama_tools/paramix/bytes.dart' show w16, w32, u32;
import 'package:tama_tools/paramix/feld.dart';

final String src = '${File.fromUri(Platform.script).parent.parent.parent.path}/third_party/paramix-studio';
Uint8List bin(String f) => File('$src/$f').readAsBytesSync();
// the embedded binaries
final Uint8List feldBin = bin('feld/feld.bin'), stubBin = bin('feld/stub_feld_tpl.bin'), feldcBin = bin('feld/feldc.bin'), emuStub = bin('emu/stub_tpl.bin');
final Uint8List feldSBin = bin('feld/feld_s.bin'), feldcSBin = bin('feld/feldc_s.bin');
final FeldEmbedded emb = FeldEmbedded(stub: stubBin, feld: feldBin, feldS: feldSBin);
final FeldEmbedded embStrip = FeldEmbedded(stub: stubBin, oldStub: emuStub), embStrip0 = FeldEmbedded(stub: stubBin);
const FeldEmu emu = FeldEmuPort();
const List<String> eds = ['water', 'land', 'sky', 'jade', 'tropical', 'glacier', 'neon'];

// ---------------------------------------------------------------- SHA-256
final Uint32List _k = Uint32List.fromList([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, //
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);
String sha(Uint8List d) {
  final n = d.length, total = ((n + 9 + 63) ~/ 64) * 64;
  final tail = Uint8List(total - (n ~/ 64) * 64);
  tail.setRange(0, n % 64, d, (n ~/ 64) * 64);
  tail[n % 64] = 0x80;
  ByteData.sublistView(tail).setUint64(tail.length - 8, n * 8);
  var h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a, h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;
  final w = Uint32List(64);
  void block(Uint8List b, int o) {
    for (var i = 0; i < 16; i++) {
      w[i] = (b[o + 4 * i] << 24) | (b[o + 4 * i + 1] << 16) | (b[o + 4 * i + 2] << 8) | b[o + 4 * i + 3];
    }
    for (var i = 16; i < 64; i++) {
      final x = w[i - 15], y = w[i - 2];
      final s0 = ((x >> 7) | (x << 25)) ^ ((x >> 18) | (x << 14)) ^ (x >> 3);
      final s1 = ((y >> 17) | (y << 15)) ^ ((y >> 19) | (y << 13)) ^ (y >> 10);
      w[i] = w[i - 16] + (s0 & 0xFFFFFFFF) + w[i - 7] + (s1 & 0xFFFFFFFF);
    }
    var a = h0, bb = h1, c = h2, dd = h3, e = h4, f = h5, g = h6, h = h7;
    for (var i = 0; i < 64; i++) {
      final s1 = (((e >> 6) | (e << 26)) ^ ((e >> 11) | (e << 21)) ^ ((e >> 25) | (e << 7))) & 0xFFFFFFFF;
      final t1 = (h + s1 + ((e & f) ^ (~e & 0xFFFFFFFF & g)) + _k[i] + w[i]) & 0xFFFFFFFF;
      final s0 = (((a >> 2) | (a << 30)) ^ ((a >> 13) | (a << 19)) ^ ((a >> 22) | (a << 10))) & 0xFFFFFFFF;
      final t2 = (s0 + ((a & bb) ^ (a & c) ^ (bb & c))) & 0xFFFFFFFF;
      h = g;
      g = f;
      f = e;
      e = (dd + t1) & 0xFFFFFFFF;
      dd = c;
      c = bb;
      bb = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }
    h0 = (h0 + a) & 0xFFFFFFFF;
    h1 = (h1 + bb) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF;
    h3 = (h3 + dd) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF;
    h5 = (h5 + f) & 0xFFFFFFFF;
    h6 = (h6 + g) & 0xFFFFFFFF;
    h7 = (h7 + h) & 0xFFFFFFFF;
  }

  for (var o = 0; o + 64 <= n; o += 64) {
    block(d, o);
  }
  for (var o = 0; o < tail.length; o += 64) {
    block(tail, o);
  }
  return [h0, h1, h2, h3, h4, h5, h6, h7].map((v) => v.toRadixString(16).padLeft(8, '0')).join();
}

String shaS(String s) => sha(latin1.encode(s));
String hex(int v) => '0x${(v & 0xFFFFFFFF).toRadixString(16)}';
bool eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List copy(Uint8List b) => Uint8List.fromList(b);
Uint8List cut(Uint8List b, int a, int e) => Uint8List.fromList(Uint8List.sublistView(b, a, e));
Uint8List view(Uint8List b, int a, int e) => Uint8List.sublistView(b, a, e);

int count = 0;
void p(String name, Object? v) {
  count++;
  print('$name $v');
}

String err(Object e) => e is StateError
    ? 'ERR ${e.message}'
    : e is FormatException
        ? 'ERR ${e.message}'
        : 'ERR ?${e.runtimeType} $e';

/// Run fn; on an error print it under `name` and return null.
T? t<T>(String name, T Function() fn) {
  try {
    return fn();
  } catch (e) {
    p(name, err(e));
    return null;
  }
}

String fmtF(FeldInfo? f) => f != null ? [f.off, f.stubOff, f.version, f.slotOff, f.slotSize, f.nslots, f.flags, f.catOff, f.catN, f.slotOff2, f.slotN1].map(hex).join(' ') : 'null';
String opt(Object? v) => v == null
    ? '-'
    : v is int
        ? hex(v)
        : '$v';
String pagesStr(Map<int, Uint8List> pages) {
  final b = BytesBuilder();
  pages.forEach((a, d) {
    b.add(ascii.encode(hex(a)));
    b.add(d);
  });
  return '${pages.length} ${sha(b.toBytes())}';
}

String charsStr(Uint8List rom) {
  final c = characters(rom);
  return '${c.length} ${shaS(c.map((x) => [x.id, x.stage, x.field, x.name].join(',')).join('\n'))}';
}

void info(String tag, Uint8List rom) {
  t('$tag.info', () {
    final e = edition(rom), id = feldId(rom);
    p('$tag.edition', e != null ? '${e.profile.name} ${e.id} ${hex(e.at)}' : 'null');
    p('$tag.ids', [id, canFields(rom), fieldNames(rom).join(','), fieldNow(rom), familyOf(id) ?? '', isSix(rom), appKind(rom), "'${emuType(rom)}'", isClean(rom), isLaunch(rom, stubBin)].join(' '));
    final ci = cleanInfo(rom);
    p('$tag.cleanInfo', ci != null ? '${hex(ci.feld)} ${hex(ci.clock)}' : 'null');
    p('$tag.feldFind', fmtF(feldFind(rom, stubBin)));
    final a = feldApps(rom, stubBin);
    p('$tag.feldApps', '${shaS('${a.name0}|${a.apps.map((x) => '${hex(x.src)}:${x.name}').join(';')}')} ${a.apps.length} ${[a.v9, opt(a.mainSrc), opt(a.auto), opt(a.noClock), opt(a.dl)].join(' ')}');
    final ss = saveSlots(rom, stubBin);
    p('$tag.saveSlots', ss != null ? '${ss.saves} ${ss.live} ${ss.list.map((x) => x.used ? 1 : 0).join()}' : 'null');
    p('$tag.fieldOfSettings', '${fieldOfSettings(rom, view(rom, 0xEFE000, 0xEFF000))} ${fieldOfSettings(rom, view(rom, 0xEFF000, 0xF00000))} ${fieldOfSettings(rom, null)}');
    final sl = feldSlots(rom, stubBin);
    p('$tag.feldSlots', sl.length);
    for (var k = 0; k < sl.length; k++) {
      final s = sl[k];
      p('$tag.slot$k', [s.index, s.field, s.bytes, s.pool, s.list.length, hex(s.b), sha(s.head), sha(s.stream)].join(' '));
      t('$tag.slot$k.pages', () => p('$tag.slot$k.pages', pagesStr(slotPages(s))));
    }
  });
}

void heavy(String tag, Uint8List rom) {
  t('$tag.itemCatalog', () {
    final c = itemCatalog(rom);
    p('$tag.itemCatalog',
        '${c.items.length} ${c.pack} ${shaS(c.items.map((x) => [x.id, x.fixed, x.pic, x.sum, x.at != null ? [x.at!.addr, x.at!.len, x.at!.sum, x.at!.head].join('/') : '-', x.text, x.name].join(',')).join('\n'))}');
  });
  t('$tag.characters', () => p('$tag.characters', charsStr(rom)));
  t('$tag.textTabelle', () {
    final tt = textTabelle(rom);
    p('$tag.textTabelle', tt < 0 ? '0xffffffff' : hex(tt));
    if (tt >= 0) {
      final l = [for (var n = 0; n < 400; n++) zeichenkette(rom, tt, n)];
      p('$tag.zeichenkette', '${shaS(l.join('\n'))} ${shaS(fieldText.map((n) => zeichenkette(rom, tt, n)).join('\n'))}');
    }
  });
}

const List<FeldApp> apps2 = [FeldApp(0x10200000, 'DOOM'), FeldApp(0x10300000, 'A VERY LONG NAME')];
List<FeldApp> appsN(int n) => [for (var i = 0; i < n; i++) FeldApp(0x10200000 + 0x10000 * i, 'PROG $i')];
final List<(String, FeldOpts)> combos = [
  ('fields', const FeldOpts(fields: true)),
  ('fieldsNoSaves', const FeldOpts(fields: true, saves: false)),
  ('bag', const FeldOpts(bag: true)),
  ('tama', const FeldOpts(tama: true)),
  ('gplay', const FeldOpts(gplay: true)),
  ('all', const FeldOpts(fields: true, bag: true, tama: true, gplay: true, name0: 'TAMAEMU PLUS XYZ', apps: apps2, fieldNames: ['MEADOW HILLS LONG', 'WATER', ''])),
  ('low', const FeldOpts(fields: true, bag: true, appsLow: 0x900000)),
  ('lowErr', const FeldOpts(fields: true, appsLow: 0x840000)),
  ('launch', FeldOpts(launch: true, fields: true, bag: true, tama: true, apps: appsN(12), dl: 0x10400000, mainSrc: 0x10200000, auto: true)),
  ('launch0', const FeldOpts(launch: true)),
  ('none', const FeldOpts()),
  ('apps13', FeldOpts(bag: true, apps: appsN(13))),
];

Uint8List? applyCase(String tag, Uint8List base, FeldOpts opts, List<FeldSlot> saved, [Uint8List? stripBack]) {
  final r = t(tag, () => feldApply(base, opts, saved, emb, emu));
  if (r == null) return null;
  p(tag, sha(r));
  info(tag, r);
  final s = t('$tag.strip', () => feldStrip(r, embStrip, emu));
  if (s != null) {
    p('$tag.strip', sha(s));
    p('$tag.strip.same', eq(s, stripBack ?? base));
  }
  final s0 = t('$tag.strip0', () => feldStrip(r, embStrip0, emu));
  if (s0 != null) p('$tag.strip0', sha(s0));
  return r;
}

void lzCases(String tag, Uint8List rom) {
  final pages = <(String, Uint8List)>[];
  for (var o = 0; o < 0x1000000; o += 0x100000) {
    pages.add(('rom${hex(o)}', cut(rom, o, o + 0x1000)));
  }
  for (final o in [0x11000, 0x111000, 0x112000, 0x234000, 0xD49000, 0xEFE000, 0xEFF000]) {
    pages.add(('rom${hex(o)}', cut(rom, o, o + 0x1000)));
  }
  for (final (n, pg) in pages) {
    lzOne('$tag.lz.$n', pg);
  }
}

void lzOne(String tag, Uint8List pg) {
  final c = t(tag, () => lzPack(pg));
  if (c == null) return;
  p(tag, '${c.length} ${sha(c)}');
  t('$tag.back', () => p('$tag.back', eq(lzUnpack(c, c.length), pg)));
}

void lzSynthetic() {
  Uint8List mk(int Function(int) fn) {
    final pg = Uint8List(0x1000);
    for (var i = 0; i < 0x1000; i++) {
      pg[i] = fn(i) & 255;
    }
    return pg;
  }

  var x = 12345;
  int rnd() {
    x = (x * 1103515245 + 12345) & 0xFFFFFFFF;
    return x >> 16;
  }

  lzOne('lz.zero', mk((_) => 0));
  lzOne('lz.ff', mk((_) => 0xFF));
  lzOne('lz.random', mk((_) => rnd()));
  lzOne('lz.count', mk((i) => i));
  lzOne('lz.period7', mk((i) => i % 7));
  lzOne('lz.period300', mk((i) => (i % 300) * 7 + (i % 300 >> 3)));
  lzOne(
      'lz.mixed',
      mk((i) => i < 0x400
          ? rnd()
          : i < 0x800
              ? 0x55
              : i < 0xC00
                  ? (i * 3) >> 2
                  : rnd() & 3));
  lzOne('lz.tail', mk((i) => i < 0xFFE ? 9 : i));
  final c = lzPack(mk((i) => i % 7));
  void bad(String n, Uint8List inp, int len) {
    try {
      p('lz.bad.$n', sha(lzUnpack(inp, len)));
    } catch (e) {
      p('lz.bad.$n', err(e));
    }
  }

  bad('short', c, c.length - 1);
  bad('long', Uint8List(c.length + 1)..setRange(0, c.length, c), c.length + 1);
  bad('empty', Uint8List(0), 0);
  bad('ref0', Uint8List.fromList([0xFF, 0x00, 0x00]), 3);
  bad('lit', Uint8List.fromList([0x00, 1, 2, 3]), 4);
  final d = copy(c);
  d[1] ^= 0x5A;
  d[2] = 0xFF;
  d[3] = 0xFF;
  bad('garbage', d, d.length);
}

void clockCases() {
  int crc(Uint8List pg) {
    var c = 0;
    for (var i = 4; i < pg.length; i++) {
      c ^= pg[i];
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (c >> 1) ^ 0xA001 : c >> 1;
      }
    }
    return c;
  }

  final pg = Uint8List(4096);
  for (var i = 32; i < 4096; i++) {
    pg[i] = (i * 31) >> 4;
  }
  w32(pg, 12, 300);
  w32(pg, 16, 40000);
  final c = crc(pg);
  w16(pg, 0, c);
  w16(pg, 2, ~c);
  FeldSlot mk() => slotBuild({0xEFE000: copy(pg), 0xEFF000: copy(pg), 0xEFD000: copy(pg)}, 0, 0xEFD000, 0xF00000);
  void stamp(FeldSlot s, int from, int to) {
    w32(s.head, 4080, 0x43544D50);
    w32(s.head, 4084, from);
    w32(s.head, 4088, to);
    w32(s.head, 4092, 0x43544D50 ^ from ^ to);
  }

  FeldSlot run(String n, int from, int to, [void Function(FeldSlot)? breakIt]) {
    final s = mk();
    stamp(s, from, to);
    if (breakIt != null) breakIt(s);
    p('clock.$n.head', '${sha(s.head)} ${s.bytes} ${sha(s.stream)}');
    try {
      p('clock.$n', pagesStr(slotPages(s)));
    } catch (e) {
      p('clock.$n', err(e));
    }
    return s;
  }

  final s = run('rebase', 100, 1000);
  run('forward', 90000, 5);
  run('underflow', 0, 0xF0000000);
  run('sum', 100, 1000, (x) => x.head[4092] ^= 1);
  run('stream', 100, 1000, (x) => x.stream[5] ^= 1);
  final out = Uint8List(0x10000), f = FeldInfo(slotOff: 0x1000, slotSize: 0x4000, nslots: 3), used = <int>{};
  p('clock.place', '${slotPlace(out, f, 2, s, used).map(hex).join(',')} ${used.join(',')} ${sha(out)}');
  final back = slotParse(f, 2, view(out, 0x9000, 0xA000));
  p('clock.parse', back != null ? [back.field, back.bytes, back.pool, back.list.map(hex).join(','), hex(back.b)].join(' ') : 'null');
  p('clock.poolAddr', '${[0, 1, 2, 3, 5, 8].map((k) => hex(poolAddr(f, k))).join(',')} ${[0, 1, 2].map((i) => hex(slotAddr(f, i))).join(',')}');
  try {
    slotPlace(out, f, 0, FeldSlot(head: s.head, field: 1, bytes: 0x9000 + 1, stream: Uint8List(0x9001)), used);
    p('clock.full', 'placed');
  } catch (e) {
    p('clock.full', err(e));
  }
}

Future<void> slotCases(String tag, Uint8List base, Edition ed) async {
  final a = t('$tag.slots.apply', () => feldApply(base, const FeldOpts(fields: true, bag: true), [], emb, emu));
  if (a == null) return;
  final f = feldFind(a, stubBin);
  if (f == null || f.nslots < 2) {
    p('$tag.slots', 'noslots');
    return;
  }
  final all = <int, Uint8List>{}, two = <int, Uint8List>{};
  for (var o = 0xD00000; o < 0xF00000; o += 0x1000) {
    all[o] = cut(base, o, o + 0x1000);
  }
  for (final o in [0xEFF000, 0xEFE000]) {
    two[o] = cut(base, o, o + 0x1000);
  }
  final from = ed.at + 0x1000;
  final s0 = slotBuild(all, 0, from, 0xF00000), s1 = slotBuild(two, 1, 0xEFE000, 0xF00000);
  for (var k = 0; k < 2; k++) {
    final s = k == 0 ? s0 : s1;
    p('$tag.slots.build$k', [s.field, s.bytes, u32(s.head, 8), sha(s.head), sha(s.stream)].join(' '));
    t('$tag.slots.build$k.pages', () {
      final pg = slotPages(s);
      var same = true;
      pg.forEach((x, d) {
        if (!eq(d, (k != 0 ? two : all)[x]!)) same = false;
      });
      p('$tag.slots.build$k.pages', '${pagesStr(pg)} $same');
    });
  }
  final a2 = copy(a), used = <int>{};
  final w0 = t('$tag.slots.place0', () => slotPlace(a2, f, 0, s0, used));
  if (w0 != null) p('$tag.slots.place0', '${w0.length} ${shaS(w0.map(hex).join(','))} ${used.length}');
  final w1 = t('$tag.slots.place1', () => slotPlace(a2, f, 1, s1, used));
  if (w1 != null) p('$tag.slots.place1', '${w1.map(hex).join(',')} ${used.length}');
  // an old slot (before 1.2.12): the packed data right behind the header
  if (f.nslots > 2) {
    final b = slotAddr(f, 2), h = copy(s1.head);
    w32(h, 4, 3);
    a2.setRange(b, b + h.length, h);
    a2.setRange(b + 0x1000, b + 0x1000 + s1.stream.length, s1.stream);
  }
  p('$tag.slots.image', sha(a2));
  info('$tag.slots', a2);
  final heads = <Uint8List?>[for (var i = 0; i < f.nslots; i++) i == 1 && f.nslots > 3 ? null : view(a2, slotAddr(f, i), slotAddr(f, i) + 0x1000)];
  for (final skip in [-1, 0, 2]) {
    final l = (poolUsed(f, heads, skip).toList()..sort()).join(',');
    p('$tag.slots.poolUsed$skip', '${l.length} ${shaS(l)}');
  }
  for (var i = 0; i < f.nslots; i++) {
    final q = slotParse(f, i, view(a2, slotAddr(f, i), slotAddr(f, i) + 0x1000));
    p('$tag.slots.parse$i', q != null ? [q.field, q.bytes, q.pool, q.list.length, hex(q.b)].join(' ') : 'null');
    final r = await slotReadAsync((addr, len) async => cut(a2, addr, addr + len), f, i);
    p('$tag.slots.async$i', r != null ? '${r.bytes} ${sha(r.stream)}' : 'null');
  }
  final saved = feldSlots(a2, stubBin);
  final st = t('$tag.slots.strip', () => feldStrip(a2, embStrip, emu));
  if (st == null) return;
  p('$tag.slots.strip', '${sha(st)} ${eq(st, base)}');
  applyCase('$tag.slots.reapply', st, const FeldOpts(fields: true, bag: true, tama: true), saved, base);
  applyCase('$tag.slots.reapplyLow', st, const FeldOpts(fields: true, appsLow: 0x900000), saved, base);
  // a save that is too big for the room
  final big = FeldSlot(head: s0.head, field: 1, bytes: f.nslots * f.slotSize, stream: Uint8List(f.nslots * f.slotSize), index: 1);
  applyCase('$tag.slots.reapplyBig', st, const FeldOpts(fields: true), [big], base);
  FeldSlot at(int index) => FeldSlot(head: s1.head, field: s1.field, bytes: s1.bytes, stream: s1.stream, index: index);
  applyCase('$tag.slots.reapplyOut', st, const FeldOpts(fields: true), [at(9), at(-1)], base);
}

void sixCases(String tag, Uint8List base) {
  for (final (n, ver, fl) in [('six7', 7, 4), ('six6', 6, 0)]) {
    final s = copy(base);
    s.fillRange(0x10F000, 0x110000, 0xFF);
    w32(s, 0x10F000, 0x31584953);
    w32(s, 0x10F004, ver);
    w32(s, 0x10F020, fl);
    s[0xEFE000 + 0xF04] = 1;
    info('$tag.$n', s);
    t('$tag.$n.characters', () => p('$tag.$n.characters', charsStr(s)));
    final r = applyCase('$tag.$n.apply', s, const FeldOpts(fields: true, bag: true, tama: true, fieldNames: ['A', 'B', 'C', 'D', 'E LONG NAME HERE', 'F']), []);
    if (r != null && n == 'six7') {
      final f = feldFind(r, stubBin)!, two = {0xEFE000: cut(s, 0xEFE000, 0xEFF000), 0xEFF000: cut(s, 0xEFF000, 0xF00000)}, r2 = copy(r), used = <int>{};
      for (var i = 0; i < f.nslots; i++) {
        t('$tag.six7.place$i', () => p('$tag.six7.place$i', slotPlace(r2, f, i, slotBuild(two, i, 0xEFE000, 0xF00000), used).map(hex).join(',')));
      }
      info('$tag.six7.placed', r2);
      final saved = feldSlots(r2, stubBin), st = t('$tag.six7.strip', () => feldStrip(r2, embStrip, emu));
      if (st != null) {
        p('$tag.six7.strip', '${sha(st)} ${eq(st, s)}');
        applyCase('$tag.six7.reapply', st, const FeldOpts(fields: true), saved, s);
      }
    }
  }
}

void appCases(String tag, Uint8List base) {
  const pmxc = 0x43584D50, pdmc = 0x434D4450;
  Uint8List mkApp(int magic, [void Function(Uint8List)? fn]) {
    final a = Uint8List(0x800);
    for (var i = 0; i < a.length; i++) {
      a[i] = (i * 7) & 0x7F;
    }
    w32(a, 0x140, magic);
    for (var i = 0x144; i < 0x400; i += 4) {
      w32(a, i, 0);
    }
    if (fn != null) fn(a);
    return a;
  }

  final apps = <(String, Uint8List, void Function(Uint8List)?)>[
    ('tama', mkApp(pmxc, (a) => w32(a, 0x148, 0x900000)), null),
    ('tamaBig', mkApp(pmxc, (a) => w32(a, 0x148, 0x840000)), null),
    ('doom', mkApp(pmxc, (a) => w32(a, 0x150, pdmc)), (r) => r.fillRange(0xB1000, 0xD0000, 0)),
    ('doomFull', mkApp(pmxc, (a) => w32(a, 0x150, pdmc)), (r) => r.fillRange(0xB1000, 0x10E000 - 0x9000, 0)),
    (
      't18',
      mkApp(0x38584D50, (a) {
        a.fillRange(0x140 + 16, 0x140 + 400, 0xFF);
        w32(a, 0x140 + 12, 2);
        w16(a, 0x140 + 16, 0xC0);
        w16(a, 0x140 + 20, 0xF8);
        w16(a, 0x140 + 272, 0xB8);
        w32(a, 0x140 + 400, 0);
      }),
      null
    ),
    (
      't18none',
      mkApp(0x38584D50, (a) {
        a.fillRange(0x140 + 16, 0x140 + 400, 0xFF);
        w32(a, 0x140 + 12, 0);
        w32(a, 0x140 + 400, 0);
      }),
      null
    ),
    ('t7', mkApp(0x37584D50), null),
    ('v1', mkApp(0x31584D50), null),
  ];
  for (final (n, app, after) in apps) {
    // raw: only the program at 0x0A0000 (the kind is read from it), installed: through installApp of emu.js
    final raw = copy(base);
    raw.setRange(0xA0000, 0xA0000 + app.length, app);
    p('$tag.$n.raw', [appKind(raw), "'${emuType(raw)}'", hex(emu.t18Low(raw))].join(' '));
    applyCase('$tag.$n.raw.apply', raw, const FeldOpts(fields: true, bag: true), []);
    final inst = t('$tag.$n.inst', () => emu.installApp(base, app, emuStub));
    if (inst == null) continue;
    if (after != null) after(inst);
    p('$tag.$n.inst', sha(inst));
    info('$tag.$n.inst', inst);
    applyCase('$tag.$n.inst.all', inst, const FeldOpts(fields: true, bag: true, tama: true, name0: 'MAIN', apps: apps2), []);
    applyCase('$tag.$n.inst.gplay', inst, const FeldOpts(gplay: true), []);
    applyCase('$tag.$n.inst.launch', inst, const FeldOpts(launch: true, apps: apps2, dl: 0x10400000), []);
  }
}

void cleanCases(String tag, Uint8List rom, Uint8List base) {
  p('$tag.cleanReserved', cleanReserved().map((x) => x.map(hex).join('-')).join(','));
  final cb = t('$tag.cleanBase', () => cleanBase(rom));
  if (cb == null) return;
  p('$tag.cleanBase', sha(cb));
  info('$tag.cleanBase', cb);
  // the JS passes { feld: fe.feldc, stub }; the small menu comes from feldc_s.bin
  final ce = FeldEmbedded(stub: stubBin, feldc: feldcBin, feldcS: feldcSBin).forClean();
  Uint8List? one(String n, Uint8List src, FeldOpts opts, [FeldEmbedded? e]) {
    final r = t('$tag.clean.$n', () => cleanApply(src, opts, e ?? ce));
    if (r == null) return null;
    p('$tag.clean.$n', sha(r));
    info('$tag.clean.$n', r);
    return r;
  }

  final c = one('apps', cb, FeldOpts(apps: appsN(12), dl: 0x10400000, mainSrc: 0x10210000, auto: true, noClock: true));
  one('plain', cb, const FeldOpts());
  one('app', cb, const FeldOpts(app: 0x10200001, name0: 'TAMAEMU PLUS XYZ', apps: apps2, auto: true));
  one('name0NoApp', cb, const FeldOpts(name0: 'IGNORED', noClock: true));
  one('spot', cb, const FeldOpts(apps: apps2, spot: CleanInfo(0xC8000, 0xD8000)));
  one('apps13', cb, FeldOpts(apps: appsN(13)));
  one('paradise', base, const FeldOpts(apps: apps2));
  one('oldMenu', cb, const FeldOpts(), FeldEmbedded(stub: stubBin, feld: feldBin, feldcS: feldcSBin));
  final big = Uint8List(0xE000 + 4)..setRange(0, feldcBin.length, feldcBin);
  one('small', cb, const FeldOpts(apps: apps2), FeldEmbedded(stub: stubBin, feld: big, feldcS: feldcSBin));
  one('noTable', copy(cb)..[0] = 0x58, const FeldOpts());
  one('noEdition', copy(cb)..fillRange(0xEFD000, 0xEFE000, 0xFF), const FeldOpts());
  t('$tag.cleanBase.none', () => p('$tag.cleanBase.none', sha(cleanBase(Uint8List(0x1000000)))));
  if (c != null) {
    final fa = feldApps(c, stubBin);
    final again = one('again', c, FeldOpts(apps: fa.apps, dl: fa.dl ?? 0, mainSrc: fa.mainSrc ?? 0, auto: fa.auto ?? false, noClock: fa.noClock ?? false, spot: cleanInfo(c)));
    if (again != null) p('$tag.clean.again.same', eq(again, c));
    t('$tag.clean.strip', () => p('$tag.clean.strip', sha(feldStrip(c, embStrip, emu))));
    t('$tag.clean.feldApply', () => p('$tag.clean.feldApply', sha(feldApply(c, const FeldOpts(bag: true), [], emb, emu))));
  }
}

Future<void> main() async {
  final dumps = Platform.environment['DUMPS'] ?? '';
  lzSynthetic();
  clockCases();
  for (final name in eds) {
    final file = File('$dumps/$name.bin');
    if (!file.existsSync()) {
      p(name, 'missing');
      continue;
    }
    final rom = file.readAsBytesSync();
    p('$name.size', rom.length);
    info('$name.orig', rom);
    heavy('$name.orig', rom);
    lzCases(name, rom);
    final base = t('$name.base', () => feldStrip(rom, embStrip, emu));
    if (base == null) continue;
    p('$name.base', '${sha(base)} ${eq(base, rom)}');
    final ed = edition(base);
    final done = <String, Uint8List?>{};
    for (final (n, opts) in combos) {
      done[n] = applyCase('$name.apply.$n', base, opts, []);
    }
    final df = done['fields'];
    if (df != null) t('$name.apply.twice', () => p('$name.apply.twice', sha(feldApply(df, const FeldOpts(bag: true), [], emb, emu))));
    t('$name.apply.half', () => p('$name.apply.half', sha(feldApply(view(base, 0, 0x800000), const FeldOpts(bag: true), [], emb, emu))));
    for (final k in ['launch', 'launch0']) {
      final d = done[k];
      if (d == null) continue;
      final c = copy(d), f = feldFind(c, stubBin)!;
      final first = launchRestore(c, f.stubOff);
      p('$name.launchRestore.$k', '$first ${sha(c)} ${launchRestore(c, f.stubOff)} ${launchRestore(c, 0x90000)}');
    }
    if (ed != null) await slotCases(name, base, ed);
    sixCases(name, base);
    appCases(name, base);
    cleanCases(name, rom, base);
  }
  stderr.writeln('cases: $count');
}
