import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../paradise/paradise_machine.dart';
import '../paradise/unlock.dart';
import '../services/app_state.dart';
import '../services/rom_library.dart';

/// A game's menu (long press on its card): play, stop, edit the save, reset the save.
Future<void> showGameMenu(BuildContext context, RomEntry e) {
  final app = AppState.instance;
  final running = app.games.containsKey(e.id);
  final name = e.name.replaceFirst('Tamagotchi Paradise · ', '');
  return showModalBottomSheet(
    context: context,
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(name, style: const TextStyle(fontWeight: FontWeight.w800))),
        ListTile(
          leading: const Icon(Icons.play_arrow_rounded),
          title: Text(running ? 'Play' : 'Start'),
          onTap: () {
            Navigator.pop(c);
            app.page.value = 0;
            ParadiseUnlock.instance.play(e);
          },
        ),
        ListTile(
          leading: const Icon(Icons.edit_note_rounded),
          title: const Text('Edit the save'),
          subtitle: const Text('The pet, the planet, the clock, every byte'),
          onTap: () async {
            Navigator.pop(c);
            await openSaveEditor(context, e);
          },
        ),
        if (running)
          ListTile(
            leading: const Icon(Icons.stop_circle_outlined),
            title: const Text('Stop this game'),
            subtitle: const Text('Saved; it no longer lives in the background'),
            onTap: () {
              Navigator.pop(c);
              app.stopGame(e.id);
            },
          ),
        ListTile(
          leading: const Icon(Icons.restart_alt_rounded, color: Colors.redAccent),
          title: const Text('Reset the save', style: TextStyle(color: Colors.redAccent)),
          subtitle: const Text('Back to the ROM as it was dumped'),
          onTap: () async {
            Navigator.pop(c);
            await resetSave(context, e);
          },
        ),
      ]),
    ),
  );
}

/// Throws the game's save away: it starts again from the dump (where the game offers CONTINUE
/// or RESET ALL; RESET ALL starts a brand-new Tamagotchi).
Future<void> resetSave(BuildContext context, RomEntry e) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Reset the save?'),
      content: const Text('Everything this game saved here goes: it starts again from the ROM as it was dumped. '
          'On the first screen, RESET ALL then starts a brand-new Tamagotchi. This cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep it')),
        FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.redAccent), onPressed: () => Navigator.pop(c, true), child: const Text('Reset')),
      ],
    ),
  );
  if (ok != true) return;
  final app = AppState.instance;
  await app.stopGame(e.id);
  for (final f in [app.library.paradiseSave(e), app.shotFile(e.id)]) {
    if (await f.exists()) await f.delete();
  }
  final partner = app.library.paradiseSave(e).path.replaceFirst('.save', '-partner.save');
  final pf = File(partner);
  if (await pf.exists()) await pf.delete();
  app.shotsChanged();
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The save was reset.')));
}

/// Opens the editor; the game is started (in the background) when it is not running.
Future<void> openSaveEditor(BuildContext context, RomEntry e) async {
  final app = AppState.instance;
  if (!app.games.containsKey(e.id)) {
    final err = await app.playParadise(e, focus: false);
    if (err != null) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err == 'key' ? 'This game does not start.' : err)));
      return;
    }
  }
  final m = app.games[e.id];
  if (m == null || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SaveEditor(m: m, rom: e)));
}

/// The save, field by field: what is known has its own control (with the values the game uses),
/// and every byte of the settings block can be changed by hand.
class SaveEditor extends StatefulWidget {
  const SaveEditor({super.key, required this.m, required this.rom});
  final ParadiseMachine m;
  final RomEntry rom;

  @override
  State<SaveEditor> createState() => _SaveEditorState();
}

class _SaveEditorState extends State<SaveEditor> {
  Timer? _tick;
  Uint8List? _b;
  late final (int, int) _places = widget.m.petPlaces();
  String? _note;

  int get _pet => _places.$1;
  int get _level => _places.$2;

  static const stages = ['Egg', 'Baby', 'Child', 'Teen', 'Adult', 'Senior'];

  @override
  void initState() {
    super.initState();
    _read();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _read());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _read() => setState(() => _b = widget.m.block());

  void _write(int offset, List<int> v, String what) {
    final ok = widget.m.blockWrite(offset, v);
    setState(() => _note = ok ? '$what saved.' : 'The save could not be written.');
    _read();
  }

  int _u8(int o) => _b![o];
  int _u16(int o) => _b![o] | (_b![o + 1] << 8);
  int _u32(int o) => _u16(o) | (_u16(o + 2) << 16);

  @override
  Widget build(BuildContext context) {
    final b = _b;
    final name = widget.rom.name.replaceFirst('Tamagotchi Paradise · ', '');
    return Scaffold(
      appBar: AppBar(title: Text('Save · $name'), actions: [
        IconButton(
          tooltip: 'Restart the console on the save',
          icon: const Icon(Icons.restart_alt),
          onPressed: () {
            widget.m.reset();
            setState(() => _note = 'The console restarted on the save (choose CONTINUE).');
          },
        ),
      ]),
      body: b == null
          ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('The save is not readable yet (the game is starting). One moment …')))
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (_note != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_note!, style: const TextStyle(color: Colors.white60))),
              _section('The pet'),
              _slider('Hunger', _u8(_pet + 0x1C), 6, (v) => _write(_pet + 0x1C, [v], 'Hunger')),
              _slider('Happiness', _u8(_pet + 0x1D), 20, (v) => _write(_pet + 0x1D, [v], 'Happiness')),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Sick'),
                value: _u8(_pet + 0x10) != 0,
                onChanged: (v) => _write(_pet + 0x10, [v ? 1 : 0], 'Health'),
              ),
              _dropdown('Stage', (_u8(_pet + 0x18) >> 2) & 7, {for (var i = 0; i < stages.length; i++) i: stages[i]},
                  (v) => _write(_pet + 0x18, [(_u8(_pet + 0x18) & ~0x1C) | ((v & 7) << 2)], 'Stage')),
              _hexField('Character', _u16(_pet + 4), 4, (v) => _write(_pet + 4, [v & 255, v >> 8, v & 255, v >> 8], 'Character'),
                  help: 'The character\'s number (a wrong one can show a broken sprite: note the old one first).'),
              _section('The planet'),
              _dropdown('Planet level', _u8(_level) & 15, {for (var i = 0; i <= 10; i++) i: 'Level $i'},
                  (v) => _write(_level, [(v << 4) | v], 'Planet level')),
              _section('The clock'),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Clock origin'),
                subtitle: Text(_clock(_u32(0x0C), _u32(0x10))),
                trailing: OutlinedButton(
                  onPressed: () {
                    final n = DateTime.now();
                    final local = n.millisecondsSinceEpoch ~/ 1000 + n.timeZoneOffset.inSeconds - 1735689600;
                    final h = widget.m.consoleSeconds;
                    final origin = local - h;
                    if (origin < 0) return;
                    final d = origin ~/ 86400, s = origin % 86400;
                    _write(0x0C, [d & 255, (d >> 8) & 255, (d >> 16) & 255, d >> 24, s & 255, (s >> 8) & 255, (s >> 16) & 255, s >> 24], 'Clock');
                  },
                  child: const Text('Set to now'),
                ),
              ),
              _section('Every byte'),
              const Text('The settings block (4 KB) as the game keeps it. Tap a row to change its bytes. Bytes 0 to 3 are the checksum: the app keeps it right.',
                  style: TextStyle(fontSize: 12, color: Colors.white54)),
              const SizedBox(height: 6),
              for (var row = 0; row < 256; row++)
                if (b.sublist(row * 16, row * 16 + 16).any((x) => x != 0) || row == _pet ~/ 16 || row == _level ~/ 16)
                  InkWell(
                    onTap: row == 0 ? null : () => _editRow(row),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        '${(row * 16).toRadixString(16).padLeft(3, '0').toUpperCase()}  '
                        '${[for (var i = 0; i < 16; i++) b[row * 16 + i].toRadixString(16).padLeft(2, '0').toUpperCase()].join(' ')}',
                        style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: row == _pet ~/ 16 || row == _pet ~/ 16 + 1 ? Theme.of(context).colorScheme.primary : null),
                      ),
                    ),
                  ),
              const SizedBox(height: 30),
            ]),
    );
  }

  String _clock(int days, int secs) {
    final t = DateTime.utc(2025).add(Duration(days: days, seconds: secs));
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')} (plus the console\'s running seconds)';
  }

  Widget _section(String s) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 4),
        child: Text(s, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
      );

  Widget _slider(String label, int v, int max, ValueChanged<int> onChanged) => Row(children: [
        SizedBox(width: 92, child: Text(label)),
        Expanded(
          child: Slider(value: v.clamp(0, max).toDouble(), min: 0, max: max.toDouble(), divisions: max, label: '$v', onChanged: (x) => onChanged(x.round())),
        ),
        SizedBox(width: 44, child: Text('$v/$max', textAlign: TextAlign.end)),
      ]);

  Widget _dropdown(String label, int v, Map<int, String> items, ValueChanged<int> onChanged) => Row(children: [
        SizedBox(width: 92, child: Text(label)),
        Expanded(
          child: DropdownButton<int>(
            isExpanded: true,
            value: items.containsKey(v) ? v : null,
            hint: Text('Value $v'),
            items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (x) {
              if (x != null) onChanged(x);
            },
          ),
        ),
      ]);

  Widget _hexField(String label, int v, int digits, ValueChanged<int> onChanged, {String? help}) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: help == null ? null : Text(help, style: const TextStyle(fontSize: 12)),
        trailing: OutlinedButton(
          onPressed: () async {
            final ctl = TextEditingController(text: v.toRadixString(16).toUpperCase().padLeft(digits, '0'));
            final r = await showDialog<String>(
              context: context,
              builder: (c) => AlertDialog(
                title: Text(label),
                content: TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(prefixText: '0x')),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
                  FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Save')),
                ],
              ),
            );
            final n = r == null ? null : int.tryParse(r.trim(), radix: 16);
            if (n != null) onChanged(n);
          },
          child: Text(v.toRadixString(16).toUpperCase().padLeft(digits, '0')),
        ),
      );

  Future<void> _editRow(int row) async {
    final b = _b!;
    final ctl = TextEditingController(text: [for (var i = 0; i < 16; i++) b[row * 16 + i].toRadixString(16).padLeft(2, '0').toUpperCase()].join(' '));
    final r = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Bytes at ${(row * 16).toRadixString(16).toUpperCase()}'),
        content: TextField(controller: ctl, autofocus: true, maxLines: 2, style: const TextStyle(fontFamily: 'monospace')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Save')),
        ],
      ),
    );
    if (r == null) return;
    final parts = r.trim().split(RegExp(r'\s+'));
    final v = [for (final p in parts) int.tryParse(p, radix: 16)];
    if (v.length != 16 || v.any((x) => x == null || x > 255)) {
      setState(() => _note = 'Sixteen bytes in hex, separated by spaces.');
      return;
    }
    _write(row * 16, v.cast<int>(), 'Row ${(row * 16).toRadixString(16).toUpperCase()}');
  }
}
