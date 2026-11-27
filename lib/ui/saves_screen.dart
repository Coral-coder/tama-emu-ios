import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../emu/rom_info.dart';
import '../paramix/edition.dart' show editionNames;
import '../paramix/flash.dart';
import '../paramix/save_flow.dart' as sf;
import '../paramix/saves.dart';
import '../paramix/sprites.dart' show Rgba;
import '../services/app_state.dart';
import '../services/native.dart';
import '../services/rom_library.dart';
import '../services/save_backups.dart';
import '../services/serial/serial_hub.dart';
import '../services/serial/usb_transport.dart';
import 'hardware_screen.dart';
import 'theme.dart';

/// Save games of the Paradise, native: take a save from the toy, a ROM, a file or a game of the
/// app; see and change what is in it; keep it, share it, put it into a ROM or onto the toy.
/// What Paramix Studio's Save tab and the save buttons of its device panel do
/// (lib/paramix/save_flow.dart), without the web page.
class SavesScreen extends StatefulWidget {
  const SavesScreen({super.key});

  @override
  State<SavesScreen> createState() => _SavesScreenState();
}

typedef _Groups = List<({String label, int stage, List<sf.PetChar> chars})>;

/// Names and pictures of a ROM's characters (worked out off the UI thread).
({_Groups groups, Map<int, sf.CharLook> looks}) _lookJob(Uint8List rom) => (groups: sf.petChars(rom), looks: sf.charLooks(rom));

/// The save that is open.
class _Open {
  _Open(this.pet, this.source, this.name);
  sf.PetOpen pet;

  /// Where it came from, and the base of its file name.
  final String source, name;
  bool edited = false;

  /// The ROM the names and pictures come from.
  RomEntry? namesRom;
  _Groups groups = const [];
  Map<int, sf.CharLook> looks = const {};

  ParaSave get save => pet.save;
  int get edition => pet.edition;
}

class _SavesScreenState extends State<SavesScreen> {
  AppState get app => AppState.instance;
  SerialHub get hub => app.serial;
  RomLibrary get lib => app.library;
  late final SaveBackups _store = SaveBackups(Directory('${lib.docs.path}/save_backups'));
  List<SaveBackup> _backups = [];

  _Open? _cur;
  int _level = 0;
  sf.PetChar? _char;
  bool _care = false;
  final Map<int, Future<ui.Image?>> _pics = {};

  // the toy on the dongle
  List<UsbAdapter> _usb = [];
  FlashLink? _link;
  Paradise? _dev;
  Uint8List? _flashApp;
  Timer? _usbPoll;

  bool _busy = false, _cancel = false, _canCancel = false;
  String _phase = '';
  double? _progress;
  String? _note;
  bool _noteBad = false;

  @override
  void initState() {
    super.initState();
    _reloadBackups();
    _refreshUsb();
    _usbPoll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!hub.connected) _refreshUsb();
    });
    hub.addListener(_hubChanged);
  }

  @override
  void dispose() {
    _usbPoll?.cancel();
    hub.removeListener(_hubChanged);
    _link?.dispose();
    super.dispose();
  }

  void _hubChanged() {
    if (!hub.connected && _dev != null) {
      _link?.dispose();
      _link = null;
      _dev = null;
    }
    if (mounted) setState(() {});
  }

  Future<void> _refreshUsb() async {
    if (!UsbTransport.supported) return;
    try {
      final l = await UsbTransport.list();
      if (mounted) setState(() => _usb = l);
      // one adapter plugged in and nothing connected: open it right away
      if (l.length == 1 && !hub.connected && !_busy) await _openUsb(l.first);
    } catch (_) {}
  }

  Future<void> _openUsb(UsbAdapter a) => _task('Opening ${a.name}', () async {
        await hub.attach(await UsbTransport.open(a, paradiseBaud));
        hub.baud = paradiseBaud;
      });

  Future<void> _reloadBackups() async {
    final l = await _store.list();
    if (mounted) setState(() => _backups = l);
  }

  // ------------------------------------------------------------------ tasks and messages
  void _say(String s, {bool bad = false}) {
    if (!mounted) return;
    setState(() {
      _note = s;
      _noteBad = bad;
    });
  }

  void _prog(String phase, int done, int total) {
    if (!mounted) return;
    setState(() {
      _phase = switch (phase) {
        'load' => 'Loading the flash app',
        'read' => 'Reading the save',
        'compare' => 'Looking what is on the toy',
        'write' => 'Writing',
        'check' => 'Checking',
        'prepare' => 'Preparing',
        _ => phase,
      };
      _progress = total > 0 ? (done / total).clamp(0.0, 1.0) : null;
    });
  }

  String _why(Object e) => switch (e) {
        FlashError() => e.code == 'cancelled' ? 'Cancelled. Nothing was written.' : e.message,
        sf.SaveFlowError() => e.message,
        FormatException() => e.message,
        StateError() => e.message,
        _ => '$e',
      };

  /// Runs a piece of work with the progress card. [device]: work on the toy, which takes a
  /// while: the app stays alive in the background and the screen stays on, as on the Device page.
  Future<void> _task(String what, Future<void> Function() f, {bool device = false, bool canCancel = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _cancel = false;
      _canCancel = canCancel;
      _phase = what;
      _progress = null;
    });
    if (device) {
      await NativeBridge.keepAlive(true, title: 'Tama', text: what);
      await NativeBridge.keepScreenOn(true);
    }
    try {
      await f();
    } catch (e) {
      _say(_why(e), bad: true);
    } finally {
      if (device) {
        await NativeBridge.keepScreenOn(false);
        if (!(app.backgroundRun && (app.games.isNotEmpty || app.machine != null))) await NativeBridge.keepAlive(false);
      }
      if (mounted) {
        setState(() {
          _busy = false;
          _phase = '';
          _progress = null;
        });
      }
    }
  }

  Future<bool> _confirm(String title, String text, String yes) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(text)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(yes)),
        ],
      ),
    );
    return r == true;
  }

  Future<RomEntry?> _pickRom(String title, {String? hint}) {
    final list = lib.entries.where((e) => e.kind == RomKind.paradise).toList();
    return showModalBottomSheet<RomEntry>(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(title: Text(title), subtitle: hint == null ? null : Text(hint)),
          if (list.isEmpty) const ListTile(title: Text('No Paradise ROM in your library yet.')),
          for (final r in list) ListTile(leading: const Icon(Icons.memory), title: Text(r.name), subtitle: r.note == null ? null : Text(r.note!), onTap: () => Navigator.pop(c, r)),
        ]),
      ),
    );
  }

  // ------------------------------------------------------------------ opening a save
  /// Shows a save. [rom] and [entry]: the ROM it belongs to (for names and pictures); without
  /// one a ROM of the same kind is looked for in the library.
  Future<void> _show(ParaSave save, String source, String name, {Uint8List? rom, RomEntry? entry}) async {
    var names = rom;
    var from = entry;
    if (names == null) {
      final want = save.edition;
      for (final e in lib.entries.where((e) => e.kind == RomKind.paradise)) {
        if (want == 0) break;
        try {
          final b = await lib.bytes(e), id = sf.romEdition(b);
          if (id != 0 && family(id) == family(want)) {
            names = b;
            from = e;
            // the same edition is the best match; else any ROM of the same firmware
            if (id == want) break;
          }
        } catch (_) {}
      }
    }
    final o = _Open(sf.petOpen(save, names == null ? null : sf.romEdition(names)), source, name)..namesRom = from;
    if (names != null) {
      final l = await compute(_lookJob, names);
      o.groups = l.groups;
      o.looks = l.looks;
    }
    if (!mounted) return;
    setState(() {
      _cur = o;
      _pics.clear();
      _resetControls();
      _note = null;
    });
  }

  void _resetControls() {
    _level = _cur?.pet.pet.level ?? 0;
    _char = null;
    _care = false;
  }

  Future<bool> _connect() async {
    if (_dev != null) return true;
    if (!hub.connected) {
      _say('Plug the dongle in first (USB), wire it to the toy and put the toy on its download screen.', bad: true);
      return false;
    }
    await _task('Connecting to the toy', device: true, () async {
      _flashApp ??= (await rootBundle.load('assets/paramix/flashapp.bin')).buffer.asUint8List();
      _link?.dispose();
      final link = FlashLink(hub.input, hub.write);
      _link = link;
      if (hub.transport?.canSetBaud ?? false) await hub.setBaud(paradiseBaud);
      final ble = hub.transport?.kind == 'BLE';
      final (dev, _) = await connectParadise(link, _flashApp!, _prog, readBlock: ble ? 1024 : null);
      _dev = dev;
      _say('Connected: Paradise ${dev.info!.name}.');
    });
    return _dev != null;
  }

  Future<void> _fromToy() async {
    if (!await _connect()) return;
    await _task('Backing up the save of the toy', device: true, canCancel: true, () async {
      final d = sf.ParadiseSaveDevice(_dev!);
      final bk = await sf.devSaveRead(d, progress: _prog, cancel: () => _cancel);
      final source = 'My toy (${d.name})';
      // a backup is a backup: it is kept right away, whatever is in it
      final kept = await _store.add(bk.file, title: 'Paradise ${d.name}', source: source, edition: d.edition);
      await _reloadBackups();
      await _show(bk.save, source, sf.edSlug(d.edition));
      final c = _cur;
      if (c != null) {
        // now that the names are known: say what is in it
        await _store.remove(kept);
        await _store.add(bk.file, title: _summary(c), source: source, edition: d.edition, now: kept.date);
        await _reloadBackups();
      }
      _say('Backed up from the toy and kept under Backups.${bk.clock ? ' The clock is in it.' : ' The clock could not be read: set it on the toy after writing this save back.'}');
    });
  }

  Future<void> _fromRom() async {
    final e = await _pickRom('The save of which ROM?', hint: 'A ROM read from a toy has that toy\'s game in it.');
    if (e == null) return;
    await _task('Opening ${e.name}', () async {
      final rom = await lib.bytes(e);
      if (sf.romEdition(rom) == 0) throw sf.SaveFlowError('noEdition', 'This ROM has no Paradise in it, so it has no Paradise save.');
      var save = sf.romSave(rom);
      var source = 'ROM: ${e.name}';
      // the menu of a ROM made with Paramix can keep further saves in slots
      final stub = (await rootBundle.load('assets/paramix/stub_feld_tpl.bin')).buffer.asUint8List();
      final ss = sf.paraSlots(rom, stub);
      if (ss != null && mounted) {
        final choices = sf.slotChoices(ss, rom);
        if (choices.any((c) => !c.live && c.used)) {
          final pick = await showModalBottomSheet<sf.SlotChoice>(
            context: context,
            builder: (c) => SafeArea(
              child: ListView(shrinkWrap: true, children: [
                const ListTile(title: Text('Which save?'), subtitle: Text('The menu of this ROM keeps several.')),
                for (final x in choices) ListTile(leading: Icon(x.live ? Icons.play_circle_outline : Icons.save_outlined), title: Text(x.label), enabled: x.used, onTap: () => Navigator.pop(c, x)),
              ]),
            ),
          );
          if (pick == null) return;
          if (!pick.live) {
            save = await sf.romSlotSave(rom, ss, pick.index);
            source = 'ROM: ${e.name}, ${pick.label}';
          }
        }
      }
      await _show(save, source, e.name, rom: rom, entry: e);
    });
  }

  Future<void> _fromFile() async {
    List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles(type: FileType.any);
    } catch (e) {
      _say('The file picker failed: $e', bad: true);
      return;
    }
    if (picked.isEmpty) return;
    final f = picked.first;
    await _task('Opening ${f.name}', () async {
      final path = f.path;
      final b = path != null ? await File(path).readAsBytes() : await f.readAsBytes();
      final save = paraDecode(b);
      final name = f.name.replaceFirst(RegExp(r'\.(tamasave|save)$', caseSensitive: false), '');
      if (save.edition != 0) {
        await _show(save, 'File: ${f.name}', name);
        return;
      }
      // a save of the emulator (this app's or Capybara's): it does not say which Paradise it
      // is from and holds only the pages the game wrote; with its ROM it becomes a whole save
      if (!mounted) return;
      final e = await _pickRom('Which ROM does this save belong to?', hint: 'This file does not say which Paradise it is from. Choose the ROM the game was played with.');
      if (e == null) return;
      final rom = await lib.bytes(e);
      await _show(sf.gameSave(rom, b), 'File: ${f.name} (with ${e.name})', name, rom: rom, entry: e);
    });
  }

  Future<void> _fromGame() async {
    final games = <RomEntry>[];
    for (final e in lib.entries.where((e) => e.kind == RomKind.paradise)) {
      if (app.games.containsKey(e.id) || await lib.paradiseSave(e).exists()) games.add(e);
    }
    if (!mounted) return;
    final e = await showModalBottomSheet<RomEntry>(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('The save of which game?')),
          if (games.isEmpty) const ListTile(title: Text('No game has been played in the app yet.')),
          for (final r in games)
            ListTile(leading: Icon(app.games.containsKey(r.id) ? Icons.play_circle_outline : Icons.save_outlined), title: Text(r.name), subtitle: Text(app.games.containsKey(r.id) ? 'Running now' : 'Saved game'), onTap: () => Navigator.pop(c, r)),
        ]),
      ),
    );
    if (e == null) return;
    await _task('Opening ${e.name}', () async {
      app.games[e.id]?.save(); // a running game: as it is right now
      final file = lib.paradiseSave(e);
      if (!await file.exists()) throw sf.SaveFlowError('noGame', 'This game has not saved anything yet. Play it for a moment first.');
      final rom = await lib.bytes(e);
      await _show(sf.gameSave(rom, await file.readAsBytes()), 'Game in the app: ${e.name}', e.name, rom: rom, entry: e);
    });
  }

  Future<void> _fromBackup(SaveBackup b) => _task('Opening the backup', () async {
        await _show(paraDecode(await b.file.readAsBytes()), 'Backup of ${_date(b.date)} (${b.source})', sf.edSlug(b.edition));
      });

  Future<void> _namesFrom() async {
    final c = _cur;
    if (c == null) return;
    final e = await _pickRom('Names and pictures from which ROM?', hint: 'A ROM of the same Paradise as the save.');
    if (e == null) return;
    await _task('Opening ${e.name}', () async {
      final rom = await lib.bytes(e);
      final o = sf.petOpen(c.save, sf.romEdition(rom)); // refuses a ROM of another Paradise
      final l = await compute(_lookJob, rom);
      if (!mounted) return;
      setState(() {
        c.pet = o;
        c.namesRom = e;
        c.groups = l.groups;
        c.looks = l.looks;
        _pics.clear();
        _char = null;
      });
    });
  }

  // ------------------------------------------------------------------ what is in it
  String _charName(_Open c, int id) {
    if (id == 0) return 'No Tama yet (an egg or a new game)';
    final n = c.looks[id]?.name ?? '';
    if (n.isNotEmpty) return n;
    for (final g in c.groups) {
      for (final x in g.chars) {
        if (x.id == id) return x.name;
      }
    }
    return 'Tama no. $id';
  }

  String _summary(_Open c) => '${_charName(c, c.pet.pet.id)}, level ${c.pet.pet.level}';

  static String _date(DateTime d) {
    String z(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${z(d.month)}-${z(d.day)} ${z(d.hour)}:${z(d.minute)}';
  }

  Future<ui.Image?> _pic(_Open c, int id) => _pics.putIfAbsent(id, () {
        final Rgba? p = c.looks[id]?.picture;
        if (p == null || p.w <= 0 || p.h <= 0) return Future.value(null);
        final done = Completer<ui.Image?>();
        try {
          ui.decodeImageFromPixels(p.data, p.w, p.h, ui.PixelFormat.rgba8888, done.complete);
        } catch (_) {
          done.complete(null);
        }
        return done.future;
      });

  Widget _picture(_Open c, int id, double size) => SizedBox(
        width: size,
        height: size,
        child: FutureBuilder<ui.Image?>(
          future: _pic(c, id),
          builder: (_, s) => s.data == null ? Icon(Icons.egg_outlined, size: size * 0.6, color: Colors.white38) : RawImage(image: s.data, fit: BoxFit.contain, filterQuality: FilterQuality.none),
        ),
      );

  Widget _bar(String label, int v, int max) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          SizedBox(width: 92, child: Text(label)),
          Expanded(child: LinearProgressIndicator(value: max > 0 ? (v / max).clamp(0.0, 1.0) : 0, minHeight: 8, borderRadius: BorderRadius.circular(4))),
          SizedBox(width: 56, child: Text('$v / $max', textAlign: TextAlign.end)),
        ]),
      );

  // ------------------------------------------------------------------ editing
  Future<void> _chooseChar() async {
    final c = _cur;
    if (c == null) return;
    final pick = await showModalBottomSheet<(sf.PetChar?,)>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (_, scroll) => ListView(controller: scroll, children: [
          ListTile(leading: const Icon(Icons.undo), title: const Text('Leave the Tama as it is'), onTap: () => Navigator.pop(ctx, (null,))),
          for (final g in c.groups) ...[
            if (g.chars.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text(g.label, style: Theme.of(ctx).textTheme.titleSmall!.copyWith(color: kAmber))),
            for (final x in g.chars)
              ListTile(
                leading: _picture(c, x.id, 40),
                title: Text(x.name),
                subtitle: x.field.isEmpty ? null : Text(x.field),
                trailing: x.id == c.pet.pet.id ? const Text('now') : null,
                onTap: () => Navigator.pop(ctx, (x,)),
              ),
          ],
        ]),
      ),
    );
    if (pick != null) setState(() => _char = pick.$1);
  }

  sf.PetChange? get _change {
    final c = _cur;
    if (c == null) return null;
    final ch = sf.petChange(c.pet.pet, level: _level, char: _char, care: _care);
    return ch.isEmpty ? null : ch;
  }

  void _apply() {
    final c = _cur, ch = _change;
    if (c == null || ch == null) return;
    try {
      final nw = sf.petApply(c.pet, ch);
      setState(() {
        c.pet = sf.PetOpen(nw, c.edition, paraPet(nw, c.edition)!);
        c.edited = true;
        _resetControls();
      });
      _say('Changed. It is only in this copy so far: keep it, share it, or write it to a ROM or to the toy below.');
    } catch (e) {
      _say(_why(e), bad: true);
    }
  }

  /// Changes not applied yet would be left out of what is kept or written: ask.
  Future<bool> _pending() async {
    if (_change == null) return true;
    final yes = await _confirm('Use your changes?', 'You changed the level, the Tama or the care above but did not apply it yet.', 'Apply and go on');
    if (yes) _apply();
    return yes && _change == null;
  }

  // ------------------------------------------------------------------ actions
  String _fileName(_Open c) {
    final base = c.name.replaceAll(RegExp(r'[^A-Za-z0-9 _.()-]'), '_').trim();
    return '${base.isEmpty ? sf.edSlug(c.edition) : base}${c.edited ? '-edited' : ''}-${sf.stamp()}.tamasave';
  }

  Future<void> _keep() async {
    final c = _cur;
    if (c == null || !await _pending()) return;
    await _store.add(paraWrite(c.save, c.edition), title: _summary(c), source: c.source + (c.edited ? ', edited' : ''), edition: c.edition);
    await _reloadBackups();
    _say('Kept under Backups.');
  }

  Future<void> _share() async {
    final c = _cur;
    if (c == null || !await _pending()) return;
    final dir = await getTemporaryDirectory(), name = _fileName(c);
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(paraWrite(c.save, c.edition), flush: true);
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], subject: name));
  }

  /// The save goes into a game of the app (that game's own save is kept under Backups first),
  /// and the game starts on it.
  Future<void> _toGame() async {
    final c = _cur;
    if (c == null || !await _pending()) return;
    final e = await _pickRom('Play this save in which game?', hint: 'The game\'s save in the app is replaced (it is kept under Backups first).');
    if (e == null) return;
    await _task('Putting the save into ${e.name}', () async {
      final rom = await lib.bytes(e);
      final id = sf.romEdition(rom), check = sf.devSaveCheck(c.save, id, editionNames[id] ?? 'this ROM');
      if (check.error != null) throw sf.SaveFlowError('devErr', check.error!.replaceFirst('the device is', 'the game is'));
      if (!mounted) return;
      final yes = await _confirm(
        'Play this save on the phone?',
        '${e.name} in the app continues with this save: ${_summary(c)}. The save it has now is kept under Backups.'
            '${check.warn.isEmpty ? '' : '\n\nNote: ${check.warn.replaceAll('as on the device', 'as in the game')}.'}',
        'Play it',
      );
      if (!yes) return;
      if (app.games.containsKey(e.id)) await app.stopGame(e.id);
      final file = lib.paradiseSave(e);
      if (await file.exists() && await file.length() > 0) {
        try {
          final old = sf.gameSave(rom, await file.readAsBytes());
          await _store.add(paraWrite(old, old.edition), title: 'Before the toy\'s save', source: 'the game ${e.name} in the app', edition: old.edition);
        } catch (_) {
          // an unreadable old save is not worth stopping for
        }
      }
      await file.parent.create(recursive: true);
      await file.writeAsBytes(paraWrite(c.save, id), flush: true);
      await _reloadBackups();
      final err = await app.playParadise(e);
      if (!mounted) return;
      if (err != null) {
        _say('The game did not start: $err');
        return;
      }
      Navigator.of(context).popUntil((r) => r.isFirst);
    });
  }

  Future<void> _toRom() async {
    final c = _cur;
    if (c == null || !await _pending()) return;
    final e = await _pickRom('Put the save into which ROM?', hint: 'A new copy is made. The ROM you choose stays as it is.');
    if (e == null) return;
    await _task('Writing the save into a copy of ${e.name}', () async {
      final rom = await lib.bytes(e);
      final id = sf.romEdition(rom), check = sf.devSaveCheck(c.save, id, editionNames[id] ?? 'this ROM');
      if (check.error != null) throw sf.SaveFlowError('devErr', check.error!.replaceFirst('the device is', 'the ROM is'));
      if (!mounted) return;
      final yes = await _confirm(
        'Make a new ROM with this save?',
        'A copy of ${e.name} is made with this save in place of the one it has: ${_summary(c)}. ${e.name} itself is not changed.'
            '${check.warn.isEmpty ? '' : '\n\nNote: ${check.warn.replaceAll('as on the device', 'as in the ROM')}.'}',
        'Make the ROM',
      );
      if (!yes) return;
      final (out, _) = sf.romSaveWrite(rom, c.save);
      final name = '${e.name.replaceAll(RegExp(r' \(save\)$'), '')} (save)';
      final made = await lib.import(out, '${name.replaceAll(RegExp(r'[^A-Za-z0-9 _.()-]'), '_')}.bin', note: 'with the save: ${_summary(c)}');
      if (!mounted) return;
      _say('${made.name} is in your ROMs.');
      await showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('Your new ROM is ready'),
          content: Text('${made.name} is in your ROMs with this save in it: play it in the app, or write it to the toy from Paramix → Device (switch "Keep the saves on the device" off there, or the toy keeps its own save).'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: const Text('OK')),
            FilledButton(
              onPressed: () async {
                Navigator.pop(d);
                await app.playParadise(made);
                if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
              },
              child: const Text('Play it'),
            ),
          ],
        ),
      );
    });
  }

  Future<void> _toToy() async {
    final c = _cur;
    if (c == null || !await _pending()) return;
    if (!await _connect() || !mounted) return;
    final d = sf.ParadiseSaveDevice(_dev!);
    final check = sf.devSaveCheck(c.save, d.edition, d.name);
    if (check.error != null) {
      _say('This save cannot go onto this toy. ${check.error}.', bad: true);
      return;
    }
    final hasClock = paraClock(c.save) != null;
    var backup = true;
    final yes = await showDialog<bool>(
      context: context,
      builder: (dlg) => StatefulBuilder(
        builder: (dlg, set) => AlertDialog(
          title: const Text('Replace the save on the toy?'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('The game now on your Paradise ${d.name} is replaced by this save: ${_summary(c)}.\n\n'
                  '${hasClock ? 'The clock comes with it.' : 'This save has no clock: set the clock on the toy afterwards.'} '
                  'Only the pages that differ are written. Keep the toy switched on and the cable in until it is done.'
                  '${check.warn.isEmpty ? '' : '\n\nNote: ${check.warn}.'}'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: backup,
                onChanged: (v) => set(() => backup = v ?? true),
                title: const Text('First keep the toy\'s current save under Backups'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dlg, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dlg, true), child: const Text('Write to the toy')),
          ],
        ),
      ),
    );
    if (yes != true) return;
    await _task('Writing the save to the toy', device: true, canCancel: true, () async {
      if (backup) {
        final bk = await sf.devSaveRead(d, progress: _prog, cancel: () => _cancel);
        var title = d.name;
        try {
          final p = sf.petOpen(bk.save, null).pet;
          title = '${p.id == 0 ? 'No Tama yet' : (c.looks[p.id]?.name.isNotEmpty ?? false) ? c.looks[p.id]!.name : 'Tama no. ${p.id}'}, level ${p.level}';
        } catch (_) {
          // a toy without a game yet
        }
        await _store.add(bk.file, title: title, source: 'My toy (${d.name}), before writing', edition: d.edition);
        await _reloadBackups();
      }
      final w = await sf.devSaveWrite(d, c.save, check.chk, guard: _flashApp, progress: _prog, cancel: () => _cancel);
      if (w.written < w.planned) {
        _say('Cancelled after ${w.written} of ${w.planned} pages. The save on the toy is now mixed: write this save again (or your backup) before you use the toy.', bad: true);
      } else {
        _say('${w.written == 0 ? 'The toy already holds this save, nothing had to be written.' : 'Done: ${w.written} pages written and checked.'} '
            '${w.clock ? 'The clock was taken over.' : 'Please set the clock on the toy.'}');
        await _leaveToy();
      }
    });
  }

  /// The toy leaves the flash screen and starts its game (no reset button).
  Future<void> _leaveToy() async {
    final dev = _dev;
    if (dev == null) return;
    final ok = await dev.restart();
    if (ok) {
      _dev = null;
      _say('${_note ?? ''} The toy restarts into its game.'.trim());
    } else {
      _say('${_note ?? ''} Press the toy\'s reset button to play.'.trim());
    }
  }

  Future<void> _clockNow() async {
    if (!await _connect() || !mounted) return;
    await _task('Setting the toy\'s clock', device: true, () async {
      final err = await sf.devClockNow(_dev!);
      _say(err ?? 'The toy\'s clock is set to the phone\'s time.', bad: err != null);
      await _leaveToy();
    });
  }

  Future<void> _backupMenu(SaveBackup b) async {
    final what = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(b.title.isEmpty ? 'Backup' : b.title), subtitle: Text('${_date(b.date)} · ${b.source} · ${editionNames[b.edition] ?? 'Paradise'}')),
          ListTile(leading: const Icon(Icons.folder_open), title: const Text('Open it'), subtitle: const Text('To look at it, change it, or restore it to the toy or a ROM'), onTap: () => Navigator.pop(c, 'open')),
          ListTile(leading: const Icon(Icons.ios_share), title: const Text('Share as a .tamasave file'), onTap: () => Navigator.pop(c, 'share')),
          ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete this backup'), onTap: () => Navigator.pop(c, 'delete')),
        ]),
      ),
    );
    if (what == 'open') {
      await _fromBackup(b);
    } else if (what == 'share') {
      final dir = await getTemporaryDirectory(), name = '${sf.edSlug(b.edition)}-${sf.stamp(b.date)}.tamasave';
      final f = await File('${dir.path}/$name').writeAsBytes(await b.file.readAsBytes(), flush: true);
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], subject: name));
    } else if (what == 'delete') {
      if (!mounted || !await _confirm('Delete this backup?', '${b.title} of ${_date(b.date)} (${b.source}) is removed from the app for good.', 'Delete')) return;
      await _store.remove(b);
      await _reloadBackups();
    }
  }

  // ------------------------------------------------------------------ the page
  @override
  Widget build(BuildContext context) {
    final t = hub.transport, c = _cur;
    final title = Theme.of(context).textTheme.titleSmall!.copyWith(color: kAmber);
    Widget head(String s) => Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text(s, style: title));
    return Scaffold(
      appBar: AppBar(title: const Text('Save games'), actions: [
        IconButton(
          tooltip: 'Connections & terminal',
          icon: const Icon(Icons.terminal),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HardwareScreen())),
        ),
      ]),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        if (_busy)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(_phase),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: _progress),
                if (_canCancel)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(onPressed: _cancel ? null : () => setState(() => _cancel = true), child: Text(_cancel ? 'Stopping …' : 'Cancel')),
                  ),
              ]),
            ),
          ),
        if (_note != null)
          Card(
            child: ListTile(
              leading: Icon(_noteBad ? Icons.error_outline : Icons.check_circle_outline, color: _noteBad ? Colors.redAccent : Colors.greenAccent),
              title: Text(_note!, style: const TextStyle(fontSize: 14)),
            ),
          ),
        head('Open a save'),
        Card(
          child: Column(children: [
            ListTile(
              leading: Icon(Icons.usb_rounded, color: _dev != null ? Colors.greenAccent : null),
              title: const Text('From my toy'),
              subtitle: Text(_dev != null
                  ? 'Connected: Paradise ${_dev!.info!.name}. Backs up its save with the clock.'
                  : t == null
                      ? (UsbTransport.supported ? 'Plug the dongle in, wire it to the toy and put the toy on its download screen.' : 'Connect the dongle on the connections page (top right) first.')
                      : 'Dongle ready (${t.label}). Put the toy on its download screen.'),
              onTap: _busy ? null : _fromToy,
            ),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('Set my toy\'s clock and start its game'),
              subtitle: const Text('The phone\'s time goes onto the toy, then it leaves the flash screen by itself.'),
              onTap: _busy ? null : _clockNow,
            ),
            if (_dev != null)
              ListTile(
                leading: const Icon(Icons.restart_alt),
                title: const Text('Leave the flash screen'),
                subtitle: const Text('The toy starts its game, without its reset button.'),
                onTap: _busy ? null : () => _task('Restarting the toy', device: true, _leaveToy),
              ),
            if (t == null)
              for (final a in _usb) ListTile(dense: true, leading: const Icon(Icons.cable), title: Text(a.name), trailing: const Icon(Icons.link), onTap: _busy ? null : () => _openUsb(a)),
            ListTile(leading: const Icon(Icons.memory), title: const Text('From a ROM in my library'), subtitle: const Text('The game inside a ROM, for example one read from a toy.'), onTap: _busy ? null : _fromRom),
            ListTile(leading: const Icon(Icons.insert_drive_file_outlined), title: const Text('From a save file'), subtitle: const Text('A .tamasave file.'), onTap: _busy ? null : _fromFile),
            ListTile(leading: const Icon(Icons.videogame_asset_outlined), title: const Text('From a game in the app'), subtitle: const Text('A game you play here, as it is right now.'), onTap: _busy ? null : _fromGame),
          ]),
        ),
        if (c != null) ...[
          head('In this save'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    decoration: BoxDecoration(color: const Color(0xFF26222E), borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.all(6),
                    child: _picture(c, c.pet.pet.id, 72),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_charName(c, c.pet.pet.id), style: Theme.of(context).textTheme.titleMedium),
                      Text('Paradise ${editionNames[c.edition] ?? ''} · planet level ${c.pet.pet.level}${c.pet.pet.sick != 0 ? ' · sick' : ''}'),
                      Text('${c.source}${c.edited ? ' · changed here' : ''}', style: const TextStyle(fontSize: 12, color: Colors.white54)),
                    ]),
                  ),
                ]),
                _bar('Hunger', c.pet.pet.hunger, 6),
                _bar('Happiness', c.pet.pet.happy, 20),
                const SizedBox(height: 8),
                Text(
                  c.save.counter != 0 && c.save.stamp != 0
                      ? 'Clock: in the save, as it was on ${_date(DateTime.fromMillisecondsSinceEpoch(c.save.stamp * 1000))}. Written to the toy, the time since is added.'
                      : 'Clock: not in this save. After writing it to the toy, set the clock there.',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
                if (c.namesRom == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('No ROM of this Paradise is in your library, so names and pictures are missing and the Tama cannot be changed.', style: TextStyle(fontSize: 12, color: Colors.white70)),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(onPressed: _busy ? null : _namesFrom, child: Text(c.namesRom == null ? 'Choose a ROM for names and pictures' : 'Names and pictures from: ${c.namesRom!.name}')),
                ),
              ]),
            ),
          ),
          head('Change it'),
          Card(
            child: Column(children: [
              ListTile(
                title: const Text('Planet level'),
                trailing: DropdownButton<int>(
                  value: _level,
                  items: [for (var i = 0; i <= 10; i++) DropdownMenuItem(value: i, child: Text('$i'))],
                  onChanged: _busy ? null : (v) => setState(() => _level = v ?? _level),
                ),
              ),
              ListTile(
                enabled: c.groups.any((g) => g.chars.isNotEmpty),
                leading: _char == null ? null : _picture(c, _char!.id, 40),
                title: const Text('Tama'),
                subtitle: Text(_char == null ? 'Unchanged' : 'Becomes ${_char!.text}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy ? null : _chooseChar,
              ),
              SwitchListTile(
                title: const Text('Full care'),
                subtitle: const Text('Fed, happy and healthy'),
                value: _care,
                onChanged: _busy ? null : (v) => setState(() => _care = v),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(onPressed: _busy || _change == null ? null : _apply, icon: const Icon(Icons.check), label: Text(_change == null ? 'Nothing changed' : 'Apply these changes')),
                ),
              ),
            ]),
          ),
          head('Use it'),
          Card(
            child: Column(children: [
              ListTile(leading: const Icon(Icons.inventory_2_outlined), title: const Text('Keep as a backup in the app'), onTap: _busy ? null : _keep),
              ListTile(leading: const Icon(Icons.ios_share), title: const Text('Share as a .tamasave file'), onTap: _busy ? null : _share),
              ListTile(
                  leading: const Icon(Icons.play_arrow_rounded),
                  title: const Text('Play it on my phone'),
                  subtitle: const Text('A game in the app continues with this save.'),
                  onTap: _busy ? null : _toGame),
              ListTile(leading: const Icon(Icons.memory), title: const Text('Put it into a ROM of my library'), subtitle: const Text('Makes a new copy of the ROM with this save.'), onTap: _busy ? null : _toRom),
              ListTile(leading: const Icon(Icons.upload), title: const Text('Write it to my toy'), subtitle: const Text('Replaces the game on the toy. Asks first.'), onTap: _busy ? null : _toToy),
            ]),
          ),
        ],
        head('Backups'),
        Card(
          child: Column(children: [
            if (_backups.isEmpty) const ListTile(title: Text('No backups yet'), subtitle: Text('A save taken from the toy is kept here by itself; any other save with "Keep as a backup in the app".')),
            for (final b in _backups)
              ListTile(
                leading: const Icon(Icons.save_outlined),
                title: Text(b.title.isEmpty ? 'Backup' : b.title),
                subtitle: Text('${_date(b.date)} · ${b.source}'),
                trailing: const Icon(Icons.more_horiz),
                onTap: _busy ? null : () => _backupMenu(b),
              ),
          ]),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text('Writing to the toy is at your own risk. Keep a backup, and keep the toy switched on while it is written.', style: TextStyle(fontSize: 12, color: Colors.white54)),
        ),
      ]),
    );
  }
}
