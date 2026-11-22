// The Paramix link protocol (plink.h by mameise, GPL-3.0): frames A5 type len data sum, sum =
// type + len + data (low byte); 5A is taken as a start byte too. 'H' hello every second; 'D' frames
// carry the edges of the toy's contact (P20): level, time in microseconds (u32, little endian).
//
// The same frames go over a real UART (to a Paradise running V1Emu, 460800 8N1) or through the
// internet tunnel to another phone, so an emulated toy can meet an emulated or a real one.

import 'dart:typed_data';

typedef FrameHandler = void Function(int type, Uint8List data);

class PlinkCodec {
  PlinkCodec(this.onFrame);

  final FrameHandler onFrame;
  int _st = 0, _ty = 0, _len = 0, _pos = 0, _sum = 0;
  final Uint8List _f = Uint8List(64);
  DateTime? lastRx;

  static Uint8List encode(int type, List<int> data) {
    final out = Uint8List(data.length + 4);
    out[0] = 0xA5;
    out[1] = type;
    out[2] = data.length;
    var s = (type + data.length) & 0xFF;
    for (var i = 0; i < data.length; i++) {
      out[3 + i] = data[i];
      s = (s + data[i]) & 0xFF;
    }
    out[out.length - 1] = s;
    return out;
  }

  void feed(List<int> bytes) {
    for (final b in bytes) {
      switch (_st) {
        case 0:
          if (b == 0xA5 || b == 0x5A) _st = 1;
          break;
        case 1:
          _ty = b;
          _sum = b;
          _st = 2;
          break;
        case 2:
          if (b > 64) {
            _st = 0;
            break;
          }
          _len = b;
          _pos = 0;
          _sum = (_sum + b) & 0xFF;
          _st = b != 0 ? 3 : 4;
          break;
        case 3:
          _f[_pos++] = b;
          _sum = (_sum + b) & 0xFF;
          if (_pos >= _len) _st = 4;
          break;
        default:
          _st = 0;
          if (b != _sum) break; // noise on an open contact
          lastRx = DateTime.now();
          if (_ty != 0x48 /* H */ && _ty != 0x50 /* P */) onFrame(_ty, Uint8List.fromList(_f.sublist(0, _len)));
          break;
      }
    }
  }
}

/// Replays the other toy's edges at their time plus an offset (V1Emu's v1_link_in): the pulse
/// lengths stay exact, the transport only shifts them.
class LinkPlayback {
  static const int lead = 20000; // us
  final List<(int, bool)> _q = [];
  bool _low = false;
  int _have = 0;
  int _off = 0;
  int _lastRt = 0;

  void push(bool low, int tUs) {
    if (_q.length >= 64) _q.removeAt(0);
    _q.add((tUs, low));
  }

  bool lineLow(int nowUs) {
    while (_q.isNotEmpty) {
      final (rt, low) = _q.first;
      if (_have == 0 || (_s32(rt - _lastRt) > 30000 && _have != 2)) {
        _off = _s32(nowUs - rt) + lead;
        _have = 2;
      }
      if (_s32(nowUs - (rt + _off)) < 0) break;
      _low = low;
      _lastRt = rt;
      _q.removeAt(0);
      _have = 1;
    }
    return _low;
  }

  void reset() {
    _q.clear();
    _low = false;
    _have = 0;
  }

  static int _s32(int v) => (v & 0xFFFFFFFF).toSigned(32);
}
