import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

/// Android: keeps the app up to date from the GitHub releases of this repository. The release
/// workflow publishes every build of main as `android-<version>-<build>` with the APK; the app
/// compares the build number with its own, downloads the newer APK and hands it to Android's
/// installer (the user confirms there). iOS updates through TestFlight.
class Updater {
  Updater._();
  static final Updater instance = Updater._();

  static const _repo = 'Coral-coder/tama-emu-ios';
  static const MethodChannel _ch = MethodChannel('tama/native');

  /// A newer release, when one was found: (build, version, APK url, size).
  final ValueNotifier<({int build, String version, String url, int size})?> available = ValueNotifier(null);
  final ValueNotifier<double?> progress = ValueNotifier(null);
  int? _mine;

  bool get supported => !kIsWeb && Platform.isAndroid;

  Future<int> mine() async => _mine ??= ((await _ch.invokeMethod<int>('appVersion')) ?? 0);

  /// Looks for a newer Android release. Returns null when there is none (or no network).
  Future<({int build, String version, String url, int size})?> check() async {
    if (!supported) return null;
    final client = HttpClient()..userAgent = 'Tama-app-updater';
    try {
      final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$_repo/releases?per_page=20'));
      req.headers.set('Accept', 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final list = jsonDecode(await res.transform(utf8.decoder).join()) as List;
      final own = await mine();
      for (final r in list) {
        final tag = (r['tag_name'] ?? '') as String;
        // android-<version>-<build>; the newest comes first
        final m = RegExp(r'^android-([0-9.]+)-(\d+)$').firstMatch(tag);
        if (m == null || r['draft'] == true) continue;
        final build = int.parse(m.group(2)!);
        final apk = (r['assets'] as List).cast<Map>().where((a) => (a['name'] as String).endsWith('.apk')).firstOrNull;
        if (apk == null) continue;
        final found = (build: build, version: m.group(1)!, url: apk['browser_download_url'] as String, size: (apk['size'] as num).toInt());
        available.value = build > own ? found : null;
        return available.value;
      }
      return null;
    } catch (e) {
      debugPrint('update check: $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// Downloads the APK and opens Android's installer.
  Future<String?> install(({int build, String version, String url, int size}) u) async {
    final client = HttpClient()..userAgent = 'Tama-app-updater';
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/update');
      await dir.create(recursive: true);
      final f = File('${dir.path}/Tama-${u.version}-${u.build}.apk');
      if (!(await f.exists() && await f.length() == u.size)) {
        progress.value = 0;
        final res = await (await client.getUrl(Uri.parse(u.url))).close();
        if (res.statusCode != 200) return 'The download failed (${res.statusCode}).';
        final sink = f.openWrite();
        var got = 0;
        await for (final chunk in res) {
          sink.add(chunk);
          got += chunk.length;
          if (u.size > 0) progress.value = got / u.size;
        }
        await sink.close();
      }
      progress.value = null;
      final r = await _ch.invokeMethod<String>('installApk', {'path': f.path});
      return r == 'ok' ? null : r;
    } catch (e) {
      progress.value = null;
      return 'The update could not be installed: $e';
    } finally {
      client.close();
    }
  }

  /// At start (and when the app comes back after a while): offers a newer version.
  Future<void> offer(BuildContext context, {bool quiet = true}) async {
    final u = await check();
    if (!context.mounted) return;
    if (u == null) {
      if (!quiet) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tama is up to date.')));
      return;
    }
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('A new Tama is ready'),
        content: Text('Version ${u.version} (build ${u.build}), ${(u.size / 1048576).toStringAsFixed(1)} MB. '
            'It downloads now and Android asks you to install it. Your games and saves stay.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Later')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Update')),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Downloading the update …'), duration: Duration(seconds: 3)));
    final err = await install(u);
    if (err != null) messenger.showSnackBar(SnackBar(content: Text(err)));
  }
}
