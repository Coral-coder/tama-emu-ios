import 'dart:typed_data';

import 'hw.dart';
import 'rom_db.dart';

/// What kind of file a ROM is.
enum RomKind {
  /// E0C6S46 / E0C6S48 program (P1, P2, Angel, Digimon ...): playable in the emulator.
  e0c6s4x,

  /// 16 MB Tamagotchi Paradise flash image: opened in Paramix Studio.
  paradise,

  /// Anything else (colour Tamagotchi firmware, Tama-Go, figures ...): Studio material.
  other,
}

int fnv1a(Uint8List b) {
  var h = 2166136261;
  for (final x in b) {
    h = ((h ^ x) * 16777619) & 0xFFFFFFFF;
  }
  return h;
}

RomKind detectKind(Uint8List b) {
  if (b.length == 0x3000 || b.length == 0x4000) {
    var ok = true;
    for (var i = 0; i < b.length; i += 2) {
      if (b[i] > 0x0F) {
        ok = false;
        break;
      }
    }
    if (ok) return RomKind.e0c6s4x;
  }
  if (b.length == 0x1000000) return RomKind.paradise;
  return RomKind.other;
}

/// Edition of a Paradise flash image, from its strings (best effort).
String? paradiseEdition(Uint8List b) {
  const names = ['Neon', 'Glacier', 'Tropical', 'Jade', 'Land', 'Water', 'Sky'];
  // The editions differ in their field names; a quick scan of the first MB for them.
  final n = b.length < 0x200000 ? b.length : 0x200000;
  final s = String.fromCharCodes(b.sublist(0, n).map((c) => c >= 32 && c < 127 ? c : 32));
  for (final e in names) {
    if (s.contains(e)) return e;
  }
  return null;
}

/// How the emulator has to treat one E0C6S4x ROM (as V1Emu in Paramix Studio does).
class ToyProfile {
  ToyProfile(this.rom)
      : hash = fnv1a(rom),
        program = _words(rom) {
    name = kRomNames[hash] ?? (rom.length == 0x3000 ? 'TAMA 46' : 'TAMA 48');
  }

  final Uint8List rom;
  final int hash;
  final Uint16List program;
  late final String name;

  String get id => hash.toRadixString(16).padLeft(8, '0');
  bool get isDigimon => name.startsWith('DIGIMON');
  bool get isMothra => name == 'MOTHRA';
  bool get turned => isDigimon || name == 'YASASHII';
  bool get knowsClock => kClockRoms.contains(name);
  bool get clock12 => isDigimon || isMothra;
  int get clockBase => clock12 ? 0x1A : 0x10;

  LcdWiring get wiring {
    if (isDigimon) return LcdWiring.digimon;
    if (name == 'YASASHII') return LcdWiring.direct;
    if (kIconSegRoms.contains(name)) return LcdWiring.iconSeg;
    return LcdWiring.p1;
  }

  /// Keys the toy needs to get its clock running on a fresh start (then the time is written).
  List<int> get clockSetKeys {
    if (isDigimon) return [1, 2]; // B, C
    if (isMothra) return [1, 0, 2]; // B, A, C
    return [1, 1, 1, 0, 2]; // B, B, B, A, C
  }

  /// The pictures for the eight icon places.
  List<List<int>> get icons {
    final set = kIconSets[name] ?? (isDigimon ? kIconSets['DIGIMON'] : null);
    if (set != null) return set;
    final p = kIconSets['P']!;
    return turned ? p.reversed.toList() : p;
  }

  String get displayName {
    const pretty = {
      'TAMA P1': 'Tamagotchi P1',
      'TAMA P1 EN': 'Tamagotchi P1 (EN)',
      'TAMA P2': 'Tamagotchi P2',
      'ANGEL': 'Angelgotchi',
      'GENJIN': 'Genjintchi',
      'MORINO': 'Mori de Hakken!! Tamagotchi',
      'TAMAOTCH': 'Osutchi & Mesutchi',
      'UMINO': 'Umi de Hakken!! Tamagotchi',
      'YASASHII': 'Yasashii Tamagotchi',
      'DIGIMON V1': 'Digital Monster V1',
      'DIGIMON V2': 'Digital Monster V2',
      'DIGIMON V3': 'Digital Monster V3',
      'MOTHRA': 'Mosuratchi',
      'TAMA 46': 'E0C6S46 toy',
      'TAMA 48': 'E0C6S48 toy',
    };
    return pretty[name] ?? name;
  }

  static Uint16List _words(Uint8List b) {
    final p = Uint16List(8192);
    final n = (b.length ~/ 2).clamp(0, 8192);
    for (var i = 0; i < n; i++) {
      p[i] = ((b[2 * i] << 8) | b[2 * i + 1]) & 0xFFF;
    }
    return p;
  }
}
