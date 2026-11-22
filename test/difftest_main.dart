// Differential test driver: runs a program with the Dart core and prints the same state lines as
// the C harness (tool/difftest). Usage: dart run test/difftest_main.dart rom.bin steps
import 'dart:io';
import 'dart:typed_data';
import 'package:tama_tools/emu/cpu.dart';
import 'package:tama_tools/emu/hw.dart';

int lcdh = 0;
class H extends CpuHost {
  final lcd = LcdState();
  @override
  void setLcdPin(int seg, int com, bool on) {
    // Hash the C way: the HAL sees mapped dots / icons
    final before = Uint8List.fromList(lcd.matrix), ib = Uint8List.fromList(lcd.icons);
    lcd.setPin(seg, com, on);
    // replicate the HAL call: C calls set_lcd_matrix or set_lcd_icon for every mapped pin, changed or not
    final m = mapped(seg, com);
    if (m != null) {
      if (m[0] == 0) { lcdh = (lcdh * 31 + m[1] * 64 + m[2] * 2 + (on ? 1 : 0)) & 0xFFFFFFFF; }
      else { lcdh = (lcdh * 31 + 1000 + m[1] * 2 + (on ? 1 : 0)) & 0xFFFFFFFF; }
    }
    before; ib;
  }
  List<int>? mapped(int seg, int com) {
    const sp = [0, 1, 2, 3, 4, 5, 6, 7, 32, 8, 9, 10, 11, 12, 13, 14, 15, 33, 34, 35, 31, 30, 29, 28, 27, 26, 25, 24, 36, 23, 22, 21, 20, 19, 18, 17, 16, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50];
    if (sp[seg] < 32) return [0, sp[seg], com];
    if (seg == 8 && com < 4) return [1, com];
    if (seg == 28 && com >= 12) return [1, com - 8];
    return null;
  }
  @override
  void setBuzzerFreq(int code) { lcdh = (lcdh * 31 + buzzerFreqDhz[code]) & 0xFFFFFFFF; }
  @override
  void enableBuzzer(bool on) { bz = on; lcdh = (lcdh * 31 + 7 + ((bz || shot) ? 1 : 0)) & 0xFFFFFFFF; }
  @override
  void buzzerShot(bool on) { shot = on; lcdh = (lcdh * 31 + 7 + ((bz || shot) ? 1 : 0)) & 0xFFFFFFFF; }
  bool bz = false, shot = false;
}

void main(List<String> args) {
  final buf = File(args[0]).readAsBytesSync();
  final prog = Uint16List(8192);
  for (var i = 0; i < buf.length ~/ 2; i++) { prog[i] = ((buf[2 * i] << 8) | buf[2 * i + 1]) & 0xFFF; }
  final steps = int.parse(args[1]);
  final h = H();
  final c = Cpu(prog, h)..fastHalt = false;
  final out = StringBuffer();
  const pins = [2, 1, 0, 3]; // BTN_LEFT=K02, MIDDLE=K01, RIGHT=K00, TAP=K03
  for (var k = 1; k <= steps; k++) {
    if (k % 5000 == 1) { final btn = (k ~/ 5000) % 4; final pressed = ((k ~/ 5000) ~/ 4) % 2 == 1; c.setInputPin(pins[btn], !pressed); }
    if (!c.step()) { out.writeln('fault $k'); break; }
    if (k % 1000 == 0) {
      var hh = 0;
      for (final r in [[0, 0x300], [0xE00, 0xE66], [0xE80, 0xEE6], [0xF00, 0xF80]]) { for (var i = r[0]; i < r[1]; i++) { hh = (hh * 131 + c.memory[i]) & 0xFFFFFFFF; } }
      String hx(int v) => v.toRadixString(16);
      out.writeln('$k pc=${hx(c.pc)} x=${hx(c.x)} y=${hx(c.y)} a=${hx(c.a)} b=${hx(c.b)} sp=${hx(c.sp)} f=${hx(c.flags)} np=${hx(c.np)} t=${c.tickCounter & 0xFFFFFFFF} hl=${c.halted ? 1 : 0} mem=${hh.toRadixString(16).padLeft(8, '0')} lcd=${lcdh.toRadixString(16).padLeft(8, '0')}');
    }
  }
  stdout.write(out);
}
