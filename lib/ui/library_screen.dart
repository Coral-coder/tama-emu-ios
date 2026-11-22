import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../emu/rom_info.dart';
import '../services/app_state.dart';
import '../services/rom_library.dart';
import 'games_screen.dart';
import 'rom_detail_screen.dart';
import 'theme.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final lib = app.library;
    return Scaffold(
      appBar: AppBar(title: const Text('Studio · ROMs')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _import(context),
        icon: const Icon(Icons.file_upload_outlined),
        label: const Text('Import ROM'),
      ),
      body: ListenableBuilder(
        listenable: lib,
        builder: (context, _) {
          if (!lib.ready) return const Center(child: CircularProgressIndicator());
          final groups = <RomKind, List<RomEntry>>{};
          for (final e in lib.entries) {
            groups.putIfAbsent(e.kind, () => []).add(e);
          }
          if (lib.entries.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No ROMs yet. Import a toy ROM to play it, or a Paradise flash dump to edit it in the Studio.'),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              for (final k in RomKind.values)
                if (groups[k] != null) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(_kindTitle(k), style: Theme.of(context).textTheme.titleSmall!.copyWith(color: kAmber)),
                  ),
                  for (final e in groups[k]!) _RomTile(entry: e),
                ],
            ],
          );
        },
      ),
    );
  }

  static String _kindTitle(RomKind k) => switch (k) {
        RomKind.e0c6s4x => 'Toys (play in the emulator)',
        RomKind.paradise => 'Tamagotchi Paradise flash images',
        RomKind.other => 'Other files (emulator firmware, figures …)',
      };

  static Future<void> _import(BuildContext context) async {
    final res = await FilePicker.pickFiles(type: FileType.any);
    var n = 0;
    for (final f in res) {
      final b = await f.readAsBytes();
      await AppState.instance.library.import(b, f.name);
      n++;
    }
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Imported $n file${n == 1 ? '' : 's'}')));
  }
}

class _RomTile extends StatelessWidget {
  const _RomTile({required this.entry});
  final RomEntry entry;

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final e = entry;
    final size = e.size >= 1 << 20 ? '${(e.size / (1 << 20)).toStringAsFixed(0)} MB' : '${(e.size / 1024).toStringAsFixed(0)} KB';
    return Card(
      child: ListTile(
        leading: Icon(
          e.kind == RomKind.e0c6s4x ? Icons.egg_outlined : e.kind == RomKind.paradise ? Icons.memory : Icons.insert_drive_file_outlined,
          color: kAmber,
        ),
        title: Text(e.name),
        subtitle: Text('$size · ${e.bundled ? 'built in' : 'imported'}${e.note != null ? ' · ${e.note}' : ''}'),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RomDetailScreen(entry: e))),
        trailing: PopupMenuButton<String>(
          onSelected: (v) async {
            switch (v) {
              case 'play':
                await _play(context);
              case 'studio':
                if (context.mounted) await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RomDetailScreen(entry: e)));
              case 'share':
                final f = await app.library.exportFile(e);
                await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], subject: e.name));
              case 'rename':
                if (context.mounted) await _rename(context);
              case 'delete':
                await app.library.remove(e);
            }
          },
          itemBuilder: (_) => [
            if (e.kind != RomKind.other) const PopupMenuItem(value: 'play', child: Text('Play')),
            const PopupMenuItem(value: 'studio', child: Text('Details')),
            const PopupMenuItem(value: 'share', child: Text('Export / share')),
            if (!e.bundled) const PopupMenuItem(value: 'rename', child: Text('Rename')),
            if (!e.bundled) const PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ),
    );
  }

  Future<void> _play(BuildContext context) => startGame(context, entry);

  Future<void> _rename(BuildContext context) async {
    final c = TextEditingController(text: entry.name);
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Rename')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) await AppState.instance.library.rename(entry, name);
  }
}
