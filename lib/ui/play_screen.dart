import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../emu/machine.dart';
import '../services/app_state.dart';
import '../services/native.dart';
import 'games_screen.dart';
import 'lcd_view.dart';
import 'paradise_view.dart';
import 'theme.dart';

class PlayScreen extends StatelessWidget {
  const PlayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final p = app.paradise;
        if (p != null) return ParadiseView(machine: p, rom: app.paradiseRom!);
        final m = app.machine;
        if (m == null) return const GamesScreen();
        return _Toy(machine: m);
      },
    );
  }
}

class _Toy extends StatefulWidget {
  const _Toy({required this.machine});
  final TamaMachine machine;

  @override
  State<_Toy> createState() => _ToyState();
}

class _ToyState extends State<_Toy> {
  TamaMachine get m => widget.machine;

  void _btn(ToyButton b, bool down) {
    if (down) HapticFeedback.lightImpact();
    m.press(b, down);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return Scaffold(
      appBar: AppBar(
        title: Text(m.profile.displayName),
        actions: [
          IconButton(
            tooltip: 'Sound',
            icon: Icon(m.sound ? Icons.volume_up_rounded : Icons.volume_off_rounded),
            onPressed: () {
              setState(() => m.sound = !m.sound);
              app.sound = m.sound;
              app.setPref('sound', m.sound);
              if (!m.sound) NativeBridge.tone(0, false);
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) => _menu(context, v),
            itemBuilder: (_) => [
              if (m.profile.knowsClock) const PopupMenuItem(value: 'clock', child: Text('Set the clock to the phone\'s time')),
              if (m.profile.knowsClock) const PopupMenuItem(value: 'clockkeys', child: Text('Start the clock (press its keys)')),
              const PopupMenuItem(value: 'save', child: Text('Save to a slot …')),
              const PopupMenuItem(value: 'load', child: Text('Load a slot …')),
              const PopupMenuItem(value: 'reset', child: Text('Reset the toy')),
              const PopupMenuItem(value: 'stop', child: Text('Stop and close')),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: m,
        builder: (context, _) => LayoutBuilder(builder: (context, c) {
          final w = c.maxWidth.clamp(0.0, 520.0);
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SizedBox(
                width: w,
                child: Column(
                  children: [
                    _Shell(width: w - 32, child: LcdView(machine: m, ghost: app.ghostDots)),
                    const SizedBox(height: 18),
                    _keys(),
                    const SizedBox(height: 18),
                    _status(context),
                    const SizedBox(height: 8),
                    _controls(context),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _keys() {
    Widget key(String label, ToyButton b, double drop) => Padding(
          padding: EdgeInsets.only(top: drop),
          child: _RoundKey(label: label, onDown: () => _btn(b, true), onUp: () => _btn(b, false)),
        );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [key('A', ToyButton.a, 0), key('B', ToyButton.b, 22), key('C', ToyButton.c, 0)],
    );
  }

  Widget _status(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall!.copyWith(color: Colors.white60);
    final clock = m.toyClock();
    String two(int v) => v.toString().padLeft(2, '0');
    final parts = <String>[
      if (m.fault != null) 'Stopped: ${m.fault}',
      if (m.catchingUp) 'Catching up ${_dur(m.catchUpSeconds)} …',
      if (!m.running && m.fault == null) 'Paused',
      if (m.speed > 1) '${m.speed}× speed',
      if (clock != null) 'Toy clock ${two(clock.inHours)}:${two(clock.inMinutes % 60)}',
      if (m.linked) 'Link: ${m.linkEdgesOut} out / ${m.linkEdgesIn} in',
    ];
    return Text(parts.isEmpty ? 'Running' : parts.join('  ·  '), style: style, textAlign: TextAlign.center);
  }

  static String _dur(double s) {
    if (s < 90) return '${s.round()} s';
    if (s < 5400) return '${(s / 60).round()} min';
    return '${(s / 3600).toStringAsFixed(1)} h';
  }

  Widget _controls(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: () {
            HapticFeedback.mediumImpact();
            m.shake();
          },
          icon: const Icon(Icons.vibration),
          label: const Text('Shake'),
        ),
        OutlinedButton.icon(
          onPressed: () => setState(m.togglePause),
          icon: Icon(m.running ? Icons.pause : Icons.play_arrow),
          label: Text(m.running ? 'Pause' : 'Run'),
        ),
        OutlinedButton.icon(
          onPressed: () => setState(() => m.speed = m.speed >= 16 ? 1 : m.speed * 4),
          icon: const Icon(Icons.fast_forward),
          label: Text('${m.speed}×'),
        ),
        OutlinedButton.icon(
          onPressed: () => AppState.instance.page.value = 3,
          icon: Icon(m.linked ? Icons.link : Icons.link_off),
          label: const Text('Link'),
        ),
      ],
    );
  }

  Future<void> _menu(BuildContext context, String v) async {
    final app = AppState.instance;
    final lib = app.library;
    final id = '${m.profile.id}-${app.machineRom!.id}';
    switch (v) {
      case 'clock':
        m.writeClock();
        _toast(context, 'Clock set to the phone\'s time');
      case 'clockkeys':
        m.scheduleClockSet();
        _toast(context, 'Pressing the clock keys, then writing the time');
      case 'save':
        final slot = await _pickSlot(context, 'Save to slot');
        if (slot == null) return;
        await lib.slotFileFor(id, slot).writeAsBytes(m.snapshot());
        if (context.mounted) _toast(context, 'Saved to slot $slot');
      case 'load':
        final slot = await _pickSlot(context, 'Load slot');
        if (slot == null) return;
        final f = lib.slotFileFor(id, slot);
        if (!await f.exists()) {
          if (context.mounted) _toast(context, 'Slot $slot is empty');
          return;
        }
        final ok = m.loadSnapshot(await f.readAsBytes());
        if (context.mounted) _toast(context, ok ? 'Loaded slot $slot' : 'That slot does not fit this ROM');
      case 'reset':
        final yes = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Reset the toy?'),
            content: const Text('This is like taking the battery out: the current pet is gone.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reset')),
            ],
          ),
        );
        if (yes == true) await m.resetToy();
      case 'stop':
        await app.stopToy();
    }
  }

  Future<int?> _pickSlot(BuildContext context, String title) {
    return showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text(title),
        children: [for (var i = 1; i <= 4; i++) SimpleDialogOption(onPressed: () => Navigator.pop(c, i), child: Text('Slot $i'))],
      ),
    );
  }

  void _toast(BuildContext context, String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
}

class _Shell extends StatelessWidget {
  const _Shell({required this.width, required this.child});
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: EdgeInsets.all(width * 0.09),
      decoration: BoxDecoration(
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF2A2C33), Color(0xFF15161A)]),
        borderRadius: BorderRadius.all(Radius.elliptical(width * 0.5, width * 0.45)),
        border: Border.all(color: kAmber.withValues(alpha: 0.35), width: 1.2),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 18, offset: Offset(0, 8))],
      ),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: const Color(0xFF0B0C0E), borderRadius: BorderRadius.circular(14)),
        child: child,
      ),
    );
  }
}

class _RoundKey extends StatefulWidget {
  const _RoundKey({required this.label, required this.onDown, required this.onUp});
  final String label;
  final VoidCallback onDown, onUp;

  @override
  State<_RoundKey> createState() => _RoundKeyState();
}

class _RoundKeyState extends State<_RoundKey> {
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
        width: 72,
        height: 72,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _down ? const Color(0xFFCC8C00) : kAmber,
          boxShadow: _down ? const [] : const [BoxShadow(color: Colors.black87, blurRadius: 6, offset: Offset(0, 4))],
        ),
        child: Text(widget.label, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.black)),
      ),
    );
  }
}
