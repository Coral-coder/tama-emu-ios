import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../paradise/paradise_core.dart';
import '../paradise/paradise_machine.dart';
import '../services/app_state.dart';
import '../services/rom_library.dart';
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
    ui.decodeImageFromPixels(_rgba, 128, 128, ui.PixelFormat.rgba8888, (im) {
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
                case 'stop':
                  await app.stopParadise();
              }
              if (mounted) setState(() {});
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'pause', child: Text(m.running ? 'Pause' : 'Run')),
              const PopupMenuItem(value: 'stop', child: Text('Back to the games')),
            ],
          ),
        ],
      ),
      body: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth.clamp(0.0, 460.0);
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: w,
              child: Column(children: [
                Container(
                  width: w - 24,
                  padding: EdgeInsets.all(w * 0.1),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFFFF9EC4), Color(0xFFB98CFF)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                    borderRadius: BorderRadius.all(Radius.elliptical(w * 0.5, w * 0.46)),
                    boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 18, offset: Offset(0, 8))],
                  ),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Container(
                      decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(18)),
                      padding: const EdgeInsets.all(6),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: _img == null
                            ? const Center(child: CircularProgressIndicator())
                            : RawImage(image: _img, fit: BoxFit.contain, filterQuality: FilterQuality.none),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  _key('A', ParadiseHandle.pinA),
                  Padding(padding: const EdgeInsets.only(top: 26), child: _key('B', ParadiseHandle.pinB)),
                  _key('C', ParadiseHandle.pinC),
                ]),
                const SizedBox(height: 18),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  IconButton.filledTonal(iconSize: 30, onPressed: () => m.turn(false), icon: const Icon(Icons.rotate_left)),
                  const SizedBox(width: 12),
                  _key('dial', ParadiseHandle.pinWheel, size: 56),
                  const SizedBox(width: 12),
                  IconButton.filledTonal(iconSize: 30, onPressed: () => m.turn(true), icon: const Icon(Icons.rotate_right)),
                ]),
                const SizedBox(height: 14),
                Text(
                  m.error ?? (m.running ? 'Running · ${(m.load * 100).round()} % speed' : 'Paused'),
                  style: TextStyle(color: m.error != null ? Colors.redAccent : Colors.white60, fontSize: 12),
                ),
              ]),
            ),
          ),
        );
      }),
    );
  }
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

