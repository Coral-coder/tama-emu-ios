// Paramix Studio: six fields on Tropical/Glacier. A port of Paramix Studio's six.js (mameise, GPL-3.0).
//
// The Tropical/Glacier firmware has three field slots (Tropical, Glacier, Forest;
// byte 499 of the settings block). It already holds the characters of all six
// fields, only the field pictures of Land, Water and Sky are missing. This module
//   - copies those pictures from the user's own Land, Water or Sky ROM into the
//     archive (8 bit maps, colours reduced to 128 per field, identical tiles shared),
//   - patches four places of the firmware so that a flag byte in the settings block
//     (offset 0xF04) switches the three slots to Land, Water, Sky: backgrounds,
//     child, teen and adult characters,
//   - writes the helper code and its tables to flash 0x10F000 (source in six/src).
// The menu (feld.js) then offers six fields; a field of the second three is
// slot 0..2 plus the flag. Nothing of a Land ROM is shipped: everything comes from
// the ROM the user opens.
//
// The helper program six.bin (third_party/paramix-studio/six/six.bin, in the app
// assets/paramix/six.bin) is passed in as `blob`.

import 'dart:math' as math;
import 'dart:typed_data';

import 'bytes.dart';
import 'edition.dart' show sixMagic, sixOff;
import 'sprite_edit.dart' show rleEncode;
import 'sprites.dart' show SpriteHeader, arc2Parse, assetBase, packSplit;

const int _sixXip = 0x100FE000;
const int sixFlagOff = 0xF04; // set byte in the settings block
int _xip(int off) => 0x10000000 + off - 0x11000;
const int sixVersion = 7;
/* DNA per field (1.7.2, switch): the DNA history and the per slot values of the firmware follow the six
 * fields. An add-on of the version 7 page (code from 0xC00), so a ROM with six fields gets it without the
 * Land ROM. Option bit 3 in the header. */
/* 1.7.4 SIX_FOOD (switch): food per field. Land, Water, Sky food counted for the young stage (the
 * firmware took the Land, Water, Sky characters for its own fields). Part of the DNA part. */
const bool _sixFoodOn = true;
const bool sixDnaSwitch = true;
const int _pDna = 0xC00, _pDnaFn = 0xC40, _dnaChild = 7, _dnaFset = 9, _dnaEnd = 0x1000;
// page layout (six/src/six.s)
const int _pFm = 0x800, _pFmFn = 0x830, _pPmap = 0x1B0, _pBg = 0x1C0, _pChild = 0x1CC, _pFn = 0x1E0, _tBg = 0x200, _tChild = 0x340, _tChildO = 0x348, _tSites = 0x380, _tMore = 0x500;
const List<int> _fnTab = [0, 1, 5];
const int _fnBg = 2, _fnChild = 3, _fnPmap = 4;
// Region B (0xF00000, unused by the firmware): cells of the rain pictures (Tropical/Glacier). Header
// "SIXB", count, per picture: sprite id and 64 offsets into the data (0xFFFFFFFF = cell in the archive).
const int _bOff = 0xF00000, _bEnd = 0xFF0000, _bMagic = 0x42584953; // 1.6.13 test13: 0xFF0000 stays free for the rescue start (was 0x1000000)
// Tropical maps reduced to 128 colours to make room (look the same)
const List<(int, int)> _tropMaps = [(1118, 7), (1132, 7), (1146, 7)];
const int _kColors = 128;

/// movw/movt pair that loads a per field table: offset in the firmware window, register, table,
/// name of the alternative table.
class _Site {
  const _Site(this.at, this.reg, this.table, this.name);
  final int at, reg, table;
  final String name;
}

/// A firmware place of the DNA / food part: XIP address, original bytes, how, helper number or bytes.
class _Patch {
  const _Patch(this.xip, this.orig, this.how, this.fn, [this.bytes = '']);
  final int xip, fn;
  final String orig, how, bytes;
}

class _Food {
  const _Food({this.ram = 0, this.field = 0, this.slots = 0, required this.hist, required this.kinds, required this.sites});
  final int ram, field, slots, hist;
  final List<int> kinds;
  final List<_Patch> sites;
}

class _Dna {
  const _Dna({required this.base, required this.cnt, required this.field, required this.stash, required this.mark, required this.bits, required this.mask, required this.slots, required this.regions, required this.icons, required this.sites, this.food});
  final int base, cnt, field, stash, mark, bits, mask, slots;
  final List<(int, int)> regions;
  final List<int> icons;
  final List<_Patch> sites;
  final _Food? food;
}

class _Fm {
  const _Fm({required this.obj, required this.field, required this.level, required this.build, required this.prev, required this.cmp, required this.set, required this.read, required this.imm, required this.off, required this.ent});
  final int obj, field, level, set;
  final List<int> build, prev, cmp, off, ent;
  final String read;
  final List<(int, int, int)> imm;
}

class _Planet {
  const _Planet({required this.calls, required this.fn, required this.field, required this.rows, required this.sites});
  final List<int> calls, rows;
  final int fn, field;
  final List<_Site> sites;
}

class _Kind {
  const _Kind({required this.id, required this.idPage, required this.ids, required this.flag, required this.slots, required this.bgAt, required this.bgOrig, required this.bgTable, required this.bgMode, required this.childAt, required this.childOrig, required this.childBack, required this.childSp, required this.childList, required this.sites, required this.planet, required this.fm, this.dna, this.food});
  final int id, idPage, flag, bgAt, bgTable, bgMode, childAt, childBack, childSp;
  final String bgOrig, childOrig;
  final List<int> ids, slots, childList;
  final List<_Site> sites;
  final _Planet planet;
  final _Fm fm;
  final _Dna? dna;
  final _Food? food;
}

/*
 * The firmwares. bg: function that returns the background composites of a field (replaced by a
 * jump), child: code that picks the child from a list in the code, sites: movw/movt pairs that
 * load a per field table (offset in the firmware window, register, table, name of the
 * alternative table). Offsets are relative to flash 0x11000.
 */
const Map<String, _Kind> _kinds = {
  'gen3': _Kind(
    id: 0, idPage: 0xD29000, ids: [5, 6], flag: 0x18000BE8 + 0xF00, slots: [0, 1, 2],
    bgAt: 0xAEAC, bgOrig: '81b08df8', bgTable: 0x10092E06, bgMode: 0,
    childAt: 0xFD62, childOrig: '40f61500adf8', childBack: 0xFD7C, childSp: 0xC4, childList: [2091, 2113, 2069],
    sites: [
      _Site(0xFED2, 1, 0x10091314, 'teen'), _Site(0xFFBC, 1, 0x1009132C, 'adult'),
      _Site(0x3FBBC, 1, 0x100A012C, 'speed'), _Site(0x3FDD2, 1, 0x100A012C, 'speed'), _Site(0x3FEA0, 1, 0x100A012C, 'speed'),
      _Site(0x432AE, 1, 0x10095790, 'egg'), _Site(0x4366C, 0, 0x10095790, 'egg'), _Site(0x435C0, 1, 0x10093382, 'eggPic'),
      _Site(0x4307C, 1, 0x10095778, 'wagon'),
      _Site(0x560B6, 1, 0x1009472C, 'scene'), _Site(0x56316, 1, 0x1009472C, 'scene'), _Site(0x56624, 1, 0x1009472C, 'scene'),
      _Site(0x7FEA4, 0, 0x1009472C, 'scene'), _Site(0x7FED2, 0, 0x1009472C, 'scene'),
      // special adult per field: two halfwords per movw/movt (Tropical/Glacier: 4112, 4134, 4090)
      _Site(0x10060, 0, 0x0FFA0FFA, 'spec2'), _Site(0x1006A, 0, 0x10261010, 'spec1'),
    ],
    // planet: calls of the edition-to-row function, the field byte, row per field slot, and the
    // two planet stage tables (3 rows of 11 stages, and the same rows loaded one by one)
    planet: _Planet(calls: [0x7C7A, 0x7C98, 0x7CB4, 0x575FA], fn: 0x1002B314, field: 0x18000BE8 + 0x1EF, rows: [0, 1, 2], sites: [
      _Site(0x7CC4, 2, 0x100A1020, 'plTab'), _Site(0x57636, 1, 0x10094786, 'pl0'), _Site(0x5768E, 1, 0x100947B2, 'pl1'),
      _Site(0x576E6, 1, 0x1009479C, 'pl2'), _Site(0x5773E, 1, 0x10094786, 'pl0'),
    ]),
    // the game's field menu: menu object pointer, field byte, planet level, list builder call,
    // preview loader calls, reads of the list (compare with the field, switch the field),
    // immediates that move the index and count (old, new), offsets list/index/count/flag, entries
    fm: _Fm(obj: 0x1801417C, field: 0x18000BE8 + 0x1EF, level: 0x18000BE8 + 0x84, build: [0x265E2, 0x100167D8],
        prev: [0x100856D4, 0x414EC, 0x41818, 0x41B38], cmp: [0x41690, 0x41782, 0x4183A, 0x418EA], set: 0x416B8, read: '90f94c00',
        imm: [(0x265EA, 0x50, 0x48), (0x41496, 0x4F, 0x53), (0x41618, 0x4F, 0x53)], off: [0x4C, 0x48, 0x53, 0x68], ent: [0, 1, 2, 0x80, 0x81, 0x82]),
    // DNA per field (1.7.2, helper page DNA part): settings block, offsets of the DNA count and the
    // field byte, stash and marker (RAM offsets, free in the settings block), byte with one bit per
    // slot, regions kept per slot (offset, length), DNA picture per field (Tropical, Glacier, Forest,
    // Land, Water, Sky), and the firmware places: [XIP, original bytes, how, helper number or bytes]
    dna: _Dna(base: 0x18000BE8, cnt: 0x131, field: 0x1EF, stash: 0xF0C, mark: 0xF0B, bits: 133, mask: 7, slots: 7,
        regions: [(256, 6), (350, 6), (422, 72), (500, 12)], icons: [1184, 1185, 1180, 1165, 1166, 1167],
        sites: [
          _Patch(0x10081C68, '80b590b0', 'bw', 0), _Patch(0x10081CEC, '80b590b0', 'bw', 1), _Patch(0x1000AE44, '81b08df8', 'bw', 2),
          _Patch(0x1003BFB2, '0328', 'hex', 0, '0628'), _Patch(0x1008211C, 'fff7a4fd', 'bl', 3), _Patch(0x10082124, '0228', 'hex', 0, '0528'),
          _Patch(0x10013BBE, '90f8ef01', 'bl', 4), _Patch(0x10072676, '90f8ef01', 'bl', 4), _Patch(0x10013C78, '91f8ef01', 'bl', 5),
          _Patch(0x10013C3E, '91f9ef11', 'bl', 6), _Patch(0x10013F42, '91f9ef11', 'bl', 6), _Patch(0x10068B54, '28f018f981790ca830f81100', 'bl', 8),
        ],
        // food per field: history offset, first food kind per field 0..5, check of the kind, young stage branch
        food: _Food(hist: 0x13E, kinds: [12, 15, 9, 0, 3, 6], sites: [_Patch(0x1001027E, '0df055fd', 'bl', 10), _Patch(0x10081D70, '80b596b0', 'bw', 11)])),
  ),
  'jade': _Kind(
    id: 1, idPage: 0xD49000, ids: [4], flag: 0x18000BA0 + 0xF00, slots: [1],
    bgAt: 0x966C, bgOrig: '81b08df8', bgTable: 0x1007F98C, bgMode: 1,
    childAt: 0xE1DA, childOrig: '40f61500adf8', childBack: 0xE1F4, childSp: 0xBC, childList: [2002, 2003, 2069],
    sites: [
      _Site(0xE3F2, 1, 0x1007DFC4, 'teen'), _Site(0xE536, 1, 0x1007DFDC, 'adult'),
      _Site(0x3AA58, 1, 0x1008BCE8, 'speed'), _Site(0x3AC6E, 1, 0x1008BCE8, 'speed'), _Site(0x3AD3C, 1, 0x1008BCE8, 'speed'),
      _Site(0x3DE22, 1, 0x100820E8, 'egg'), _Site(0x3DBF4, 1, 0x100820D0, 'wagon'),
      _Site(0x4F1FE, 1, 0x10081198, 'scene'), _Site(0x4F45E, 1, 0x10081198, 'scene'), _Site(0x4F76C, 1, 0x10081198, 'scene'),
      _Site(0x7164C, 0, 0x10081198, 'scene'), _Site(0x7167A, 0, 0x10081198, 'scene'),
      _Site(0xE5E2, 0, 0x0FE30FE2, 'spec1'),
    ],
    planet: _Planet(calls: [0x670A, 0x6728, 0x6744, 0x50742], fn: 0x10026E10, field: 0x18000BA0 + 0x1B7, rows: [0xFF, 1, 0xFF], sites: [
      _Site(0x6754, 2, 0x1008CBD0, 'plTab'), _Site(0x5077E, 1, 0x100811DA, 'pl0'), _Site(0x507D6, 1, 0x10081206, 'pl1'),
      _Site(0x5082E, 1, 0x100811F0, 'pl2'), _Site(0x50886, 1, 0x100811DA, 'pl0'),
    ]),
    fm: _Fm(obj: 0x180140B8, field: 0x18000BA0 + 0x1B7, level: 0x18000BA0 + 0x78, build: [0x2262C, 0x10014954],
        prev: [0x1007564C, 0x3C2E0, 0x3C5C2], cmp: [0x3C470, 0x3C53E, 0x3C5EA, 0x3C69A], set: 0x3C498, read: '90f94a00',
        imm: [(0x22634, 0x4E, 0x48), (0x3C29E, 0x4D, 0x4F), (0x3C3F8, 0x4D, 0x4F)], off: [0x4A, 0x48, 0x4F, 0x64], ent: [0, 1, 2, 0x81]),
    // food per field without the DNA part (option bit 64): settings block, field byte, switched slots, history,
    // first food kind per field (Land, Water, Forest, -, Sky in the Water slot, -), check and young stage branch
    food: _Food(ram: 0x18000BA0, field: 0x1B7, slots: 2, hist: 0x132, kinds: [0, 3, 9, 0, 6, 0], sites: [_Patch(0x1000E7F6, '0cf035f9', 'bl', 10), _Patch(0x10072750, '80b590b0', 'bw', 11)]),
  ),
};
/* 1.7.3 test23 SIX_HUNT: the egg hunt gives 8 entries per field (picture, item, found bit; two groups of 4, one picked at
 * random). It was left on the slot's own row, so Sky in the Forest slot gave Jade Forest ingredients. The rows of Land,
 * Water and Sky as in their firmware (items and found bits), the pictures from this ROM's item table. Jade Forest: Sky in
 * the Water slot keeps the Water slot's found bits. Option bit 4 in the header. */
const bool sixHuntSwitch = true;
const List<List<(int, int)>> _huntRows = [
  [(5003, 0), (5004, 1), (5007, 4), (5008, 5), (5005, 2), (5006, 3), (5007, 4), (5008, 5)], // Land
  [(5009, 6), (5010, 7), (5013, 10), (5014, 11), (5011, 8), (5012, 9), (5013, 10), (5014, 11)], // Water
  [(5015, 12), (5016, 13), (5017, 14), (5018, 15), (5019, 16), (5020, 17), (5017, 14), (5018, 15)], // Sky
];
const Map<String, List<_Site>> _huntSites = {
  'gen3': [_Site(0x4336E, 1, 0x100A0600, 'hunt'), _Site(0x433AC, 0, 0x100A0600, 'hunt')],
  'jade': [_Site(0x3DEE2, 1, 0x1008C1BC, 'hunt'), _Site(0x3DF20, 0, 0x1008C1BC, 'hunt')],
};
/* 1.7.3 test24 SIX_COOK: the kitchen's recipe table (12 pairs dish, ingredient; 4 per field, all three fields of the
 * firmware) also follows the set byte: Land, Water and Sky recipes as in their firmware (Jade Forest: Sky in place of
 * Water). Option bit 5 in the header. */
const List<List<int>> _cookRows = [
  [5021, 5004, 5022, 5005, 5023, 5006, 5024, 5008],
  [5025, 5009, 5026, 5010, 5027, 5012, 5028, 5014],
  [5029, 5016, 5030, 5018, 5031, 5019, 5032, 5020],
];
final Map<String, List<_Site>> _cookSites = {
  'gen3': [for (final o in [0x30A72, 0x4B930, 0x4B9A0, 0x4BAB4, 0x4BB7A, 0x6F202]) _Site(o, 0, 0x10091FBC, 'cook')],
  'jade': [for (final o in [0x2C426, 0x45B94, 0x45C04, 0x45D18, 0x45DDE, 0x635CA]) _Site(o, 0, 0x1007EB5C, 'cook')],
};
const int _tCook = 0x740; // 24 halfwords up to the egg hunt table

/* the add-on tables of six fields: name, sites, place in the helper page, option bit, table for this ROM */
class _Extra {
  _Extra(this.name, this.sites, this.at, this.bit, this.tab);
  final String name;
  final Map<String, List<_Site>> sites;
  final int at, bit;
  final List<int> Function(Uint8List rom, String kind) tab;
}

final List<_Extra> _extras = [
  _Extra('hunt', _huntSites, 0x770, 16, (rom, kind) => kind == 'jade' ? _rows(rom, _huntSites['jade']![0].table, 24, 3, {1: _huntRow(rom, 2, 6)}) : [for (var r = 0; r < 3; r++) ..._huntRow(rom, r)]),
  _Extra('cook', _cookSites, _tCook, 32, (rom, kind) => kind == 'jade' ? _rows(rom, _cookSites['jade']![0].table, 8, 3, {1: _cookRows[2]}) : [for (final r in _cookRows) ...r]),
];

/// SIX_HUNT, SIX_COOK for a ROM that has six fields already (no Land ROM needed): table, site entries, jumps
Uint8List sixHunt(Uint8List rom) {
  var out = rom;
  for (final x in _extras) {
    out = _extraAdd(out, x);
  }
  return out;
}

Uint8List _extraAdd(Uint8List rom, _Extra x) {
  final info = sixInfo(rom);
  if (info == null || info.version < 7 || (u32(rom, sixOff + 32) & x.bit) != 0 || !_extraCan(rom, info.kind, x)) return rom;
  int f(int o) => 0x11000 + o;
  final out = Uint8List.fromList(rom);
  const p = sixOff;
  final s = x.sites[info.kind]!, tab = x.tab(rom, info.kind);
  for (var i = p + x.at; i < p + x.at + 2 * tab.length; i++) {
    if (out[i] != 0xFF && out[i] != 0) return rom; // free (the program leaves its tables empty)
  }
  var n = 0;
  while (u32(out, p + _tSites + 12 * n) != 0) {
    n++;
    if (12 * (n + s.length + 1) > _tMore - _tSites) return rom;
  }
  for (var i = 0; i < tab.length; i++) {
    w16(out, p + x.at + 2 * i, tab[i]);
  }
  int fn(int k) => u32(out, p + _pFn + 4 * k) & ~1;
  for (var i = 0; i < s.length; i++) {
    final o = s[i].at, e = p + _tSites + 12 * (n + i);
    w32(out, e, (_xip(f(o)) + 4) | 1);
    w32(out, e + 4, s[i].table);
    w32(out, e + 8, _sixXip + x.at);
    final b = Uint8List(8);
    b.setAll(0, _branch(_xip(f(o)), fn(_fnTab[s[i].reg]), true));
    w16(b, 4, 0xBF00);
    w16(b, 6, 0xBF00);
    out.setAll(f(o), b);
  }
  w32(out, p + _tSites + 12 * (n + s.length), 0);
  w32(out, p + 32, u32(out, p + 32) | x.bit);
  return out;
}

bool _extraCan(Uint8List rom, String kind, _Extra x) {
  return x.sites[kind]!.every((s) => _eq(rom, 0x11000 + s.at, _movPairBytes(s.reg, s.table)));
}

List<int> _huntRow(Uint8List rom, int r, [int? bitBase]) {
  final pic = _itemPics(rom);
  final out = <int>[];
  for (final (id, bit) in _huntRows[r]) {
    if (!pic.containsKey(id)) throw StateError('item $id missing');
    out.addAll([pic[id]!, id, bitBase == null ? bit : bitBase + (bit % 6)]);
  }
  return out;
}

// v1 and v2 (1.2.0, 1.2.1) of Tropical/Glacier jumped from these places too
const List<(int, String)> _oldPatch = [(0x20ED2, '41f21431c1f20901'), (0x20FBC, '41f22c31c1f20901')];
// Land firmware: background table, adult table and a few code places (to recognise it)
const int _landBg = 0x1007BAA8, _landAdult = 0x10079AA4, _landSpeed = 0x10086918, _landPlanet = 0x100877EC;
// planet stages of Sky (Land, Water, Sky ROMs: third row of LAND_PLANET)
const List<int> _skyPlanet = [2, 5, 5, 5, 8, 8, 9, 9, 9, 9, 10];
const int _landBgAt = 0x11000 + 0x158F8, _landAdultAt = 0x11000 + 0xE2D0;
const List<(int, String)> _landFp = [(0x11000 + 0x38AA6, '46f61811c1f20801'), (0x11000 + 0x4D316, '01f65301')];
/*
 * Land, Water, Sky scripts per table column (Land numbers, + field): found through Jade Forest,
 * whose tables have the same layout as Tropical's and whose scripts match Land's one to one.
 * scene: 5 columns, wagon: 2 columns (the other two stay), egg: field eggs.
 */
// 1.7.6 SCENE_LAND (switch): the scene table (0x1009472C) holds a script in column 0 and PICTURES in columns 1..4
// (walk ground and objects 0x56316/0x56624, objects of the scene at 0x7FEA4). Land: script 2131+field, pictures
// 1437+field (table 0x1007AD60), 1443+field (0x1004D860), 1440+field and 1446+field (0x1006D77A/0x1006D79A).
// The old values (scripts 1558..1567) left the WALKING game of the PLAY list black on Land, Water and Sky.
const List<int> _landScene = [0x853, 1437, 1443, 1440, 1446], _landWagon = [1464, 1467];
const int _landEgg = 180;
// Jade Forest keeps the Sky pictures and scripts itself: Sky values in Jade's own numbers
const List<int> _jadeBg = [773, 774, 775, 775, 776, 777, 777, 778, 779, 779, 780, 781, 781, 780, 781, 781];
const List<int> _jadeSpeed = [1371, 1372, 1373], _jadeEgg = [183], _jadeScene = [2273, 1670, 1676, 1673, 1679], _jadeWagon = [1576, 1579, 1580, 1581];
const List<int> _jadeTeen = [3013, 3014, 3015, 3016], _jadeChild = [2002, 2004, 2069];
const List<int> _jadeAdult = [4050, 4051, 4052, 4053, 4060, 4059, 4058, 4061, 4054, 4055, 4056, 4057, 4062, 4063, 4064, 4065];
// Script ids of op 15 (probably sounds) that moved between the editions (Land -> Tropical)
const Map<int, int> _op15 = {24: 26, 25: 27, 26: 28, 27: 29, 28: 30, 29: 31, 30: 32, 31: 33, 32: 34, 33: 35, 34: 37, 35: 38, 36: 39, 37: 40, 38: 41, 39: 42, 40: 43, 41: 44, 42: 45, 43: 46, 44: 47, 45: 48};

/// u32 that reads missing bytes as 0 (as a JS typed array read past the end does)
int _u32s(Uint8List b, int o) {
  var v = 0;
  for (var k = 0; k < 4; k++) {
    if (o + k >= 0 && o + k < b.length) v |= b[o + k] << (8 * k);
  }
  return v;
}

Uint8List _hexBytes(String h) => Uint8List.fromList([for (var k = 0; k < h.length ~/ 2; k++) int.parse(h.substring(2 * k, 2 * k + 2), radix: 16)]);

/// rom[o, o + bytes.length) == bytes
bool _eq(Uint8List rom, int o, List<int> bytes) {
  if (o < 0 || o + bytes.length > rom.length) return false;
  for (var k = 0; k < bytes.length; k++) {
    if (rom[o + k] != bytes[k]) return false;
  }
  return true;
}

bool _eqHex(Uint8List rom, int o, String h) => _eq(rom, o, _hexBytes(h));

Uint8List _concat(Iterable<Uint8List> parts) {
  var n = 0;
  for (final p in parts) {
    n += p.length;
  }
  final o = Uint8List(n);
  var k = 0;
  for (final p in parts) {
    o.setAll(k, p);
    k += p.length;
  }
  return o;
}

/// Array.prototype.slice for non negative arguments
List<int> _slice(List<int> a, int s, [int? e]) {
  final n = a.length;
  final x = s < 0 ? 0 : (s > n ? n : s);
  var y = e == null ? n : (e > n ? n : (e < 0 ? 0 : e));
  if (y < x) y = x;
  return a.sublist(x, y);
}

// ------------------------------------------------------------ Thumb-2
int _movwDec(Uint8List b, int o) {
  final h1 = u16(b, o), h2 = u16(b, o + 2);
  if ((h1 & 0xFBF0) != 0xF240 && (h1 & 0xFBF0) != 0xF2C0) return -1;
  return ((h1 & 15) << 12) | (((h1 >> 10) & 1) << 11) | (((h2 >> 12) & 7) << 8) | (h2 & 255);
}

Uint8List _movEnc(int rd, int imm, [bool top = false]) {
  final o = Uint8List(4);
  w16(o, 0, (top ? 0xF2C0 : 0xF240) | (((imm >> 11) & 1) << 10) | ((imm >> 12) & 15));
  w16(o, 2, (((imm >> 8) & 7) << 12) | (rd << 8) | (imm & 255));
  return o;
}

int _movPair(Uint8List b, int o) {
  final lo = _movwDec(b, o), hi = _movwDec(b, o + 4);
  return lo < 0 || hi < 0 ? -1 : ((hi << 16) | lo) & 0xFFFFFFFF;
}

Uint8List _branch(int src, int dst, bool link) {
  final off = (dst - (src + 4)) & 0xFFFFFFFF;
  final s = (off >> 24) & 1, i1 = (off >> 23) & 1, i2 = (off >> 22) & 1;
  final h1 = 0xF000 | (s << 10) | ((off >> 12) & 0x3FF);
  final h2 = (link ? 0xD000 : 0x9000) | (((~i1 ^ s) & 1) << 13) | (((~i2 ^ s) & 1) << 11) | ((off >> 1) & 0x7FF);
  final o = Uint8List(4);
  w16(o, 0, h1);
  w16(o, 2, h2);
  return o;
}

Uint8List _movPairBytes(int r, int t) => _concat([_movEnc(r, t & 0xFFFF), _movEnc(r, (t >> 16) & 0xFFFF, true)]);

// ------------------------------------------------------------ data pack
// Header: u32 word offsets (in 16 bit units) of 22 tables, then the end.
List<Uint8List> _dpSplit(Uint8List d) {
  final n = u32(d, 0) * 2 ~/ 4 - 1;
  final offs = [for (var i = 0; i <= n; i++) u32(d, 4 * i) * 2];
  return [for (var i = 0; i < n; i++) Uint8List.fromList(d.sublist(math.min(offs[i], d.length), math.max(math.min(offs[i], d.length), math.min(offs[i + 1], d.length))))];
}

Uint8List _dpJoin(List<Uint8List> tables) {
  final n = tables.length, hdr = 4 * (n + 1), h = Uint8List(hdr);
  var pos = hdr;
  for (var i = 0; i < n; i++) {
    w32(h, 4 * i, pos ~/ 2);
    pos += tables[i].length;
  }
  w32(h, 4 * n, pos ~/ 2);
  return _concat([h, ...tables]);
}

List<int> _words(Uint8List t) => [for (var i = 0; i + 1 < t.length; i += 2) u16(t, i)];

Uint8List _toBytes(List<int> a) {
  final b = Uint8List(2 * a.length);
  for (var i = 0; i < a.length; i++) {
    w16(b, 2 * i, a[i]);
  }
  return b;
}

// composites: table 4 = start of each (16 bit units into table 5)
List<int> _comp(List<Uint8List> tabs, int i) {
  final ix = _words(tabs[4]), d = _words(tabs[5]);
  return _slice(d, ix[i], i + 1 < ix.length ? ix[i + 1] : d.length);
}

// ------------------------------------------------------------ maps
List<double> _rgb(int v) => [((v >> 11) & 31) * 255 / 31, ((v >> 5) & 63) * 255 / 63, (v & 31) * 255 / 31];

/// Math.round of JS (half up)
int _jsRound(double x) {
  final f = x.floorToDouble();
  return (x - f >= 0.5 ? f + 1 : f).toInt();
}

int _to565(List<double> c) => (_jsRound(c[0] * 31 / 255) << 11) | (_jsRound(c[1] * 63 / 255) << 5) | _jsRound(c[2] * 31 / 255);

// from core.js: rleDecode (byte runs; bytes past the end read as 0)
Uint8List _rleDecode(Uint8List d) {
  final out = <int>[];
  var i = 0;
  int at(int k) => k < d.length ? d[k] : 0;
  while (i < d.length) {
    final c = d[i++];
    if (c == 0) break;
    if ((c & 0x80) != 0) {
      final n = c & 0x7f;
      for (var k = 0; k < n; k++) {
        out.add(at(i + k));
      }
      i += n;
    } else {
      final v = at(i++);
      for (var k = 0; k < c; k++) {
        out.add(v);
      }
    }
  }
  return Uint8List.fromList(out);
}

/// One 8 bit map of 8 x 8 cells: header, the entry itself, index cells and the palette (RGB, 0..255).
class SixMap {
  SixMap(this.h, this.raw, this.cells, this.pal);
  final SpriteHeader h;
  final Uint8List raw;
  final List<Uint8List> cells;
  final List<List<double>> pal;
}

SixMap mapCells(Uint8List e) {
  final h = SpriteHeader(e);
  if (h.bpp != 3 || (h.flags & 0x20) == 0 || h.numSprites != 64) throw const FormatException('unexpected map picture');
  final cells = <Uint8List>[];
  for (var s = 0; s < h.numSprites; s++) {
    var off = u32(e, h.pixOffset + 8 * s);
    final ln = u32(e, h.pixOffset + 8 * s + 4);
    final unc = off & 0x80000000;
    off &= 0x7fffffff;
    final a = math.min(h.pixOffset + off, e.length), b = math.max(a, math.min(h.pixOffset + off + ln, e.length));
    var d = Uint8List.fromList(e.sublist(a, b));
    if ((h.flags & 0x80) != 0) {
      for (var k = 0; k < d.length; k++) {
        d[k] ^= 0x53;
      }
    }
    if (unc == 0) d = _rleDecode(d);
    cells.add(d);
  }
  final pal = [for (var k = 0; k < 256; k++) _rgb(u16(e, h.palOffset + 2 * k))];
  return SixMap(h, e, cells, pal);
}

/* Reduce the colours of a group of 8 bit maps that share their pixel indices (seasons
 * of one field): k-means over the indices, each picture keeps its own colours per cluster. */
(Uint8List, List<List<int>>) _reduce(List<SixMap> group, int kMax) {
  final cnt = Float64List(256);
  for (final s in group) {
    for (final c in s.cells) {
      for (final v in c) {
        cnt[v]++;
      }
    }
  }
  final used = [
    for (var k = 0; k < 256; k++)
      if (cnt[k] != 0) k,
  ];
  final x = [
    for (final k in used) [for (final s in group) ...s.pal[k]],
  ];
  final w = [for (final k in used) cnt[k]];
  final dim = x[0].length;
  double d2(List<double> a, List<double> b) {
    var s = 0.0;
    for (var i = 0; i < dim; i++) {
      final t = a[i] - b[i];
      s += t * t;
    }
    return s;
  }

  List<List<double>> cent;
  if (used.length <= kMax) {
    cent = [for (final v in x) List<double>.of(v)];
  } else {
    var mx = w[0], mi = 0;
    for (var i = 1; i < w.length; i++) {
      if (w[i] > mx) {
        mx = w[i];
        mi = i;
      }
    }
    cent = [List<double>.of(x[mi])];
    while (cent.length < kMax) {
      var best = -1.0, bi = 0;
      for (var i = 0; i < x.length; i++) {
        var d = 1e18;
        for (final c in cent) {
          final e = d2(x[i], c);
          if (e < d) d = e;
        }
        d *= math.sqrt(w[i]);
        if (d > best) {
          best = d;
          bi = i;
        }
      }
      cent.add(List<double>.of(x[bi]));
    }
  }
  final map = List<int>.filled(x.length, 0);
  for (var it = 0; it < 20; it++) {
    for (var i = 0; i < x.length; i++) {
      var d = 1e18, b = 0;
      for (var k = 0; k < cent.length; k++) {
        final e = d2(x[i], cent[k]);
        if (e < d) {
          d = e;
          b = k;
        }
      }
      map[i] = b;
    }
    final sv = [for (var k = 0; k < cent.length; k++) List<double>.filled(dim, 0)];
    final sw = List<double>.filled(cent.length, 0);
    for (var i = 0; i < x.length; i++) {
      final t = sv[map[i]];
      for (var j = 0; j < dim; j++) {
        t[j] += x[i][j] * w[i];
      }
      sw[map[i]] += w[i];
    }
    cent = [
      for (var k = 0; k < cent.length; k++)
        if (sw[k] != 0) [for (final v in sv[k]) v / sw[k]] else cent[k],
    ];
  }
  final remap = Uint8List(256);
  for (var i = 0; i < used.length; i++) {
    remap[used[i]] = map[i];
  }
  return (
    remap,
    [
      for (var g = 0; g < group.length; g++) [for (final c in cent) _to565(c.sublist(3 * g, 3 * g + 3))],
    ],
  );
}

const int _head = 24 + 512 + 8 * 64; // header, palette, cell table of one 8x8 map

/// Result of [packGroup]: the entries, per entry the offsets of its cells outside the pack (or null),
/// and the data of those cells (for region B).
class SixPacked {
  SixPacked(this.entries, this.outside, this.bdata);
  final List<Uint8List> entries;
  final List<List<int>?> outside;
  final Uint8List bdata;
}

class _Place {
  final Map<String, (int, int)> seen = {};
  int pos = 0;
}

/* Pack entries for a group: all headers first, then the cell data, shared between the
 * pictures where it is the same (offsets always point forward). */
SixPacked packGroup(List<SixMap> group, int kMax, [List<bool>? ext]) {
  final (remap, pals) = _reduce(group, kMax);
  final ex = ext ?? const <bool>[];
  bool isExt(int j) => j < ex.length && ex[j];
  final enc = [
    for (final s in group)
      [
        for (final c in s.cells)
          () {
            final r = rleEncode([for (final v in c) remap[v]]);
            for (var k = 0; k < r.length; k++) {
              r[k] ^= 0x53;
            }
            return r;
          }(),
      ],
  ];
  // in the pack: every cell a picture inside the pack uses; outside (region B): cells only rain pictures use
  (int, int) place(_Place into, List<Uint8List> list, Uint8List r, String key) {
    final have = into.seen[key];
    if (have != null) return have;
    final pad = (4 - into.pos % 4) % 4;
    if (pad != 0) {
      list.add(Uint8List(pad));
      into.pos += pad;
    }
    final t = (into.pos, r.length);
    into.seen[key] = t;
    list.add(r);
    into.pos += r.length;
    return t;
  }

  final keys = [
    for (final e in enc) [for (final r in e) String.fromCharCodes(r)],
  ];
  final pa = _Place(), pb = _Place();
  final dA = <Uint8List>[], dB = <Uint8List>[];
  for (var j = 0; j < group.length; j++) {
    if (!isExt(j)) {
      for (var k = 0; k < enc[j].length; k++) {
        place(pa, dA, enc[j][k], keys[j][k]);
      }
    }
  }
  // per cell: (in the pack?, offset, length)
  final tables = <List<(bool, int, int)>>[];
  for (var j = 0; j < group.length; j++) {
    final t = <(bool, int, int)>[];
    for (var k = 0; k < enc[j].length; k++) {
      final a = pa.seen[keys[j][k]];
      if (a != null) {
        t.add((true, a.$1, a.$2));
      } else {
        final b = place(pb, dB, enc[j][k], keys[j][k]);
        t.add((false, b.$1, b.$2));
      }
    }
    tables.add(t);
  }
  final n = group.length, blob = _concat(dA);
  final out = <Uint8List>[];
  final outside = <List<int>?>[];
  for (var j = 0; j < n; j++) {
    final s = group[j];
    final e = Uint8List(_head + (j == n - 1 ? blob.length : 0));
    e.setRange(0, 24, s.raw);
    w32(e, 0, _head * (n - j) + blob.length);
    e[4] = 0xA3;
    e[5] = 3;
    e[15] = 1;
    w16(e, 18, 24);
    w16(e, 20, 536);
    for (var k = 0; k < pals[j].length; k++) {
      w16(e, 24 + 2 * k, pals[j][k]);
    }
    final rel = <int>[];
    for (var k = 0; k < tables[j].length; k++) {
      final (inPack, pos, len) = tables[j][k];
      if (inPack) {
        w32(e, 536 + 8 * k, _head * (n - j) - 536 + pos);
        w32(e, 536 + 8 * k + 4, len);
        rel.add(-1);
      } else {
        w32(e, 536 + 8 * k, 0);
        w32(e, 536 + 8 * k + 4, len);
        rel.add(pos);
      }
    }
    if (j == n - 1) e.setAll(_head, blob);
    out.add(e);
    outside.add(rel.any((v) => v >= 0) ? rel : null);
  }
  return SixPacked(out, outside, _concat(dB));
}

/* One map on its own, colours reduced (for the Tropical maps). */
Uint8List reduceOne(Uint8List e, int kMax) => packGroup([mapCells(e)], kMax).entries[0];

// ------------------------------------------------------------ scripts (animations)
// Table 13 = start of each script (16 bit, in 4 byte units) in table 14. A script: one word,
// then commands: low byte = command, high byte = which parameters follow (one bit each).
// Command 16 starts another script (first parameter), command 1 shows a sprite, command 15
// refers to a numbered entry that moved between the editions (OP15).
class _Scripts {
  _Scripts(List<Uint8List> tabs)
      : ix = _words(tabs[13]),
        w = _words(tabs[14]);
  final List<int> ix, w;
  List<int> get(int a) => _slice(w, 2 * ix[a], a + 1 < ix.length ? 2 * ix[a + 1] : w.length);
}

class _Op {
  _Op(this.op, this.mask, this.p);
  final int op, mask;
  final List<int> p;
}

List<_Op> _parseScript(List<int> s) {
  final ops = <_Op>[];
  var i = 1;
  while (i < s.length) {
    final op = s[i];
    if (op == 0xFCBD && i == s.length - 1) {
      i++;
      break;
    }
    var n = 0;
    for (var m = op >> 8; m != 0; m >>= 1) {
      n += m & 1;
    }
    ops.add(_Op(op & 255, op >> 8, _slice(s, i + 1, i + 1 + n)));
    i += 1 + n;
  }
  return ops;
}

String _key(Uint8List e) => '${e.length}:${crc32(e)}';

/// Copies scripts (with the scripts and sprites they use) from one archive into another.
class _Importer {
  _Importer(List<Uint8List> srcTabs, this.srcEntries, this.dstTabs, List<Uint8List> dstEntries, this.entries)
      : s = _Scripts(srcTabs),
        d = _Scripts(dstTabs) {
    for (var i = 0; i < dstEntries.length; i++) {
      have.putIfAbsent(_key(dstEntries[i]), () => i);
    }
  }
  final List<Uint8List> srcEntries, dstTabs, entries;
  final _Scripts s, d;
  final Map<int, int> anims = {}, sprites = {};
  final Map<String, int> have = {};
  final List<List<int>?> made = [];

  int sprite(int i) {
    final c = sprites[i];
    if (c != null) return c;
    final e = srcEntries[i], k = _key(e);
    var id = have[k];
    if (id == null) {
      id = entries.length;
      entries.add(e);
      have[k] = id;
    }
    sprites[i] = id;
    return id;
  }

  int anim(int a) {
    final c = anims[a];
    if (c != null) return c;
    final id = d.ix.length + made.length;
    anims[a] = id;
    made.add(null);
    final sc = s.get(a), out = <int>[sc[0]];
    for (final o in _parseScript(sc)) {
      final p = List<int>.of(o.p);
      if ((o.mask & 0x80) != 0 && p.isNotEmpty) {
        if (o.op == 16) {
          p[0] = anim(p[0]);
        } else if (o.op == 1) {
          p[0] = sprite(p[0]);
        } else if (o.op == 15 && _op15.containsKey(p[0])) {
          p[0] = _op15[p[0]]!;
        }
      }
      out.add(o.op | (o.mask << 8));
      out.addAll(p);
    }
    if ((out.length & 1) != 0) out.add(0xFCBD);
    made[id - d.ix.length] = out;
    return id;
  }

  void done() {
    final ix = List<int>.of(d.ix), w = List<int>.of(d.w);
    for (final out in made) {
      if (w.length / 2 > 0xFFFF) throw StateError('script table full');
      ix.add(w.length ~/ 2);
      w.addAll(out!);
    }
    dstTabs[13] = _toBytes(ix);
    dstTabs[14] = _toBytes(w);
  }
}

// ------------------------------------------------------------ lab games per start field (1.7.2, version 7)
/*
 * Land, Water and Sky have other lab games than Tropical and Glacier (Matching Meals, Catching Poop and
 * Cleaning Dust in place of Fish Matching, Fruit Gathering and Curling); Jade Forest has Matching Meals and
 * Catching Poop next to Cloudy Coin. The game code is the same in all firmwares, only the numbers of the
 * pictures differ. With the family byte (0xF05, written by the Paramix menu when it starts a field) the
 * firmware places below take the Land numbers (translated into this ROM, missing pictures are copied from the
 * user's Land, Water or Sky ROM). Sites: XIP address, kind (w: movw/mov.w, a: addw/add.w with rn), rd, rn,
 * original value, resource (c composite, s script, p picture), Land number, families (1 Land, 2 Jade, 3 both).
 * Tables (movw/movt pairs): XIP address of the pair, register, table name, families, flags (1: in every scene,
 * for the PLAY list of the care menu, which runs in the home scene).
 */
const List<int> _gScenes = [44, 45, 46, 47, 48, 49, 50, 51, 92, 95, 96, 97]; // lab card list (44, 45..51 back from game k), result, games
const List<List<int>> _gSeq = [
  [0, 1, 2, 3, 6, 5],
  [0, 1, 2, 3, 4, 5],
];
const List<(int, int)> _gNav = [(0x1002FFE4, 1), (0x1003003A, 2)]; // ldrh.w r1,[r2,#126] -> six_cnext / six_cprev
const String _gNavOrig = 'b2f87e10';

class _GSite {
  const _GSite(this.xip, this.kind, this.rd, this.rn, this.gv, this.res, this.lv, this.fams);
  final int xip, rd, rn, gv, lv, fams;
  final String kind, res;
}

class _GTab {
  const _GTab(this.xip, this.rd, this.name, this.fams, this.flags);
  final int xip, rd, fams, flags;
  final String name;
}

class _GTable {
  const _GTable(this.addr, this.n, this.w, this.f1, this.f2);
  final int addr, n, w;
  final List<(int, String, int)>? f1, f2;
}

const List<_GSite> _gSites = [
  _GSite(0x10050b1e, 'w', 0, -1, 1225, 'c', 997, 3),
  _GSite(0x10050b46, 'w', 1, -1, 2626, 's', 1967, 3),
  _GSite(0x10070760, 'w', 2, -1, 1227, 'c', 999, 3),
  _GSite(0x10070778, 'w', 0, -1, 1228, 'c', 1001, 3),
  _GSite(0x1007079a, 'w', 0, -1, 1232, 'c', 1005, 3),
  _GSite(0x100707ba, 'w', 0, -1, 1236, 'c', 1009, 3),
  _GSite(0x10071054, 'w', 0, -1, 1253, 'c', 1026, 3),
  _GSite(0x1007107a, 'w', 1, -1, 2645, 's', 2001, 3),
  _GSite(0x10071092, 'w', 0, -1, 1250, 'c', 1023, 3),
  _GSite(0x100710b8, 'w', 1, -1, 2636, 's', 1985, 3),
  _GSite(0x100710d0, 'w', 0, -1, 1251, 'c', 1024, 3),
  _GSite(0x100710f6, 'w', 1, -1, 2643, 's', 1993, 3),
  _GSite(0x10071110, 'w', 0, -1, 1252, 'c', 1025, 3),
  _GSite(0x10071136, 'w', 1, -1, 2644, 's', 1997, 3),
  _GSite(0x100711fc, 'w', 2, -1, 1227, 'c', 999, 3),
  _GSite(0x1007122a, 'w', 0, -1, 1228, 'c', 1001, 3),
  _GSite(0x1007124c, 'w', 0, -1, 1232, 'c', 1005, 3),
  _GSite(0x1007126c, 'w', 0, -1, 1236, 'c', 1009, 3),
  _GSite(0x100713aa, 'a', 2, 2, 1231, 'c', 1004, 3),
  _GSite(0x100713e8, 'a', 2, 2, 1231, 'c', 1004, 3),
  _GSite(0x10071418, 'a', 1, 1, 2167, 'p', 1387, 3),
  _GSite(0x10069ef4, 'a', 1, 1, 1231, 'c', 1004, 3),
  _GSite(0x10069f32, 'a', 1, 1, 1231, 'c', 1004, 3),
  _GSite(0x10069f68, 'a', 1, 1, 2167, 'p', 1387, 3),
  _GSite(0x10051e6e, 'w', 0, -1, 1285, 'c', 1060, 3),
  _GSite(0x10051e94, 'w', 1, -1, 2662, 's', 2025, 3),
  _GSite(0x10051eac, 'w', 0, -1, 1286, 'c', 1061, 3),
  _GSite(0x10051ed2, 'w', 1, -1, 2667, 's', 2027, 3),
  _GSite(0x10051eea, 'w', 0, -1, 1287, 'c', 1062, 3),
  _GSite(0x10051f10, 'w', 1, -1, 2669, 's', 2030, 3),
  _GSite(0x10051f2a, 'w', 0, -1, 1288, 'c', 1063, 3),
  _GSite(0x10051f50, 'w', 1, -1, 2671, 's', 2033, 3),
  _GSite(0x100843a8, 'w', 2, -1, 1256, 'c', 1029, 3),
  _GSite(0x100843c4, 'w', 2, -1, 1257, 'c', 1030, 3),
  _GSite(0x10084368, 'w', 2, -1, 1262, 'c', 1035, 3),
  _GSite(0x10084304, 'w', 2, -1, 1271, 'c', 1044, 3),
  _GSite(0x1007d08a, 'w', 2, -1, 1263, 'c', 1036, 3),
  _GSite(0x1007d152, 'w', 2, -1, 1262, 'c', 1035, 3),
  _GSite(0x1008f4f4, 'w', 0, -1, 1275, 'c', 1048, 3),
  _GSite(0x1006aa1a, 'w', 0, -1, 1271, 'c', 1044, 3),
  _GSite(0x1006aa34, 'a', 0, 0, 1271, 'c', 1044, 3),
  _GSite(0x100842ca, 'w', 2, -1, 1279, 'c', 1054, 3),
  _GSite(0x1008f768, 'w', 0, -1, 1265, 'c', 1038, 3),
  _GSite(0x10021758, 'w', 2, -1, 1291, 'c', 1066, 1),
  _GSite(0x1002176e, 'w', 2, -1, 1298, 'c', 1072, 1),
  _GSite(0x1005219e, 'w', 1, -1, 2675, 's', 2034, 1),
  _GSite(0x1005236a, 'w', 0, -1, 1294, 'c', 1069, 1),
  _GSite(0x100528f8, 'w', 0, -1, 1294, 'c', 1069, 1),
  _GSite(0x1006fc84, 'a', 1, 1, 1301, 'c', 1075, 1),
  _GSite(0x1005fd98, 'w', 0, -1, 1296, 'c', 1071, 1),
  _GSite(0x1005fda4, 'w', 0, -1, 1298, 'c', 1072, 1),
  _GSite(0x100788e8, 'w', 0, -1, 1296, 'c', 1071, 1),
  _GSite(0x100788f4, 'w', 0, -1, 1298, 'c', 1072, 1),
  _GSite(0x10051696, 'w', 0, -1, 1254, 'c', 1027, 3),
  _GSite(0x1005184c, 'w', 0, -1, 1284, 'c', 1059, 3),
];
const List<_GTab> _gTabs = [
  _GTab(0x100410a4, 3, 'play', 1, 1),
  _GTab(0x10041200, 0, 'play', 1, 1),
  _GTab(0x1005168a, 0, 'intro03', 3, 0),
  _GTab(0x10051840, 0, 'intro03', 3, 0),
  _GTab(0x10083938, 1, 'avatar', 3, 0),
  _GTab(0x1007d0a6, 0, 'avatar2', 3, 0),
  _GTab(0x1007d16e, 0, 'avatar2', 3, 0),
  _GTab(0x1008f782, 0, 'avatar2', 3, 0),
  _GTab(0x100301de, 1, 'cardPic', 3, 0),
  _GTab(0x100303d8, 1, 'cardPic', 3, 0),
  _GTab(0x100304aa, 1, 'cardPic', 3, 0),
  _GTab(0x100306a6, 1, 'cardPic', 3, 0),
  _GTab(0x100478c4, 1, 'cardPic', 3, 0),
  _GTab(0x10047b8c, 1, 'cardPic', 3, 0),
  _GTab(0x100301fc, 0, 'cardName', 3, 0),
  _GTab(0x100303f6, 0, 'cardName', 3, 0),
  _GTab(0x100304c8, 0, 'cardName', 3, 0),
  _GTab(0x100306c4, 0, 'cardName', 3, 0),
  _GTab(0x100478e2, 0, 'cardName', 3, 0),
  _GTab(0x10047baa, 0, 'cardName', 3, 0),
  _GTab(0x1008f89c, 0, 'bg03', 3, 0),
  _GTab(0x1008f8d0, 0, 'bg03', 3, 0),
  _GTab(0x1008f906, 0, 'bg03', 3, 0),
  _GTab(0x1008f934, 0, 'bg03', 3, 0),
  _GTab(0x1008f96a, 0, 'bg03', 3, 0),
  _GTab(0x1008f9ee, 0, 'bg03', 3, 0),
  _GTab(0x1008fa24, 0, 'bg03', 3, 0),
  _GTab(0x1008fa52, 0, 'bg03', 3, 0),
  _GTab(0x1008fa88, 0, 'bg03', 3, 0),
  _GTab(0x1008fafa, 0, 'bg03', 3, 0),
  _GTab(0x100300b0, 0, 'cardLevel', 3, 0),
  _GTab(0x10047e1e, 0, 'cardLevel', 3, 0),
];
const Map<String, _GTable> _gTables = {
  'avatar': _GTable(0x100A008A, 23, 2, [(0, 's', 1984), (1, 'c', 1022), (2, 's', 1981), (3, 'c', 1019), (4, 's', 1982), (5, 'c', 1020), (6, 's', 1983), (7, 'c', 1021), (20, 'c', 1038), (21, 'c', 1039), (22, 'c', 1040)], [(0, 's', 1984), (1, 'c', 1022), (2, 's', 1981), (3, 'c', 1019), (4, 's', 1982), (5, 'c', 1020), (6, 's', 1983), (7, 'c', 1021), (20, 'c', 1038), (21, 'c', 1039), (22, 'c', 1040)]),
  'avatar2': _GTable(0x100A00B2, 3, 2, [(0, 'c', 1038), (1, 'c', 1039), (2, 'c', 1040)], [(0, 'c', 1038), (1, 'c', 1039), (2, 'c', 1040)]),
  'cardPic': _GTable(0x10093544, 7, 4, [(0, 'p', 1335), (1, 'p', 1336), (2, 'p', 1337), (3, 'p', 1338), (6, 'p', 1339), (5, 'p', 1340)], [(0, 'p', 1335), (1, 'p', 1336), (2, 'p', 1337), (3, 'p', 1338), (5, 'p', 1340)]),
  'cardName': _GTable(0x10093560, 8, 2, [(0, '=', 803), (1, '=', 804), (2, '=', 805), (3, '=', 806), (6, '=', 807), (5, '=', 808)], [(0, '=', 803), (1, '=', 804), (2, '=', 805), (3, '=', 806), (5, '=', 808)]),
  'cardLevel': _GTable(0x10093976, 7, 2, [(0, '=', 1), (1, '=', 4), (2, '=', 4), (3, '=', 4), (6, '=', 1), (5, '=', 1)], [(0, '=', 1), (1, '=', 4), (2, '=', 4), (3, '=', 4), (5, '=', 1)]),
  'intro03': _GTable(0x10094368, 2, 2, [(0, 's', 2005), (1, 's', 2015)], [(0, 's', 2005), (1, 's', 2015)]),
  'bg03': _GTable(0x10091CC4, 5, 2, [(0, 'p', 1402), (1, 'p', 1402), (2, 'p', 1402), (3, 'p', 1402), (4, 'p', 1402)], [(0, 'p', 1402), (1, 'p', 1402), (2, 'p', 1402), (3, 'p', 1402), (4, 'p', 1402)]),
  'play': _GTable(0x10094140, 24, 2, [(0, '=', 809), (2, '=', 101), (12, '=', 811), (14, '=', 103), (18, '=', 812), (20, '=', 104)], null),
};
const int _pGm = 0x980, _pGmFn = 0x9B0;

/* movw / mov.w / addw / add.w with an immediate: kind w or a, rd, rn, value */
({String kind, int rd, int rn, int imm})? _immDec(Uint8List b, int o) {
  final h1 = u16(b, o), h2 = u16(b, o + 2), i12 = (((h1 >> 10) & 1) << 11) | (((h2 >> 12) & 7) << 8) | (h2 & 255), rd = (h2 >> 8) & 15, rn = h1 & 15;
  if ((h2 & 0x8000) != 0) return null;
  int expand(int v) {
    final x = v & 255;
    if ((v >> 10) == 0) return [x, (x << 16) | x, ((x << 24) | (x << 8)) & 0xFFFFFFFF, (x * 0x01010101) & 0xFFFFFFFF][(v >> 8) & 3];
    final u = 0x80 | (v & 0x7F), r = v >> 7;
    return ((u >> r) | (u << (32 - r))) & 0xFFFFFFFF;
  }

  if ((h1 & 0xFBF0) == 0xF240) return (kind: 'w', rd: rd, rn: -1, imm: ((h1 & 15) << 12) | i12);
  if ((h1 & 0xFBFF) == 0xF04F) return (kind: 'w', rd: rd, rn: -1, imm: expand(i12));
  if ((h1 & 0xFBF0) == 0xF200) return (kind: 'a', rd: rd, rn: rn, imm: i12);
  if ((h1 & 0xFBF0) == 0xF100) return (kind: 'a', rd: rd, rn: rn, imm: expand(i12));
  return null;
}

/// Finds Land resources in this ROM (same content) or copies them over.
class _Translator {
  _Translator(List<Uint8List> lTabs, this.lEntries, this.tt, this.entries)
      : lix = _words(lTabs[4]),
        lcw = _words(lTabs[5]),
        lsx = _words(lTabs[13]),
        lsw = _words(lTabs[14]),
        tix = _words(tt[4]),
        tcw = _words(tt[5]),
        tsx = _words(tt[13]),
        tsw = _words(tt[14]) {
    n0c = tix.length;
    n0s = tsx.length;
    for (var i = 0; i < entries.length; i++) {
      tSpr.putIfAbsent(_key(entries[i]), () => i);
    }
    for (var a = 0; a < n0s; a++) {
      tScrM.putIfAbsent(tScr(a).join(','), () => a);
    }
    for (var i = 0; i < n0c; i++) {
      tCompM.putIfAbsent(tComp(i).join(','), () => i);
    }
  }
  final List<Uint8List> lEntries, tt, entries;
  final List<int> lix, lcw, lsx, lsw, tix, tcw, tsx, tsw;
  late final int n0c, n0s;
  final Map<String, int> tSpr = {}, tScrM = {}, tCompM = {};
  final Map<int, int?> fSpr = {}, fScr = {}, fComp = {};
  final Map<int, int> gSpr = {}, gScr = {}, gComp = {};
  final List<(int, List<int>)> pend = [];

  List<int> lComp(int i) => _slice(lcw, lix[i], i + 1 < lix.length ? lix[i + 1] : lcw.length);
  List<int> tComp(int i) => _slice(tcw, tix[i], i + 1 < tix.length ? tix[i + 1] : tcw.length);
  List<int> lScr(int a) => _slice(lsw, 2 * lsx[a], a + 1 < lsx.length ? 2 * lsx[a + 1] : lsw.length);
  List<int> tScr(int a) => _slice(tsw, 2 * tsx[a], a + 1 < tsx.length ? 2 * tsx[a + 1] : tsw.length);
  String shape(List<int> s) => _parseScript(s).map((o) => '${o.op}:${o.mask}').join(',');

  int? findSprite(int i) {
    if (!fSpr.containsKey(i)) fSpr[i] = i < lEntries.length ? tSpr[_key(lEntries[i])] : null;
    return fSpr[i];
  }

  List<int>? mapScript(List<int> s, int? Function(int) sub, int? Function(int) spr) {
    final out = <int>[s[0]];
    for (final o in _parseScript(s)) {
      final p = List<int>.of(o.p);
      if ((o.mask & 0x80) != 0 && p.isNotEmpty) {
        if (o.op == 16) {
          final r = sub(p[0]);
          if (r == null) return null;
          p[0] = r;
        } else if (o.op == 1) {
          final r = spr(p[0]);
          if (r == null) return null;
          p[0] = r;
        }
      }
      out.add(o.op | (o.mask << 8));
      out.addAll(p);
    }
    if ((out.length & 1) != 0) out.add(0xFCBD);
    return out;
  }

  int? findScript(int a, [int d = 0]) {
    if (fScr.containsKey(a)) return fScr[a];
    fScr[a] = null;
    if (a >= lsx.length || d > 12) return null;
    final out = mapScript(lScr(a), (x) => findScript(x, d + 1), findSprite);
    final r = out == null ? null : tScrM[out.join(',')];
    fScr[a] = r;
    return r;
  }

  int? findComp(int i) {
    if (fComp.containsKey(i)) return fComp[i];
    int? r;
    if (i < lix.length) {
      final w = lComp(i), t = w.isEmpty ? 0 : w[0] >> 12;
      var ok = true;
      if (t == 1 && w.length > 3) {
        final x = findSprite(w[3]);
        if (x == null) {
          ok = false;
        } else {
          w[3] = x;
        }
      } else if (t == 5 && w.length > 3) {
        final x = findScript(w[3]);
        if (x == null) {
          ok = false;
        } else {
          w[3] = x;
        }
      }
      if (ok) r = tCompM[w.join(',')];
    }
    fComp[i] = r;
    return r;
  }

  // the same block of Land numbers sits elsewhere in this ROM: offset of the nearest neighbour found
  int? near(int? Function(int) find, int id) {
    for (var d = 1; d < 40; d++) {
      for (final k in [id - d, id + d]) {
        if (k < 0) continue;
        final r = find(k);
        if (r != null) return r - k;
      }
    }
    return null;
  }

  int? looseScript(int a) {
    final r = findScript(a);
    if (r != null) return r;
    final off = near(findScript, a);
    return off != null && a + off >= 0 && a + off < n0s && a < lsx.length && shape(tScr(a + off)) == shape(lScr(a)) ? a + off : null;
  }

  int? looseComp(int i) {
    final r = findComp(i);
    if (r != null) return r;
    final off = near(findComp, i);
    if (off == null || i + off >= n0c || i >= lix.length) return null;
    final w = lComp(i), g = tComp(i + off);
    int? at(List<int> l, int k) => k < l.length ? l[k] : null;
    if (g.length != w.length || at(g, 0) != at(w, 0) || at(g, 1) != at(w, 1) || at(g, 2) != at(w, 2)) return null;
    if (w.isNotEmpty && (w[0] >> 12) == 5 && shape(tScr(g[3])) != shape(lScr(w[3]))) return null;
    return i + off;
  }

  int sprite(int i) {
    final c = gSpr[i];
    if (c != null) return c;
    var j = findSprite(i);
    if (j == null) {
      j = entries.length;
      entries.add(lEntries[i]);
      tSpr[_key(lEntries[i])] = j;
    }
    gSpr[i] = j;
    return j;
  }

  int script(int a) {
    final c = gScr[a];
    if (c != null) return c;
    final l = looseScript(a);
    if (l != null) {
      gScr[a] = l;
      return l;
    }
    final j = tsx.length;
    gScr[a] = j;
    tsx.add(tsw.length ~/ 2);
    tsw.addAll([0, 0]);
    final ls = lScr(a), out = <int>[ls[0]];
    for (final o in _parseScript(ls)) {
      final p = List<int>.of(o.p);
      if ((o.mask & 0x80) != 0 && p.isNotEmpty) {
        if (o.op == 16) {
          p[0] = script(p[0]);
        } else if (o.op == 1) {
          p[0] = sprite(p[0]);
        } else if (o.op == 15 && _op15.containsKey(p[0])) {
          p[0] = _op15[p[0]]!;
        }
      }
      out.add(o.op | (o.mask << 8));
      out.addAll(p);
    }
    if ((out.length & 1) != 0) out.add(0xFCBD);
    // the placeholder was the last script so far: put the real one there (scripts after it are appended later)
    pend.add((j, out));
    return j;
  }

  int comp(int i) {
    final c = gComp[i];
    if (c != null) return c;
    final l = looseComp(i);
    if (l != null) {
      gComp[i] = l;
      return l;
    }
    final w = lComp(i), t = w.isEmpty ? 0 : w[0] >> 12;
    if (t == 1 && w.length > 3) {
      w[3] = sprite(w[3]);
    } else if (t == 5 && w.length > 3) {
      w[3] = script(w[3]);
    }
    final j = tix.length;
    tix.add(tcw.length);
    tcw.addAll(w);
    if ((tcw.length & 1) != 0) tcw.add(0);
    gComp[i] = j;
    return j;
  }

  int res(String kind, int v) => kind == 'c' ? comp(v) : (kind == 's' ? script(v) : sprite(v));

  void done() {
    // scripts: rebuild the added ones in order (their sizes were not known when the numbers were given)
    if (pend.isNotEmpty) {
      pend.sort((a, b) => a.$1 - b.$1);
      final ix = tsx.sublist(0, pend[0].$1), w = _slice(tsw, 0, 2 * tsx[pend[0].$1]);
      for (final (j, out) in pend) {
        if (ix.length != j) throw StateError('script order');
        ix.add(w.length ~/ 2);
        w.addAll(out);
      }
      if (w.length / 2 > 0xFFFF) throw StateError('script table full');
      tt[13] = _toBytes(ix);
      tt[14] = _toBytes(w);
    }
    if (tcw.length > 0xFFFF) throw StateError('composite table full');
    tt[4] = _toBytes(tix);
    tt[5] = _toBytes(tcw);
  }
}

class _Games {
  _Games(this.bytes, this.patches, this.list, this.rest);
  final Uint8List bytes;
  final List<(int, int)> patches;
  final int list, rest;
}

/* Site list and tables of the games (region B, after the rain cells). Returns the bytes; page gets the
   addresses. base: flash offset where the bytes go. */
_Games _gamesBuild(Uint8List rom, _Translator x, int base) {
  int f(int a) => a - 0x10000000 + 0x11000;
  int map(int off) => 0x60000000 + off; // flash, as the firmware reads its archive
  final parts = <Uint8List>[];
  final tabAt = <String, int>{};
  var pos = 0;
  int put(Uint8List b) {
    final at = pos;
    parts.add(b);
    pos += b.length;
    final pad = (4 - pos % 4) % 4;
    if (pad != 0) {
      parts.add(Uint8List(pad));
      pos += pad;
    }
    return at;
  }

  // tables: copy of the original with the family values
  for (final MapEntry(key: name, value: t) in _gTables.entries) {
    for (var fam = 1; fam <= 2; fam++) {
      final sub = fam == 1 ? t.f1 : t.f2;
      if (sub == null) continue;
      final b = Uint8List(t.n * t.w);
      for (var i = 0; i < t.n; i++) {
        if (t.w == 4) {
          w32(b, 4 * i, u32(rom, f(t.addr + 4 * i)));
        } else {
          w16(b, 2 * i, u16(rom, f(t.addr + 2 * i)));
        }
      }
      for (final (i, kind, lv) in sub) {
        final v = kind == '=' ? lv : x.res(kind, lv);
        if (t.w == 4) {
          w32(b, 4 * i, v);
        } else {
          w16(b, 2 * i, v);
        }
      }
      tabAt['$name$fam'] = map(base + put(b));
    }
  }
  final ent = <Uint8List>[];
  void site(int xip, int rd, int rn, List<int> vals, [int flags = 0]) {
    final b = Uint8List(20);
    w32(b, 0, (xip + 4) | 1);
    for (var k = 0; k < vals.length; k++) {
      w32(b, 4 + 4 * k, vals[k]);
    }
    b[16] = rd;
    b[17] = rn;
    b[18] = flags;
    ent.add(b);
  }

  final patches = <(int, int)>[];
  for (final s in _gSites) {
    final d = _immDec(rom, f(s.xip));
    // the place must still hold the original instruction with the original value
    if (d == null || d.kind != s.kind || d.imm != s.gv || d.rd != s.rd || (s.kind == 'a' && d.rn != s.rn)) throw StateError('game place changed 0x${s.xip.toRadixString(16)}');
    final nv = x.res(s.res, s.lv);
    site(s.xip, s.rd, s.kind == 'a' ? s.rn : 0xFF, [s.gv, (s.fams & 1) != 0 ? nv : s.gv, (s.fams & 2) != 0 ? nv : s.gv]);
    patches.add((s.xip, 4));
  }
  for (final s in _gTabs) {
    final t = _movPair(rom, f(s.xip));
    if (t != _gTables[s.name]!.addr) throw StateError('game table place changed 0x${s.xip.toRadixString(16)}');
    final t1 = tabAt['${s.name}1'], t2 = tabAt['${s.name}2'];
    site(s.xip, s.rd, 0xFF, [t, (s.fams & 1) != 0 && t1 != null ? t1 : t, (s.fams & 2) != 0 && t2 != null ? t2 : t], s.flags);
    patches.add((s.xip, 8));
  }
  ent.add(Uint8List(4));
  final listAt = put(_concat(ent));
  // original bytes of every place (for taking the games out again): count, then XIP address, length, 8 bytes
  final rest = Uint8List(4 + 16 * (patches.length + _gNav.length));
  var n = 0;
  for (final (xip, len) in [...patches, for (final (nx, _) in _gNav) (nx, 4)]) {
    final o = 4 + 16 * n++;
    w32(rest, o, xip);
    w32(rest, o + 4, len);
    rest.setRange(o + 8, o + 8 + len, rom, f(xip));
  }
  w32(rest, 0, n);
  final restAt = put(rest);
  return _Games(_concat(parts), patches, map(base + listAt), base + restAt);
}

// ------------------------------------------------------------ install
/// 'gen3' (Tropical/Glacier), 'jade' (Jade Forest) or null.
String? kindOf(Uint8List rom) {
  if (rom.length != 0x1000000) return null;
  final a = u32(rom, 0xD29000), b = u32(rom, 0xD49000);
  if (a == 5 || a == 6) return 'gen3';
  if (b == 4) return 'jade';
  return null;
}

/// The helper page of a ROM with more fields.
class SixInfo {
  SixInfo({required this.version, required this.kind, required this.flagOff, required this.sprites, required this.comps, required this.anims, required this.planet, required this.fieldMenu, required this.games, required this.dna, required this.hunt, required this.food, required this.scene, required this.gamesRest});
  final int version, flagOff, sprites, comps, anims, gamesRest;
  final String kind;
  final bool planet, fieldMenu, games, dna, hunt, food, scene;
}

SixInfo? sixInfo(Uint8List rom) {
  if (rom.length < sixOff + 0x400 || u32(rom, sixOff) != sixMagic) return null;
  final version = u32(rom, sixOff + 4), opt = u32(rom, sixOff + 32);
  return SixInfo(
    version: version,
    kind: version >= 3 && u32(rom, sixOff + 28) == 1 ? 'jade' : 'gen3',
    flagOff: u32(rom, sixOff + 12),
    sprites: u32(rom, sixOff + 16),
    comps: u32(rom, sixOff + 20),
    anims: version >= 2 ? u32(rom, sixOff + 24) : 0,
    planet: version >= 5 && (opt & 1) == 1,
    fieldMenu: version >= 6 && (opt & 2) == 2,
    games: version >= 7 && (opt & 4) == 4,
    dna: version >= 7 && (opt & 8) == 8,
    hunt: version >= 7 && (opt & 16) == 16,
    food: version >= 7 && (opt & 64) == 64,
    scene: version >= 7 && (opt & 128) == 128,
    gamesRest: version >= 7 ? u32(rom, sixOff + 36) : 0,
  );
}

/// Can this ROM get more fields? (Tropical/Glacier: Land, Water, Sky; Jade Forest: Sky)
bool sixCan(Uint8List rom) {
  final k = kindOf(rom);
  if (k == null) return false;
  if (sixInfo(rom) != null) return true;
  final kd = _kinds[k]!;
  int f(int o) => 0x11000 + o;
  return _eqHex(rom, f(kd.bgAt), kd.bgOrig) &&
      _eqHex(rom, f(kd.childAt), kd.childOrig) &&
      [...kd.sites, ...kd.planet.sites].every((s) => _eq(rom, f(s.at), _movPairBytes(s.reg, s.table))) &&
      kd.planet.calls.every((o) => _eq(rom, f(o), _branch(_xip(f(o)), kd.planet.fn, true)));
}

/// Is this a Land, Water or Sky ROM that can give its fields?
bool sixSource(Uint8List? land) {
  if (land == null || land.length != 0x1000000) return false;
  final id = u32(land, 0xD49000);
  if (id < 1 || id > 3) return false;
  return _movPair(land, _landBgAt) == _landBg && _movPair(land, _landAdultAt) == _landAdult && _landFp.every((p) => _eqHex(land, p.$1, p.$2));
}

/// SCENE_LAND: six fields of an older Studio with the wrong walk pictures; saving again with the Land ROM fixes them.
bool sixStale(SixInfo? si) => si != null && si.kind == 'gen3' && !si.scene;

/// Does this ROM need a Land, Water or Sky ROM for its extra fields? (Jade Forest does not)
bool sixNeedsSource(Uint8List rom) => kindOf(rom) == 'gen3';

// from core.js: openRom (the parts six fields use)
class _Rom {
  _Rom(this.files, this.entries, this.assetEnd, this.limit);
  final List<Uint8List> files, entries;
  final int assetEnd, limit;
}

_Rom _openRom(Uint8List rom) {
  if (rom.length < assetBase + 16 || asciiAt(rom, 0, 8) != 'SONIXDEV') throw const FormatException('not a Paradise flash dump (SONIXDEV header missing)');
  final root = arc2Parse(rom, assetBase);
  if (root.ents.length != 3) throw FormatException('unexpected asset archive (${root.ents.length} files)');
  final files = [for (final e in root.ents) Uint8List.fromList(rom.sublist(assetBase + e.$2, assetBase + e.$2 + e.$4))];
  final entries = packSplit(files[1]);
  final end = assetBase + 16 + root.length;
  // free space ends at the first used 4 KB page after the assets (version page / user data)
  var limit = (end + 0xfff) & ~0xfff;
  bool page(int p) {
    for (var i = p; i < p + 0x1000 && i < rom.length; i++) {
      if (rom[i] != 0xff) return false;
    }
    return true;
  }

  while (limit < rom.length && page(limit)) {
    limit += 0x1000;
  }
  return _Rom(files, entries, end, limit);
}

// from core.js: packJoin
Uint8List _packJoin(List<Uint8List> entries) {
  final n = entries.length;
  var pos = 4 * n;
  final head = Uint8List(4 * n);
  final parts = <Uint8List>[head];
  for (var i = 0; i < n; i++) {
    final pad = (4 - pos % 4) % 4;
    if (pad != 0) {
      parts.add(Uint8List(pad));
      pos += pad;
    }
    w32(head, 4 * i, pos);
    parts.add(entries[i]);
    pos += entries[i].length;
  }
  return _concat(parts);
}

// from core.js: arc2Checksum
int _arc2Checksum(Uint8List buf, int off, int length) {
  var s = 0;
  final end = off + 16 + length;
  for (var i = off + 8; i < end; i++) {
    s += buf[i];
  }
  return s & 0xFFFFFFFF;
}

// from core.js: arc2Build
Uint8List _arc2Build(List<Uint8List> files) {
  final n = files.length;
  var pos = 16 + 16 * n;
  final ents = <List<int>>[];
  final body = <Uint8List>[];
  for (final f in files) {
    final pad = (4 - pos % 4) % 4;
    if (pad != 0) {
      body.add(Uint8List(pad));
      pos += pad;
    }
    final aligned = f.length + ((4 - f.length % 4) % 4);
    ents.add([0, pos, aligned, f.length]);
    body.add(f);
    if (aligned > f.length) body.add(Uint8List(aligned - f.length));
    pos += aligned;
  }
  final out = Uint8List(pos);
  w32(out, 0, 0x32435241); // "ARC2"
  w32(out, 8, pos - 16);
  w32(out, 12, n);
  for (var i = 0; i < n; i++) {
    for (var k = 0; k < 4; k++) {
      w32(out, 16 + 16 * i + 4 * k, ents[i][k]);
    }
  }
  out.setAll(16 + 16 * n, _concat(body));
  w32(out, 4, _arc2Checksum(out, 0, pos - 16));
  return out;
}

// from core.js: buildRom (entries and data pack given, nothing changed) with the checksum part of verifyRom
Uint8List _buildRom(Uint8List rom, List<Uint8List> entries, Uint8List file2, int limit, int assetEnd, Uint8List dataPack) {
  final root = _arc2Build([dataPack, _packJoin(entries), file2]);
  final end = assetBase + root.length;
  if (end > limit) throw StateError('too big: assets would end at 0x${end.toRadixString(16)}, free space ends at 0x${limit.toRadixString(16)}');
  final out = Uint8List.fromList(rom);
  out.setAll(assetBase, root);
  if (end < assetEnd) out.fillRange(end, assetEnd, 0xff);
  void check(int off) {
    final a = arc2Parse(out, off);
    if (_arc2Checksum(out, off, a.length) != a.chk) throw StateError('checksum wrong at 0x${off.toRadixString(16)}');
    for (final e in a.ents) {
      if (u32(out, off + e.$2) == 0x32435241) check(off + e.$2);
    }
  }

  check(assetBase);
  return out;
}

// from feld.js: bildTabelle (the image table of the ROM, only searched inside the asset archive)
int _bildTabelle(Uint8List d) {
  final end = math.min(d.length, 0x111000 + 16 + u32(d, 0x111000 + 8));
  for (var o = 0x111000; o + 4 < end; o += 4) {
    final e0 = u32(d, o);
    if (e0 < 0x1000 || e0 > 0x8000 || e0 % 4 != 0) continue;
    var prev = e0, ok = true;
    for (var i = 1; i < 60; i++) {
      final w = _u32s(d, o + 4 * i);
      if (w <= prev || w > 0x1000000) {
        ok = false;
        break;
      }
      prev = w;
    }
    if (!ok) continue;
    final k = o + e0;
    if (k + 24 >= d.length) continue;
    final g = u32(d, k), p = u32(d, k + 20);
    if (p > 24 && p < g && g >= 1 && g <= 0x20000 && p % 8 == 0 && d[k + 8] > 0 && d[k + 9] > 0) return o;
  }
  return -1;
}

const int _satz = 46; // item record

// from feld.js: itemTabelle (start and count of the item table; nb: number of pictures)
(int, int) _itemTabelle(Uint8List d, int nb) {
  var best = -1, bn = 0;
  for (var o = 0; o + _satz < d.length; o += 2) {
    final k0 = u16(d, o);
    if (k0 < 5001 || k0 > 9999) continue;
    final seen = <int>{};
    var n = 0;
    while (n < 400 && o + n * _satz + 5 < d.length) {
      final k = u16(d, o + n * _satz), b = u16(d, o + n * _satz + 4);
      if (k < 5001 || k > 9999 || b >= nb || seen.contains(k)) break;
      seen.add(k);
      n++;
    }
    if (n > bn) {
      bn = n;
      best = o;
    }
    if (n > 8) o += n * _satz - 2;
  }
  return (best, bn);
}

// from feld.js: itemCatalog (only item number -> picture, groups 5 to 8)
Map<int, int> _itemPics(Uint8List d) {
  final out = <int, int>{};
  final bt = _bildTabelle(d);
  if (bt < 0) return out;
  final (it, n) = _itemTabelle(d, u32(d, bt) ~/ 4);
  if (it < 0 || n < 100) return out;
  for (var i = 0; i < n; i++) {
    final o = it + i * _satz, id = u16(d, o);
    if (id < 5001 || id > 8999) continue;
    out[id] = u16(d, o + 4);
  }
  return out;
}

void _putHex(Uint8List out, int o, String h) => out.setAll(o, _hexBytes(h));

/// Takes the extra fields out again (firmware places, helper page, added pictures and scripts).
Uint8List sixStrip(Uint8List rom) {
  final info = sixInfo(rom);
  if (info == null) return rom;
  final out = Uint8List.fromList(rom), kd = _kinds[info.kind]!;
  int f(int o) => 0x11000 + o;
  if (info.dna) _dnaStrip(out, kd, info);
  if (info.food && kd.food != null) _foodStrip(out, kd);
  _putHex(out, f(kd.bgAt), kd.bgOrig);
  _putHex(out, f(kd.childAt), kd.childOrig);
  if (info.kind == 'gen3') {
    for (final (o, h) in _oldPatch) {
      _putHex(out, o, h);
    }
  }
  for (final s in [...kd.sites, ...kd.planet.sites, for (final x in _extras) ...x.sites[info.kind]!]) {
    out.setAll(f(s.at), _movPairBytes(s.reg, s.table));
  }
  for (final o in kd.planet.calls) {
    out.setAll(f(o), _branch(_xip(f(o)), kd.planet.fn, true));
  }
  if (info.fieldMenu) _fmStrip(out, kd);
  if (info.games && info.gamesRest >= _bOff && info.gamesRest < _bEnd) {
    final r = info.gamesRest, n = u32(out, r);
    for (var k = 0; k < n && k < 4096; k++) {
      final o = r + 4 + 16 * k, xip = u32(out, o), len = u32(out, o + 4);
      out.setAll(xip - 0x10000000 + 0x11000, out.sublist(o + 8, o + 8 + len));
    }
  }
  out.fillRange(sixOff, sixOff + 0x1000, 0xFF);
  if (u32(out, _bOff) == _bMagic) out.fillRange(_bOff, 0x1000000, 0xFF);
  if (info.kind == 'jade') return out;
  final t = _openRom(out), tabs = _dpSplit(t.files[0]);
  final ix = _words(tabs[4]), cw = _words(tabs[5]);
  tabs[4] = _toBytes(_slice(ix, 0, info.comps));
  tabs[5] = _toBytes(_slice(cw, 0, info.comps < ix.length ? ix[info.comps] : null));
  if (info.version >= 2) {
    final s = _Scripts(tabs);
    tabs[13] = _toBytes(_slice(s.ix, 0, info.anims));
    tabs[14] = _toBytes(_slice(s.w, 0, info.anims < s.ix.length ? 2 * s.ix[info.anims] : 0));
  }
  return _buildRom(out, _sliceEntries(t.entries, info.sprites), t.files[2], t.limit, t.assetEnd, _dpJoin(tabs));
}

List<Uint8List> _sliceEntries(List<Uint8List> e, int n) => e.sublist(0, math.min(n, e.length));

/* The game's field menu: are the places as the original firmware has them? */
bool _fmCan(Uint8List rom, _Kind kd) {
  final fm = kd.fm;
  int f(int o) => 0x11000 + o;
  if (!_eq(rom, f(fm.build[0]), _branch(0x10000000 + fm.build[0], fm.build[1], true))) return false;
  if (!fm.prev.skip(1).every((o) => _eq(rom, f(o), _branch(0x10000000 + o, fm.prev[0], true)))) return false;
  if (![...fm.cmp, fm.set].every((o) => _eqHex(rom, f(o), fm.read))) return false;
  return fm.imm.every((t) => rom[f(t.$1) + 2] == t.$2);
}

void _fmStrip(Uint8List out, _Kind kd) {
  final fm = kd.fm;
  int f(int o) => 0x11000 + o;
  out.setAll(f(fm.build[0]), _branch(0x10000000 + fm.build[0], fm.build[1], true));
  for (final o in fm.prev.skip(1)) {
    out.setAll(f(o), _branch(0x10000000 + o, fm.prev[0], true));
  }
  for (final o in [...fm.cmp, fm.set]) {
    _putHex(out, f(o), fm.read);
  }
  for (final (o, old, _) in fm.imm) {
    out[f(o) + 2] = old;
  }
}

void _fmInstall(Uint8List out, Uint8List page, _Kind kd) {
  final fm = kd.fm;
  int f(int o) => 0x11000 + o;
  int fn(int k) => u32(page, _pFmFn + 4 * k) & ~1;
  w32(page, _pFm, fm.obj);
  w32(page, _pFm + 4, fm.field);
  w32(page, _pFm + 8, fm.level);
  w32(page, _pFm + 12, fm.build[1] | 1);
  w32(page, _pFm + 16, fm.prev[0] | 1);
  for (var i = 0; i < fm.off.length; i++) {
    page[_pFm + 0x14 + i] = fm.off[i];
  }
  page[_pFm + 0x18] = fm.ent.length;
  page.fillRange(_pFm + 0x19, _pFm + 0x1C, 0);
  page.fillRange(_pFm + 0x1C, _pFm + 0x24, 0);
  for (var i = 0; i < fm.ent.length; i++) {
    page[_pFm + 0x1C + i] = fm.ent[i];
  }
  out.setAll(f(fm.build[0]), _branch(0x10000000 + fm.build[0], fn(0), true));
  for (final o in fm.cmp) {
    out.setAll(f(o), _branch(0x10000000 + o, fn(1), true));
  }
  out.setAll(f(fm.set), _branch(0x10000000 + fm.set, fn(2), true));
  for (final o in fm.prev.skip(1)) {
    out.setAll(f(o), _branch(0x10000000 + o, fn(3), true));
  }
  for (final (o, _, nu) in fm.imm) {
    out[f(o) + 2] = nu;
  }
}

/* Helper page and firmware jumps. alt: alternative tables by name (rows like the original; a list of
   halfwords, or a number: a value instead of a table). */
Uint8List _install(Uint8List out, String kind, Uint8List blob, Map<String, Object> alt, List<int> counts, bool planet, bool fieldMenu, _Games? games) {
  final kd = _kinds[kind]!;
  int f(int o) => 0x11000 + o;
  final on = [
    for (final x in _extras)
      if (alt.containsKey(x.name)) x,
  ];
  final sites = <_Site>[...kd.sites, if (planet) ...kd.planet.sites, for (final x in on) ...x.sites[kind]!];
  final page = Uint8List(0x1000)..fillRange(0, 0x1000, 0xFF);
  page.setRange(0, math.min(blob.length, _pDna), blob);
  w32(page, 8, kd.flag);
  w32(page, 12, sixFlagOff);
  w32(page, 16, counts[0]);
  w32(page, 20, counts[1]);
  w32(page, 24, counts[2]);
  w32(page, 28, kd.id);
  var opt = (planet ? 1 : 0) | (fieldMenu ? 2 : 0) | (games != null ? 4 : 0) | (kind == 'gen3' ? 128 : 0);
  for (final x in on) {
    opt |= x.bit;
  }
  w32(page, 32, opt);
  w32(page, 36, games != null ? games.rest : 0);
  // background table and child list
  final bg = alt['bg']! as List<int>, child = alt['child']! as List<int>;
  for (var i = 0; i < bg.length; i++) {
    w16(page, _tBg + 2 * i, bg[i]);
  }
  w32(page, _pBg, kd.bgTable);
  w32(page, _pBg + 4, _sixXip + _tBg);
  w32(page, _pBg + 8, kd.bgMode);
  for (var i = 0; i < kd.childList.length; i++) {
    w16(page, _tChildO + 2 * i, kd.childList[i]);
  }
  for (var i = 0; i < child.length; i++) {
    w16(page, _tChild + 2 * i, child[i]);
  }
  w32(page, _pChild, _sixXip + _tChildO);
  w32(page, _pChild + 4, _sixXip + _tChild);
  w32(page, _pChild + 8, kd.childSp);
  // other tables, then the site list
  var pos = _tMore;
  final at = <String, int>{};
  for (final name in <String>{for (final s in sites) s.name}) {
    final v = alt[name];
    if (v == null) throw StateError('table $name missing');
    // add-on tables: fixed places (also for the add-on path)
    final xs = _extras.where((y) => y.name == name);
    if (xs.isNotEmpty) {
      final x = xs.first, l = v as List<int>;
      at[name] = x.at;
      for (var i = 0; i < l.length; i++) {
        w16(page, x.at + 2 * i, l[i]);
      }
      continue;
    }
    if (v is int) {
      at[name] = v - _sixXip; // a value instead of a table
      continue;
    }
    final l = v as List<int>;
    at[name] = pos;
    for (var i = 0; i < l.length; i++) {
      w16(page, pos + 2 * i, l[i]);
    }
    pos += (2 * l.length + 3) & ~3;
  }
  var top = 0x800;
  for (final x in on) {
    top = math.min(top, x.at);
  }
  if (pos > top) throw StateError('helper page full');
  if (12 * (sites.length + 1) > _tMore - _tSites) throw StateError('helper page full');
  for (var i = 0; i < sites.length; i++) {
    final e = _tSites + 12 * i;
    w32(page, e, (_xip(f(sites[i].at)) + 4) | 1);
    w32(page, e + 4, sites[i].table);
    w32(page, e + 8, _sixXip + at[sites[i].name]!);
  }
  w32(page, _tSites + 12 * sites.length, 0);
  // planet: original function, field byte, row per field slot
  w32(page, _pPmap, kd.planet.fn | 1);
  w32(page, _pPmap + 4, kd.planet.field);
  for (var i = 0; i < kd.planet.rows.length; i++) {
    page[_pPmap + 8 + i] = kd.planet.rows[i];
  }
  if (fieldMenu) _fmInstall(out, page, kd);
  out.setAll(sixOff, page);
  // firmware: background function -> b.w, child -> bl + b, sites -> bl + 2 nop
  int fn(int k) => u32(page, _pFn + 4 * k) & ~1;
  out.setAll(f(kd.bgAt), _branch(_xip(f(kd.bgAt)), fn(_fnBg), false));
  {
    final src = _xip(f(kd.childAt)), b = Uint8List(6);
    b.setAll(0, _branch(src, fn(_fnChild), true));
    w16(b, 4, 0xE000 | (((_xip(f(kd.childBack)) - (src + 8)) >> 1) & 0x7FF));
    out.setAll(f(kd.childAt), b);
  }
  for (final s in sites) {
    final b = Uint8List(8);
    b.setAll(0, _branch(_xip(f(s.at)), fn(_fnTab[s.reg]), true));
    w16(b, 4, 0xBF00);
    w16(b, 6, 0xBF00);
    out.setAll(f(s.at), b);
  }
  if (planet) {
    for (final o in kd.planet.calls) {
      out.setAll(f(o), _branch(_xip(f(o)), fn(_fnPmap), true));
    }
  }
  if (games != null) _gamesInstall(out, page, kd, games);
  out.setAll(sixOff, page);
  return out;
}

void _gamesInstall(Uint8List out, Uint8List page, _Kind kd, _Games games) {
  int g(int k) => u32(page, _pGmFn + 4 * k) & ~1;
  int fo(int x) => x - 0x10000000 + 0x11000;
  w32(page, _pGm, games.list);
  w32(page, _pGm + 4, kd.flag + 1);
  w32(page, _pGm + 8, 0x18001CB4);
  page.fillRange(_pGm + 0x0C, _pGm + 0x18, 0);
  for (var i = 0; i < _gScenes.length; i++) {
    page[_pGm + 0x0C + i] = _gScenes[i];
  }
  page.fillRange(_pGm + 0x18, _pGm + 0x28, 0xFF);
  for (var fam = 0; fam < _gSeq.length; fam++) {
    for (var i = 0; i < _gSeq[fam].length; i++) {
      page[_pGm + 0x18 + 8 * fam + i] = _gSeq[fam][i];
    }
  }
  for (final (xip, len) in games.patches) {
    final b = Uint8List(len);
    b.setAll(0, _branch(xip, g(0), true));
    if (len == 8) {
      w16(b, 4, 0xBF00);
      w16(b, 6, 0xBF00);
    }
    out.setAll(fo(xip), b);
  }
  for (final (xip, k) in _gNav) {
    if (!_eqHex(out, fo(xip), _gNavOrig)) throw StateError('game place changed ${xip.toRadixString(16)}');
    out.setAll(fo(xip), _branch(xip, g(k), true));
  }
}

/* DNA per field: can this ROM (with six fields of version 7 or new) get it? */
bool _dnaCan(Uint8List rom, _Kind? kd) {
  final d = kd?.dna;
  if (d == null) return false;
  return _dnaSites(d).every((s) => _eqHex(rom, s.xip - 0x10000000 + 0x11000, s.orig));
}

/* the firmware places of the DNA part (with the food places when on) */
List<_Patch> _dnaSites(_Dna d) => _sixFoodOn && d.food != null ? [...d.sites, ...d.food!.sites] : d.sites;

/* An old DNA part without the food places: put the DNA part in again (the saved values stay).
 * Jade Forest (no DNA part): the food part alone. */
Uint8List _sixFood(Uint8List rom, Uint8List? blob) {
  final info = sixInfo(rom);
  if (info == null || info.version < 7 || blob == null || blob.length <= _pDnaFn + 4 * 11 || _u32s(blob, _pDnaFn + 4 * 11) == 0) return rom;
  final kd = _kinds[info.kind]!;
  final fd = kd.dna != null ? kd.dna!.food : kd.food;
  if (fd == null || !fd.sites.every((s) => _eqHex(rom, s.xip - 0x10000000 + 0x11000, s.orig))) return rom;
  final out = Uint8List.fromList(rom);
  if (kd.dna != null) {
    if (!info.dna) return rom;
    _dnaStrip(out, kd, info);
    _dnaInstall(out, kd, blob, info.fieldMenu);
  } else if (!info.dna) {
    _foodInstall(out, kd, blob);
  }
  return out;
}

void _setFrom(Uint8List page, int at, Uint8List blob, int from) {
  if (from < blob.length) page.setRange(at, at + blob.length - from, blob, from);
}

/* Food part alone (Jade Forest): the code of the DNA part, only the values the food code reads. */
void _foodInstall(Uint8List out, _Kind kd, Uint8List blob) {
  final fd = kd.food!, page = Uint8List.sublistView(out, sixOff, sixOff + 0x1000);
  page.fillRange(_pDna, _dnaEnd, 0xFF);
  _setFrom(page, _pDna, blob, _pDna);
  page.fillRange(_pDna, _pDna + 0x40, 0);
  w32(page, _pDna, fd.ram);
  w16(page, _pDna + 6, fd.field);
  page[_pDna + 15] = fd.slots;
  w16(page, _pDna + 0x34, fd.hist);
  for (var i = 0; i < fd.kinds.length; i++) {
    page[_pDna + 0x36 + i] = fd.kinds[i];
  }
  w32(page, 32, u32(page, 32) | 64);
  _sitesPut(out, fd.sites, (k) => u32(page, _pDnaFn + 4 * k) & ~1);
}

void _foodStrip(Uint8List out, _Kind kd) {
  final fd = kd.food!, page = Uint8List.sublistView(out, sixOff, sixOff + 0x1000);
  for (final s in fd.sites) {
    _putHex(out, s.xip - 0x10000000 + 0x11000, s.orig);
  }
  w32(page, 32, u32(page, 32) & ~64);
  page.fillRange(_pDna, _dnaEnd, 0xFF);
}

void _sitesPut(Uint8List out, List<_Patch> sites, int Function(int) fn) {
  for (final s in sites) {
    final n = s.orig.length ~/ 2;
    final b = Uint8List(n);
    if (s.how == 'hex') {
      b.setAll(0, _hexBytes(s.bytes).take(n));
    } else {
      b.setAll(0, _branch(s.xip, fn(s.fn), s.how == 'bl'));
      for (var k = 4; k < n; k += 2) {
        w16(b, k, 0xBF00);
      }
    }
    out.setAll(s.xip - 0x10000000 + 0x11000, b);
  }
}

/* Puts the DNA part in (page at SIX_OFF of out, its code from blob) and patches the firmware. */
void _dnaInstall(Uint8List out, _Kind kd, Uint8List? blob, bool fieldMenu) {
  final d = kd.dna!;
  if (blob == null || blob.length <= _pDnaFn) throw StateError('six fields program missing');
  final page = Uint8List.sublistView(out, sixOff, sixOff + 0x1000);
  page.fillRange(_pDna, _dnaEnd, 0xFF);
  _setFrom(page, _pDna, blob, _pDna);
  w32(page, _pDna, d.base);
  w16(page, _pDna + 4, d.cnt);
  w16(page, _pDna + 6, d.field);
  w16(page, _pDna + 8, d.stash);
  w16(page, _pDna + 10, d.mark);
  w16(page, _pDna + 12, d.bits);
  page[_pDna + 14] = d.mask;
  page[_pDna + 15] = d.slots;
  page.fillRange(_pDna + 0x10, _pDna + 0x28, 0);
  for (var i = 0; i < d.regions.length; i++) {
    w16(page, _pDna + 0x10 + 4 * i, d.regions[i].$1);
    w16(page, _pDna + 0x12 + 4 * i, d.regions[i].$2);
  }
  for (var i = 0; i < d.icons.length; i++) {
    w16(page, _pDna + 0x28 + 2 * i, d.icons[i]);
  }
  final fd = d.food;
  if (_sixFoodOn && fd != null) {
    w16(page, _pDna + 0x34, fd.hist);
    for (var i = 0; i < fd.kinds.length; i++) {
      page[_pDna + 0x36 + i] = fd.kinds[i];
    }
  }
  w32(page, 32, u32(page, 32) | 8);
  int fn(int k) => u32(page, _pDnaFn + 4 * k) & ~1;
  _sitesPut(out, _dnaSites(d), fn);
  out.setAll(0x11000 + kd.childAt, _branch(_xip(0x11000 + kd.childAt), fn(_dnaChild), true));
  if (fieldMenu) out.setAll(0x11000 + kd.fm.set, _branch(0x10000000 + kd.fm.set, fn(_dnaFset), true));
}

/* Takes the DNA part out again (the firmware places as before, the six fields stay). */
void _dnaStrip(Uint8List out, _Kind kd, SixInfo info) {
  final d = kd.dna;
  if (d == null) return;
  final page = Uint8List.sublistView(out, sixOff, sixOff + 0x1000);
  for (final s in d.food != null ? [...d.sites, ...d.food!.sites] : d.sites) {
    _putHex(out, s.xip - 0x10000000 + 0x11000, s.orig);
  }
  int fn(int k) => u32(page, _pFn + 4 * k) & ~1;
  out.setAll(0x11000 + kd.childAt, _branch(_xip(0x11000 + kd.childAt), fn(_fnChild), true));
  if (info.fieldMenu) out.setAll(0x11000 + kd.fm.set, _branch(0x10000000 + kd.fm.set, u32(page, _pFmFn + 8) & ~1, true));
  w32(page, 32, u32(page, 32) & ~8);
  page.fillRange(_pDna, _dnaEnd, 0xFF);
}

/// DNA per field on or off for a ROM that has six fields already (no Land ROM needed). Returns the ROM
/// unchanged when there is nothing to do or the ROM cannot take it.
Uint8List sixDna(Uint8List rom, Uint8List? blob, bool on) {
  final info = sixInfo(rom);
  if (info != null && info.version >= 7 && on && (info.dna || _kinds[info.kind]!.dna == null)) return _sixFood(rom, blob);
  if (info != null && info.food && !on) {
    final o = Uint8List.fromList(rom);
    _foodStrip(o, _kinds[info.kind]!);
    return o;
  }
  if (info == null || info.version < 7 || info.dna == on) return rom;
  final kd = _kinds[info.kind]!, out = Uint8List.fromList(rom);
  if (!on) {
    _dnaStrip(out, kd, info);
    return out;
  }
  if (kd.dna == null || blob == null || _u32s(blob, _pDnaFn) == 0 || !_dnaCan(rom, kd)) return rom;
  _dnaInstall(out, kd, blob, info.fieldMenu);
  return out;
}

/// Can this ROM get DNA per field?
bool sixDnaCan(Uint8List rom) {
  final i = sixInfo(rom), k = i != null ? i.kind : kindOf(rom);
  return k != null && _kinds[k]!.dna != null;
}

/* rows of an original table with some rows replaced: table at XIP address, per row n values */
List<int> _rows(Uint8List rom, int addr, int n, int nrows, Map<int, List<int>> repl) {
  final o = addr - 0x10000000 + 0x11000, v = <int>[];
  for (var r = 0; r < nrows; r++) {
    for (var i = 0; i < n; i++) {
      final rp = repl[r];
      v.add(rp != null ? rp[i] : u16(rom, o + 2 * (n * r + i)));
    }
  }
  return v;
}

class _Field {
  _Field(this.row, this.base, this.sprs, this.ext);
  final List<int> row, sprs;
  final int base;
  final List<bool> ext;
}

/// More fields: returns a new image. rom: Tropical/Glacier or Jade Forest image without the menu
/// (call feldStrip first). land: the user's Land, Water or Sky image (only for Tropical/Glacier).
/// blob: six.bin.
Uint8List sixApply(Uint8List rom, Uint8List? land, Uint8List? blob, {bool planet = true, bool fieldMenu = true, bool games = true, bool dna = true, bool hunt = true, bool cook = true}) {
  final have = sixInfo(rom);
  final extraOpt = {'hunt': hunt, 'cook': cook};
  final wantGames = games && kindOf(rom) == 'gen3';
  final k0 = have != null ? have.kind : kindOf(rom);
  final wantDna = dna && k0 != null && _kinds[k0]!.dna != null;
  final wantFood = _sixFoodOn && dna;

  if (have != null && have.version >= sixVersion && !sixStale(have) && have.planet == planet && have.fieldMenu == fieldMenu && have.games == wantGames) {
    var r = sixDna(rom, blob, wantDna);
    if (wantFood) r = _sixFood(r, blob);
    return sixHunt(r);
  }
  if (have != null) rom = sixStrip(rom);
  final kind = kindOf(rom);
  if (kind != null && fieldMenu && !_fmCan(rom, _kinds[kind]!)) fieldMenu = false;
  if (kind == null || !sixCan(rom)) throw StateError('more fields need a Tropical, Glacier or Jade Forest ROM with the original firmware');
  if (blob == null || blob.length > 0x1000 || _u32s(blob, 0) != sixMagic || _u32s(blob, 4) != sixVersion) throw StateError('six fields program missing');
  final dnaOk = wantDna && _dnaCan(rom, _kinds[kind]);
  for (var i = sixOff; i < sixOff + 0x1000; i++) {
    if (rom[i] != 0xFF) throw StateError('area 0x10F000 is in use');
  }
  if (kind == 'jade') {
    final t = _openRom(rom), jt = _dpSplit(t.files[0]), ix = _words(jt[4]);
    if (ix.length <= 781 || _comp(jt, 773).firstOrNull != 0x1007) throw const FormatException('unexpected Jade Forest data');
    final alt = <String, Object>{
      'bg': _rows(rom, _kinds['jade']!.bgTable, 16, 3, {1: _jadeBg}),
      'child': _jadeChild,
      'teen': _rows(rom, 0x1007DFC4, 4, 3, {1: _jadeTeen}),
      'adult': _rows(rom, 0x1007DFDC, 16, 3, {1: _jadeAdult}),
      'speed': _rows(rom, 0x1008BCE8, 3, 3, {1: _jadeSpeed}),
      'egg': _rows(rom, 0x100820E8, 1, 3, {1: _jadeEgg}),
      'wagon': _rows(rom, 0x100820D0, 4, 3, {1: _jadeWagon}),
      'scene': _rows(rom, 0x10081198, 5, 3, {1: _jadeScene}),
      'spec1': 0x0FE40FE2, // Land 4066, Sky 4068 (Yayacorntchi) in the Water slot
    };
    // planet: Sky stages in the Water row (the field slot of Sky)
    alt['plTab'] = _rows(rom, 0x1008CBD0, 11, 3, {1: _skyPlanet});
    alt['pl0'] = _rows(rom, 0x100811DA, 11, 1, {});
    alt['pl1'] = _skyPlanet;
    alt['pl2'] = _rows(rom, 0x100811F0, 11, 1, {});
    for (final x in _extras) {
      if (extraOpt[x.name]! && _extraCan(rom, 'jade', x)) alt[x.name] = x.tab(rom, 'jade');
    }
    final outJ = _install(Uint8List.fromList(rom), 'jade', blob, alt, [0, 0, 0], planet, fieldMenu, null);
    if (dnaOk) {
      _dnaInstall(outJ, _kinds['jade']!, blob, fieldMenu);
    } else if (wantFood) {
      return _sixFood(outJ, blob);
    }
    return outJ;
  }
  if (land == null || !sixSource(land)) throw const FormatException('the second ROM must be a Land, Water or Sky ROM');
  final trop = rom;
  final t = _openRom(trop), l = _openRom(land);
  final tt = _dpSplit(t.files[0]), lt = _dpSplit(l.files[0]);
  int lw(int off) => u16(land, off);
  int lfw(int x) => 0x11000 + x - 0x10000000;
  // Land backgrounds: 3 fields x 10 composites (5 times of day x clear/rain), base before them
  final lbg = [for (var i = 0; i < 30; i++) lw(lfw(_landBg) + 2 * i)];
  final adult = [for (var i = 0; i < 48; i++) lw(lfw(_landAdult) + 2 * i)];
  final entries = List<Uint8List>.of(t.entries);
  final nspr0 = entries.length, ix = _words(tt[4]), cw = _words(tt[5]), ncomp0 = ix.length, nanim0 = _words(tt[13]).length;
  final compNew = <int, int>{}, sprNew = <int, int>{};
  final lix = _words(lt[4]), lcw = _words(lt[5]);
  List<int> lcomp(int i) => _slice(lcw, lix[i], i + 1 < lix.length ? lix[i + 1] : lcw.length);
  final fields = [
    for (var fi = 0; fi < 3; fi++)
      () {
        final row = lbg.sublist(10 * fi, 10 * fi + 10), base = row[0] - 1;
        final clear = [base, row[0], row[2], row[4], row[6], row[8]], rain = [row[1], row[3], row[5], row[7], row[9]];
        final sprs = <int>[], ext = <bool>[];
        for (final c in [...clear, ...rain]) {
          final w = lcomp(c);
          if (w.length < 4 || w[0] != 0x1007) throw FormatException('unexpected Land picture $c');
          if (!sprs.contains(w[3])) {
            sprs.add(w[3]);
            ext.add(!clear.contains(c));
          }
        }
        return _Field(row, base, sprs, ext);
      }(),
  ];
  final bList = <(int, List<int>)>[];
  final bData = <Uint8List>[];
  var bPos = 0;
  for (final fd in fields) {
    final group = [for (final i in fd.sprs) mapCells(l.entries[i])];
    final packed = packGroup(group, _kColors, fd.ext);
    for (var j = 0; j < fd.sprs.length; j++) {
      sprNew[fd.sprs[j]] = entries.length;
      final o = packed.outside[j];
      if (o != null) bList.add((entries.length, [for (final v in o) v < 0 ? -1 : v + bPos]));
      entries.add(packed.entries[j]);
    }
    bData.add(packed.bdata);
    bPos += packed.bdata.length;
    final pad = (4 - bPos % 4) % 4;
    if (pad != 0) {
      bData.add(Uint8List(pad));
      bPos += pad;
    }
  }
  final bHead = 8 + bList.length * 260;
  if (_bOff + bHead + bPos > _bEnd) throw StateError('rain pictures too big');
  int addComp(int c) {
    final h = compNew[c];
    if (h != null) return h;
    final w = lcomp(c);
    w[3] = sprNew[w[3]]!;
    final id = ix.length;
    ix.add(cw.length);
    cw.addAll(w);
    if ((cw.length & 1) != 0) cw.add(0);
    compNew[c] = id;
    return id;
  }

  final tBg = <int>[];
  for (final fd in fields) {
    final half = [addComp(fd.base)];
    for (var s = 0; s < 5; s++) {
      final c = addComp(fd.row[2 * s]), r = addComp(fd.row[2 * s + 1]);
      half.addAll([c, r, r]);
    }
    tBg.addAll(half);
    tBg.addAll(half);
  }
  if (cw.length > 0xFFFF) throw StateError('composite table full');
  tt[4] = _toBytes(ix);
  tt[5] = _toBytes(cw);
  // scenes: travel backgrounds, field eggs, scene animations, wagon
  final imp = _Importer(lt, l.entries, tt, t.entries, entries);
  final speed = [for (var i = 0; i < 9; i++) imp.anim(lw(lfw(_landSpeed) + 2 * i))];
  final ls = _Scripts(lt);
  int firstPic(int a, [int d = 0]) {
    for (final o in _parseScript(ls.get(a))) {
      if ((o.mask & 0x80) != 0 && o.p.isNotEmpty && o.op == 1) return o.p[0];
      if ((o.mask & 0x80) != 0 && o.p.isNotEmpty && o.op == 16 && d < 4) {
        final r = firstPic(o.p[0], d + 1);
        if (r >= 0) return r;
      }
    }
    return -1;
  }

  final egg = [for (var fi = 0; fi < 3; fi++) imp.anim(_landEgg + fi)];
  final eggPic = [
    for (var fi = 0; fi < 3; fi++)
      () {
        final p = firstPic(_landEgg + fi);
        if (p < 0) throw FormatException('unexpected Land picture ${_landEgg + fi}');
        return imp.sprite(p);
      }(),
  ];
  final scene = <int>[], wagon = <int>[], tw = _rows(trop, 0x10095778, 4, 3, {});
  for (var fi = 0; fi < 3; fi++) {
    for (var k = 0; k < _landScene.length; k++) {
      scene.add(k > 0 ? imp.sprite(_landScene[k] + fi) : imp.anim(_landScene[k] + fi));
    }
    wagon.addAll([imp.anim(_landWagon[0] + fi), imp.anim(_landWagon[1] + fi), tw[4 * fi + 2], tw[4 * fi + 3]]);
  }
  imp.done();
  // lab games per start field: Land pictures go in with the rest, the site list after the rain cells
  _Games? gm;
  final gBase = (_bOff + bHead + bPos + 0xFFF) & ~0xFFF;
  if (games) {
    final x = _Translator(lt, l.entries, tt, entries);
    gm = _gamesBuild(trop, x, gBase);
    x.done();
    if (gBase + gm.bytes.length > _bEnd) throw StateError('rain pictures too big');
  }
  for (final (a, n) in _tropMaps) {
    for (var i = a; i < a + n; i++) {
      entries[i] = reduceOne(entries[i], _kColors);
    }
  }
  final out = _buildRom(trop, entries, t.files[2], t.limit, t.assetEnd, _dpJoin(tt));
  final alt = <String, Object>{
    'bg': tBg,
    'child': const [2002, 2003, 2004],
    'teen': [for (var i = 0; i < 12; i++) 3005 + i],
    'adult': adult,
    'speed': speed,
    'egg': egg,
    'eggPic': eggPic,
    'scene': scene,
    'wagon': wagon,
    'spec1': 0x0FE30FE2,
    'spec2': 0x0FE40FE4, // specials Chodracotchi 4066, Mermarintchi 4067, Yayacorntchi 4068
  };
  // planet stages of Land, Water, Sky (from the Land ROM, the same in all three)
  final plTab = [for (var i = 0; i < 33; i++) lw(lfw(_landPlanet) + 2 * i)];
  if (plTab[0] != 2 || plTab[11] != 2 || plTab[22] != 2) throw const FormatException('unexpected Land planet table');
  alt['plTab'] = plTab;
  alt['pl0'] = plTab.sublist(0, 11);
  alt['pl1'] = plTab.sublist(11, 22);
  alt['pl2'] = plTab.sublist(22, 33);
  for (final x in _extras) {
    if (extraOpt[x.name]! && _extraCan(trop, 'gen3', x)) alt[x.name] = x.tab(trop, 'gen3');
  }
  _install(out, 'gen3', blob, alt, [nspr0, ncomp0, nanim0], planet, fieldMenu, gm);
  if (dnaOk) _dnaInstall(out, _kinds['gen3']!, blob, fieldMenu);
  // region B: rain cells
  for (var i = _bOff; i < _bEnd; i++) {
    if (trop[i] != 0xFF) throw StateError('area 0xF00000 is in use');
  }
  final bh = Uint8List(bHead);
  w32(bh, 0, _bMagic);
  w32(bh, 4, bList.length);
  for (var k = 0; k < bList.length; k++) {
    final o = 8 + k * 260;
    final (id, rel) = bList[k];
    w32(bh, o, id);
    for (var c = 0; c < rel.length; c++) {
      w32(bh, o + 4 + 4 * c, rel[c] < 0 ? 0xFFFFFFFF : rel[c]);
    }
  }
  out.setAll(_bOff, bh);
  out.setAll(_bOff + bHead, _concat(bData));
  if (gm != null) out.setAll(gBase, gm.bytes);
  return sixFix(out);
}

/// Points the rain pictures at their cells in region B again (call after every archive rebuild).
Uint8List sixFix(Uint8List rom) {
  if (sixInfo(rom) == null || u32(rom, _bOff) != _bMagic) return rom;
  final out = Uint8List.fromList(rom), n = u32(out, _bOff + 4), data = _bOff + 8 + n * 260;
  final pack = 0x111000 + u32(out, 0x111000 + 16 + 16 + 4);
  for (var k = 0; k < n; k++) {
    final o = _bOff + 8 + k * 260, id = u32(out, o), h = pack + u32(out, pack + 4 * id), pix = h + u16(out, h + 20);
    for (var t = 0; t < 64; t++) {
      final r = u32(out, o + 4 + 4 * t);
      if (r != 0xFFFFFFFF) w32(out, pix + 8 * t, data + r - pix);
    }
  }
  w32(out, 0x111004, _arc2Checksum(out, 0x111000, u32(out, 0x111008))); // archive checksum
  return out;
}
