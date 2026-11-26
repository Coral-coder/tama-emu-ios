import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One Paradise save kept in the app: a .tamasave file with a small note next to it.
class SaveBackup {
  SaveBackup({required this.id, required this.title, required this.source, required this.date, required this.edition, required this.file});
  final String id;

  /// What is in it, in a few words ("Mametchi, level 3").
  final String title;

  /// Where it came from ("My toy", a ROM's name, a file name).
  final String source;
  final DateTime date;
  final int edition;
  final File file;

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'source': source, 'date': date.toIso8601String(), 'edition': edition};
}

/// The "Backups" list of the save screen: files under the documents folder, in save_backups.
class SaveBackups {
  SaveBackups(this.dir);
  final Directory dir;

  Future<List<SaveBackup>> list() async {
    final out = <SaveBackup>[];
    if (!await dir.exists()) return out;
    await for (final f in dir.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final file = File(f.path.replaceFirst(RegExp(r'\.json$'), '.tamasave'));
        if (!await file.exists()) continue;
        out.add(SaveBackup(
          id: m['id'] as String,
          title: m['title'] as String? ?? '',
          source: m['source'] as String? ?? '',
          date: DateTime.tryParse(m['date'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
          edition: m['edition'] as int? ?? 0,
          file: file,
        ));
      } catch (_) {
        // a damaged note: leave it out
      }
    }
    out.sort((a, b) => b.date.compareTo(a.date));
    return out;
  }

  Future<SaveBackup> add(Uint8List tamasave, {required String title, required String source, required int edition, DateTime? now}) async {
    await dir.create(recursive: true);
    final date = now ?? DateTime.now();
    var id = date.millisecondsSinceEpoch.toRadixString(36);
    while (await File('${dir.path}/$id.json').exists()) {
      id = '${id}x';
    }
    final b = SaveBackup(id: id, title: title, source: source, date: date, edition: edition, file: File('${dir.path}/$id.tamasave'));
    await b.file.writeAsBytes(tamasave, flush: true);
    await File('${dir.path}/$id.json').writeAsString(jsonEncode(b.toJson()), flush: true);
    return b;
  }

  Future<void> remove(SaveBackup b) async {
    for (final f in [b.file, File('${dir.path}/${b.id}.json')]) {
      if (await f.exists()) await f.delete();
    }
  }
}
