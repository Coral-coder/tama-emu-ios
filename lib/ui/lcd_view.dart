import 'package:material_ui/material_ui.dart';

import '../emu/hw.dart';
import '../emu/machine.dart';
import 'theme.dart';

/// The toy's screen: four icons above, the 32x16 dots, four icons below.
class LcdView extends StatelessWidget {
  const LcdView({super.key, required this.machine, this.ghost = true});

  final TamaMachine machine;
  final bool ghost;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 32 / 26,
      child: RepaintBoundary(
        child: ListenableBuilder(
          listenable: machine,
          builder: (context, _) => CustomPaint(painter: _LcdPainter(machine, ghost)),
        ),
      ),
    );
  }
}

class _LcdPainter extends CustomPainter {
  _LcdPainter(this.m, this.ghost) : _stamp = Object.hashAll([...m.lcd.matrix, ...m.lcd.icons]);

  final TamaMachine m;
  final bool ghost;
  final int _stamp;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = kLcdBg;
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(size.width * 0.03)), bg);
    // Layout in "dot" units: width 32, height 26 = 4.5 icon + 1 gap + 16 dots + 1 gap + 4.5 icon (icons 4 dots tall)
    final u = size.width / 32;
    final on = Paint()..color = kLcdOn;
    final off = Paint()..color = kLcdOff;
    final turned = m.profile.turned;
    final digi = m.profile.isDigimon;
    final top = u * 5;
    final mat = m.lcd.matrix;
    final gap = u * 0.1;
    for (var y = 0; y < lcdHeight; y++) {
      for (var x = 0; x < lcdWidth; x++) {
        final sx = turned ? 31 - x : x, sy = turned ? 15 - y : y;
        final lit = mat[sy * lcdWidth + sx] != 0;
        if (!lit && !ghost) continue;
        canvas.drawRect(Rect.fromLTWH(x * u + gap, top + y * u + gap, u - 2 * gap, u - 2 * gap), lit ? on : off);
      }
    }
    // icons, 16x16 pictures scaled to 4 dots
    final icons = m.profile.icons;
    final iu = u * 4 / 16;
    for (var place = 0; place < 8; place++) {
      final row = place < 4 ? 0 : 1;
      final col = place % 4;
      final lit = m.lcd.icons[digi ? place : (turned ? 7 - place : place)] != 0;
      if (!lit && !ghost) continue;
      final ox = col * 8 * u + 2 * u;
      final oy = row == 0 ? u * 0.5 : top + 16 * u + u * 0.5;
      final p = lit ? on : off;
      final pic = icons[place];
      for (var r = 0; r < 16; r++) {
        final bits = pic[r];
        if (bits == 0) continue;
        for (var b = 0; b < 16; b++) {
          if (bits & (0x8000 >> b) != 0) canvas.drawRect(Rect.fromLTWH(ox + b * iu, oy + r * iu, iu, iu), p);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_LcdPainter old) => old._stamp != _stamp || old.ghost != ghost;
}
