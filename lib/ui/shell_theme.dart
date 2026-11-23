import 'dart:convert';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// How the dial's face is painted.
enum DialPattern {
  glitter('Glitter'),
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
    this.arrows = true,
  });

  final String name;
  final Color shell;
  final Color? shell2; // the lower half, when the shell is split
  final Color buttons;
  final List<Color> dial; // 1 to 4
  final DialPattern pattern;
  /// The two turning arrows on the dial's face (as on the toy).
  final bool arrows;

  bool get split => shell2 != null;
  Color get lower => shell2 ?? shell;

  /// Text and icons on the shell: dark on a light shell, light on a dark one.
  Color get onShell => shell.computeLuminance() > 0.45 ? const Color(0xFF2A1E2E) : Colors.white;
  Color get onButtons => buttons.computeLuminance() > 0.45 ? const Color(0xFF2A1E2E) : Colors.white;

  ShellTheme copyWith({String? name, Color? shell, Color? shell2, bool clearShell2 = false, Color? buttons, List<Color>? dial, DialPattern? pattern, bool? arrows}) =>
      ShellTheme(
        name: name ?? this.name,
        shell: shell ?? this.shell,
        shell2: clearShell2 ? null : (shell2 ?? this.shell2),
        buttons: buttons ?? this.buttons,
        dial: dial ?? this.dial,
        pattern: pattern ?? this.pattern,
        arrows: arrows ?? this.arrows,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'shell': shell.toARGB32(),
        if (shell2 != null) 'shell2': shell2!.toARGB32(),
        'buttons': buttons.toARGB32(),
        'dial': [for (final c in dial) c.toARGB32()],
        'pattern': pattern.name,
        'arrows': arrows,
      };

  static ShellTheme fromJson(Map<String, dynamic> j) => ShellTheme(
        name: j['name'] as String? ?? 'Mine',
        shell: Color(j['shell'] as int),
        shell2: j['shell2'] == null ? null : Color(j['shell2'] as int),
        buttons: Color(j['buttons'] as int),
        dial: [for (final c in (j['dial'] as List)) Color(c as int)],
        pattern: DialPattern.values.firstWhere((p) => p.name == j['pattern'], orElse: () => DialPattern.solid),
        arrows: j['arrows'] as bool? ?? true,
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

  /// The dial's colours, in order: the knurled ring, the face, the two arrows.
  Color get ring => dial.isNotEmpty ? dial[0] : buttons;
  Color get face => dial.length > 1 ? dial[1] : const Color(0xFF2A2340);
  Color get arrow1 => dial.length > 2 ? dial[2] : const Color(0xFF3FD8A0);
  Color get arrow2 => dial.length > 3 ? dial[3] : const Color(0xFFE6F23A);

  static const presets = [
    ShellTheme(name: 'Periwinkle', shell: Color(0xFFE9E6FA), shell2: Color(0xFF8C8FE6), buttons: Color(0xFF5A5FC8),
        dial: [Color(0xFF8088E0), Color(0xFF2A2340), Color(0xFF3FD8A0), Color(0xFFE6F23A)], pattern: DialPattern.glitter),
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

/// The whole dial, as on the toy: a knurled ring, a face (glitter or a pattern) under a clear
/// dome, two turning arrows, and the small silver push button in the middle. Turned by [angle].
void paintDial(Canvas canvas, Offset c, double r, ShellTheme t, double angle, {bool pressed = false}) {
  // shadow under the knob
  canvas.drawCircle(c + Offset(0, r * 0.06), r * 0.95, Paint()..color = Colors.black38..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.08));
  // the knurled ring: bumps all round, turning with the finger
  final ring = Paint()..color = t.ring;
  canvas.drawCircle(c, r * 0.88, ring);
  for (var i = 0; i < 24; i++) {
    final a = angle + i * 2 * math.pi / 24;
    canvas.drawCircle(c + Offset.fromDirection(a, r * 0.88), r * 0.085, ring);
  }
  canvas.drawCircle(c, r * 0.88, Paint()
    ..shader = RadialGradient(center: const Alignment(-0.35, -0.45), radius: 1.0, colors: [Colors.white.withValues(alpha: 0.30), Colors.transparent, Colors.black.withValues(alpha: 0.18)], stops: const [0, 0.55, 1])
        .createShader(Rect.fromCircle(center: c, radius: r)));
  // the bezel and the face
  canvas.drawCircle(c, r * 0.74, Paint()..color = Color.lerp(t.ring, Colors.black, 0.28)!);
  final fr = r * 0.68;
  paintDialFace(canvas, c, fr, t, angle);
  // the two arrows going round
  if (t.arrows) {
    _arrow(canvas, c, fr * 0.62, fr * 0.2, angle + 0.35, 2.25, t.arrow1);
    _arrow(canvas, c, fr * 0.62, fr * 0.2, angle + 0.35 + math.pi, 2.25, t.arrow2);
  }
  // the clear dome over the face
  canvas.drawCircle(c, fr, Paint()
    ..shader = RadialGradient(center: const Alignment(-0.45, -0.55), radius: 0.9, colors: [Colors.white.withValues(alpha: 0.38), Colors.white.withValues(alpha: 0.0)])
        .createShader(Rect.fromCircle(center: c, radius: fr)));
  canvas.drawCircle(c, fr, Paint()..style = PaintingStyle.stroke..strokeWidth = r * 0.03..color = Colors.white.withValues(alpha: 0.35));
  // the silver push button
  final br = r * 0.17;
  canvas.drawCircle(c + Offset(0, br * 0.12), br, Paint()..color = Colors.black45);
  canvas.drawCircle(c, br, Paint()
    ..shader = RadialGradient(center: const Alignment(-0.3, -0.4), colors: pressed ? const [Color(0xFFB8B8B8), Color(0xFF6E6E6E)] : const [Color(0xFFFFFFFF), Color(0xFF9C9C9C)])
        .createShader(Rect.fromCircle(center: c, radius: br)));
  canvas.drawCircle(c, br * 0.55, Paint()..color = Colors.white.withValues(alpha: pressed ? 0.15 : 0.45));
}

void _arrow(Canvas canvas, Offset c, double radius, double width, double start, double sweep, Color color) {
  final p = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.butt;
  canvas.drawArc(Rect.fromCircle(center: c, radius: radius), start, sweep, false, p);
  // the head, pointing along the circle
  final end = start + sweep;
  final tip = c + Offset.fromDirection(end + 0.32, radius);
  final outer = c + Offset.fromDirection(end, radius + width * 0.95);
  final inner = c + Offset.fromDirection(end, radius - width * 0.95);
  canvas.drawPath(Path()..moveTo(outer.dx, outer.dy)..lineTo(tip.dx, tip.dy)..lineTo(inner.dx, inner.dy)..close(), Paint()..color = color);
}

/// Paints a dial's face (the part under the dome) in the theme's colours and pattern.
void paintDialFace(Canvas canvas, Offset c, double r, ShellTheme t, double angle) {
  final cols = [t.face, if (t.dial.length > 2) t.arrow1 else Color.lerp(t.face, Colors.white, 0.3)!, if (t.dial.length > 3) t.arrow2, t.ring];
  final rect = Rect.fromCircle(center: c, radius: r);
  canvas.save();
  canvas.clipPath(Path()..addOval(rect));
  canvas.drawCircle(c, r, Paint()..color = cols.first);
  final n = cols.length;
  Paint p(int i) => Paint()..color = cols[i % n];
  switch (t.pattern) {
    case DialPattern.glitter:
      // holographic glitter: specks of every colour, sparkling as the dial turns
      final rnd = math.Random(11);
      for (var i = 0; i < 260; i++) {
        final a = angle + rnd.nextDouble() * 2 * math.pi;
        final d = r * math.sqrt(rnd.nextDouble());
        final hue = (rnd.nextDouble() * 360 + angle * 40) % 360;
        final col = HSVColor.fromAHSV(0.55 + 0.45 * rnd.nextDouble(), hue, 0.65, 1).toColor();
        canvas.drawCircle(c + Offset.fromDirection(a, d), r * (0.012 + 0.02 * rnd.nextDouble()), Paint()..color = col);
      }
    case DialPattern.solid:
      break;
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

/// A theme in a game's own colours: the strongest hue of its artwork becomes the shell (light on
/// top, deeper below) and the dial's ring, the next distinct hue the buttons and the arrows.
ShellTheme themeFromPixels(String name, List<int> rgba) {
  final buckets = List<double>.filled(24, 0);
  for (var i = 0; i + 3 < rgba.length; i += 4 * 3) {
    final c = HSVColor.fromColor(Color.fromARGB(255, rgba[i], rgba[i + 1], rgba[i + 2]));
    if (c.saturation < 0.25 || c.value < 0.3) continue;
    buckets[(c.hue / 15).floor() % 24] += c.saturation * c.value;
  }
  final order = List<int>.generate(24, (i) => i)..sort((a, b) => buckets[b].compareTo(buckets[a]));
  final h1 = buckets[order.first] > 0 ? order.first * 15.0 + 7.5 : 260.0;
  var h2 = (h1 + 150) % 360;
  for (final b in order.skip(1)) {
    final h = b * 15.0 + 7.5;
    final d = ((h - h1).abs() % 360);
    if (buckets[b] > 0 && math.min(d, 360 - d) >= 45) {
      h2 = h;
      break;
    }
  }
  Color hsv(double h, double s, double v) => HSVColor.fromAHSV(1, h % 360, s, v).toColor();
  return ShellTheme(
    name: name,
    shell: hsv(h1, 0.16, 0.98),
    shell2: hsv(h1, 0.48, 0.88),
    buttons: hsv(h2, 0.62, 0.86),
    dial: [hsv(h1, 0.52, 0.80), hsv(h1, 0.55, 0.22), hsv(h2, 0.55, 0.95), hsv(h2 + 60, 0.65, 0.95)],
    pattern: DialPattern.glitter,
  );
}

/// Each edition's own colours (its field: earth, sea, sky, forest, ice, sun, neon), used until
/// you change a game's colours. Null for an unknown ROM (it gets colours from its artwork).
ShellTheme? editionTheme(String name) {
  final n = name.toLowerCase();
  const glitter = DialPattern.glitter;
  if (n.contains('land')) {
    return const ShellTheme(name: 'Land', shell: Color(0xFFFFE3EF), shell2: Color(0xFFFF8CC0), buttons: Color(0xFF7BD66B),
        dial: [Color(0xFFFF6FAE), Color(0xFF3A1E33), Color(0xFF7BD66B), Color(0xFFFFE066)], pattern: glitter);
  }
  if (n.contains('water')) {
    return const ShellTheme(name: 'Water', shell: Color(0xFFE2F4FF), shell2: Color(0xFF4AA8F0), buttons: Color(0xFFFFFFFF),
        dial: [Color(0xFF2F7FE0), Color(0xFF13284A), Color(0xFF6FE3FF), Color(0xFFFFFFFF)], pattern: glitter);
  }
  if (n.contains('sky')) {
    return const ShellTheme(name: 'Sky', shell: Color(0xFFF0EAFF), shell2: Color(0xFFA98CF0), buttons: Color(0xFFFFE066),
        dial: [Color(0xFF8C6FE6), Color(0xFF261E44), Color(0xFF9BE7FF), Color(0xFFFFE066)], pattern: glitter);
  }
  if (n.contains('jade') || n.contains('forest')) {
    return const ShellTheme(name: 'Jade Forest', shell: Color(0xFFE4F7EC), shell2: Color(0xFF3FB98A), buttons: Color(0xFFFFD447),
        dial: [Color(0xFF2E9E73), Color(0xFF123326), Color(0xFFB6F27A), Color(0xFFFFD447)], pattern: glitter);
  }
  if (n.contains('glacier')) {
    return const ShellTheme(name: 'Glacier', shell: Color(0xFFFFFFFF), shell2: Color(0xFFBFE6F5), buttons: Color(0xFF3F7FC0),
        dial: [Color(0xFF5FA8D8), Color(0xFF1F3A4D), Color(0xFFFFFFFF), Color(0xFF9BE7FF)], pattern: glitter);
  }
  if (n.contains('tropical')) {
    return const ShellTheme(name: 'Tropical', shell: Color(0xFFFFF4D6), shell2: Color(0xFFFF9F43), buttons: Color(0xFF2EC4B6),
        dial: [Color(0xFFFF8A3D), Color(0xFF3A230E), Color(0xFF2EC4B6), Color(0xFFFFE066)], pattern: glitter);
  }
  if (n.contains('neon')) {
    return const ShellTheme(name: 'Neon Planets', shell: Color(0xFF2A2350), shell2: Color(0xFF14112E), buttons: Color(0xFFFF4FD8),
        dial: [Color(0xFF6E4FFF), Color(0xFF0D0B20), Color(0xFF4FF0FF), Color(0xFFFF4FD8)], pattern: DialPattern.stars);
  }
  return null;
}
