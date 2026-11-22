import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../paradise/paradise_core.dart';
import '../paradise/paradise_machine.dart';
import '../services/app_state.dart';
import 'theme.dart';

/// Looking after the pet from a menu: its state read live from the game, feeding, playing and
/// medicine at a touch, and care kept up by itself (while you are at work: the game keeps running
/// in the background, and the care is checked every 10 seconds of game time).
Future<void> showCare(BuildContext context, ParadiseMachine m, String romId) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: kPanel,
    builder: (_) => _Care(m: m, romId: romId),
  );
}

class _Care extends StatefulWidget {
  const _Care({required this.m, required this.romId});
  final ParadiseMachine m;
  final String romId;

  @override
  State<_Care> createState() => _CareState();
}

class _CareState extends State<_Care> {
  Timer? _tick;
  PetState? _pet;
  String? _note;

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

  void _read() => setState(() => _pet = widget.m.pet());

  void _do(int what, String done) {
    final ok = widget.m.care(what);
    setState(() => _note = ok ? done : 'No pet in this game yet.');
    _read();
  }

  Future<void> _auto(int bit, bool on) async {
    final v = on ? widget.m.autoCareBits | bit : widget.m.autoCareBits & ~bit;
    widget.m.autoCareBits = v;
    await AppState.instance.setAutoCare(widget.romId, v);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = _pet;
    final auto = widget.m.autoCareBits;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Care', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          if (p == null || !p.exists)
            const Text('No pet found in this game yet (it appears once one has hatched).', style: TextStyle(color: Colors.white60))
          else ...[
            _row('Hunger', _hearts(p.hunger, 6)),
            const SizedBox(height: 8),
            _row('Happiness', _bar(p.happy, 20)),
            const SizedBox(height: 8),
            _row('Health', Text(p.sick == 0 ? 'Well' : 'Sick', style: TextStyle(color: p.sick == 0 ? Colors.greenAccent : Colors.redAccent))),
            const SizedBox(height: 8),
            _row('Stage', Text('${p.stageName} · character ${p.character.toRadixString(16).toUpperCase().padLeft(4, '0')} · planet level ${p.level}',
                style: const TextStyle(color: Colors.white70))),
          ],
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: FilledButton.icon(onPressed: () => _do(ParadiseHandle.careFeed, 'Fed: full.'), icon: const Icon(Icons.restaurant), label: const Text('Feed'))),
            const SizedBox(width: 8),
            Expanded(child: FilledButton.icon(onPressed: () => _do(ParadiseHandle.carePlay, 'Played: happy.'), icon: const Icon(Icons.sports_esports), label: const Text('Play'))),
            const SizedBox(width: 8),
            Expanded(child: FilledButton.icon(onPressed: () => _do(ParadiseHandle.careCure, 'Medicine given.'), icon: const Icon(Icons.healing), label: const Text('Cure'))),
          ]),
          if (_note != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_note!, style: const TextStyle(color: Colors.white60))),
          const Divider(height: 28),
          const Text('Daycare: kept up by itself, also in the background', style: TextStyle(color: Colors.white70)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Keep fed'),
            value: auto & ParadiseHandle.careFeed != 0,
            onChanged: (v) => _auto(ParadiseHandle.careFeed, v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Keep happy'),
            value: auto & ParadiseHandle.carePlay != 0,
            onChanged: (v) => _auto(ParadiseHandle.carePlay, v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Keep healthy'),
            value: auto & ParadiseHandle.careCure != 0,
            onChanged: (v) => _auto(ParadiseHandle.careCure, v),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => GameInside(m: widget.m))),
              icon: const Icon(Icons.manage_search),
              label: const Text('Look inside the game'),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _row(String label, Widget v) => Row(children: [SizedBox(width: 92, child: Text(label, style: const TextStyle(color: Colors.white60))), Expanded(child: v)]);

  Widget _hearts(int n, int max) => Row(children: [
        for (var i = 0; i < max; i++) Icon(i < n ? Icons.favorite : Icons.favorite_border, size: 20, color: kAmber),
        Text('  $n / $max', style: const TextStyle(color: Colors.white54)),
      ]);

  Widget _bar(int n, int max) => Row(children: [
        Expanded(child: LinearProgressIndicator(value: (n / max).clamp(0.0, 1.0), minHeight: 8, borderRadius: BorderRadius.circular(4))),
        Text('  $n / $max', style: const TextStyle(color: Colors.white54)),
      ]);
}

/// The game's settings block, live from memory: every byte, the known fields named, changes
/// lit up as the game writes them.
class GameInside extends StatefulWidget {
  const GameInside({super.key, required this.m});
  final ParadiseMachine m;

  @override
  State<GameInside> createState() => _GameInsideState();
}

class _GameInsideState extends State<GameInside> {
  Timer? _tick;
  Uint8List? _b, _prev;
  final Map<int, int> _changedAt = {};
  int _frame = 0;

  @override
  void initState() {
    super.initState();
    _read();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) => _read());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _read() {
    final b = widget.m.block();
    _frame++;
    if (b != null && _prev != null) {
      for (var i = 0; i < b.length; i++) {
        if (b[i] != _prev![i]) _changedAt[i] = _frame;
      }
    }
    setState(() {
      _prev = b;
      _b = b;
    });
  }

  @override
  Widget build(BuildContext context) {
    final b = _b;
    final pet = widget.m.pet();
    return Scaffold(
      appBar: AppBar(title: const Text('Inside the game')),
      body: b == null
          ? const Center(child: Text('The settings block is not in memory yet.'))
          : ListView(padding: const EdgeInsets.all(12), children: [
              Text(
                'The settings block (4 KB, kept in flash and worked on in memory at 0x${(pet?.block ?? 0).toRadixString(16).toUpperCase()}). '
                'Bytes that just changed are lit. Known: +0x0C clock days since 2025, +0x10 clock seconds, '
                'pet record +0x104 (Land, Water, Sky) / +0x108 (Jade) / +0x114 (Tropical, Glacier, Neon): '
                '+4 character, +0x10 sickness, +0x18 stage (bits 2-4), +0x1C hunger 0-6, +0x1D happiness 0-20.',
                style: const TextStyle(color: Colors.white60, fontSize: 12),
              ),
              const SizedBox(height: 10),
              for (var row = 0; row < 256; row++)
                if (b.sublist(row * 16, row * 16 + 16).any((x) => x != 0) || _changedRow(row))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Text.rich(TextSpan(children: [
                      TextSpan(text: '${(row * 16).toRadixString(16).padLeft(3, '0').toUpperCase()}  ', style: const TextStyle(color: Colors.white38)),
                      for (var i = row * 16; i < row * 16 + 16; i++)
                        TextSpan(
                          text: '${b[i].toRadixString(16).padLeft(2, '0').toUpperCase()} ',
                          style: TextStyle(color: (_changedAt[i] ?? -99) >= _frame - 4 ? kAmber : (b[i] == 0 ? Colors.white24 : Colors.white)),
                        ),
                    ]), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                  ),
            ]),
    );
  }

  bool _changedRow(int row) {
    for (var i = row * 16; i < row * 16 + 16; i++) {
      if ((_changedAt[i] ?? -99) >= _frame - 4) return true;
    }
    return false;
  }
}
