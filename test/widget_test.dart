import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tama_tools/emu/cpu.dart';
import 'package:tama_tools/emu/plink.dart';
import 'package:tama_tools/emu/rom_info.dart';

class _Host extends CpuHost {
  int pins = 0;
  @override
  void setLcdPin(int seg, int com, bool on) => pins++;
  @override
  void setBuzzerFreq(int code) {}
  @override
  void enableBuzzer(bool on) {}
  @override
  void buzzerShot(bool on) {}
}

void main() {
  test('a tiny program writes the display and halts on the clock interrupt', () {
    // LD X 0x00 / LD XP A (A=0xE via LD A,#E) ... keep it simple: loop writing M(X) with X in display RAM
    final p = Uint16List(8192);
    var i = 0x100; // reset vector: page 1, step 0
    p[i++] = 0xE00 | (0 << 4) | 0xE; // LD A,#E
    p[i++] = 0xE80 | 0; // LD XP,A  -> XP = E
    p[i++] = 0xB00 | 0x00; // LD X,#00 -> X = E00
    p[i++] = 0xE60 | 0xF; // LDPX MX,#F (display)
    p[i++] = 0xFF8; // HALT (no interrupts enabled: stays halted, time goes on)
    final h = _Host();
    final c = Cpu(p, h);
    for (var k = 0; k < 10; k++) {
      c.step();
    }
    expect(c.memory[0xE00], 0xF);
    expect(h.pins, 4);
    expect(c.halted, isTrue);
    final t0 = c.tickCounter;
    c.runUntil(t0 + 32768);
    expect(c.tickCounter, greaterThanOrEqualTo(t0 + 32768));
    final s = c.saveState();
    final c2 = Cpu(p, h)..loadState(s);
    expect(c2.tickCounter, c.tickCounter);
    expect(c2.memory[0xE00], 0xF);
  });

  test('plink frames round-trip', () {
    final got = <List<int>>[];
    final codec = PlinkCodec((t, d) => got.add([t, ...d]));
    codec.feed([0x00, ...PlinkCodec.encode(0x44, [1, 2, 3, 4, 5]), 0x13, ...PlinkCodec.encode(0x48, [0])]);
    expect(got, [
      [0x44, 1, 2, 3, 4, 5]
    ]);
  });

  test('ROM kinds', () {
    expect(detectKind(Uint8List(0x3000)), RomKind.e0c6s4x);
    expect(detectKind(Uint8List(0x1000000)), RomKind.paradise);
    expect(detectKind(Uint8List(100)), RomKind.other);
  });
}
