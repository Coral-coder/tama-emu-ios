// Check of lib/paramix/six.dart against Paramix Studio's six.js: the same cases as six.js in this folder.
// DUMPS=<folder with the seven dumps> dart run tool/paramix_check/six_check.dart
// Prints one line per case (hashes, sizes, values only); the output must equal that of six.js.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:tama_tools/paramix/edition.dart' show sixOff;
import 'package:tama_tools/paramix/six.dart';
import 'package:tama_tools/paramix/sprite_edit.dart' show buildRom;
import 'package:tama_tools/paramix/sprites.dart' show ParadiseAssets;

const names = ['water', 'land', 'sky', 'jade', 'tropical', 'glacier', 'neon'];
final rom = <String, Uint8List>{};
late final Uint8List blob;
var count = 0;

String sha(List<int> b) => sha256.convert(b).toString();
bool same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void line(String name, Object? v) {
  stdout.writeln('$name $v');
  count++;
}

void run(String name, Object? Function() fn) {
  Object? v;
  try {
    v = fn();
  } on FormatException catch (e) {
    v = 'ERR ${e.message}';
  } on StateError catch (e) {
    v = 'ERR ${e.message}';
  }
  line(name, v);
}

String info(Uint8List r) {
  final i = sixInfo(r);
  if (i == null) return 'null';
  return '{"version":${i.version},"kind":"${i.kind}","flagOff":${i.flagOff},"sprites":${i.sprites},"comps":${i.comps},"anims":${i.anims},"planet":${i.planet},"fieldMenu":${i.fieldMenu},'
      '"games":${i.games},"dna":${i.dna},"hunt":${i.hunt},"food":${i.food},"scene":${i.scene},"gamesRest":${i.gamesRest}}';
}

void romLine(String name, Uint8List r) {
  line(name, '${r.length} ${sha(r)}');
  line('$name.info', info(r));
}

String cellsHash(SixMap m) {
  final b = BytesBuilder();
  var n = 0;
  for (final c in m.cells) {
    b.add(c);
    n += c.length;
  }
  final f = Float64List(m.pal.length * 3);
  for (var i = 0; i < m.pal.length; i++) {
    f.setAll(3 * i, m.pal[i]);
  }
  b.add(f.buffer.asUint8List());
  return '${m.cells.length} $n ${sha(b.takeBytes())}';
}

void packLine(String name, SixPacked p) {
  for (var j = 0; j < p.entries.length; j++) {
    line('$name.$j', '${p.entries[j].length} ${sha(p.entries[j])}');
  }
  line('$name.outside', sha(utf8.encode(jsonEncode(p.outside))));
  line('$name.bdata', '${p.bdata.length} ${sha(p.bdata)}');
}

class Opt {
  const Opt({this.planet = true, this.fieldMenu = true, this.games = true, this.dna = true, this.hunt = true, this.cook = true});
  final bool planet, fieldMenu, games, dna, hunt, cook;
}

Uint8List apply(Uint8List r, Uint8List? land, Uint8List? b, [Opt o = const Opt()]) => sixApply(r, land, b, planet: o.planet, fieldMenu: o.fieldMenu, games: o.games, dna: o.dna, hunt: o.hunt, cook: o.cook);

const variants = {
  'planet0': Opt(planet: false),
  'menu0': Opt(fieldMenu: false),
  'games0': Opt(games: false),
  'dna0': Opt(dna: false),
  'hunt0': Opt(hunt: false),
  'cook0': Opt(cook: false),
  'huntcook0': Opt(hunt: false, cook: false),
  'all0': Opt(planet: false, fieldMenu: false, games: false, dna: false, hunt: false, cook: false),
};

Uint8List flip(Uint8List r, int at, [int? set]) {
  final o = Uint8List.fromList(r);
  if (set != null) {
    o[at] = set;
  } else {
    o[at] ^= 1;
  }
  return o;
}

void main() {
  final d = Platform.environment['DUMPS'];
  if (d == null) {
    stderr.writeln('DUMPS is not set');
    exit(2);
  }
  blob = File('third_party/paramix-studio/six/six.bin').readAsBytesSync();
  for (final n in names) {
    rom[n] = File('$d/$n.bin').readAsBytesSync();
  }

  // A. every edition as it is
  for (final n in names) {
    final r = rom[n]!;
    line('$n.kindOf', kindOf(r));
    line('$n.sixCan', sixCan(r));
    line('$n.sixSource', sixSource(r));
    line('$n.sixNeedsSource', sixNeedsSource(r));
    line('$n.sixInfo', info(r));
    line('$n.sixStale', sixStale(sixInfo(r)));
    line('$n.sixDnaCan', sixDnaCan(r));
    line('$n.sixStrip.same', identical(sixStrip(r), r));
    line('$n.sixFix.same', identical(sixFix(r), r));
    line('$n.sixHunt.same', identical(sixHunt(r), r));
    line('$n.sixDna.same', identical(sixDna(r, blob, true), r));
  }
  line('sixSource.null', sixSource(null));
  line('sixStale.null', sixStale(null));
  line('const', [sixVersion, sixDnaSwitch, sixHuntSwitch, sixFlagOff, sixOff].join(','));

  // B. maps
  for (final n in ['tropical', 'glacier', 'land', 'water', 'sky', 'jade']) {
    final ent = ParadiseAssets.open(rom[n]!).entries, maps = <int>[];
    for (var i = 0; i < ent.length; i++) {
      final e = ent[i];
      if (e.length >= 24 && e[5] == 3 && (e[4] & 0x20) != 0 && (e[6] | (e[7] << 8)) == 64) maps.add(i);
    }
    line('$n.maps', '${maps.length} ${maps.take(3).join(',')}');
    run('$n.mapCells.err', () => cellsHash(mapCells(ent[0])));
    final first = maps.take(3).toList();
    for (final i in first) {
      run('$n.mapCells.$i', () => cellsHash(mapCells(ent[i])));
    }
    for (final k in [128, 16]) {
      run('$n.reduceOne.$k', () {
        final e = reduceOne(ent[first[0]], k);
        return '${e.length} ${sha(e)}';
      });
    }
    List<SixMap> group() => [for (final i in first) mapCells(ent[i])];
    packLine('$n.packGroup.128', packGroup(group(), 128));
    packLine('$n.packGroup.64ext', packGroup(group(), 64, [false, false, true]));
    packLine('$n.packGroup.300', packGroup(group().sublist(0, 2), 300, [true, false]));
  }

  // C. Tropical/Glacier with Land, Water, Sky
  for (final t in ['tropical', 'glacier']) {
    final built = <String, Uint8List>{};
    for (final l in ['land', 'water', 'sky']) {
      built[l] = apply(rom[t]!, rom[l], blob);
      romLine('apply.$t.$l', built[l]!);
    }
    final l = t == 'tropical' ? 'land' : 'sky', six = built[l]!, p = 'six.$t.$l';
    final v = <String, Uint8List>{};
    for (final MapEntry(key: k, value: o) in variants.entries) {
      v[k] = apply(rom[t]!, rom[l], blob, o);
      romLine('$p.$k', v[k]!);
    }
    line('$p.kindOf', kindOf(six));
    line('$p.sixCan', sixCan(six));
    line('$p.sixSource', sixSource(six));
    line('$p.sixNeedsSource', sixNeedsSource(six));
    line('$p.sixStale', sixStale(sixInfo(six)));
    line('$p.sixDnaCan', sixDnaCan(six));
    final st = sixStrip(six);
    line('$p.strip', sha(st));
    line('$p.strip.base', same(st, rom[t]!));
    for (final k in ['games0', 'dna0', 'all0']) {
      line('$p.$k.strip', sha(sixStrip(v[k]!)));
    }
    line('$p.again.same', identical(apply(six, rom[l], blob), six));
    line('$p.again.nosrc.same', identical(apply(six, null, blob), six));
    run('$p.again.menu0', () => sha(apply(six, rom[l], blob, const Opt(fieldMenu: false))));
    run('$p.again.othersrc', () => sha(apply(six, rom['water'], blob, const Opt(planet: false))));
    run('$p.again.menu0.nosrc', () => sha(apply(six, null, blob, const Opt(fieldMenu: false))));
    final off = sixDna(six, blob, false);
    romLine('$p.dnaOff', off);
    line('$p.dnaOff.is.dna0', same(off, v['dna0']!));
    final on = sixDna(off, blob, true);
    line('$p.dnaOn', sha(on));
    line('$p.dnaOn.six', same(on, six));
    line('$p.dnaOn.noblob.same', identical(sixDna(off, null, true), off));
    line('$p.dnaOn.again.same', identical(sixDna(six, blob, true), six));
    final hc = sixHunt(v['huntcook0']!);
    romLine('$p.sixHunt', hc);
    line('$p.sixHunt.six', same(hc, six));
    romLine('$p.sixHunt.hunt0', sixHunt(v['hunt0']!));
    romLine('$p.sixHunt.cook0', sixHunt(v['cook0']!));
    run('$p.apply.dna0', () {
      final r = apply(v['dna0']!, null, blob);
      return '${sha(r)} ${same(r, six)}';
    });
    run('$p.apply.huntcook0', () {
      final r = apply(v['huntcook0']!, null, blob);
      return '${sha(r)} ${same(r, six)}';
    });
    run('$p.apply.dnaOffOpt', () {
      final r = apply(six, null, blob, const Opt(dna: false));
      return '${sha(r)} ${same(r, off)}';
    });
    line('$p.sixFix', sha(sixFix(six)));
    final moved = buildRom(six, {});
    line('$p.moved', sha(moved));
    final fixed = sixFix(moved);
    line('$p.moved.sixFix', sha(fixed));
    line('$p.moved.sixFix.six', same(fixed, six));
  }

  // D. Jade Forest
  {
    final j = rom['jade']!, six = apply(j, null, blob);
    const p = 'six.jade';
    romLine('apply.jade', six);
    line('apply.jade.land.is', same(apply(j, rom['land'], blob), six));
    final v = <String, Uint8List>{};
    for (final MapEntry(key: k, value: o) in variants.entries) {
      v[k] = apply(j, null, blob, o);
      romLine('$p.$k', v[k]!);
    }
    line('$p.kindOf', kindOf(six));
    line('$p.sixCan', sixCan(six));
    line('$p.sixNeedsSource', sixNeedsSource(six));
    line('$p.sixStale', sixStale(sixInfo(six)));
    line('$p.sixDnaCan', sixDnaCan(six));
    final st = sixStrip(six);
    line('$p.strip', sha(st));
    line('$p.strip.base', same(st, j));
    line('$p.all0.strip', sha(sixStrip(v['all0']!)));
    line('$p.again.same', identical(apply(six, null, blob), six));
    run('$p.again.menu0', () => sha(apply(six, null, blob, const Opt(fieldMenu: false))));
    final off = sixDna(six, blob, false);
    romLine('$p.dnaOff', off);
    line('$p.dnaOff.is.dna0', same(off, v['dna0']!));
    final on = sixDna(off, blob, true);
    line('$p.dnaOn', sha(on));
    line('$p.dnaOn.six', same(on, six));
    final hc = sixHunt(v['huntcook0']!);
    romLine('$p.sixHunt', hc);
    line('$p.sixHunt.six', same(hc, six));
    run('$p.apply.dna0', () {
      final r = apply(v['dna0']!, null, blob);
      return '${sha(r)} ${same(r, six)}';
    });
    line('$p.sixFix.same', identical(sixFix(six), six));
    run('$p.shortblob', () => sha(apply(j, null, Uint8List.fromList(blob.sublist(0, 0xC40)))));
  }

  // E. errors
  final tr = rom['tropical']!, gl = rom['glacier']!, jd = rom['jade']!;
  run('err.land', () => sha(apply(rom['land']!, rom['sky'], blob)));
  run('err.neon', () => sha(apply(rom['neon']!, rom['land'], blob)));
  run('err.src.tropical', () => sha(apply(tr, tr, blob)));
  run('err.src.null', () => sha(apply(gl, null, blob)));
  run('err.src.jade', () => sha(apply(gl, jd, blob)));
  run('err.blob.null', () => sha(apply(tr, rom['land'], null)));
  run('err.blob.short', () => sha(apply(tr, rom['land'], Uint8List.fromList(blob.sublist(0, 3)))));
  run('err.blob.version', () => sha(apply(jd, null, flip(blob, 4))));
  run('err.blob.long', () => sha(apply(jd, null, Uint8List(0x1001))));
  run('err.area', () => sha(apply(flip(jd, 0x10F800, 0), null, blob)));
  run('err.areaB', () => sha(apply(flip(tr, 0xF12345, 0), rom['land'], blob)));
  run('err.firmware', () => sha(apply(flip(tr, 0x11000 + 0xAEAC), rom['land'], blob)));
  run('err.gameplace', () => sha(apply(flip(tr, 0x10050b1e - 0x10000000 + 0x11000 + 2), rom['land'], blob)));
  run('ok.gameplace.games0', () => sha(apply(flip(tr, 0x10050b1e - 0x10000000 + 0x11000 + 2), rom['land'], blob, const Opt(games: false))));
  run('ok.nomenu', () {
    final o = apply(flip(gl, 0x11000 + 0x41496 + 2), rom['water'], blob);
    return '${sha(o)} ${info(o)}';
  });
  run('ok.nodna', () {
    final o = apply(flip(tr, 0x10081C68 - 0x10000000 + 0x11000), rom['sky'], blob);
    return '${sha(o)} ${info(o)}';
  });
  run('ok.nohunt', () {
    final o = apply(flip(jd, 0x11000 + 0x3DEE2), null, blob);
    return '${sha(o)} ${info(o)}';
  });
  stderr.writeln('$count cases');
}
