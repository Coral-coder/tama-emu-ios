import 'package:material_ui/material_ui.dart';

import 'device_screen.dart';
import 'studio_screen.dart';

/// Every Paramix Studio tool, one tap each. All of them open the full Studio (offline, in the
/// app) on that tool; the device page also exists natively.
class ParamixMenu extends StatelessWidget {
  const ParamixMenu({super.key});

  static const _sections = <(String, List<_Tool>)>[
    ('Fields and the device menu', [
      _Tool('All 6 fields + device menu', 'Tropical / Glacier: Land, Water and Sky added from your own ROM. Jade Forest: Sky as 4th field. '
          'Several saves, items, Tamapoints, change Tama (A + C on the home screen).', Icons.public_rounded, Color(0xFF2EC4B6), tab: 'feld'),
      _Tool('Neon Planets menu', 'Menu with saves, items, Tamapoints and Tama, programs in the menu, own characters for its planets '
          '(Neon switches planets itself: no field switch).', Icons.auto_awesome_rounded, Color(0xFFB04CFF), tab: 'feld'),
    ]),
    ('Emulators inside your Paradise', [
      _Tool('TamaEmu · T7 · T18 · V1 · V3', 'Plus Color, iD L, P\'s, 4U+, 4U; Tama-Go and Friends; Meets / On; P1, P2, Angel, '
          'Digimon; Connection V3. Up to twelve programs, start device, visits between two Paradise.', Icons.memory_rounded, Color(0xFFFF9F43), tab: 'emu'),
      _Tool('Game Boy / Color', 'From your own game files.', Icons.videogame_asset_rounded, Color(0xFF6FD96F), tab: 'gb'),
      _Tool('Master System / Game Gear', 'From your own game files.', Icons.sports_esports_rounded, Color(0xFF2F6BFF), tab: 'sms'),
      _Tool('Pokémon mini', 'From your own game files and BIOS.', Icons.catching_pokemon_rounded, Color(0xFFFF5A5A), tab: 'pm'),
      _Tool('Arduboy', 'From your own game files.', Icons.gamepad_rounded, Color(0xFF8A6B4E), tab: 'ab'),
      _Tool('DOOM', 'From your own DOOM.WAD.', Icons.local_fire_department_rounded, Color(0xFFD7263D), tab: 'doom'),
      _Tool('Wolf3D', 'From your own game files.', Icons.castle_rounded, Color(0xFF5C6BC0), tab: 'wolf'),
    ]),
    ('Characters and texts', [
      _Tool('Characters', 'Export a character as a sheet, repaint it, upload it; fields as ZIP.', Icons.face_rounded, Color(0xFFFF4F9A), tab: 'figs'),
      _Tool('All sprites', 'Every picture of the ROM.', Icons.grid_view_rounded, Color(0xFF7B5CFF), tab: 'all'),
      _Tool('Names', 'Rename fields, Tamas and items; move eyes and mouth.', Icons.text_fields_rounded, Color(0xFF26A69A), tab: 'names'),
      _Tool('Cards', 'Characters from character cards, TamaSma cards and DIM cards.', Icons.style_rounded, Color(0xFFFFB300), tab: 'dim'),
    ]),
    ('Saves and the device', [
      _Tool('Save games', 'Save editor (level, character, care), back up and restore the Paradise and TamaEmu saves.', Icons.save_rounded, Color(0xFF42A5F5), tab: 'save'),
      _Tool('Device (Studio)', 'Read the ROM, write only what changed, keep the saves; over your dongle.', Icons.usb_rounded, Color(0xFF2F6BFF), button: 'btnDevice'),
    ]),
  ];

  @override
  Widget build(BuildContext context) {
    void go(Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));
    return Scaffold(
      appBar: AppBar(title: const Text('Paramix')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          Card(
            color: const Color(0xFF2F6BFF),
            child: ListTile(
              leading: const Icon(Icons.apps_rounded, color: Colors.white, size: 32),
              title: const Text('Paramix Studio: everything', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              subtitle: const Text('The whole Studio. Open a ROM with the folder button at the top.', style: TextStyle(color: Colors.white70)),
              onTap: () => go(const StudioScreen()),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.cable_rounded),
              title: const Text('Device: read and write (quick)'),
              subtitle: const Text('The app\'s own device page: dump, write changes, keep the saves.'),
              onTap: () => go(const DeviceScreen()),
            ),
          ),
          for (final (title, tools) in _sections) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
              child: Text(title, style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final t in tools)
              Card(
                child: ListTile(
                  leading: CircleAvatar(backgroundColor: t.color, child: Icon(t.icon, color: Colors.white)),
                  title: Text(t.title),
                  subtitle: Text(t.subtitle),
                  onTap: () => go(StudioScreen(title: t.title, tab: t.tab, button: t.button)),
                ),
              ),
          ],
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 16, 4, 0),
            child: Text(
              'Paramix Studio by mameise (GPL-3.0), built into the app, works offline. It contains no ROM, firmware or game '
              'files: bring your own. Back up your device before writing to it.',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tool {
  const _Tool(this.title, this.subtitle, this.icon, this.color, {this.tab, this.button});
  final String title, subtitle;
  final IconData icon;
  final Color color;
  final String? tab, button;
}
