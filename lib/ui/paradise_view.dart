import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../paradise/paradise_core.dart';
import '../paradise/paradise_machine.dart';
import '../services/app_state.dart';
import '../services/native.dart';
import '../services/rom_library.dart';
import '../services/watch.dart';
import 'care_sheet.dart';
import '../emu/rom_info.dart';
import 'hardware_screen.dart';
import 'paradise_screen.dart';
import 'pictures_screen.dart';
import 'save_editor.dart';
import 'screen_filters.dart';
import 'shell_theme.dart';
import 'theme_screen.dart';
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
  bool _decoding = false;
  int _shown = -1;
  final Uint8List _rgba = Uint8List(128 * 128 * 4);

  ParadiseMachine get m => widget.machine;

  /// Linked to a second game: the keys and the dial drive the console picked on screen.
  bool _second = false;
  ParadiseMachine get t {
    final p = AppState.instance.partner;
    return _second && p != null ? p : m;
  }

  @override
  void initState() {
    super.initState();
    m.addListener(_onFrame);
    _onFrame();
    NativeBridge.keepScreenOn(AppState.instance.keepScreenOn);
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
    NativeBridge.keepScreenOn(false);
    super.dispose();
  }

  void _onFrame() {
    if (m.frame == _shown) {
      if (mounted) setState(() {});
      return;
    }
    if (_decoding) return; // big upscales: one picture at a time, the next tick takes the newest
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
    final f = processFrame(_rgba, app.upscale, app.filters);
    _decoding = true;
    ui.decodeImageFromPixels(f.rgba, f.w, f.h, ui.PixelFormat.rgba8888, (im) {
      _decoding = false;
      if (!mounted) return;
      setState(() {
        _img?.dispose();
        _img = im;
      });
    });
  }

  /// The phone's keyboard for the game's naming screens: what is typed is entered letter by letter
  /// with the picker, as one would with the dial.
  Future<void> _type(BuildContext context) async {
    final ctl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Type a name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('On the game\'s naming screen, with the cursor on the first empty box. Letters, digits and spaces.', style: TextStyle(color: Colors.white60, fontSize: 13)),
            const SizedBox(height: 12),
            TextField(
              controller: ctl,
              autofocus: true,
              maxLength: 8,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9 ]'))],
              onSubmitted: (v) => Navigator.pop(c, v),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Type it')),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
    final skipped = await m.typeText(text);
    if (context.mounted && skipped.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Not on the picker: $skipped')));
    }
  }

  Widget _mainScreen(AppState app) => _img == null
      ? const ColoredBox(color: Colors.black)
      : RawImage(image: _img, fit: BoxFit.fill, filterQuality: app.upscale == Upscale.smooth || app.upscale == Upscale.hq ? FilterQuality.medium : FilterQuality.none);

  /// One of the two linked consoles; touching it gives it the keys and the dial.
  Widget _pick(bool second, Widget screen) => GestureDetector(
    onTap: () {
      m.releaseAll();
      AppState.instance.partner?.releaseAll();
      setState(() => _second = second);
    },
    child: Container(
      margin: const EdgeInsets.all(3),
      decoration: BoxDecoration(border: Border.all(color: _second == second ? kAmber : Colors.white12, width: 3)),
      child: screen,
    ),
  );

  Future<void> _pickPartner(BuildContext context) async {
    final app = AppState.instance;
    final games = app.library.entries.where((e) => e.kind == RomKind.paradise).toList();
    final e = await showDialog<RomEntry>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Link with which game?'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('Both run side by side, link port to link port. Touch a screen to play it.', style: TextStyle(color: Colors.white60)),
          ),
          for (final g in games) SimpleDialogOption(onPressed: () => Navigator.pop(c, g), child: Text(g.name.replaceFirst('Tamagotchi Paradise · ', ''))),
        ],
      ),
    );
    if (e == null) return;
    final err = await app.linkPartner(e);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Linked. On both consoles open CONNECTION and pick the same thing (PLAYDATE, GIFTS …).')));
    }
  }

  Widget _key(String label, int pin, {double size = 70}) => _HoldKey(
    label: label,
    size: size,
    onDown: () {
      HapticFeedback.lightImpact();
      t.press(pin);
    },
    onUp: () => t.release(pin),
  );

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final th = app.currentTheme;
    return Scaffold(
      backgroundColor: th.lower,
      extendBodyBehindAppBar: false,
      appBar: AppBar(
        leading: IconButton(tooltip: 'All games', icon: const Icon(Icons.grid_view_rounded), onPressed: () => app.showGames()),
        backgroundColor: th.shell,
        foregroundColor: th.onShell,
        title: Text(
          widget.rom.name.replaceFirst('Tamagotchi Paradise · ', ''),
          style: TextStyle(color: th.onShell, fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: 'Care',
            icon: const Icon(Icons.favorite_rounded),
            onPressed: () {
              m.releaseAll();
              showCare(context, m, widget.rom.id);
            },
          ),
          IconButton(
            tooltip: 'Type a name',
            icon: const Icon(Icons.keyboard_rounded),
            onPressed: m.typing
                ? null
                : () {
                    m.releaseAll();
                    _type(context);
                  },
          ),
          IconButton(tooltip: 'Sound', icon: Icon(m.sound ? Icons.volume_up_rounded : Icons.volume_off_rounded), onPressed: () => setState(() => m.sound = !m.sound)),
          PopupMenuButton<String>(
            onSelected: (v) async {
              m.releaseAll();
              switch (v) {
                case 'pause':
                  m.running ? m.pause() : m.start();
                case 'edit':
                  if (context.mounted) await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SaveEditor(m: m, rom: widget.rom)));
                case 'pictures':
                  if (context.mounted) await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PicturesScreen(rom: widget.rom)));
                case 'theme':
                  if (context.mounted) await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ThemeScreen(gameId: widget.rom.id, gameName: widget.rom.name)));
                case 'look':
                  if (context.mounted) await pickScreenLook(context);
                  _shown = -1;
                  _onFrame();
                case 'watch':
                  final err = await WatchLink.instance.syncAll();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(err ?? 'Sent to your Apple Watch: open Tama there and it continues. Its save comes back here when you put the watch down.')));
                  }
                case 'reset':
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('Reset the console?'),
                      content: const Text('Like the reset button on the back of the toy: the console restarts. Your Tamagotchi and its progress stay.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reset')),
                      ],
                    ),
                  );
                  if (ok == true) m.reset();
                case 'twin':
                  if (context.mounted) await _pickPartner(context);
                case 'unit':
                  final err = await app.linkUnit();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(err ?? 'Linked to the real unit. On both, open CONNECTION and pick the same thing (PLAYDATE, GIFTS …).'),
                        action: err == null
                            ? null
                            : SnackBarAction(
                                label: 'Hardware',
                                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HardwareScreen())),
                              ),
                      ),
                    );
                  }
                case 'unlink':
                  _second = false;
                  await app.unlink();
                case 'stop':
                  await app.showGames();
                case 'quit':
                  await app.stopParadise();
              }
              if (mounted) setState(() {});
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'pause', child: Text(m.running ? 'Pause' : 'Run')),
              const PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit_note), title: Text('Change the save (live)'))),
              const PopupMenuItem(value: 'pictures', child: ListTile(leading: Icon(Icons.brush), title: Text('Repaint the pictures'))),
              const PopupMenuItem(value: 'theme', child: Text('This game\'s colours …')),
              const PopupMenuItem(value: 'look', child: Text('Upscaler & filter …')),
              const PopupMenuItem(value: 'reset', child: Text('Reset button')),
              if (app.link == null) const PopupMenuItem(value: 'twin', child: Text('Link with another game …')),
              if (app.link == null) const PopupMenuItem(value: 'unit', child: Text('Link with my real unit')),
              if (app.link != null) const PopupMenuItem(value: 'unlink', child: Text('Unlink')),
              if (WatchLink.instance.available) const PopupMenuItem(value: 'watch', child: Text('Send to Apple Watch now')),
              const PopupMenuItem(value: 'stop', child: Text('Back to the games (it lives on)')),
              const PopupMenuItem(value: 'quit', child: Text('Stop this game')),
            ],
          ),
        ],
      ),
      body: ShellBackground(
        theme: th,
        child: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, c) {
              // the screen as big as it gets: full width, leaving room for the keys and the dial
              const controls = 250.0;
              final side = c.maxWidth.clamp(0.0, (c.maxHeight - controls).clamp(160.0, c.maxHeight));
              final partner = app.partner;
              return Column(
                children: [
                  if (partner != null)
                    Row(
                      children: [
                        Expanded(child: _pick(false, AspectRatio(aspectRatio: 1, child: _mainScreen(app)))),
                        Expanded(
                          child: _pick(true, AspectRatio(aspectRatio: 1, child: ParadiseScreen(machine: partner))),
                        ),
                      ],
                    )
                  else
                    SizedBox(
                      width: side,
                      height: side,
                      child: _img == null
                          ? const Center(child: CircularProgressIndicator())
                          : Stack(
                              fit: StackFit.expand,
                              children: [
                                RawImage(image: _img, fit: BoxFit.fill, filterQuality: app.upscale == Upscale.smooth || app.upscale == Upscale.hq ? FilterQuality.medium : FilterQuality.none),
                                for (final f in app.filters)
                                  if (isOverlay(f)) IgnorePointer(child: CustomPaint(painter: OverlayPainter(f))),
                              ],
                            ),
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: LayoutBuilder(
                        builder: (context, cc) {
                          final dial = (cc.maxHeight - 24).clamp(120.0, (cc.maxWidth * 0.42).clamp(120.0, 240.0));
                          final key = ((cc.maxWidth - dial - 18) / 2.4).clamp(52.0, 84.0).clamp(0.0, (cc.maxHeight - 8) / 2.05);
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: SizedBox(
                                  height: key * 2.05,
                                  child: Stack(
                                    children: [
                                      // A, B, C on a gentle arc, as on the toy's face
                                      Align(
                                        alignment: const Alignment(-1, -1),
                                        child: _key('A', ParadiseHandle.pinA, size: key),
                                      ),
                                      Align(
                                        alignment: const Alignment(0, 1),
                                        child: _key('B', ParadiseHandle.pinB, size: key),
                                      ),
                                      Align(
                                        alignment: const Alignment(1, -1),
                                        child: _key('C', ParadiseHandle.pinC, size: key),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 18),
                              Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Dial(
                                    size: dial,
                                    onStep: (right) {
                                      HapticFeedback.selectionClick();
                                      t.turn(right);
                                    },
                                    onPress: (down) {
                                      if (down) HapticFeedback.mediumImpact();
                                      down ? t.press(ParadiseHandle.pinWheel) : t.release(ParadiseHandle.pinWheel);
                                    },
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    app.link != null
                                        ? app.link!.status
                                        : m.error ?? (m.typing ? 'Typing … ${(m.typingProgress * 100).round()} %' : (m.running ? '${(m.load * 100).round()} % speed' : 'Paused')),
                                    style: TextStyle(color: m.error != null ? Colors.redAccent : th.onShell.withValues(alpha: 0.6), fontSize: 11),
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
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
      child: RepaintBoundary(child: CustomPaint(size: Size.square(widget.size), painter: _DialPainter(_angle, _pressed, AppState.instance.currentTheme))),
    );
  }

  @override
  void dispose() {
    if (_pressed) widget.onPress(false);
    super.dispose();
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
  _DialPainter(this.angle, this.pressed, this.theme);
  final double angle;
  final bool pressed;
  final ShellTheme theme;

  @override
  void paint(Canvas canvas, Size size) {
    paintDial(canvas, size.center(Offset.zero), size.width / 2, theme, angle, pressed: pressed);
  }

  @override
  // only when it turns, is pushed or changes colours (not on every frame of the game)
  bool shouldRepaint(_DialPainter o) => o.angle != angle || o.pressed != pressed || !identical(o.theme, theme);
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

  @override
  void dispose() {
    if (_down) widget.onUp(); // never leave a key held when the button goes away mid-press
    super.dispose();
  }

  void _set(bool d) {
    if (d == _down) return;
    setState(() => _down = d);
    d ? widget.onDown() : widget.onUp();
  }

  @override
  Widget build(BuildContext context) {
    final sz = widget.size;
    final th = AppState.instance.currentTheme;
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down ? 0.92 : 1,
        duration: const Duration(milliseconds: 70),
        child: Container(
          width: sz,
          height: sz,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // a domed key: lit from above, sunk when pressed
            gradient: RadialGradient(
              center: const Alignment(-0.3, -0.45),
              radius: 0.95,
              colors: _down ? [Color.lerp(th.buttons, Colors.black, 0.15)!, Color.lerp(th.buttons, Colors.black, 0.35)!] : [Color.lerp(th.buttons, Colors.white, 0.35)!, th.buttons],
            ),
            border: Border.all(color: Colors.black.withValues(alpha: 0.18), width: 2),
            boxShadow: _down ? [BoxShadow(color: th.buttons.withValues(alpha: 0.45), blurRadius: 16)] : const [BoxShadow(color: Colors.black38, blurRadius: 8, offset: Offset(0, 5))],
          ),
          child: Text(
            widget.label,
            style: TextStyle(fontSize: sz * 0.36, fontWeight: FontWeight.w800, color: th.onButtons, letterSpacing: 0.5),
          ),
        ),
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
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Upscaler')),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final u in Upscale.values)
                  ChoiceChip(
                    label: Text(u.label),
                    selected: app.upscale == u,
                    onSelected: (_) {
                      app.setLook(upscale: u);
                      setS(() {});
                    },
                  ),
              ],
            ),
            const ListTile(title: Text('Filters'), subtitle: Text('Pick as many as you like: they stack, in the order picked.')),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in ScreenFilter.values.where((f) => f != ScreenFilter.none))
                  FilterChip(
                    label: Text(app.filters.contains(f) ? '${app.filters.indexOf(f) + 1}. ${f.label}' : f.label),
                    selected: app.filters.contains(f),
                    onSelected: (on) {
                      final l = [...app.filters];
                      on ? l.add(f) : l.remove(f);
                      app.setLook(filters: l);
                      setS(() {});
                    },
                  ),
                ActionChip(
                  label: const Text('None'),
                  onPressed: () {
                    app.setLook(filters: []);
                    setS(() {});
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    ),
  );
}
