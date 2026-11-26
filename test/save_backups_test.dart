// The "Backups" list of the save screen: files in a folder, newest first.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tama_tools/services/save_backups.dart';

void main() {
  test('keep, list, read back, delete', () async {
    final dir = await Directory.systemTemp.createTemp('backups');
    final s = SaveBackups(Directory('${dir.path}/save_backups'));
    expect(await s.list(), isEmpty);
    final t = DateTime(2026, 3, 4, 5, 6);
    final a = await s.add(Uint8List.fromList([1, 2, 3]), title: 'Mametchi, level 3', source: 'My toy (Land)', edition: 1, now: t);
    final b = await s.add(Uint8List.fromList([4, 5]), title: 'Kuchipatchi, level 1', source: 'File: x.tamasave', edition: 5, now: t.add(const Duration(minutes: 1)));
    final c = await s.add(Uint8List.fromList([6]), title: 'same moment', source: 's', edition: 1, now: t);
    expect(c.id, isNot(a.id));
    final l = await s.list();
    expect([for (final x in l) x.title].first, 'Kuchipatchi, level 1');
    expect(l.length, 3);
    final got = l.firstWhere((x) => x.id == a.id);
    expect(got.source, 'My toy (Land)');
    expect(got.edition, 1);
    expect(got.date, t);
    expect(await got.file.readAsBytes(), [1, 2, 3]);
    await s.remove(b);
    await s.remove(c);
    expect([for (final x in await s.list()) x.id], [a.id]);
    await dir.delete(recursive: true);
  });
}
