// Paradise editions: a port of the edition detection of Paramix Studio's feld.js (mameise, GPL-3.0).
// ID page: word 0 = ID, footer at +0xFF8: k with k + ID = profile constant, then ~k.

import 'dart:typed_data';

import 'bytes.dart';

const int edGen34 = 7; // Tropical/Glacier family with ID 4 (Forest or Sky home)
const int cleanId = 0xEFD000; // ID page of a "clean" ROM (start device without the Paradise)
const int sixOff = 0x10F000, sixMagic = 0x31584953;

const Map<int, String> editionNames = {
  1: 'Land',
  2: 'Water',
  3: 'Sky',
  4: 'Jade Forest',
  5: 'Tropical',
  6: 'Glacier',
  7: 'Tropical/Glacier',
  8: 'Neon Planets',
};

class EditionProfile {
  const EditionProfile(this.name, this.idPage, this.edIds, this.c, {this.ring = false, this.fields = const [], this.tama = 0, this.level = 0, this.bag = const []});
  final String name;
  final int idPage;
  final List<int> edIds;
  final int c;
  final bool ring; // Neon Planets: settings ring, planets switch in the game
  final List<String> fields;
  final int tama, level;
  final List<int> bag; // money, item list, item counts

  bool get isGen3 => name == 'gen3';
}

const List<EditionProfile> profiles = [
  EditionProfile('gen1', 0xD49000, [1, 2, 3], 0x70169E2C, fields: ['Land', 'Water', 'Sky'], tama: 0x104, level: 0x7C, bag: [0xb4, 0x240, 0x740]),
  EditionProfile('jade', 0xD49000, [4], 0x849633DB, fields: ['Land', 'Water', 'Forest'], tama: 0x108, level: 0x7C, bag: [0xb4, 0x244, 0x744]),
  EditionProfile('gen3', 0xD29000, [5, 6], 0x96CB83B8, fields: ['Tropical', 'Glacier', 'Forest'], tama: 0x114, level: 0x88, bag: [0xc0, 0x270, 0x770]),
  EditionProfile('neon', 0xD85000, [8], 0x99431749, ring: true, fields: ['Cosmic', 'New Tama', 'Tama'], tama: 0x114, level: 0x88, bag: [0xc0, 0x284, 0x784]),
];

class Edition {
  Edition(this.profile, this.id, this.at);
  final EditionProfile profile;
  final int id;
  final int at;
  String get name => editionNames[id] ?? 'Edition $id';
}

bool isSix(Uint8List rom) => rom.length > sixOff + 4 && u32(rom, sixOff) == sixMagic;
bool isParadiseImage(Uint8List rom) => rom.length == 0x1000000 && asciiAt(rom, 0, 8) == 'SONIXDEV';

bool _footer(Uint8List rom, int a, int id, int c) {
  final k = u32(rom, a + 0xFF8);
  return ((k + id) & 0xFFFFFFFF) == c && u32(rom, a + 0xFFC) == (~k & 0xFFFFFFFF);
}

/// Edition of a ROM image, or null.
Edition? edition(Uint8List rom) {
  final neon = profiles.firstWhere((p) => p.ring);
  for (final at in [neon.idPage, cleanId]) {
    if (at + 0x1000 <= rom.length && u32(rom, at) == 7 && _footer(rom, at, 7, neon.c)) return Edition(neon, 8, at);
  }
  for (final at in [null, cleanId]) {
    for (final p in profiles.reversed) {
      if (p.ring) continue;
      final a = at ?? p.idPage;
      if (a + 0x1000 > rom.length) continue;
      final id = u32(rom, a);
      if (p.edIds.contains(id) && _footer(rom, a, id, p.c)) return Edition(p, id, a);
      if (p.isGen3 && id == 4 && _footer(rom, a, 4, p.c)) return Edition(p, edGen34, a);
    }
  }
  for (final p in profiles) {
    if (p.ring) continue;
    if (p.idPage + 4 > rom.length) continue;
    final id = u32(rom, p.idPage);
    if (p.edIds.contains(id)) return Edition(p, id, p.idPage);
  }
  return null;
}

/// Family of an edition ID (same firmware, only the active field differs).
String? familyOf(int id) {
  if (id == edGen34) return 'gen3';
  for (final p in profiles) {
    if (p.edIds.contains(id)) return p.name;
  }
  return null;
}
