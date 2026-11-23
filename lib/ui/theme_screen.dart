import 'package:material_ui/material_ui.dart';

import '../services/app_state.dart';
import 'shell_theme.dart';

/// Colour the app like a toy: presets, or the shell (split halfway if you like), the buttons and
/// the dial (up to four colours in a pattern), with a live preview.
class ThemeScreen extends StatefulWidget {
  const ThemeScreen({super.key, this.gameId, this.gameName});
  /// Set: this game's own colours; not set: the app's default.
  final String? gameId;
  final String? gameName;

  @override
  State<ThemeScreen> createState() => _ThemeScreenState();
}

class _ThemeScreenState extends State<ThemeScreen> {
  late ShellTheme t = AppState.instance.themeOf(widget.gameId);

  void _set(ShellTheme n) {
    setState(() => t = n);
    final id = widget.gameId;
    id == null ? AppState.instance.setShellTheme(n) : AppState.instance.setGameTheme(id, n);
  }

  Future<Color?> _pick(Color current) => showModalBottomSheet<Color>(
        context: context,
        builder: (c) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(spacing: 10, runSpacing: 10, children: [
              for (final s in ShellTheme.swatches)
                GestureDetector(
                  onTap: () => Navigator.pop(c, s),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: s,
                      shape: BoxShape.circle,
                      border: Border.all(color: s == current ? Colors.white : Colors.white24, width: s == current ? 3 : 1),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      );

  Widget _swatch(String label, Color c, ValueChanged<Color> onPick, {VoidCallback? onRemove}) => Column(mainAxisSize: MainAxisSize.min, children: [
        GestureDetector(
          onTap: () async {
            final n = await _pick(c);
            if (n != null) onPick(n);
          },
          onLongPress: onRemove,
          child: Container(width: 52, height: 52, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.white38))),
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.white60)),
      ]);

  @override
  Widget build(BuildContext context) {
    final title = Theme.of(context).textTheme.titleMedium;
    return Scaffold(
      appBar: AppBar(title: Text(widget.gameName == null ? 'Theme' : 'Colours · ${widget.gameName}'), actions: [
        if (widget.gameId != null)
          TextButton(
            onPressed: () async {
              final app = AppState.instance;
              final e = app.library.entries.where((x) => x.id == widget.gameId);
              if (e.isEmpty) return;
              await app.ensureGameTheme(e.first, fresh: true);
              setState(() => t = app.themeOf(widget.gameId));
            },
            child: const Text('Game\'s own'),
          ),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          SizedBox(width: 200, height: 250, child: ShellPreview(theme: t)),
          const SizedBox(width: 16),
          SizedBox(width: 110, height: 110, child: CustomPaint(painter: _BigDial(t))),
        ]),
        const SizedBox(height: 18),
        Text('Ready-made', style: title),
        const SizedBox(height: 8),
        SizedBox(
          height: 86,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final p in ShellTheme.presets)
              GestureDetector(
                onTap: () => _set(p),
                child: Container(
                  width: 70,
                  margin: const EdgeInsets.only(right: 10),
                  child: Column(children: [
                    SizedBox(width: 56, height: 56, child: CustomPaint(painter: _MiniShell(p))),
                    const SizedBox(height: 4),
                    Text(p.name, style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis),
                  ]),
                ),
              ),
          ]),
        ),
        const Divider(height: 30),
        Text('Shell', style: title),
        const SizedBox(height: 8),
        Row(children: [
          _swatch(t.split ? 'Top' : 'Shell', t.shell, (c) => _set(t.copyWith(shell: c))),
          const SizedBox(width: 12),
          if (t.split) _swatch('Bottom', t.lower, (c) => _set(t.copyWith(shell2: c))),
          const Expanded(child: Text('Split halfway', textAlign: TextAlign.end, overflow: TextOverflow.ellipsis)),
          Switch(value: t.split, onChanged: (v) => _set(v ? t.copyWith(shell2: ShellTheme.swatches[21]) : t.copyWith(clearShell2: true))),
        ]),
        const SizedBox(height: 16),
        Text('Buttons', style: title),
        const SizedBox(height: 8),
        Row(children: [_swatch('Buttons', t.buttons, (c) => _set(t.copyWith(buttons: c)))]),
        const SizedBox(height: 16),
        Text('Dial', style: title),
        const SizedBox(height: 4),
        const Text('Ring, face, then the two arrows. Hold a colour to take it away.', style: TextStyle(fontSize: 12, color: Colors.white54)),
        const SizedBox(height: 8),
        Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (var i = 0; i < t.dial.length; i++)
            _swatch('${i + 1}', t.dial[i], (c) {
              final d = [...t.dial];
              d[i] = c;
              _set(t.copyWith(dial: d));
            }, onRemove: t.dial.length > 1
                ? () {
                    final d = [...t.dial]..removeAt(i);
                    _set(t.copyWith(dial: d));
                  }
                : null),
          if (t.dial.length < 4)
            IconButton.filledTonal(
              onPressed: () async {
                final n = await _pick(Colors.white);
                if (n != null) _set(t.copyWith(dial: [...t.dial, n]));
              },
              icon: const Icon(Icons.add),
            ),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in DialPattern.values)
            ChoiceChip(label: Text(p.label), selected: t.pattern == p, onSelected: (_) => _set(t.copyWith(pattern: p))),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Turning arrows on the dial'),
          value: t.arrows,
          onChanged: (v) => _set(t.copyWith(arrows: v)),
        ),
        const SizedBox(height: 30),
      ]),
    );
  }
}

/// A small toy in the theme's colours: shell, screen, three buttons and the dial.
class ShellPreview extends StatelessWidget {
  const ShellPreview({super.key, required this.theme});
  final ShellTheme theme;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _MiniShell(theme, detailed: true));
}

class _MiniShell extends CustomPainter {
  _MiniShell(this.t, {this.detailed = false});
  final ShellTheme t;
  final bool detailed;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final body = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, h), Radius.elliptical(w * 0.5, h * 0.42));
    canvas.save();
    canvas.clipRRect(body);
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h / 2), Paint()..color = t.shell);
    canvas.drawRect(Rect.fromLTWH(0, h / 2, w, h / 2), Paint()..color = t.lower);
    canvas.restore();
    canvas.drawRRect(body, Paint()..style = PaintingStyle.stroke..strokeWidth = detailed ? 3 : 1.5..color = Colors.black26);
    // the screen
    final sc = Rect.fromCenter(center: Offset(w / 2, h * 0.36), width: w * 0.5, height: w * 0.5);
    canvas.drawRRect(RRect.fromRectAndRadius(sc.inflate(w * 0.03), Radius.circular(w * 0.05)), Paint()..color = Colors.black87);
    canvas.drawRRect(RRect.fromRectAndRadius(sc, Radius.circular(w * 0.03)), Paint()..color = const Color(0xFFB8E6FF));
    if (detailed) {
      // a little face on the screen
      final f = sc.center;
      canvas.drawCircle(f, sc.width * 0.22, Paint()..color = Colors.white);
      canvas.drawCircle(f + Offset(-sc.width * 0.08, -sc.width * 0.03), sc.width * 0.025, Paint()..color = Colors.black);
      canvas.drawCircle(f + Offset(sc.width * 0.08, -sc.width * 0.03), sc.width * 0.025, Paint()..color = Colors.black);
      canvas.drawArc(Rect.fromCenter(center: f + Offset(0, sc.width * 0.04), width: sc.width * 0.12, height: sc.width * 0.08), 0.2, 2.7, false,
          Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = Colors.black);
    }
    // buttons A B C
    final r = w * 0.065;
    for (final o in [Offset(w * 0.28, h * 0.72), Offset(w * 0.5, h * 0.78), Offset(w * 0.72, h * 0.72)]) {
      canvas.drawCircle(o + const Offset(0, 2), r, Paint()..color = Colors.black26);
      canvas.drawCircle(o, r, Paint()..color = t.buttons);
    }
    // the dial, on the side
    paintDial(canvas, Offset(w * 0.5, h * 0.9), w * 0.1, t, 0);
  }

  @override
  bool shouldRepaint(_MiniShell o) => true;
}

class _BigDial extends CustomPainter {
  _BigDial(this.t);
  final ShellTheme t;

  @override
  void paint(Canvas canvas, Size size) => paintDial(canvas, size.center(Offset.zero), size.width / 2, t, 0.4);

  @override
  bool shouldRepaint(_BigDial o) => true;
}
