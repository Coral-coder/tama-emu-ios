import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../emu/rom_info.dart';
import '../paramix/bytes.dart';
import '../paramix/edition.dart';
import '../paramix/sprites.dart';
import '../services/app_state.dart';
import '../services/rom_library.dart';
import 'games_screen.dart';
import 'device_screen.dart';
import 'theme.dart';

/// One ROM in the Studio: what it is, its pictures, and what to do with it.
class RomDetailScreen extends StatefulWidget {
  const RomDetailScreen({super.key, required this.entry});
  final RomEntry entry;

  @override
  State<RomDetailScreen> createState() => _RomDetailScreenState();
}

class _RomInfo {
  _RomInfo(this.rom, this.edition, this.assets, this.error);
  final Uint8List rom;
  final Edition? edition;
  final ParadiseAssets? assets;
  final String? error;
}

class _RomDetailScreenState extends State<RomDetailScreen> {
  late final Future<_RomInfo> _info = _load();

  Future<_RomInfo> _load() async {
    final b = await AppState.instance.library.bytes(widget.entry);
    if (widget.entry.kind != RomKind.paradise) return _RomInfo(b, null, null, null);
    try {
      return _RomInfo(b, edition(b), ParadiseAssets.open(b), null);
    } catch (e) {
      return _RomInfo(b, edition(b), null, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    return Scaffold(
      appBar: AppBar(title: Text(e.name)),
      body: FutureBuilder<_RomInfo>(
        future: _info,
        builder: (context, snap) {
          final i = snap.data;
          if (i == null) return const Center(child: CircularProgressIndicator());
          return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
            FutureBuilder<File?>(
              future: AppState.instance.library.cover(e),
              builder: (context, s) => s.data == null
                  ? const SizedBox(height: 8)
                  : AspectRatio(aspectRatio: 2, child: Image.file(s.data!, fit: BoxFit.cover, filterQuality: FilterQuality.medium)),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _row('Kind', e.kind == RomKind.paradise ? 'Tamagotchi Paradise flash image' : e.kind == RomKind.e0c6s4x ? 'First-generation toy ROM (E0C6S46/48)' : 'Other file'),
                  _row('Size', '${e.size} bytes'),
                  _row('CRC-32', crc32(i.rom).toRadixString(16).padLeft(8, '0')),
                  if (e.kind == RomKind.e0c6s4x) _row('Toy', ToyProfile(i.rom).displayName),
                  if (i.edition != null) _row('Edition', i.edition!.name),
                  if (i.edition != null && !i.edition!.profile.ring) _row('Fields', i.edition!.profile.fields.join(', ') + (isSix(i.rom) ? ' + three more (six fields)' : '')),
                  if (i.assets != null) _row('Pictures', '${i.assets!.entries.length} sprites, assets end at ${hex(i.assets!.assetEnd)}'),
                  if (e.kind == RomKind.paradise) _row('Device key', AppState.instance.paradiseKey(e)?.toRadixString(16).padLeft(8, '0').toUpperCase() ?? 'not set'),
                  if (i.error != null) Text(i.error!, style: const TextStyle(color: Colors.redAccent)),
                ]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                if (e.kind != RomKind.other)
                  FilledButton.icon(
                    onPressed: () async {
                      Navigator.of(context).pop();
                      await startGame(context, e);
                    },
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play'),
                  ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final f = await AppState.instance.library.exportFile(e);
                    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], subject: e.name));
                  },
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Export'),
                ),
                if (e.kind == RomKind.paradise)
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const DeviceScreen())),
                    icon: const Icon(Icons.upload),
                    label: const Text('Write to the device'),
                  ),
              ]),
            ),
            if (i.assets != null) _SpriteStrip(assets: i.assets!),
          ]);
        },
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 96, child: Text(k, style: const TextStyle(color: kAmber))),
          Expanded(child: Text(v)),
        ]),
      );
}

/// The ROM's full-screen pictures (title, backgrounds, fields), decoded from the ROM itself.
class _SpriteStrip extends StatefulWidget {
  const _SpriteStrip({required this.assets});
  final ParadiseAssets assets;

  @override
  State<_SpriteStrip> createState() => _SpriteStripState();
}

class _SpriteStripState extends State<_SpriteStrip> {
  late final List<int> _big = [
    for (var i = 0; i < widget.assets.entries.length; i++)
      if (_isBig(i)) i,
  ];

  bool _isBig(int i) {
    try {
      final h = widget.assets.header(i);
      return h.width >= 128 && h.height >= 128 && h.width <= 512;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
        child: Text('Pictures in this ROM (${_big.length})', style: Theme.of(context).textTheme.titleSmall!.copyWith(color: kAmber)),
      ),
      SizedBox(
        height: 140,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: _big.length,
          itemBuilder: (context, k) => Padding(
            padding: const EdgeInsets.all(4),
            child: _SpriteTile(assets: widget.assets, index: _big[k]),
          ),
        ),
      ),
    ]);
  }
}

class _SpriteTile extends StatelessWidget {
  const _SpriteTile({required this.assets, required this.index});
  final ParadiseAssets assets;
  final int index;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: () async {
        final r = spriteDecode(assets.entries[index]);
        return Image.memory(_bmp(r), width: 128, height: 128, fit: BoxFit.cover, filterQuality: FilterQuality.none, gaplessPlayback: true);
      }(),
      builder: (context, s) => Column(children: [
        SizedBox(width: 128, height: 118, child: s.data ?? const ColoredBox(color: Colors.black26)),
        Text('#$index', style: const TextStyle(fontSize: 10, color: Colors.white54)),
      ]),
    );
  }

  /// RGBA to a BMP file (32-bit, top-down), which Image.memory can show.
  static Uint8List _bmp(Rgba r) {
    final size = 54 + r.w * r.h * 4;
    final b = Uint8List(size);
    b.setAll(0, [0x42, 0x4D]);
    w32(b, 2, size);
    w32(b, 10, 54);
    w32(b, 14, 40);
    w32(b, 18, r.w);
    w32(b, 22, -r.h & 0xFFFFFFFF);
    w16(b, 26, 1);
    w16(b, 28, 32);
    w32(b, 34, r.w * r.h * 4);
    var o = 54;
    for (var i = 0; i < r.w * r.h; i++) {
      final a = r.data[i * 4 + 3];
      b[o++] = a == 0 ? 0x22 : r.data[i * 4 + 2];
      b[o++] = a == 0 ? 0x22 : r.data[i * 4 + 1];
      b[o++] = a == 0 ? 0x22 : r.data[i * 4];
      b[o++] = 255;
    }
    return b;
  }
}
