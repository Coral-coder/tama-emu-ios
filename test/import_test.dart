// Import a ROM through the library and show the games page, as the app does after the file picker.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tama_tools/services/app_state.dart';
import 'package:tama_tools/ui/games_screen.dart';
import 'package:tama_tools/ui/theme.dart';

class FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  FakePaths(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
  @override
  Future<String?> getTemporaryPath() async => dir;
}

void main() {
  final dump = Platform.environment['PARADISE_DUMP'];
  testWidgets('import a Paradise dump and show it', (tester) async {
    if (dump == null) return;
    final tmp = Directory.systemTemp.createTempSync('tama');
    PathProviderPlatform.instance = FakePaths(tmp.path);
    SharedPreferences.setMockInitialValues({});
    final errors = <FlutterErrorDetails>[];
    FlutterError.onError = errors.add;
    await tester.runAsync(() async {
      await AppState.instance.init();
      await AppState.instance.library.import(File(dump).readAsBytesSync(), 'Tamagotchi_Paradise_Land_MX25L12835F.bin');
    });
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const GamesScreen()));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Land'), findsWidgets);
    expect(errors, isEmpty, reason: errors.map((e) => e.exceptionAsString()).join('\n'));
  });
}
