import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../emu/rom_info.dart';
import '../services/app_state.dart';
import '../services/rom_library.dart';
import '../paradise/unlock.dart';
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
        actions: [IconButton(tooltip: 'Import a ROM', icon: const Icon(Icons.add_circle_outline), onPressed: () => importRoms(context))],
      ),
      body: ListenableBuilder(
        listenable: lib,
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
          return GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 220, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.78),
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
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: FutureBuilder<File?>(
              future: AppState.instance.library.cover(e),
              builder: (context, snap) {
                final f = snap.data;
                if (f != null) return Image.file(f, fit: BoxFit.cover, filterQuality: FilterQuality.medium);
                if (e.kind == RomKind.paradise && snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                }
                return _ToyCover(name: short);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
            child: Text(short, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Text(e.kind == RomKind.paradise ? 'Tamagotchi Paradise' : 'First-generation toy',
                style: const TextStyle(fontSize: 11, color: Colors.white54)),
          ),
        ]),
      ),
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
