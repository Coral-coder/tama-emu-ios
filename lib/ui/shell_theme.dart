import 'dart:convert';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// How the dial's face is painted.
enum DialPattern {
  solid('Solid'),
  stripes('Stripes'),
  rays('Rays'),
  dots('Dots'),
  checker('Checker'),
  swirl('Swirl'),
  stars('Stars');

  const DialPattern(this.label);
  final String label;
}

/// The app coloured like a toy: the shell (one colour, or two split halfway down), the buttons,
/// and the dial (up to four colours in a pattern).
class ShellTheme {
  const ShellTheme({
    required this.name,
    required this.shell,
    this.shell2,
    required this.buttons,
    required this.dial,
    this.pattern = DialPattern.solid,
  });

  final String name;
  final Color shell;
  final Color? shell2; // the lower half, when the shell is split
  final Color buttons;
  final List<Color> dial; // 1 to 4
  final DialPattern pattern;

  bool get split => shell2 != null;
  Color get lower => shell2 ?? shell;

  /// Text and icons on the shell: dark on a light shell, light on a dark one.
  Color get onShell => shell.computeLuminance() > 0.45 ? const Color(0xFF2A1E2E) : Colors.white;
  Color get onButtons => buttons.computeLuminance() > 0.45 ? const Color(0xFF2A1E2E) : Colors.white;

  ShellTheme copyWith({String? name, Color? shell, Color? shell2, bool clearShell2 = false, Color? buttons, List<Color>? dial, DialPattern? pattern}) =>
      ShellTheme(
        name: name ?? this.name,
        shell: shell ?? this.shell,
        shell2: clearShell2 ? null : (shell2 ?? this.shell2),
        buttons: buttons ?? this.buttons,
        dial: dial ?? this.dial,
        pattern: pattern ?? this.pattern,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'shell': shell.toARGB32(),
        if (shell2 != null) 'shell2': shell2!.toARGB32(),
        'buttons': buttons.toARGB32(),
        'dial': [for (final c in dial) c.toARGB32()],
        'pattern': pattern.name,
      };

  static ShellTheme fromJson(Map<String, dynamic> j) => ShellTheme(
        name: j['name'] as String? ?? 'Mine',
        shell: Color(j['shell'] as int),
        shell2: j['shell2'] == null ? null : Color(j['shell2'] as int),
        buttons: Color(j['buttons'] as int),
        dial: [for (final c in (j['dial'] as List)) Color(c as int)],
        pattern: DialPattern.values.firstWhere((p) => p.name == j['pattern'], orElse: () => DialPattern.solid),
      );

  String encode() => jsonEncode(toJson());
  static ShellTheme? decode(String? s) {
    if (s == null) return null;
    try {
      return fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static const presets = [
    ShellTheme(name: 'Bubblegum', shell: Color(0xFFFF8CC6), shell2: Color(0xFFB98CFF), buttons: Color(0xFFFFE066), dial: [Color(0xFFFFFFFF), Color(0xFFFF8CC6)], pattern: DialPattern.stripes),
    ShellTheme(name: 'Night sky', shell: Color(0xFF1B1F3B), shell2: Color(0xFF3A2C6B), buttons: Color(0xFFFFB000), dial: [Color(0xFF3A2C6B), Color(0xFFFFE066)], pattern: DialPattern.stars),
    ShellTheme(name: 'Mint', shell: Color(0xFF8EE3C8), buttons: Color(0xFFFF7A90), dial: [Color(0xFFFFFFFF), Color(0xFF8EE3C8), Color(0xFFFF7A90)], pattern: DialPattern.dots),
    ShellTheme(name: 'Sunny', shell: Color(0xFFFFD447), shell2: Color(0xFFFF9F43), buttons: Color(0xFF4AA3FF), dial: [Color(0xFFFF9F43), Color(0xFFFFFFFF)], pattern: DialPattern.rays),
    ShellTheme(name: 'Ocean', shell: Color(0xFF3EC1F3), shell2: Color(0xFF2F6BFF), buttons: Color(0xFFFFFFFF), dial: [Color(0xFF2F6BFF), Color(0xFF3EC1F3), Color(0xFFFFFFFF), Color(0xFF9BE7FF)], pattern: DialPattern.swirl),
    ShellTheme(name: 'Classic', shell: Color(0xFF16171A), buttons: Color(0xFFFFB000), dial: [Color(0xFF3B342D)], pattern: DialPattern.solid),
    ShellTheme(name: 'Lilac', shell: Color(0xFFCDB4FF), buttons: Color(0xFF7B5CFF), dial: [Color(0xFFFFFFFF), Color(0xFFCDB4FF)], pattern: DialPattern.checker),
    ShellTheme(name: 'Melon', shell: Color(0xFFB6F27A), shell2: Color(0xFFFF8C8C), buttons: Color(0xFF2E2A2A), dial: [Color(0xFFFF8C8C), Color(0xFFB6F27A)], pattern: DialPattern.stripes),
  ];

  static const swatches = [
    Color(0xFFFFFFFF), Color(0xFFF2EDE4), Color(0xFFFFD1E8), Color(0xFFFF8CC6), Color(0xFFFF4F9A), Color(0xFFFF7A90),
    Color(0xFFFF8C8C), Color(0xFFFF5A5A), Color(0xFFFF9F43), Color(0xFFFFB000), Color(0xFFFFD447), Color(0xFFFFE066),
    Color(0xFFB6F27A), Color(0xFF6FD96F), Color(0xFF8EE3C8), Color(0xFF2EC4B6), Color(0xFF9BE7FF), Color(0xFF3EC1F3),
    Color(0xFF4AA3FF), Color(0xFF2F6BFF), Color(0xFFCDB4FF), Color(0xFFB98CFF), Color(0xFF7B5CFF), Color(0xFF3A2C6B),
    Color(0xFF1B1F3B), Color(0xFF16171A), Color(0xFF3B342D), Color(0xFF8A6B4E), Color(0xFF9E9E9E), Color(0xFF2E2A2A),
  ];
}

/// The shell behind the play screen: one colour, or two split halfway down with a soft seam.
class ShellBackground extends StatelessWidget {
  const ShellBackground({super.key, required this.theme, required this.child});
  final ShellTheme theme;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: t.split ? [t.shell, t.shell, t.lower, t.lower] : [Color.lerp(t.shell, Colors.white, 0.08)!, t.shell],
          stops: t.split ? const [0, 0.49, 0.51, 1] : const [0, 1],
        ),
      ),
      child: child,
    );
  }
}

/// Paints a dial's face in the theme's colours and pattern, turned by [angle].
void paintDialFace(Canvas canvas, Offset c, double r, ShellTheme t, double angle) {
  final cols = t.dial.isEmpty ? [const Color(0xFF3B342D)] : t.dial;
  final rect = Rect.fromCircle(center: c, radius: r);
  canvas.save();
  canvas.clipPath(Path()..addOval(rect));
  canvas.drawCircle(c, r, Paint()..color = cols.first);
  final n = cols.length;
  Paint p(int i) => Paint()..color = cols[i % n];
  switch (t.pattern) {
    case DialPattern.solid:
      if (n > 1) {
        for (var i = 1; i < n; i++) {
          canvas.drawCircle(c, r * (1 - i / (n + 0.5)), p(i));
        }
      }
    case DialPattern.stripes:
      canvas.translate(c.dx, c.dy);
      canvas.rotate(angle);
      final w = r / 3;
      for (var i = -8; i < 8; i++) {
        canvas.drawRect(Rect.fromLTWH(i * w, -r, w, 2 * r), p(i.abs()));
      }
    case DialPattern.rays:
      for (var i = 0; i < 16; i++) {
        final a0 = angle + i * math.pi / 8;
        final path = Path()
          ..moveTo(c.dx, c.dy)
          ..arcTo(rect, a0, math.pi / 8, false)
          ..close();
        canvas.drawPath(path, p(i));
      }
    case DialPattern.dots:
      final step = r / 2.6;
      for (var y = -3; y <= 3; y++) {
        for (var x = -3; x <= 3; x++) {
          final o = Offset(x * step + (y.isOdd ? step / 2 : 0), y * step);
          final rot = Offset(o.dx * math.cos(angle) - o.dy * math.sin(angle), o.dx * math.sin(angle) + o.dy * math.cos(angle));
          canvas.drawCircle(c + rot, step * 0.28, p(1 + ((x + y) & 1) * (n > 2 ? 1 : 0)));
        }
      }
    case DialPattern.checker:
      canvas.translate(c.dx, c.dy);
      canvas.rotate(angle);
      final s = r / 2.5;
      for (var y = -3; y < 3; y++) {
        for (var x = -3; x < 3; x++) {
          canvas.drawRect(Rect.fromLTWH(x * s, y * s, s, s), p((x + y) & 1 == 0 ? 0 : 1 + ((x * 3 + y) & 1) * (n > 2 ? 1 : 0)));
        }
      }
    case DialPattern.swirl:
      for (var k = 0; k < n * 2; k++) {
        final path = Path();
        for (var i = 0; i <= 40; i++) {
          final f = i / 40;
          final a = angle + k * 2 * math.pi / (n * 2) + f * 3.2;
          final pt = c + Offset.fromDirection(a, r * f);
          i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
        }
        canvas.drawPath(path, p(k)..style = PaintingStyle.stroke..strokeWidth = r * 0.22..strokeCap = StrokeCap.round);
      }
    case DialPattern.stars:
      final rnd = math.Random(7);
      for (var i = 0; i < 14; i++) {
        final a = angle + rnd.nextDouble() * 2 * math.pi;
        final d = r * (0.2 + 0.75 * rnd.nextDouble());
        _star(canvas, c + Offset.fromDirection(a, d), r * (0.06 + 0.06 * rnd.nextDouble()), p(1 + i % (n > 1 ? n - 1 : 1)));
      }
  }
  canvas.restore();
  // a soft shine and rim, so the dial reads as a knob
  canvas.drawCircle(c, r, Paint()
    ..shader = RadialGradient(center: const Alignment(-0.4, -0.5), radius: 1.1, colors: [Colors.white.withValues(alpha: 0.28), Colors.transparent]).createShader(rect));
  canvas.drawCircle(c, r - 1.5, Paint()..style = PaintingStyle.stroke..strokeWidth = 3..color = Colors.black.withValues(alpha: 0.35));
}

void _star(Canvas canvas, Offset c, double r, Paint p) {
  final path = Path();
  for (var i = 0; i < 10; i++) {
    final a = -math.pi / 2 + i * math.pi / 5;
    final d = i.isEven ? r : r * 0.45;
    final pt = c + Offset.fromDirection(a, d);
    i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
  }
  canvas.drawPath(path..close(), p);
}
