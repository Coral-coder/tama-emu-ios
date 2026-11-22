// LCD wiring and buzzer of the first Tamagotchis: a Dart port of TamaLIB's hw.c (GPL-2.0-or-later,
// Jean-Christophe Rona) with mameise's Paramix additions (Digimon wiring, Yasashii direct columns,
// one segment per menu icon for Umino, Genjintchi, Tamaotch and Mothra).

import 'dart:typed_data';

const int lcdWidth = 32;
const int lcdHeight = 16;
const int iconCount = 8;

enum LcdWiring { p1, digimon, direct, iconSeg }

// SEG -> column (values >= 32 are icon segments), E0C6S48 table (51 segments)
const List<int> _segPos = [
  0, 1, 2, 3, 4, 5, 6, 7, 32, 8, 9, 10, 11, 12, 13, 14, 15, 33, 34, 35, 31, 30, 29, 28, 27, 26, 25, 24, 36, 23, //
  22, 21, 20, 19, 18, 17, 16, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50,
];
const List<int> _segPosDigi = [
  40, 0, 1, 2, 3, 4, 5, 6, 7, 41, 42, 43, 8, 9, 10, 11, 12, 13, 14, 15, 31, 30, 29, 28, 27, 26, 25, 24, 44, 23, //
  22, 21, 20, 19, 18, 17, 16, 45, 46, 47,
];

/// Buzzer frequency codes 0..7 in deci-hertz.
const List<int> buzzerFreqDhz = [40960, 32768, 27307, 23406, 20480, 16384, 13653, 11703];

class LcdState {
  /// [y * 32 + x] = 1 when the dot is on.
  final Uint8List matrix = Uint8List(lcdWidth * lcdHeight);
  final Uint8List icons = Uint8List(iconCount);
  final Uint16List _iconMask = Uint16List(iconCount);
  LcdWiring wiring = LcdWiring.p1;
  bool dirty = true;

  void clear() {
    matrix.fillRange(0, matrix.length, 0);
    icons.fillRange(0, icons.length, 0);
    _iconMask.fillRange(0, _iconMask.length, 0);
    dirty = true;
  }

  void _dot(int x, int y, bool on) {
    final i = y * lcdWidth + x;
    final v = on ? 1 : 0;
    if (matrix[i] != v) {
      matrix[i] = v;
      dirty = true;
    }
  }

  void _icon(int i, bool on) {
    final v = on ? 1 : 0;
    if (icons[i] != v) {
      icons[i] = v;
      dirty = true;
    }
  }

  void setPin(int seg, int com, bool on) {
    switch (wiring) {
      case LcdWiring.direct:
        if (seg < lcdWidth) _dot(seg, com, on);
        return;
      case LcdWiring.iconSeg:
        if (seg < _segPos.length && _segPos[seg] >= lcdWidth) {
          final i = com < 8
              ? (seg == 8 ? 0 : seg == 17 ? 1 : seg == 18 ? 2 : seg == 19 ? 3 : -1)
              : (seg == 39 ? 4 : seg == 38 ? 5 : seg == 37 ? 6 : seg == 28 ? 7 : -1);
          if (i >= 0 && com < 16) {
            if (on) {
              _iconMask[i] |= 1 << com;
            } else {
              _iconMask[i] &= ~(1 << com);
            }
            _icon(i, _iconMask[i] != 0);
          }
          return;
        }
        break;
      case LcdWiring.digimon:
        if (seg < 40 && _segPosDigi[seg] < lcdWidth) {
          _dot(_segPosDigi[seg], com, on);
        } else if (com == 15 && (seg == 28 || (seg >= 37 && seg <= 39))) {
          _icon(seg == 28 ? 0 : seg - 36, on);
        } else if (com == 0 && seg >= 9 && seg <= 11) {
          _icon(15 - seg, on);
        } else if (com == 0 && seg == 0) {
          _icon(7, on);
        }
        return;
      case LcdWiring.p1:
        break;
    }
    if (seg >= _segPos.length) return;
    final pos = _segPos[seg];
    if (pos < lcdWidth) {
      _dot(pos, com, on);
    } else if (seg == 8 && com < 4) {
      _icon(com, on);
    } else if (seg == 28 && com >= 12) {
      _icon(com - 8, on);
    }
  }
}
