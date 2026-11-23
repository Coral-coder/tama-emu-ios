import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:typed_data';
import 'package:material_ui/material_ui.dart';

import '../emu/rom_info.dart';
import '../services/app_state.dart';
import '../services/rom_library.dart';
import '../paradise/unlock.dart';
import 'paradise_screen.dart';
import 'save_editor.dart';
import 'theme.dart';

/// All games: the Paradise dumps (with their edition's field as cover) and the first toys.
class GamesScreen extends StatelessWidget {
  const GamesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final lib = AppState.instance.library;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tama'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Add games',
            icon: const Icon(Icons.add_circle_outline),
            onSelected: (v) => v == 'link' ? importFromLink(context) : importRoms(context),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'files', child: ListTile(leading: Icon(Icons.folder_open), title: Text('From Files'))),
              PopupMenuItem(value: 'link', child: ListTile(leading: Icon(Icons.link), title: Text('From a link'))),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([lib, AppState.instance]),
        builder: (context, _) {
          if (!lib.ready) return const Center(child: CircularProgressIndicator());
          final games = lib.entries.where((e) => e.kind != RomKind.other).toList();
          if (games.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('The emulator is ready, but this build has no ROMs in it. Tap Import and pick your Paradise dumps (16 MB) or first-generation toy ROMs (12 / 16 KB) from Files; each one then shows here with its cover.', textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton.icon(onPressed: () => importRoms(context), icon: const Icon(Icons.file_upload_outlined), label: const Text('Import')),
                ]),
              ),
            );
          }
          // up to nine: three across, the picture with its name under it; more: a list
          if (games.length > 9) {
            return ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: games.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 88),
              itemBuilder: (context, i) => _GameRow(entry: games[i]),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 14, crossAxisSpacing: 10, childAspectRatio: 0.78),
            itemCount: games.length,
            itemBuilder: (context, i) => _GameCard(entry: games[i]),
          );
        },
      ),
    );
  }
}

/// Picks ROM files and adds them to the library, with a progress dialog and every error shown.
Future<void> importRoms(BuildContext context) async {
  List<PlatformFile> picked;
  try {
    picked = await FilePicker.pickFiles(type: FileType.any);
  } catch (e) {
    if (context.mounted) await _importError(context, 'The file picker failed: $e');
    return;
  }
  if (picked.isEmpty || !context.mounted) return;
  final status = ValueNotifier<String>('Importing …');
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      content: Row(children: [
        const CircularProgressIndicator(),
        const SizedBox(width: 16),
        Expanded(child: ValueListenableBuilder<String>(valueListenable: status, builder: (_, v, _) => Text(v))),
      ]),
    ),
  );
  final done = <String>[];
  final failed = <String>[];
  for (final f in picked) {
    status.value = 'Importing ${f.name} …';
    try {
      // the picker hands a copy in the app's temporary folder; read it by its path
      final path = f.path;
      final b = path != null ? await File(path).readAsBytes() : await f.readAsBytes();
      if (b.isEmpty) throw const FileSystemException('the file is empty (still in iCloud?)');
      final e = await AppState.instance.library.import(b, f.name);
      done.add(e.name);
    } catch (e) {
      failed.add('${f.name}: $e');
    }
  }
  if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  if (!context.mounted) return;
  if (failed.isNotEmpty) {
    await _importError(context, failed.join('\n\n'));
  } else {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added: ${done.join(', ')}')));
  }
}

/// Downloads ROMs from a link (a direct file link, such as an archive.org "download" link): a
/// .bin dump, a gzip, or a zip with dumps inside. Each one found goes into the library.
Future<void> importFromLink(BuildContext context) async {
  final ctl = TextEditingController();
  final url = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Add games from a link'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Paste the link to the file itself (a .bin, .gz or .zip). On archive.org: the file under DOWNLOAD OPTIONS, then Copy Link.',
            style: TextStyle(color: Colors.white60, fontSize: 13)),
        const SizedBox(height: 10),
        TextField(controller: ctl, autofocus: true, keyboardType: TextInputType.url, decoration: const InputDecoration(hintText: 'https://…')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Download')),
      ],
    ),
  );
  if (url == null || url.isEmpty || !context.mounted) return;
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) {
    await _importError(context, 'That is not a link: $url');
    return;
  }
  final status = ValueNotifier<String>('Connecting …');
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      content: Row(children: [
        const CircularProgressIndicator(),
        const SizedBox(width: 16),
        Expanded(child: ValueListenableBuilder<String>(valueListenable: status, builder: (_, v, _) => Text(v))),
      ]),
    ),
  );
  final added = <String>[];
  String? error;
  try {
    final client = HttpClient()..userAgent = 'Tama';
    final req = await client.getUrl(uri);
    final res = await req.close();
    if (res.statusCode != 200) throw 'the server answered ${res.statusCode}';
    final total = res.contentLength;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in res) {
      bytes.add(chunk);
      status.value = total > 0
          ? 'Downloading … ${(bytes.length * 100 / total).toStringAsFixed(0)} % of ${(total / 1048576).toStringAsFixed(1)} MB'
          : 'Downloading … ${(bytes.length / 1048576).toStringAsFixed(1)} MB';
    }
    client.close();
    final data = bytes.takeBytes();
    final name = Uri.decodeComponent(uri.pathSegments.isEmpty ? 'download.bin' : uri.pathSegments.last);
    status.value = 'Adding …';
    final files = <(String, Uint8List)>[];
    if (data.length > 4 && data[0] == 0x50 && data[1] == 0x4B) {
      for (final f in ZipDecoder().decodeBytes(data)) {
        if (f.isFile && f.size > 0) files.add((f.name.split('/').last, f.content));
      }
    } else if (data.length > 2 && data[0] == 0x1F && data[1] == 0x8B) {
      files.add((name.replaceFirst(RegExp(r'\.gz$'), ''), Uint8List.fromList(gzip.decode(data))));
    } else {
      files.add((name, data));
    }
    for (final (n, b) in files) {
      final ok = b.length == 16 * 1024 * 1024 || b.length == 12 * 1024 || b.length == 16 * 1024 || b.length == 8 * 1024;
      if (!ok) continue; // not a dump (a readme, a picture …)
      final e = await AppState.instance.library.import(b, n);
      added.add(e.name);
    }
    if (added.isEmpty) error = 'No ROM in what was downloaded (a Paradise dump is 16 MB; a first toy ROM 12 or 16 KB).';
  } catch (e) {
    error = 'The download failed: $e';
  }
  if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  if (!context.mounted) return;
  if (error != null) {
    await _importError(context, error);
  } else {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added: ${added.join(', ')}')));
  }
}

Future<void> _importError(BuildContext context, String text) => showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Import failed'),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );

Future<void> startGame(BuildContext context, RomEntry e) async {
  final app = AppState.instance;
  if (e.kind == RomKind.e0c6s4x) {
    await app.play(e);
    app.page.value = 0;
    return;
  }
  app.page.value = 0;
  await ParadiseUnlock.instance.play(e);
}

class _GameCard extends StatelessWidget {
  const _GameCard({required this.entry});
  final RomEntry entry;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final short = e.name.replaceFirst('Tamagotchi Paradise · ', '');
    return Material(
      color: kPanel,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => startGame(context, e),
        onLongPress: e.kind == RomKind.paradise ? () => showGameMenu(context, e) : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: _Picture(entry: e, short: short)),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
            child: Text(short, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          ),
        ]),
      ),
    );
  }
}

/// A game in the list (more than nine): its picture, name and state.
class _GameRow extends StatelessWidget {
  const _GameRow({required this.entry});
  final RomEntry entry;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final living = AppState.instance.games.containsKey(e.id);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(width: 64, height: 64, child: _Picture(entry: e, short: e.name)),
      ),
      title: Text(e.name, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(living ? 'Living' : (e.kind == RomKind.paradise ? 'Paradise' : 'First-generation toy')),
      onTap: () => startGame(context, e),
      onLongPress: e.kind == RomKind.paradise ? () => showGameMenu(context, e) : null,
    );
  }
}

/// The game's picture: its screen, live, while it runs; the last picture of it when it does not;
/// the cover of its edition before it was ever played.
class _Picture extends StatelessWidget {
  const _Picture({required this.entry, required this.short});
  final RomEntry entry;
  final String short;

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final e = entry;
    final live = app.games[e.id];
    if (live != null) {
      return Stack(fit: StackFit.expand, children: [
        ParadiseScreen(machine: live),
        Positioned(
          left: 8,
          top: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(10)),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.favorite, size: 12, color: Color(0xFFFF7A90)),
              SizedBox(width: 4),
              Text('living', style: TextStyle(fontSize: 11, color: Colors.white)),
            ]),
          ),
        ),
      ]);
    }
    final shot = app.shotFile(e.id);
    if (e.kind == RomKind.paradise && shot.existsSync()) {
      return Image.file(shot, key: ValueKey('${e.id}-${app.shotRevision}'), fit: BoxFit.cover, filterQuality: FilterQuality.none);
    }
    return FutureBuilder<File?>(
      future: app.library.cover(e),
      builder: (context, snap) {
        final f = snap.data;
        if (f != null) return Image.file(f, fit: BoxFit.cover, filterQuality: FilterQuality.medium);
        if (e.kind == RomKind.paradise && snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        return _ToyCover(name: short);
      },
    );
  }
}

/// Cover of a first-generation toy: its egg in a colour of its own.
class _ToyCover extends StatelessWidget {
  const _ToyCover({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final hue = (name.codeUnits.fold<int>(7, (a, b) => a * 31 + b) % 360).toDouble();
    final c = HSVColor.fromAHSV(1, hue, 0.55, 0.95).toColor();
    return Container(
      color: HSVColor.fromAHSV(1, hue, 0.35, 0.25).toColor(),
      alignment: Alignment.center,
      child: FractionallySizedBox(
        widthFactor: 0.55,
        heightFactor: 0.7,
        child: Container(
          decoration: BoxDecoration(color: c, borderRadius: const BorderRadius.all(Radius.elliptical(100, 120))),
          alignment: Alignment.center,
          child: Container(
            width: 46,
            height: 34,
            decoration: BoxDecoration(color: kLcdBg, borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.black54, width: 3)),
          ),
        ),
      ),
    );
  }
}
