import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../paradise/paradise_core.dart';
import '../paradise/paradise_machine.dart';
import '../services/app_state.dart';
import '../services/rom_library.dart';
import 'screen_filters.dart';
import 'theme.dart';

/// The Tamagotchi Paradise, played: its colour screen, A / B / C and the dial.
class ParadiseView extends StatefulWidget {
  const ParadiseView({super.key, required this.machine, required this.rom});
  final ParadiseMachine machine;
  final RomEntry rom;

  @override
  State<ParadiseView> createState() => _ParadiseViewState();
}

class _ParadiseViewState extends State<ParadiseView> {
  ui.Image? _img;
  int _shown = -1;
  final Uint8List _rgba = Uint8List(128 * 128 * 4);

  ParadiseMachine get m => widget.machine;

  @override
  void initState() {
    super.initState();
    m.addListener(_onFrame);
    _onFrame();
  }

  @override
  void didUpdateWidget(ParadiseView old) {
    super.didUpdateWidget(old);
    if (old.machine != m) {
      old.machine.removeListener(_onFrame);
      m.addListener(_onFrame);
    }
  }

  @override
  void dispose() {
    m.removeListener(_onFrame);
    super.dispose();
  }

  void _onFrame() {
    if (m.frame == _shown) {
      if (mounted) setState(() {});
      return;
    }
    _shown = m.frame;
    final s = m.screen;
    for (var i = 0; i < s.length; i++) {
      final v = s[i];
      _rgba[i * 4] = ((v >> 11) & 31) * 255 ~/ 31;
      _rgba[i * 4 + 1] = ((v >> 5) & 63) * 255 ~/ 63;
      _rgba[i * 4 + 2] = (v & 31) * 255 ~/ 31;
      _rgba[i * 4 + 3] = 255;
    }
    final app = AppState.instance;
    final f = processFrame(_rgba, app.upscale, app.filter);
    ui.decodeImageFromPixels(f.rgba, f.w, f.h, ui.PixelFormat.rgba8888, (im) {
      if (!mounted) return;
      setState(() {
        _img?.dispose();
        _img = im;
      });
    });
  }

  Widget _key(String label, int pin, {double size = 70}) => _HoldKey(
        label: label,
        size: size,
        onDown: () {
          HapticFeedback.lightImpact();
          m.press(pin);
        },
        onUp: () => m.release(pin),
      );

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.rom.name),
        actions: [
          IconButton(
            tooltip: 'Sound',
            icon: Icon(m.sound ? Icons.volume_up_rounded : Icons.volume_off_rounded),
            onPressed: () => setState(() => m.sound = !m.sound),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'pause':
                  m.running ? m.pause() : m.start();
                case 'look':
                  if (context.mounted) await pickScreenLook(context);
                  _shown = -1;
                  _onFrame();
                case 'stop':
                  await app.stopParadise();
              }
              if (mounted) setState(() {});
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'pause', child: Text(m.running ? 'Pause' : 'Run')),
              const PopupMenuItem(value: 'look', child: Text('Upscaler & filter …')),
              const PopupMenuItem(value: 'stop', child: Text('Back to the games')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(builder: (context, c) {
          // the screen as big as it gets: full width, leaving room for the keys and the dial
          const controls = 250.0;
          final side = c.maxWidth.clamp(0.0, (c.maxHeight - controls).clamp(160.0, c.maxHeight));
          return Column(children: [
            SizedBox(
              width: side,
              height: side,
              child: _img == null
                  ? const Center(child: CircularProgressIndicator())
                  : Stack(fit: StackFit.expand, children: [
                      RawImage(
                        image: _img,
                        fit: BoxFit.fill,
                        filterQuality: app.upscale == Upscale.smooth || app.upscale == Upscale.hq ? FilterQuality.medium : FilterQuality.none,
                      ),
                      if (app.filter == ScreenFilter.lcd || app.filter == ScreenFilter.scanlines || app.filter == ScreenFilter.crt)
                        IgnorePointer(child: CustomPaint(painter: OverlayPainter(app.filter))),
                    ]),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: LayoutBuilder(builder: (context, cc) {
                  final dial = (cc.maxHeight - 24).clamp(120.0, (cc.maxWidth * 0.55).clamp(120.0, 280.0));
                  return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                    Expanded(
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                          _key('A', ParadiseHandle.pinA, size: 64),
                          _key('C', ParadiseHandle.pinC, size: 64),
                        ]),
                        const SizedBox(height: 10),
                        _key('B', ParadiseHandle.pinB, size: 64),
                      ]),
                    ),
                    Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Dial(
                        size: dial,
                        onStep: (right) {
                          HapticFeedback.selectionClick();
                          m.turn(right);
                        },
                        onPress: (down) {
                          if (down) HapticFeedback.lightImpact();
                          down ? m.press(ParadiseHandle.pinWheel) : m.release(ParadiseHandle.pinWheel);
                        },
                      ),
                      const SizedBox(height: 6),
                      Text(
                        m.error ?? (m.running ? '${(m.load * 100).round()} % speed' : 'Paused'),
                        style: TextStyle(color: m.error != null ? Colors.redAccent : Colors.white38, fontSize: 11),
                      ),
                    ]),
                  ]);
                }),
              ),
            ),
          ]);
        }),
      ),
    );
  }
}

/// The wheel: turn it with a finger (one click every 24 degrees, like the toy's detents);
/// press its middle to push it in.
class Dial extends StatefulWidget {
  const Dial({super.key, required this.size, required this.onStep, required this.onPress});
  final double size;
  final void Function(bool right) onStep;
  final void Function(bool down) onPress;

  @override
  State<Dial> createState() => _DialState();
}

class _DialState extends State<Dial> {
  static const _detent = 0.42; // radians (24 degrees)
  double _angle = 0, _acc = 0;
  double? _last;
  bool _pressed = false;

  double _at(Offset p) {
    final c = widget.size / 2;
    return (p - Offset(c, c)).direction;
  }

  bool _inHub(Offset p) => (p - Offset(widget.size / 2, widget.size / 2)).distance < widget.size * 0.22;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) {
        if (_inHub(e.localPosition)) {
          setState(() => _pressed = true);
          widget.onPress(true);
        } else {
          _last = _at(e.localPosition);
        }
      },
      onPointerMove: (e) {
        final l = _last;
        if (l == null) return;
        final a = _at(e.localPosition);
        var d = a - l;
        if (d > 3.14159) d -= 6.28318;
        if (d < -3.14159) d += 6.28318;
        _last = a;
        _acc += d;
        setState(() => _angle += d);
        while (_acc >= _detent) {
          _acc -= _detent;
          widget.onStep(true);
        }
        while (_acc <= -_detent) {
          _acc += _detent;
          widget.onStep(false);
        }
      },
      onPointerUp: (_) => _end(),
      onPointerCancel: (_) => _end(),
      child: CustomPaint(size: Size.square(widget.size), painter: _DialPainter(_angle, _pressed)),
    );
  }

  void _end() {
    _last = null;
    _acc = 0;
    if (_pressed) {
      setState(() => _pressed = false);
      widget.onPress(false);
    }
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter(this.angle, this.pressed);
  final double angle;
  final bool pressed;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas.drawCircle(c + const Offset(0, 4), r - 2, Paint()..color = Colors.black87..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    canvas.drawCircle(
        c,
        r - 2,
        Paint()
          ..shader = const RadialGradient(colors: [Color(0xFF4A4036), Color(0xFF231E19)]).createShader(Rect.fromCircle(center: c, radius: r)));
    // knurled rim, turning with the finger
    final tick = Paint()
      ..color = kAmber.withValues(alpha: 0.55)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 30; i++) {
      final a = angle + i * 6.28318 / 30;
      final dir = Offset.fromDirection(a);
      canvas.drawLine(c + dir * (r * 0.78), c + dir * (r * 0.92), tick);
    }
    // the marker dot
    canvas.drawCircle(c + Offset.fromDirection(angle - 1.5708) * (r * 0.62), r * 0.06, Paint()..color = kAmber);
    // the hub (push)
    canvas.drawCircle(c, r * 0.22, Paint()..color = pressed ? const Color(0xFFCC8C00) : kAmber);
    final tp = TextPainter(
      text: const TextSpan(text: 'push', style: TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_DialPainter o) => o.angle != angle || o.pressed != pressed;
}

class _HoldKey extends StatefulWidget {
  const _HoldKey({required this.label, required this.onDown, required this.onUp, this.size = 70});
  final String label;
  final VoidCallback onDown, onUp;
  final double size;

  @override
  State<_HoldKey> createState() => _HoldKeyState();
}

class _HoldKeyState extends State<_HoldKey> {
  bool _down = false;
  void _set(bool d) {
    if (d == _down) return;
    setState(() => _down = d);
    d ? widget.onDown() : widget.onUp();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 60),
        width: widget.size,
        height: widget.size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _down ? const Color(0xFFCC8C00) : kAmber,
          boxShadow: _down ? const [] : const [BoxShadow(color: Colors.black87, blurRadius: 6, offset: Offset(0, 4))],
        ),
        child: Text(widget.label, style: TextStyle(fontSize: widget.size > 60 ? 22 : 13, fontWeight: FontWeight.w700, color: Colors.black)),
      ),
    );
  }
}



/// Lines over the picture: the LCD's dot grid, or a CRT's scanlines.
class OverlayPainter extends CustomPainter {
  OverlayPainter(this.filter);
  final ScreenFilter filter;

  @override
  void paint(Canvas canvas, Size size) {
    final px = size.width / 128;
    final p = Paint()..color = Colors.black.withValues(alpha: filter == ScreenFilter.lcd ? 0.28 : 0.35);
    if (filter == ScreenFilter.lcd) {
      for (var i = 1; i < 128; i++) {
        canvas.drawRect(Rect.fromLTWH(i * px - px * 0.08, 0, px * 0.16, size.height), p);
        canvas.drawRect(Rect.fromLTWH(0, i * px - px * 0.08, size.width, px * 0.16), p);
      }
    } else {
      for (var i = 0; i < 128; i++) {
        canvas.drawRect(Rect.fromLTWH(0, i * px + px * 0.55, size.width, px * 0.45), p);
      }
    }
  }

  @override
  bool shouldRepaint(OverlayPainter old) => old.filter != filter;
}

/// Picks the upscaler and the filter (kept for every game).
Future<void> pickScreenLook(BuildContext context) {
  final app = AppState.instance;
  return showModalBottomSheet<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setS) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Upscaler')),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final u in Upscale.values)
              ChoiceChip(
                label: Text(u.label),
                selected: app.upscale == u,
                onSelected: (_) {
                  app.setLook(upscale: u);
                  setS(() {});
                },
              ),
          ]),
          const ListTile(title: Text('Filter')),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final f in ScreenFilter.values)
              ChoiceChip(
                label: Text(f.label),
                selected: app.filter == f,
                onSelected: (_) {
                  app.setLook(filter: f);
                  setS(() {});
                },
              ),
          ]),
          const SizedBox(height: 16),
        ]),
      ),
    ),
  );
}
