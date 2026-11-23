import 'package:material_ui/material_ui.dart';

import '../services/app_state.dart';
import '../services/watch.dart';
import 'about_screen.dart';
import 'paramix_menu.dart';
import 'dongle_screen.dart';
import 'hardware_screen.dart';
import 'library_screen.dart';
import 'link_screen.dart';
import 'theme_screen.dart';

/// Everything that is not play, as big coloured tiles (one tap each).
class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tiles = <_Tile>[
      _Tile('Theme', 'Shell, buttons, dial', Icons.palette_rounded, const Color(0xFFFF4F9A), () => const ThemeScreen(), wide: true),
      _Tile('ROMs', 'Your games', Icons.auto_awesome_rounded, const Color(0xFF7B5CFF), () => const LibraryScreen()),
      _Tile('Paramix', 'Every tool: fields, emulators, menu', Icons.usb_rounded, const Color(0xFF2F6BFF), () => const ParamixMenu()),
      _Tile('Link', 'Toys and phones', Icons.hub_rounded, const Color(0xFF2EC4B6), () => const LinkScreen()),
      _Tile('Dongle', 'Your Tama Bridge', Icons.settings_input_antenna_rounded, const Color(0xFFFF5A5A), () => const DongleScreen()),
      _Tile('Hardware', 'Serial, Bluetooth, Wi-Fi', Icons.cable_rounded, const Color(0xFFFF9F43), () => const HardwareScreen()),
      if (WatchLink.instance.available) _Tile('Watch', 'Tama on your wrist', Icons.watch_rounded, const Color(0xFF6FD96F), () => const _WatchInfo()),
      _Tile('Settings', 'And about', Icons.tune_rounded, const Color(0xFF8A6B4E), () => const AboutScreen()),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Tools')),
      body: LayoutBuilder(builder: (context, c) {
        final cols = c.maxWidth > 700 ? 4 : 2;
        const gap = 10.0;
        final cell = (c.maxWidth - gap * (cols + 1)) / cols;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(gap),
          child: Wrap(spacing: gap, runSpacing: gap, children: [
            for (final t in tiles)
              SizedBox(
                width: t.wide ? cell * 2 + gap : cell,
                height: cell,
                child: _TileView(t),
              ),
          ]),
        );
      }),
    );
  }
}

class _Tile {
  const _Tile(this.title, this.subtitle, this.icon, this.color, this.page, {this.wide = false});
  final String title, subtitle;
  final IconData icon;
  final Color color;
  final Widget Function() page;
  final bool wide;
}

class _TileView extends StatefulWidget {
  const _TileView(this.t);
  final _Tile t;

  @override
  State<_TileView> createState() => _TileViewState();
}

class _TileViewState extends State<_TileView> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final on = t.color.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => t.page())),
      child: AnimatedScale(
        scale: _down ? 0.95 : 1,
        duration: const Duration(milliseconds: 90),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color.lerp(t.color, Colors.white, 0.15)!, t.color]),
            boxShadow: [BoxShadow(color: t.color.withValues(alpha: 0.35), blurRadius: 12, offset: const Offset(0, 5))],
          ),
          padding: const EdgeInsets.all(14),
          child: Stack(children: [
            // a big faint icon in the corner, as on a live tile
            Positioned(right: -10, bottom: -14, child: Icon(t.icon, size: 96, color: on.withValues(alpha: 0.16))),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(t.icon, size: 34, color: on),
              const Spacer(),
              Text(t.title, style: TextStyle(color: on, fontSize: 20, fontWeight: FontWeight.w800)),
              Text(t.subtitle, style: TextStyle(color: on.withValues(alpha: 0.8), fontSize: 12)),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _WatchInfo extends StatelessWidget {
  const _WatchInfo();

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Apple Watch')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Your games go to the watch by themselves: whatever you play here is on the watch too, with its latest save. '
            'Open Tama on the watch and it continues where you left off; when you come back here, the phone continues from the watch\'s save.'),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () async {
            final err = await WatchLink.instance.syncAll();
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Sent to the watch.')));
          },
          icon: const Icon(Icons.sync),
          label: const Text('Send everything now'),
        ),
        const SizedBox(height: 8),
        Text('${app.library.entries.length} games in the library.', style: const TextStyle(color: Colors.white54)),
      ]),
    );
  }
}
