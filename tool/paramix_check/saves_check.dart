// Checks lib/paramix/saves.dart against Paramix Studio's saves.js: prints the same lines as
// tool/paramix_check/saves.js (one per case: <case name> <sha256 or value>).
// DUMPS=<folder with water.bin ...> dart run tool/paramix_check/saves_check.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:tama_tools/paramix/core_more.dart' as core;
import 'package:tama_tools/paramix/saves.dart';

const eds = ['water', 'land', 'sky', 'jade', 'tropical', 'glacier', 'neon'];
String sha(List<int> b) => sha256.convert(b).toString();
void out(String n, Object? v) => stdout.writeln('$n $v');
void w32(Uint8List b, int o, int v) {
  b[o] = v & 255;
  b[o + 1] = (v >> 8) & 255;
  b[o + 2] = (v >> 16) & 255;
  b[o + 3] = (v >> 24) & 255;
}

int u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int Function() rng(int seed) {
  var s = seed & 0xFFFFFFFF;
  return () {
    s = (s * 1103515245 + 12345) & 0xFFFFFFFF;
    return (s >> 16) & 255;
  };
}

void fill(Uint8List b, int a, int n, int Function() r) {
  for (var i = 0; i < n; i++) {
    b[a + i] = r();
  }
}

String msg(Object e) => e is StateError ? e.message : (e is FormatException ? e.message : e.toString());
String err(String Function() f) {
  try {
    return f();
  } catch (e) {
    return 'err:${msg(e)}';
  }
}

String pagesSha(Map<int, Uint8List> pages) {
  final b = BytesBuilder();
  pages.forEach((a, d) {
    final t = Uint8List(8);
    w32(t, 0, a);
    w32(t, 4, d.length);
    b.add(t);
    b.add(d);
  });
  return '${pages.length}:${sha(b.takeBytes())}';
}

String saveStr(ParaSave sv) => [sv.stamp, sv.counter, sv.alarm, sv.status, jsonEncode([for (final r in sv.regs) [r.$1, r.$2]]), sv.edition, pagesSha(sv.pages)].join('|');
String checkStr(ParaCheck c) => '${jsonEncode(c.errors)}${jsonEncode(c.warnings)}${c.complete}|${pagesSha(c.pages)}';
void crcFix(Uint8List p) {
  final c = crc16arc(p, 4, 0x1000);
  p[0] = c & 255;
  p[1] = c >> 8;
  p[2] = ~c & 255;
  p[3] = (~c >> 8) & 255;
}

Uint8List ff(int n, [int v = 0xFF]) => Uint8List(n)..fillRange(0, n, v);
String n2s(Object? v) => v == null ? '' : '$v'; // Array.join writes nothing for null

Future<void> main() async {
  final dumps = Platform.environment['DUMPS']!;
  // ---- plain values
  for (var e = 0; e <= 9; e++) {
    out('ed$e', [idPage(e), jsonEncode(region(e)), family(e), jsonEncode(setAddrs(e))].join('|'));
  }
  out('KINDS', jsonEncode({for (final k in KINDS.keys) '$k': {'dev': KINDS[k]!.dev, 'size': KINDS[k]!.size, 'app': KINDS[k]!.app}}));
  out('T7_EE', T7_EE);
  {
    final r = rng(7), b = Uint8List(0x1000);
    fill(b, 0, 0x1000, r);
    out('crc16arc', '${crc16arc(b, 4, 0x1000)} ${crc16arc(b, 0, 100)} ${crc16arc(b, 9, 9)}');
    out('settingsOk.bad', settingsOk(b));
    crcFix(b);
    out('settingsOk.good', settingsOk(b));
  }

  // ---- every edition
  for (final name in eds) {
    final rom = File('$dumps/$name.bin').readAsBytesSync();
    final ed = core.openRom(rom).editionId;
    void P(String n, Object? v) => out('$name.$n', v);
    P('edition', ed);
    final pages = paraFromImage(rom, ed);
    P('paraFromImage', pagesSha(pages));
    final so = setOf(pages, ed);
    P('setOf', so != null ? '${so.at} ${sha(so.p)} ${settingsOk(so.p)}' : 'null');
    final file = paraEncode(pages, ed, const ParaClockIn(123456, 0xE0), 1700000000);
    P('paraEncode', '${file.length} ${sha(file)}');
    P('paraEncode.noclock', sha(paraEncode(pages, ed, null, 1700000000)));
    P('paraEncode.ctrl', sha(paraEncode(pages, ed, const ParaClockIn(0xFFFFFFFF, 0x1E5), 1800000000)));
    P('paraEncode.ctrl2', sha(paraEncode(pages, ed, const ParaClockIn(1, 0x61), 5)));
    final sv = paraDecode(file);
    P('paraDecode', saveStr(sv));
    P('paraDecode.noclock', saveStr(paraDecode(paraEncode(pages, ed, null, 1700000000))));
    P('paraWrite', sha(paraWrite(sv)));
    P('paraWrite.same', sha(paraWrite(sv)) == sha(file));
    for (final e2 in [1, 4, 6, 7, 8]) {
      P('paraWrite.ed$e2', sha(paraWrite(sv, e2)));
    }
    {
      final f2 = Uint8List.fromList(file);
      w32(f2, 12, 0x89ABCDEF);
      w32(f2, 16, 0x1234);
      final s2 = paraDecode(f2);
      P('paraWrite.stamp', '${s2.stamp} ${sha(paraWrite(s2)) == sha(f2)} ${paraClock(s2, 1700000000)} ${paraClock(s2, 0x1234 * 4294967296 + 0x89ABCDEF + 77)}');
    }
    for (var e2 = 1; e2 <= 8; e2++) {
      P('paraCheck.ed$e2', checkStr(paraCheck(sv, e2)));
    }
    for (var e2 = 1; e2 <= 8; e2++) {
      P('paraCheck.notrailer.ed$e2', checkStr(paraCheck(sv.copyWith(edition: 0), e2)));
    }
    final part = sv.copyWith(pages: {
      for (final e in sv.pages.entries)
        if (e.key >= 0xEF0000) e.key: e.value
    });
    P('paraCheck.part', checkStr(paraCheck(part, ed)));
    final part2 = sv.copyWith(pages: {
      for (final e in sv.pages.entries)
        if (e.key < 0xEF0000 && (e.key & 0x3000) == 0) e.key: e.value
    });
    P('paraCheck.part2', checkStr(paraCheck(part2, ed)));
    {
      final m = Map<int, Uint8List>.of(sv.pages);
      m[0x100000] = ff(0x1000, 3);
      m[0xF00000] = Uint8List(0x1000);
      m[region(ed)[0] + 0x3000] = ff(100, 9);
      final odd = sv.copyWith(pages: m);
      P('paraCheck.outside', checkStr(paraCheck(odd, ed)));
      final f3 = paraWrite(odd);
      P('paraWrite.odd', '${f3.length} ${sha(f3)}');
      P('paraDecode.odd', saveStr(paraDecode(f3)));
    }
    P('paraClock', [paraClock(sv, 1700000100), paraClock(sv, 1699999999), paraClock(sv, 1700000000 + 4294967296 + 5), paraClock(sv.copyWith(counter: 0), 1700000100), paraClock(sv.copyWith(stamp: 0), 1700000100), paraClock(sv.copyWith(counter: 0xFFFFFFF0), 1700000100)].map(n2s).join(' '));
    final set = paraSettings(sv, ed), set0 = paraSettings(sv);
    P('paraSettings', '${set != null ? sha(set) : 'null'} ${set0 != null ? sha(set0) : 'null'}');
    for (var e2 = 1; e2 <= 8; e2++) {
      P('paraPet.ed$e2', sha(utf8.encode(jsonEncode(paraPet(sv, e2)))));
    }
    // pet edits: exact bytes of the written save
    void petOut(String n, ParaSave Function() f) => P(
        'paraPetSet.$n',
        err(() {
          final r = f();
          return '${sha(utf8.encode(jsonEncode(paraPet(r, ed))))} ${pagesSha(r.pages)} ${sha(paraWrite(r))}';
        }));
    for (final lv in [-3, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15]) {
      petOut('level$lv', () => paraPetSet(sv, ed, level: lv));
    }
    petOut('care', () => paraPetSet(sv, ed, care: true));
    petOut('none', () => paraPetSet(sv, ed));
    petOut('stageonly', () => paraPetSet(sv, ed, stage: 5));
    final pet = paraPet(sv, ed), old = pet != null ? pet.id : 0;
    petOut('id.same', () => paraPetSet(sv, ed, id: old, stage: 3));
    petOut('id.other', () => paraPetSet(sv, ed, id: old + 1, stage: 5, level: 7, care: true));
    petOut('id.big', () => paraPetSet(sv, ed, id: 0x12345, stage: 13));
    // a save without a pet gets one, then its file (synthetic: small number at +8, the character at +12, +14 and +0x10A)
    {
      final m = Map<int, Uint8List>.of(sv.pages), so2 = setOf(m, ed);
      if (so2 != null) {
        final fam = family(ed), t = {'gen1': 0x104, 'jade': 0x108, 'gen3': 0x114, 'neon': 0x114}[fam]!;
        final p = Uint8List.fromList(so2.p);
        p[t + 4] = 0;
        p[t + 5] = 0;
        crcFix(p);
        for (final a in setAddrs(ed)) {
          if (m.containsKey(a) && settingsOk(m[a]!)) m[a] = Uint8List.fromList(p);
        }
        final sv0 = sv.copyWith(pages: m);
        petOut('nopet', () => sv0);
        petOut('nopet.id', () => paraPetSet(sv0, ed, id: 1017, stage: 4));
        final sv1 = paraPetSet(sv0, ed, id: 1017, stage: 4);
        petOut('nofile', () => paraPetSet(sv1, ed, id: 1020));
        final r = rng(ed * 31 + 5), a0 = region(ed)[0] + 0x20000, m2 = Map<int, Uint8List>.of(sv1.pages);
        void mk(int k, void Function(Uint8List d) f) {
          final d = Uint8List(0x1000);
          fill(d, 0, 0x1000, r);
          f(d);
          m2[a0 + k * 0x1000] = d;
        }

        mk(0, (d) {
          w32(d, 8, 1);
          d[14] = 1017 & 255;
          d[15] = 1017 >> 8;
          d[12] = 1;
          d[13] = 0;
          d[0x10A] = 1017 & 255;
          d[0x10B] = 1017 >> 8;
        });
        mk(1, (d) {
          w32(d, 8, 200);
          d[12] = 1017 & 255;
          d[13] = 1017 >> 8;
          d[14] = 7;
          d[15] = 0;
        });
        mk(2, (d) {
          w32(d, 8, 0);
          d[14] = 1017 & 255;
          d[15] = 1017 >> 8;
        }); // number 0: not a pet file
        mk(3, (d) {
          w32(d, 8, 256);
          d[14] = 1017 & 255;
          d[15] = 1017 >> 8;
        }); // number too big
        mk(4, (d) {
          w32(d, 8, 5);
          d[12] = 1017 & 255;
          d[13] = 1017 >> 8;
          d[14] = 1017 & 255;
          d[15] = 1017 >> 8;
        });
        {
          final d = Uint8List(0x800);
          fill(d, 0, 0x800, r);
          w32(d, 8, 1);
          d[14] = 1017 & 255;
          d[15] = 1017 >> 8;
          m2[a0 + 5 * 0x1000] = d;
        }
        final sv2 = sv1.copyWith(pages: m2);
        petOut('file', () => paraPetSet(sv2, ed, id: 1020, stage: 5, care: true, level: 3));
        petOut('file.twice', () => paraPetSet(paraPetSet(sv2, ed, id: 1020), ed, id: 2000, level: 9));
      } else {
        P('paraPetSet.nopet', 'no settings');
      }
    }
    // without a settings block
    {
      final m = Map<int, Uint8List>.of(sv.pages);
      for (final a in setAddrs(ed)) {
        m.remove(a);
      }
      final bare = sv.copyWith(pages: m);
      P('nosettings', [jsonEncode(paraPet(bare, ed)), paraSettings(bare, ed) == null, err(() => '${paraPetSet(bare, ed, level: 3)}'), checkStr(paraCheck(bare, ed))].join(' '));
    }
    // Neon ring made by hand on every save: several valid pages with different numbers (wrap around too)
    {
      final base = setOf(sv.pages, ed);
      if (base != null) {
        Uint8List mk(int seq) {
          final p = Uint8List.fromList(base.p);
          w32(p, 0xAD0, seq);
          crcFix(p);
          return p;
        }

        final ring = setAddrs(8);
        final cases = {
          'a': [5, 9, 7],
          'b': [0xFFFFFFFE, 2, 0xFFFFFFFF],
          'c': [3, 3, 3],
          'd': [0x80000000, 0, 1]
        };
        cases.forEach((k, qs) {
          final m = <int, Uint8List>{};
          for (var i = 0; i < qs.length; i++) {
            m[ring[(i * 2) % 5]] = mk(qs[i]);
          }
          final bad = mk(100);
          bad[77] ^= 1;
          m[ring[1]] = bad;
          final s8 = sv.copyWith(pages: m, edition: 8), o = setOf(m, 8)!;
          P(
              'ring.$k',
              '${o.at} ${sha(o.p)} ${checkStr(paraCheck(s8, 8))} ${err(() {
                final r = paraPetSet(s8, 8, level: 6, care: true);
                return '${pagesSha(r.pages)} ${sha(utf8.encode(jsonEncode(paraPet(r, 8))))}';
              })}');
        });
      }
    }
    // broken files
    Uint8List cut(int n) => Uint8List.fromList(file.sublist(0, n));
    Uint8List chg(void Function(Uint8List f) fn) {
      final f = Uint8List.fromList(file);
      fn(f);
      return f;
    }

    final bads = {
      'short': cut(39),
      'magic': chg((f) => f[0] = 0x58),
      'version': chg((f) => w32(f, 8, 4)),
      'cut1': cut(50),
      'cut2': cut(36 + 8 * 19 + 2),
      'cut3': cut(36 + 8 * 19 + 4 + 6),
      'cut4': cut(36 + 8 * 19 + 4 + 8 + 100),
      'cut5': cut(file.length - 16),
      'cut6': cut(file.length - 1),
      'regs': chg((f) => w32(f, 32, 0xFFFFFFFF)),
      'trailer': chg((f) => f[f.length - 16] ^= 1),
    };
    bads.forEach((k, b) => P('paraDecode.$k', err(() => saveStr(paraDecode(b)))));
    P('t7SaveOut', err(() {
      final o = t7SaveOut(rom);
      return o != null ? sha(o) : 'null';
    }));
  }

  // ---- TamaEmu: a synthetic image (settings block, packed blocks, LZ4 parts, spare pages, erased blocks)
  {
    Uint8List mkImg(int ver, String variant) {
      final r = rng(0xE0 + ver), img = ff(0x1000000);
      const c = 0xA0140, guestOff = 0x400000, guestSize = 0x60000, lzOff = 0x300000, lo = (guestOff + guestSize + 0x1FFF) & ~0x1FFF, data = lo + 0x2000, n = 5;
      w32(img, c, 0x43584D50);
      w32(img, c + 4, ver);
      w32(img, c + 8, guestOff);
      w32(img, c + 12, guestSize);
      w32(img, c + 16, 0x900000);
      w32(img, c + 20, variant == 'pc' ? 0 : 1);
      final map = ff(128);
      map[0] = 2;
      map[1] = 0;
      map[2] = 1;
      map[3] = 0xFE;
      map[5] = 4;
      map[40] = 5;
      map[70] = 3;
      img.setAll(c + 24, map);
      w32(img, c + 152, data + n * 0x2000 + (variant == 'more' ? 100 * 0x2000 : 0));
      w32(img, c + 160, lzOff);
      fill(img, guestOff, guestSize, r);
      // LZ: blocks 10 and 11 (and 2, which is mapped and so not taken)
      var pos = 512;
      for (final b in [10, 11, 2]) {
        final tab = pos;
        pos += 65 * 4;
        w32(img, lzOff + 4 * b, tab);
        for (var k = 0; k < 64; k++) {
          w32(img, lzOff + tab + 4 * k, pos);
          final kind = (k + b) % 4;
          Uint8List part;
          if (kind == 0) {
            part = Uint8List(0);
          } else if (kind == 1) {
            part = Uint8List(0x400);
            fill(part, 0, 0x400, r);
          } else {
            final raw = Uint8List(0x400);
            final q = r();
            for (var i = 0; i < 0x400; i++) {
              raw[i] = kind == 2 ? ((i * q) >> 3) & 255 : (i % 37 < 20 ? q : r() & 3);
            }
            part = core.lz4Encode(raw);
            if (part.length >= 0x400) part = raw;
          }
          img.setAll(lzOff + pos, part);
          pos += part.length;
        }
        w32(img, lzOff + tab + 256, pos);
      }
      // spare pages
      final t = ff(16 + 128 + 20);
      final vs = [(20 << 16 >> 13) + 1, 0xFFFF, (1 << 16 >> 13) + 2, 1024, (10 << 16 >> 13) + 3];
      for (var i = 0; i < vs.length; i++) {
        t[16 + 2 * i] = vs[i] & 255;
        t[17 + 2 * i] = vs[i] >> 8;
      }
      final nn = variant == 'more' ? 64 : n;
      var x = (0x50584D50 ^ ((nn * 0x9E3779B1) & 0xFFFFFFFF)) & 0xFFFFFFFF;
      for (var i = 0; i < 64; i++) {
        x = ((((x << 5) & 0xFFFFFFFF) | (x >> 27)) ^ u16(t, 16 + 2 * i)) & 0xFFFFFFFF;
      }
      w32(t, 0, 0x50584D50);
      w32(t, 4, nn);
      w32(t, 8, variant == 'badtable' ? x ^ 1 : x);
      w32(t, 12, 0);
      if (variant != 'nogone') {
        final g = [(1 << 11) | 1, 1 << (40 - 32), 0, 1 << 31];
        var y = 0x454E4F47;
        for (var i = 0; i < 4; i++) {
          w32(t, 144 + 4 * i, g[i]);
          y = (y ^ g[i]) & 0xFFFFFFFF;
        }
        w32(t, 160, variant == 'badgone' ? y ^ 4 : y);
      }
      img.setAll(lo, t);
      fill(img, data, n * 0x2000, r);
      return img;
    }

    for (final (ver, variant) in [(5, ''), (5, 'badtable'), (5, 'badgone'), (5, 'nogone'), (5, 'more'), (5, 'pc'), (4, ''), (3, ''), (2, ''), (6, '')]) {
      final img = mkImg(ver, variant), tag = 'emu.v$ver${variant.isNotEmpty ? '.$variant' : ''}';
      final cfg = emuCfg(Uint8List.sublistView(img, 0xA0000, 0xA1000))!, cfg2 = emuCfg(img, 0)!;
      out('$tag.cfg', [cfg.version, cfg.guestOff, cfg.guestSize, cfg.saveOff, cfg.kind, sha(cfg.map), cfg.spareEnd, cfg.lzOff, cfg.dev, cfg.size, cfg.app, cfg2.guestOff, sha(cfg2.map)].join('|'));
      final prog = <String>[];
      int cl(int v) => v < 0 ? 0 : (v > img.length ? img.length : v);
      Uint8List read(int a, int n2) => Uint8List.sublistView(img, cl(a), cl(a + n2));
      final g = await emuGuestAsync(read, cfg, (w, d, t) => prog.add('$w$d/$t'));
      out('$tag.guest', '${g.length} ${sha(g)} ${prog.join(',')}');
      final g2 = await emuGuestAsync((a, n2) async => Uint8List.fromList(read(a, n2)), cfg);
      out('$tag.guest.async', sha(g2));
    }
    {
      final sec = Uint8List(0x1000);
      out('emuCfg.none', emuCfg(sec));
      w32(sec, 0x140, 0x43584D50);
      w32(sec, 0x154, 5);
      out('emuCfg.badkind', emuCfg(sec));
      for (var k = 0; k < 5; k++) {
        w32(sec, 0x154, k);
        w32(sec, 0x144, k);
        final c = emuCfg(sec)!;
        out('emuCfg.kind$k', [c.dev, c.size, c.app, c.version, c.spareEnd, c.lzOff, c.map.length].join('|'));
      }
    }
    // lzGoneApply alone
    {
      final r = rng(99), g = Uint8List(0x400000);
      fill(g, 0, g.length, r);
      final t = Uint8List(64);
      final ws = [0x80000005, 0xFFFF0000, 3, 0];
      var y = 0x454E4F47;
      for (var i = 0; i < 4; i++) {
        w32(t, 8 + 4 * i, ws[i]);
        y = (y ^ ws[i]) & 0xFFFFFFFF;
      }
      w32(t, 24, y);
      final g1 = Uint8List.fromList(g);
      lzGoneApply(t, 8, g1, 0x400000);
      out('lzGoneApply', sha(g1));
      final g2 = Uint8List.fromList(g);
      lzGoneApply(t, 8, g2, 0x200000);
      out('lzGoneApply.size', sha(g2));
      final g3 = Uint8List.fromList(g);
      lzGoneApply(Uint8List.sublistView(t, 0, 27), 8, g3, 0x400000);
      out('lzGoneApply.short', sha(g3) == sha(g));
      t[24] ^= 1;
      final g4 = Uint8List.fromList(g);
      lzGoneApply(t, 8, g4, 0x400000);
      out('lzGoneApply.bad', sha(g4) == sha(g));
    }
  }

  // ---- T7Emu
  {
    var img = ff(16 << 20);
    out('t7.empty', t7SaveOut(img));
    final sv = Uint8List(4098);
    sv[0] = 0x05;
    for (var i = 2; i < 4098; i++) {
      sv[i] = (i * 7) & 255;
    }
    img = t7SaveIn(img, sv);
    out('t7.in1', '${sha(img)} ${sha(t7SaveOut(img)!)}');
    final sv2 = Uint8List.fromList(sv);
    sv2[100] ^= 0x55;
    sv2[0] = 0x07;
    sv2[1] = 0x80;
    img = t7SaveIn(img, sv2);
    out('t7.in2', '${sha(img)} ${sha(t7SaveOut(img)!)}');
    img = t7SaveIn(img, sv);
    out('t7.in3', '${sha(img)} ${sha(t7SaveOut(img)!)}');
    for (var i = 0; i < 5; i++) {
      img = t7SaveIn(img, (i & 1) != 0 ? sv : sv2);
    }
    out('t7.in8', '${sha(img)} ${sha(t7SaveOut(img)!)}');
    // sequence wrap: slot A at 0xFFFFFFFF, the next one gets 0
    {
      final im = Uint8List.fromList(img);
      w32(im, 0xC1004, 0xFFFFFFFF);
      w32(im, 0xC3004, 0xFFFFFFFE);
      final n = t7SaveIn(im, sv2);
      out('t7.wrap', '${sha(n)} ${sha(t7SaveOut(n)!)}');
    }
    {
      final im = Uint8List.fromList(img);
      im[0xC2000 + 50] ^= 1;
      out('t7.badsum', sha(t7SaveOut(im)!));
      im[0xC4000 + 50] ^= 1;
      out('t7.badsum2', t7SaveOut(im));
    }
    out('t7.base', '${sha(t7SaveIn(img, sv2, 0x850000))} ${sha(t7SaveOut(t7SaveIn(img, sv2, 0x850000), 0x850000)!)} ${t7SaveOut(img, 0x850000)}');
    out('t7.check', [t7SaveCheck(sv), t7SaveCheck(Uint8List.sublistView(sv, 1)), t7SaveCheck(null), t7SaveCheck(Uint8List(0))].join(' '));
    out('t7.err', '${err(() => '${t7SaveIn(img, Uint8List.sublistView(sv, 0, 100))}')} ${err(() => '${t7SaveIn(img, null)}')}');
    // test27: a slot written 2 bytes off
    {
      final im = ff(0x1000000);
      const base = 0x850000, at = base + 0x1000;
      final pages = Uint8List(4096);
      for (var i = 0; i < 4094; i++) {
        pages[i] = (i * 7 + 3) & 0xFF;
      }
      var s = 0x7E7E;
      for (var i = 0; i < 4096; i++) {
        s = (s * 31 + pages[i]) & 0xFFFFFFFF;
      }
      w32(im, at, 0x45453754);
      w32(im, at + 4, 5);
      w32(im, at + 8, 0xFFFF);
      w32(im, at + 12, s);
      im[at + 0x1000] = 0xAB;
      im[at + 0x1001] = 0xCD;
      im.setRange(at + 0x1002, at + 0x1002 + 4094, pages);
      final o = t7SaveOut(im, base)!;
      out('t7.shift', sha(o));
      final n = t7SaveIn(im, o, base);
      out('t7.shift.in', '${sha(n)} ${sha(t7SaveOut(n, base)!)}');
    }
  }
}
