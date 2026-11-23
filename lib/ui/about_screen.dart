import 'package:material_ui/material_ui.dart';

import '../services/app_state.dart';
import '../services/native.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings & about')),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) => ListView(children: [
          SwitchListTile(
            title: const Text('Run in the background'),
            subtitle: const Text('The toy keeps running live while the app is in the background (iOS: audio session; Android: a notification).'),
            value: app.backgroundRun,
            onChanged: (v) async {
              app.backgroundRun = v;
              await app.setPref('backgroundRun', v);
              await NativeBridge.keepAlive(v && app.machine != null);
            },
          ),
          SwitchListTile(
            title: const Text('Call me on my watch'),
            subtitle: const Text('When your Tamagotchi needs you, the watch pops up and makes a sound too, not only the phone.'),
            value: app.watchCalls,
            onChanged: (v) async {
              app.watchCalls = v;
              await app.setPref('watchCalls', v);
            },
          ),
          SwitchListTile(
            title: const Text('Keep the screen on'),
            subtitle: const Text('Off: the console goes to sleep when left alone, like the toy (a key or the dial wakes it), and the phone locks as usual. Far less battery.'),
            value: app.keepScreenOn,
            onChanged: (v) async {
              app.keepScreenOn = v;
              app.paradise?.keepScreenOn = v;
              await app.setPref('keepScreenOn', v);
            },
          ),
          SwitchListTile(
            title: const Text('Keep living while closed'),
            subtitle: const Text('When the app was closed or suspended, the time away is played through on the next start, as on a real toy.'),
            value: app.keepLiving,
            onChanged: (v) {
              app.keepLiving = v;
              app.machine?.keepLiving = v;
              app.setPref('keepLiving', v);
            },
          ),
          SwitchListTile(
            title: const Text('Show unlit dots'),
            value: app.ghostDots,
            onChanged: (v) {
              app.ghostDots = v;
              app.setPref('ghostDots', v);
            },
          ),
          ListTile(
            title: const Text('Buzzer volume'),
            subtitle: Slider(
              value: NativeBridge.volume,
              onChanged: (v) {
                NativeBridge.volume = v;
                app.setPref('volume', v);
              },
            ),
          ),
          const Divider(),
          const ListTile(
            title: Text('Tama'),
            subtitle: Text(
              'Tamagotchi emulator, Paramix Studio and UART tools.\n\n'
              'Built on:\n'
              '• Paramix Studio by mameise (GPL-3.0) — github.com/mameise/paramix-studio\n'
              '• TamaLIB by Jean-Christophe Rona (GPL-2.0+) — github.com/jcrona/tamalib, '
              'ported to Dart with mameise\'s V1Emu changes\n\n'
              'This app is free software under the GNU GPL v3. Tamagotchi is a trademark of BANDAI; '
              'Digital Monster of BANDAI. This app is not affiliated with them. Use only ROMs you own.',
            ),
          ),
        ]),
      ),
    );
  }
}
