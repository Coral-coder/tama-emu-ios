import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../emu/rom_info.dart';
import '../paramix/compose.dart';
import '../paramix/edition.dart' as ed;
import '../paramix/feld.dart' as feld;
import '../paramix/six.dart' as six;
import '../services/app_state.dart';
import '../services/rom_library.dart';
import 'device_screen.dart';

/// Native build of the on-device menu (several saves, items, Tamapoints, change Tama) and of
/// more fields (all 6 on Tropical / Glacier, Sky on Jade Forest): Paramix Studio's logic ported
/// to Dart (lib/paramix), no web page.
class MenuFieldsScreen extends StatefulWidget {
  const MenuFieldsScreen({super.key});

  @override
  State<MenuFieldsScreen> createState() => _MenuFieldsScreenState();
}

class _Job {
  _Job(this.src, this.o, this.a);
  final Uint8List src;
  final ComposeOptions o;
  final ComposeAssets a;
}

({Uint8List? rom, String? error}) _build(_Job j) {
  try {
    return (rom: composeRom(j.src, j.o, j.a), error: null);
  } on ComposeError catch (e) {
    return (rom: null, error: e.message);
  } catch (e) {
    return (rom: null, error: '$e');
  }
}

class _MenuFieldsScreenState extends State<MenuFieldsScreen> {
  AppState get app => AppState.instance;
  RomEntry? _rom;
  Uint8List? _bytes;
  String _edition = '';
  String? _kind; // gen3 (Tropical / Glacier), jade, or null
  bool _neon = false;
  six.SixInfo? _six;
  feld.FeldInfo? _menu;
  ComposeAssets? _assets;

  bool _saves = true, _bag = true, _tama = true, _gplay = false;
  bool _more = false, _planet = true, _fieldMenu = true;
  RomEntry? _source;
  bool _busy = false;
  String? _note;

  List<RomEntry> get _paradise => app.library.entries.where((e) => e.kind == RomKind.paradise).toList();

  Future<ComposeAssets> _load() async {
    Future<Uint8List> f(String n) async => (await rootBundle.load('assets/paramix/$n')).buffer.asUint8List();
    return _assets ??= ComposeAssets(
        feld: await f('feld.bin'), feldS: await f('feld_s.bin'), stubFeld: await f('stub_feld_tpl.bin'), stubEmu: await f('stub_tpl.bin'), six: await f('six.bin'));
  }

  Future<void> _pick(RomEntry e) async {
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      final a = await _load();
      final b = await app.library.bytes(e);
      final edn = ed.edition(b);
      setState(() {
        _rom = e;
        _bytes = b;
        _edition = edn?.name ?? 'not a Paradise ROM';
        _kind = six.sixCan(b) ? six.kindOf(b) : null;
        _neon = !feld.canFields(b) && edn != null;
        _six = six.sixInfo(b);
        _menu = feld.feldFind(b, a.stubFeld);
        final m = _menu;
        if (m != null) {
          _saves = (m.flags & feld.fFields) != 0;
          _bag = (m.flags & feld.fBag) != 0;
          _tama = (m.flags & feld.fTama) != 0;
          _gplay = (m.flags & feld.fGplay) != 0;
        } else {
          _saves = !_neon;
          _bag = _tama = true;
          _gplay = false;
        }
        _more = _six != null;
        _planet = _six?.planet ?? true;
        _fieldMenu = _six?.fieldMenu ?? true;
        _source = null;
      });
    } catch (err) {
      setState(() => _note = 'This ROM could not be opened: $err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _choose({required bool source}) async {
    final list = source ? _paradise.where((e) => e.id != _rom?.id).toList() : _paradise;
    final e = await showModalBottomSheet<RomEntry>(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(title: Text(source ? 'Your Land, Water or Sky ROM' : 'Which ROM?')),
          for (final r in list) ListTile(leading: const Icon(Icons.memory), title: Text(r.name), onTap: () => Navigator.pop(c, r)),
        ]),
      ),
    );
    if (e == null) return;
    if (!source) return _pick(e);
    final b = await app.library.bytes(e);
    if (!six.sixSource(b)) {
      setState(() => _note = '${e.name} is not an unchanged Land, Water or Sky ROM.');
      return;
    }
    setState(() {
      _source = e;
      _note = null;
    });
  }

  Future<void> _go() async {
    final src = _bytes, rom = _rom;
    if (src == null || rom == null) return;
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      final a = await _load();
      final sourceBytes = _more && _kind == 'gen3' && _source != null ? await app.library.bytes(_source!) : null;
      final o = ComposeOptions(
        fields: _saves && !_neon,
        bag: _bag,
        tama: _tama,
        gplay: _gplay,
        sixWant: _more && _kind != null,
        sixOff: !_more && _six != null,
        sixSource: sourceBytes,
        sixPlanet: _planet,
        sixMenu: _fieldMenu,
      );
      final r = await compute(_build, _Job(src, o, a));
      if (!mounted) return;
      if (r.rom == null) {
        setState(() => _note = r.error);
        return;
      }
      await _done(rom, r.rom!);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _done(RomEntry from, Uint8List out) async {
    final same = listEquals(out, _bytes);
    final name = '${from.name.replaceAll(RegExp(r' \(menu\)$'), '')} (menu)';
    final file = '${name.replaceAll(RegExp(r'[^A-Za-z0-9 _.()-]'), '_')}.bin';
    await showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(same ? 'Nothing changed' : 'Your new ROM is ready'),
            subtitle: Text(same ? 'This ROM already has exactly these settings.' : 'On the toy: hold A and C on the home screen to open the menu. Wheel selects, B confirms, C goes back.'),
          ),
          if (!same) ...[
            ListTile(
              leading: const Icon(Icons.play_arrow_rounded),
              title: const Text('Add to my games and play'),
              onTap: () async {
                Navigator.pop(c);
                final e = await app.library.import(out, file, note: 'menu / fields built in');
                await app.playParadise(e);
                if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
            ListTile(
              leading: const Icon(Icons.usb_rounded),
              title: const Text('Write it to my toy'),
              subtitle: const Text('Over the dongle; the toy keeps its save.'),
              onTap: () async {
                Navigator.pop(c);
                await app.library.import(out, file, note: 'menu / fields built in');
                if (mounted) await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DeviceScreen()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.library_add_outlined),
              title: const Text('Just add it to my ROMs'),
              onTap: () async {
                Navigator.pop(c);
                await app.library.import(out, file, note: 'menu / fields built in');
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('Share the file'),
              onTap: () async {
                Navigator.pop(c);
                await app.library.studioOut.create(recursive: true);
                final f = File('${app.library.studioOut.path}/$file');
                await f.writeAsBytes(out, flush: true);
                await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], subject: file));
              },
            ),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final has = _bytes != null;
    final sixHelp = _kind == 'gen3'
        ? 'Land, Water and Sky join Tropical, Glacier and Forest. The pictures come from your own Land, Water or Sky ROM.'
        : 'Sky becomes the 4th field. Jade Forest already has everything of Sky.';
    final needSource = _more && _kind == 'gen3' && (_six == null || _six!.planet != _planet || _six!.fieldMenu != _fieldMenu || six.sixStale(_six));
    return Scaffold(
      appBar: AppBar(title: const Text('Menu & fields')),
      body: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 24), children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.memory),
            title: Text(_rom?.name ?? 'Choose a ROM'),
            subtitle: Text(has
                ? '$_edition${_menu != null ? ' · menu built in' : ''}${_six != null ? ' · more fields built in' : ''}'
                : 'One of your Paradise ROMs. A new ROM is made; this one stays as it is.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : () => _choose(source: false),
          ),
        ),
        if (has) ...[
          const Padding(padding: EdgeInsets.fromLTRB(4, 16, 4, 4), child: Text('Menu on the toy (hold A + C on the home screen)')),
          Card(
            child: Column(children: [
              if (!_neon)
                SwitchListTile(
                  title: const Text('Several saves, with field choice'),
                  subtitle: const Text('Switch between saves; a new save starts on a field you pick.'),
                  value: _saves,
                  onChanged: (v) => setState(() => _saves = v),
                ),
              if (_neon) const ListTile(dense: true, title: Text('Neon Planets switches its planets itself: no field switch.')),
              SwitchListTile(
                title: const Text('Items and Tamapoints'),
                subtitle: const Text('Put items in the bag, set the Tamapoints.'),
                value: _bag,
                onChanged: (v) => setState(() => _bag = v),
              ),
              SwitchListTile(
                title: const Text('Change Tama'),
                subtitle: const Text('Level, care and character.'),
                value: _tama,
                onChanged: (v) => setState(() => _tama = v),
              ),
            ]),
          ),
          if (_kind != null) ...[
            const Padding(padding: EdgeInsets.fromLTRB(4, 16, 4, 4), child: Text('More fields')),
            Card(
              child: Column(children: [
                SwitchListTile(
                  title: Text(_kind == 'gen3' ? 'All 6 fields' : 'Sky as 4th field'),
                  subtitle: Text(sixHelp),
                  value: _more,
                  onChanged: (v) => setState(() => _more = v),
                ),
                if (_more && _kind == 'gen3')
                  ListTile(
                    leading: const Icon(Icons.landscape_rounded),
                    title: Text(_source?.name ?? (needSource ? 'Choose your Land, Water or Sky ROM' : 'Land, Water or Sky ROM (only to change the settings below)')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _busy ? null : () => _choose(source: true),
                  ),
                if (_more)
                  SwitchListTile(
                    title: const Text('Planet to match the field'),
                    subtitle: const Text('Land, Water and Sky show their own planet, like the original toys.'),
                    value: _planet,
                    onChanged: (v) => setState(() => _planet = v),
                  ),
                if (_more)
                  SwitchListTile(
                    title: const Text('All fields in the game\'s own field menu'),
                    subtitle: const Text('From planet level 4, and the Tama stays.'),
                    value: _fieldMenu,
                    onChanged: (v) => setState(() => _fieldMenu = v),
                  ),
              ]),
            ),
          ],
          if (_note != null) Padding(padding: const EdgeInsets.all(12), child: Text(_note!, style: const TextStyle(color: Colors.redAccent))),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _go,
            icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.build_rounded),
            label: Text(_busy ? 'Building …' : 'Build the new ROM'),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 12, 4, 0),
            child: Text('Read a backup of your toy before writing a changed ROM to it (Paramix → Device).', style: TextStyle(fontSize: 12, color: Colors.white54)),
          ),
        ],
        if (!has && _note != null) Padding(padding: const EdgeInsets.all(12), child: Text(_note!, style: const TextStyle(color: Colors.redAccent))),
      ]),
    );
  }
}
