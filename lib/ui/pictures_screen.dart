import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../paramix/sprite_edit.dart';
import '../paramix/sprites.dart';
import '../services/app_state.dart';
import '../services/rom_library.dart';

/// Every picture of a Paradise ROM (characters, items, fields, screens ...), to look at and
/// repaint. Changes are kept until "Write into the ROM": a ROM from the app's own collection
/// becomes your copy ("… (mine)", with the save carried over); your own ROM is changed in place.
class PicturesScreen extends StatefulWidget {
  const PicturesScreen({super.key, required this.rom});
  final RomEntry rom;

  @override
  State<PicturesScreen> createState() => _PicturesScreenState();
}

class _PicturesScreenState extends State<PicturesScreen> {
  Uint8List? _rom;
  ParadiseAssets? _assets;
  final Map<int, Uint8List> _changed = {};
  final Map<int, Future<ui.Image?>> _thumbs = {};
  String? _error;
  bool _busy = false;
  int _min = 0; // smallest picture side shown (filters the tiny parts away)

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final b = await AppState.instance.library.bytes(widget.rom);
      setState(() {
        _rom = b;
        _assets = ParadiseAssets.open(b);
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Uint8List _entry(int i) => _changed[i] ?? _assets!.entries[i];

  Future<ui.Image?> _thumb(int i) => _thumbs.putIfAbsent(i, () async {
        try {
          final p = spriteDecode(_entry(i));
          final buf = await ui.ImmutableBuffer.fromUint8List(p.data);
          final d = ui.ImageDescriptor.raw(buf, width: p.w, height: p.h, pixelFormat: ui.PixelFormat.rgba8888);
          final c = await d.instantiateCodec();
          return (await c.getNextFrame()).image;
        } catch (_) {
          return null;
        }
      });

  Future<void> _write() async {
    final rom = _rom;
    if (rom == null || _changed.isEmpty) return;
    setState(() => _busy = true);
    try {
      final out = buildRom(rom, _changed);
      final app = AppState.instance;
      final e = widget.rom;
      final wasRunning = app.games.containsKey(e.id);
      if (wasRunning) await app.stopGame(e.id);
      RomEntry target;
      if (e.file != null) {
        // your own ROM: changed in place (same game, same save)
        await e.file!.writeAsBytes(out, flush: true);
        target = e;
        await app.library.forget(e);
      } else {
        // the app's own ROM: your copy, with the save carried over
        target = await app.library.import(out, '${e.name} (mine)');
        final from = app.library.paradiseSave(e), to = app.library.paradiseSave(target);
        if (await from.exists() && !await to.exists()) await from.copy(to.path);
        await app.setGameTheme(target.id, app.themeOf(e.id));
      }
      _changed.clear();
      _thumbs.clear();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.file != null ? 'Written into ${e.name}.' : 'Saved as "${target.name}", with your save. Play it from the games.'),
      ));
      if (wasRunning) await app.playParadise(target);
      if (e.file == null && mounted) Navigator.of(context).pop();
    } catch (err) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Not written: $err')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = _assets;
    final idx = <int>[];
    if (a != null) {
      for (var i = 0; i < a.entries.length; i++) {
        try {
          final h = a.header(i);
          if (h.width >= _min && h.height >= _min) idx.add(i);
        } catch (_) {}
      }
    }
    return Scaffold(
      appBar: AppBar(title: Text('Pictures · ${widget.rom.name}'), actions: [
        PopupMenuButton<int>(
          tooltip: 'Which pictures',
          icon: const Icon(Icons.filter_list),
          onSelected: (v) => setState(() => _min = v),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 0, child: Text('All pictures')),
            PopupMenuItem(value: 32, child: Text('32 px and bigger')),
            PopupMenuItem(value: 64, child: Text('64 px and bigger (characters, screens)')),
          ],
        ),
      ]),
      floatingActionButton: _changed.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _busy ? null : _write,
              icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_alt),
              label: Text('Write ${_changed.length} into the ROM'),
            ),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
          : a == null
              ? const Center(child: CircularProgressIndicator())
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 96, mainAxisSpacing: 6, crossAxisSpacing: 6, childAspectRatio: 0.8),
                  itemCount: idx.length,
                  itemBuilder: (context, k) {
                    final i = idx[k];
                    return InkWell(
                      onTap: () async {
                        final r = await Navigator.of(context).push<Uint8List>(MaterialPageRoute(builder: (_) => SpriteEditor(entry: _entry(i), index: i)));
                        if (r != null) {
                          setState(() {
                            _changed[i] = r;
                            _thumbs.remove(i);
                          });
                        }
                      },
                      child: Column(children: [
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF26222E),
                              borderRadius: BorderRadius.circular(8),
                              border: _changed.containsKey(i) ? Border.all(color: Theme.of(context).colorScheme.primary, width: 2) : null,
                            ),
                            padding: const EdgeInsets.all(4),
                            child: FutureBuilder<ui.Image?>(
                              future: _thumb(i),
                              builder: (_, s) => s.data == null ? const SizedBox.shrink() : RawImage(image: s.data, filterQuality: FilterQuality.none),
                            ),
                          ),
                        ),
                        Text('#$i', style: const TextStyle(fontSize: 10, color: Colors.white54)),
                      ]),
                    );
                  },
                ),
    );
  }
}

enum _Tool { pen, erase, fill, pick }

/// Repaint one picture, pixel by pixel, in its own colours (all its frames).
class SpriteEditor extends StatefulWidget {
  const SpriteEditor({super.key, required this.entry, required this.index});
  final Uint8List entry;
  final int index;

  @override
  State<SpriteEditor> createState() => _SpriteEditorState();
}

class _SpriteEditorState extends State<SpriteEditor> {
  late List<Rgba> _pics;
  late final List<List<int>> _palette;
  late final bool _canErase;
  int _frame = 0;
  _Tool _tool = _Tool.pen;
  List<int> _colour = const [0, 0, 0];
  final List<(int, Uint8List)> _undo = [];
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _pics = spritePictures(widget.entry);
    final (pal, tr) = spritePalette(widget.entry);
    final h = SpriteHeader(widget.entry);
    _canErase = tr >= 0 || ((h.flags & 0x04) != 0);
    if (pal.isNotEmpty) {
      _palette = [for (var i = 0; i < pal.length; i++) if (i != tr) pal[i]];
    } else {
      // full colour: the colours already in the picture, then a few more
      final set = <int>{};
      for (final p in _pics) {
        for (var i = 0; i < p.data.length && set.length < 40; i += 4) {
          if (p.data[i + 3] >= 128) set.add((p.data[i] << 16) | (p.data[i + 1] << 8) | p.data[i + 2]);
        }
      }
      _palette = [for (final c in set) [(c >> 16) & 255, (c >> 8) & 255, c & 255]];
      for (final c in const [[0, 0, 0], [255, 255, 255], [255, 80, 80], [80, 200, 120], [80, 140, 255], [255, 210, 80]]) {
        if (!_palette.any((p) => p[0] == c[0] && p[1] == c[1] && p[2] == c[2])) _palette.add(c);
      }
    }
    if (_palette.isNotEmpty) _colour = _palette.first;
  }

  Rgba get _p => _pics[_frame];

  void _snapshot() {
    _undo.add((_frame, Uint8List.fromList(_p.data)));
    if (_undo.length > 60) _undo.removeAt(0);
  }

  void _set(int x, int y, List<int>? c) {
    final o = (y * _p.w + x) * 4;
    final d = _p.data;
    if (c == null) {
      d[o] = d[o + 1] = d[o + 2] = d[o + 3] = 0;
    } else {
      d[o] = c[0];
      d[o + 1] = c[1];
      d[o + 2] = c[2];
      d[o + 3] = 255;
    }
  }

  void _fill(int x0, int y0, List<int>? c) {
    final d = _p.data, w = _p.w, h = _p.h;
    final o0 = (y0 * w + x0) * 4;
    final target = [d[o0], d[o0 + 1], d[o0 + 2], d[o0 + 3]];
    bool same(int o) => target[3] < 128 ? d[o + 3] < 128 : (d[o + 3] >= 128 && d[o] == target[0] && d[o + 1] == target[1] && d[o + 2] == target[2]);
    final seen = Uint8List(w * h);
    final stack = [y0 * w + x0];
    while (stack.isNotEmpty) {
      final k = stack.removeLast();
      if (seen[k] == 1) continue;
      seen[k] = 1;
      if (!same(k * 4)) continue;
      _set(k % w, k ~/ w, c);
      final x = k % w, y = k ~/ w;
      if (x > 0) stack.add(k - 1);
      if (x < w - 1) stack.add(k + 1);
      if (y > 0) stack.add(k - w);
      if (y < h - 1) stack.add(k + w);
    }
  }

  void _touch(Offset local, Size size, {bool start = false}) {
    final x = (local.dx / size.width * _p.w).floor(), y = (local.dy / size.height * _p.h).floor();
    if (x < 0 || y < 0 || x >= _p.w || y >= _p.h) return;
    switch (_tool) {
      case _Tool.pick:
        final o = (y * _p.w + x) * 4;
        if (_p.data[o + 3] >= 128) setState(() => _colour = [_p.data[o], _p.data[o + 1], _p.data[o + 2]]);
        return;
      case _Tool.fill:
        if (!start) return;
        _snapshot();
        _fill(x, y, _colour);
      case _Tool.pen:
        if (start) _snapshot();
        _set(x, y, _colour);
      case _Tool.erase:
        if (!_canErase) return;
        if (start) _snapshot();
        _set(x, y, null);
    }
    setState(() => _dirty = true);
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return Scaffold(
      appBar: AppBar(title: Text('Picture #${widget.index}'), actions: [
        IconButton(
          tooltip: 'Undo',
          icon: const Icon(Icons.undo),
          onPressed: _undo.isEmpty
              ? null
              : () {
                  final (f, d) = _undo.removeLast();
                  setState(() {
                    _frame = f;
                    _pics[f].data.setAll(0, d);
                  });
                },
        ),
        TextButton(
          onPressed: !_dirty
              ? null
              : () {
                  try {
                    Navigator.pop(context, spriteEncode(widget.entry, _pics));
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
                  }
                },
          child: const Text('Keep'),
        ),
      ]),
      body: Column(children: [
        if (_pics.length > 1)
          SizedBox(
            height: 44,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
              for (var i = 0; i < _pics.length; i++)
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: ChoiceChip(label: Text('${i + 1}'), selected: i == _frame, onSelected: (_) => setState(() => _frame = i)),
                ),
            ]),
          ),
        Expanded(
          child: InteractiveViewer(
            maxScale: 12,
            panEnabled: false,
            child: Center(
              child: AspectRatio(
                aspectRatio: p.w / p.h,
                child: LayoutBuilder(
                  builder: (context, c) => GestureDetector(
                    onPanStart: (d) => _touch(d.localPosition, c.biggest, start: true),
                    onPanUpdate: (d) => _touch(d.localPosition, c.biggest),
                    onTapDown: (d) => _touch(d.localPosition, c.biggest, start: true),
                    child: CustomPaint(size: c.biggest, painter: _Pixels(p)),
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: SegmentedButton<_Tool>(
            segments: [
              const ButtonSegment(value: _Tool.pen, icon: Icon(Icons.edit), label: Text('Draw')),
              if (_canErase) const ButtonSegment(value: _Tool.erase, icon: Icon(Icons.auto_fix_normal), label: Text('Erase')),
              const ButtonSegment(value: _Tool.fill, icon: Icon(Icons.format_color_fill), label: Text('Fill')),
              const ButtonSegment(value: _Tool.pick, icon: Icon(Icons.colorize), label: Text('Pick')),
            ],
            selected: {_tool},
            onSelectionChanged: (v) => setState(() => _tool = v.first),
          ),
        ),
        SafeArea(
          top: false,
          child: SizedBox(
            height: 64,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.all(10), children: [
              for (final c in _palette)
                GestureDetector(
                  onTap: () => setState(() {
                    _colour = c;
                    if (_tool == _Tool.erase || _tool == _Tool.pick) _tool = _Tool.pen;
                  }),
                  child: Container(
                    width: 40,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: Color.fromARGB(255, c[0], c[1], c[2]),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: identical(c, _colour) || (c[0] == _colour[0] && c[1] == _colour[1] && c[2] == _colour[2]) ? Colors.white : Colors.white24, width: 3),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _Pixels extends CustomPainter {
  _Pixels(this.p);
  final Rgba p;

  @override
  void paint(Canvas canvas, Size size) {
    final cw = size.width / p.w, ch = size.height / p.h;
    final check = Paint()..color = const Color(0xFF2C2834);
    final check2 = Paint()..color = const Color(0xFF221F29);
    final paint = Paint();
    for (var y = 0; y < p.h; y++) {
      for (var x = 0; x < p.w; x++) {
        final o = (y * p.w + x) * 4;
        final r = Rect.fromLTWH(x * cw, y * ch, cw + 0.5, ch + 0.5);
        if (p.data[o + 3] < 128) {
          canvas.drawRect(r, (x + y).isEven ? check : check2);
        } else {
          paint.color = Color.fromARGB(255, p.data[o], p.data[o + 1], p.data[o + 2]);
          canvas.drawRect(r, paint);
        }
      }
    }
    if (cw >= 6) {
      final grid = Paint()..color = Colors.black.withValues(alpha: 0.18)..strokeWidth = 1;
      for (var x = 0; x <= p.w; x++) {
        canvas.drawLine(Offset(x * cw, 0), Offset(x * cw, size.height), grid);
      }
      for (var y = 0; y <= p.h; y++) {
        canvas.drawLine(Offset(0, y * ch), Offset(size.width, y * ch), grid);
      }
    }
  }

  @override
  bool shouldRepaint(_Pixels o) => true;
}
