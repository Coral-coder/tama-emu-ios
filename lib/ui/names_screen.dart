import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../emu/rom_info.dart';
import '../paramix/compose.dart';
import '../paramix/core_more.dart' as core;
import '../paramix/feld.dart' as feld;
import '../services/app_state.dart';
import '../services/rom_library.dart';

/// Native: rename fields, Tamas and items of a ROM (every language with Latin letters on the
/// toy). Paramix Studio's text code ported to Dart, no web page.
class NamesScreen extends StatefulWidget {
  const NamesScreen({super.key});

  @override
  State<NamesScreen> createState() => _NamesScreenState();
}

class _Row {
  _Row(this.idx, this.name, this.max);
  final List<int> idx;
  final String name;
  final int max;
}

class _Job {
  _Job(this.src, this.texts, this.a);
  final Uint8List src;
  final Map<int, String> texts;
  final ComposeAssets a;
}

({Uint8List? rom, String? error}) _build(_Job j) {
  try {
    return (rom: composeRom(j.src, ComposeOptions.of(j.src, j.a, texts: j.texts), j.a), error: null);
  } on ComposeError catch (e) {
    return (rom: null, error: e.message);
  } catch (e) {
    return (rom: null, error: '$e');
  }
}

class _NamesScreenState extends State<NamesScreen> {
  AppState get app => AppState.instance;
  RomEntry? _rom;
  Uint8List? _bytes;
  List<_Row> _fields = [], _tamas = [], _items = [];
  final Map<int, String> _texts = {};
  String _find = '';
  bool _busy = false;
  String? _note;

  Future<ComposeAssets> _assets() async {
    Future<Uint8List> f(String n) async => (await rootBundle.load('assets/paramix/$n')).buffer.asUint8List();
    return ComposeAssets(feld: await f('feld.bin'), feldS: await f('feld_s.bin'), stubFeld: await f('stub_feld_tpl.bin'), stubEmu: await f('stub_tpl.bin'), six: await f('six.bin'));
  }

  Future<void> _choose() async {
    final list = app.library.entries.where((e) => e.kind == RomKind.paradise).toList();
    final e = await showModalBottomSheet<RomEntry>(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Which ROM?')),
          for (final r in list) ListTile(leading: const Icon(Icons.memory), title: Text(r.name), onTap: () => Navigator.pop(c, r)),
        ]),
      ),
    );
    if (e == null) return;
    setState(() => _busy = true);
    try {
      final b = await app.library.bytes(e);
      final fields = <_Row>[], tamas = <_Row>[], items = <_Row>[];
      for (final f in fieldTextRows(b)) {
        fields.add(_Row(f.idx, f.name, 11));
      }
      final seen = <int>{};
      try {
        final ctx = core.openRom(b);
        for (final c in core.charTable(ctx.files[0]).where((c) => c.id > 1000 && c.id < 9000)) {
          if (seen.contains(c.name)) continue;
          final nm = core.textGet(b, c.name);
          if (nm.isEmpty) continue;
          seen.add(c.name);
          tamas.add(_Row([c.name], nm, 12));
        }
      } catch (_) {
        // no character table
      }
      for (final it in feld.itemCatalog(b).items) {
        if (seen.contains(it.text)) continue;
        final nm = core.textGet(b, it.text);
        if (nm.isEmpty) continue;
        seen.add(it.text);
        items.add(_Row([it.text], nm, 22));
      }
      setState(() {
        _rom = e;
        _bytes = b;
        _fields = fields;
        _tamas = tamas;
        _items = items;
        _texts.clear();
        _note = null;
      });
    } catch (err) {
      setState(() => _note = 'This ROM could not be opened: $err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _set(_Row r, String input) {
    final v = core.textClean(input) ?? '';
    setState(() {
      for (final i in r.idx) {
        if (v.isEmpty || v == r.name) {
          _texts.remove(i);
        } else {
          _texts[i] = v;
        }
      }
    });
  }

  Future<void> _go() async {
    final src = _bytes, rom = _rom;
    if (src == null || rom == null || _texts.isEmpty) return;
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      final r = await compute(_build, _Job(src, Map.of(_texts), await _assets()));
      if (!mounted) return;
      if (r.rom == null) {
        setState(() => _note = r.error);
        return;
      }
      final name = '${rom.name.replaceAll(RegExp(r' \(names\)$'), '')} (names)';
      final e = await app.library.import(r.rom!, '${name.replaceAll(RegExp(r'[^A-Za-z0-9 _.()-]'), '_')}.bin', note: 'names changed');
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Your new ROM is ready'),
          content: Text('${e.name} is in your ROMs: play it, or write it to the toy from Paramix → Device.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
            FilledButton(
              onPressed: () async {
                Navigator.pop(c);
                await app.playParadise(e);
                if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
              },
              child: const Text('Play it'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _list(String title, List<_Row> rows, {bool search = false}) {
    final q = _find.toUpperCase();
    final shown = search && q.isNotEmpty ? rows.where((r) => r.name.contains(q) || (_texts[r.idx.first] ?? '').contains(q)).toList() : rows;
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.fromLTRB(4, 16, 4, 4), child: Text('$title (${rows.length})')),
      Card(
        child: Column(children: [
          for (final r in shown.take(search ? 60 : 400))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: TextFormField(
                key: ValueKey('${_rom?.id}:${r.idx.first}'),
                initialValue: _texts[r.idx.first] ?? r.name,
                maxLength: r.max,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(labelText: r.name, counterText: '', suffixIcon: _texts.containsKey(r.idx.first) ? const Icon(Icons.edit, size: 16) : null),
                onChanged: (v) => _set(r, v),
              ),
            ),
          if (search && shown.length > 60) const Padding(padding: EdgeInsets.all(8), child: Text('Search to see more.', style: TextStyle(color: Colors.white54))),
        ]),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final has = _bytes != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Names'), actions: [
        if (_texts.isNotEmpty) TextButton(onPressed: () => setState(_texts.clear), child: const Text('Reset all')),
      ]),
      body: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 24), children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.memory),
            title: Text(_rom?.name ?? 'Choose a ROM'),
            subtitle: Text(has ? 'Capitals, digits, space and . & \' ! ? /' : 'One of your Paradise ROMs. A new ROM is made; this one stays as it is.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _choose,
          ),
        ),
        if (has) ...[
          _list('Fields', _fields),
          _list('Tamas', _tamas),
          if (_items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search items'), onChanged: (v) => setState(() => _find = v)),
            ),
          _list('Items', _items, search: true),
          if (_note != null) Padding(padding: const EdgeInsets.all(12), child: Text(_note!, style: const TextStyle(color: Colors.redAccent))),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy || _texts.isEmpty ? null : _go,
            icon: const Icon(Icons.build_rounded),
            label: Text(_busy ? 'Building …' : (_texts.isEmpty ? 'Change a name first' : 'Build the new ROM')),
          ),
        ],
        if (!has && _note != null) Padding(padding: const EdgeInsets.all(12), child: Text(_note!, style: const TextStyle(color: Colors.redAccent))),
      ]),
    );
  }
}
