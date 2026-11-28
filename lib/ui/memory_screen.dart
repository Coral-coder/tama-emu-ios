import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../paradise/paradise_core.dart';
import '../paradise/paradise_machine.dart';
import '../services/app_state.dart';

/// The game's memory, live: look at it, change any byte, find a value and narrow it down as it
/// changes in the game, hold values so the game cannot change them, keep named places.
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key, required this.machine, required this.gameKey});
  final ParadiseMachine machine;

  /// Bookmarks and held values are kept per game.
  final String gameKey;

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _Region {
  const _Region(this.id, this.name, this.base, this.help);
  final int id;
  final String name;
  final int base; // the address the console sees
  final String help;
}

const _regions = [
  _Region(0, 'Work RAM', 0x18000000, 'The game\'s live state (128 KB at 0x18000000).'),
  _Region(1, 'Flash', 0, 'ROM and save (16 MB). Saves: 0x1000-0x11000 and 0xEFE000-0xF00000. Changes go into the save.'),
  _Region(2, 'Program RAM', 0, 'Code and tables copied at boot (64 KB).'),
];

enum _Size { u8, u16, u32 }

enum _Narrow { equal, changed, same, up, down }

class _Mark {
  _Mark(this.region, this.addr, this.size, this.name, {this.held});
  final int region, addr;
  final _Size size;
  String name;
  int? held;

  Map<String, Object?> toJson() => {'r': region, 'a': addr, 's': size.index, 'n': name, 'h': held};
  static _Mark fromJson(Map<String, dynamic> j) =>
      _Mark(j['r'] as int, j['a'] as int, _Size.values[j['s'] as int], j['n'] as String, held: j['h'] as int?);
}

class _MemoryScreenState extends State<MemoryScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);
  Timer? _tick;
  int _region = 0;
  int _top = 0; // first address shown (offset in the region)
  Uint8List _view = Uint8List(0);
  Uint8List? _before; // previous look, to colour what changed
  static const _rows = 32;

  // search
  _Size _size = _Size.u8;
  List<int>? _hits; // offsets in work RAM
  Map<int, int> _last = {};
  final _value = TextEditingController();

  // bookmarks and held values
  List<_Mark> _marks = [];

  AppState get app => AppState.instance;
  ParadiseHandle? get _h => widget.machine.handle;

  @override
  void initState() {
    super.initState();
    _load();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) => _refresh());
    _refresh();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _mapPic?.dispose();
    _gamePic?.dispose();
    _tabs.dispose();
    _value.dispose();
    super.dispose();
  }

  String get _prefKey => 'memmarks:${widget.gameKey}';

  void _load() {
    final raw = app.prefs.getString(_prefKey);
    if (raw == null) return;
    try {
      _marks = [for (final j in jsonDecode(raw) as List) _Mark.fromJson(j as Map<String, dynamic>)];
      // held values come back when the tool is opened again
      for (final m in _marks) {
        if (m.held != null) _hold(m, m.held!);
      }
    } catch (_) {}
  }

  Future<void> _save() => app.prefs.setString(_prefKey, jsonEncode([for (final m in _marks) m.toJson()]));

  void _refresh() {
    final h = _h;
    if (h == null || !mounted) return;
    _before = _view;
    _view = h.memRead(_region, _top, 16 * _rows);
    _mapRefresh();
    setState(() {});
  }

  int get _regionSize => _h?.memSize(_region) ?? 0;

  int _bytes(_Size s) => s == _Size.u8 ? 1 : (s == _Size.u16 ? 2 : 4);

  int _read(int region, int addr, _Size s) {
    final b = _h?.memRead(region, addr, _bytes(s));
    if (b == null || b.length < _bytes(s)) return 0;
    final d = ByteData.sublistView(b);
    return switch (s) { _Size.u8 => d.getUint8(0), _Size.u16 => d.getUint16(0, Endian.little), _Size.u32 => d.getUint32(0, Endian.little) };
  }

  List<int> _encode(int v, _Size s) {
    final d = ByteData(4)..setUint32(0, v & 0xFFFFFFFF, Endian.little);
    return d.buffer.asUint8List().sublist(0, _bytes(s));
  }

  void _write(int region, int addr, int v, _Size s) {
    _h?.memWrite(region, addr, _encode(v, s));
    _refresh();
  }

  void _hold(_Mark m, int v) {
    m.held = v;
    _h?.memFreeze(m.region, m.addr, _encode(v, m.size));
  }

  void _letGo(_Mark m) {
    m.held = null;
    _h?.memFreeze(m.region, m.addr, const []);
  }

  int? _parse(String s) {
    s = s.trim().toLowerCase();
    if (s.isEmpty) return null;
    if (s.startsWith('0x')) return int.tryParse(s.substring(2), radix: 16);
    if (s.startsWith('\$')) return int.tryParse(s.substring(1), radix: 16);
    return int.tryParse(s);
  }

  String _hex(int v, int digits) => v.toRadixString(16).toUpperCase().padLeft(digits, '0');

  // ---- dialogs ----

  Future<void> _goTo() async {
    final c = TextEditingController(text: '0x${_hex(_regions[_region].base + _top, 8)}');
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Go to address'),
        content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(helperText: 'Hex with 0x, or decimal. Console or region address.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Go')),
        ],
      ),
    );
    final v = r == null ? null : _parse(r);
    if (v == null) return;
    _show(_region, v >= _regions[_region].base ? v - _regions[_region].base : v);
  }

  void _show(int region, int offset) {
    _region = region;
    final size = _regionSize;
    _top = (offset & ~0xF).clamp(0, size > 16 * _rows ? size - 16 * _rows : 0);
    _before = null;
    _tabs.animateTo(0);
    _refresh();
  }

  Future<void> _edit(int region, int addr, {_Size size = _Size.u8, String? title}) async {
    var s = size;
    final now = _read(region, addr, s);
    final c = TextEditingController(text: '$now');
    final name = TextEditingController();
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(title ?? '${_regions[region].name} 0x${_hex(_regions[region].base + addr, 8)}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            SegmentedButton<_Size>(
              segments: const [
                ButtonSegment(value: _Size.u8, label: Text('8-bit')),
                ButtonSegment(value: _Size.u16, label: Text('16')),
                ButtonSegment(value: _Size.u32, label: Text('32')),
              ],
              selected: {s},
              onSelectionChanged: (v) => setD(() {
                s = v.first;
                c.text = '${_read(region, addr, s)}';
              }),
            ),
            const SizedBox(height: 8),
            TextField(controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'Value', helperText: 'Decimal, or hex with 0x')),
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name it (keeps it in Saved)')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, 'hold'), child: const Text('Set and hold')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'set'), child: const Text('Set')),
          ],
        ),
      ),
    );
    if (r == null) return;
    final v = _parse(c.text);
    if (v == null) return;
    _write(region, addr, v, s);
    var mark = _marks.where((m) => m.region == region && m.addr == addr).firstOrNull;
    if (r == 'hold' || name.text.trim().isNotEmpty) {
      mark ??= _Mark(region, addr, s, name.text.trim().isEmpty ? '0x${_hex(_regions[region].base + addr, 8)}' : name.text.trim());
      if (!_marks.contains(mark)) _marks.add(mark);
      if (name.text.trim().isNotEmpty) mark.name = name.text.trim();
    }
    if (r == 'hold' && mark != null) _hold(mark, v);
    await _save();
    if (mounted) setState(() {});
  }

  // ---- the map: memory as a picture, one square a byte ----

  /// What the map can show: (name, region, first byte, length).
  List<(String, int, int, int)> get _mapAreas {
    final h = _h;
    if (h == null) return const [];
    final neon = h.memSize(1) > 0xD85004 && ByteData.sublistView(h.memRead(1, 0xD85000, 4)).getUint32(0, Endian.little) < 0x100;
    return [
      ('Work RAM', 0, 0, h.memSize(0)),
      if (neon) ('Save: settings', 1, 0xD85000, 0x6000) else ('Save: settings', 1, 0xEFE000, 0x2000),
      ('Save: game data', 1, 0x1000, 0x10000),
      ('Program RAM', 2, 0, h.memSize(2)),
    ];
  }

  int _mapArea = 0;
  int? _mapSel; // offset in the area
  Uint8List _mapNow = Uint8List(0);
  Uint8List _mapHeat = Uint8List(0);
  ui.Image? _mapPic, _gamePic;
  bool _mapBusy = false;
  int _mapSeenFrame = -1;
  final _mapZoom = TransformationController();
  static const _mapCols = 256;

  /// The fields of the pet this app knows, as (offset in work RAM, bytes, name, highest value).
  List<(int, int, String, int)> get _known {
    final h = _h;
    final pet = h?.pet();
    if (h == null || pet == null) return const [];
    final block = pet.block >= 0x18000000 ? pet.block - 0x18000000 : pet.block;
    final (rec, level) = h.petPlaces();
    final neon = _mapAreas.length > 1 && _mapAreas[1].$3 == 0xD85000;
    final r = block + rec;
    return [
      (r + 4, 2, 'Pet: character', 0xFFFF),
      (r + 0x10, 1, 'Pet: sick', 1),
      (r + 0x18, 1, 'Pet: life stage (bits 2 to 4)', 255),
      (r + 0x1C, 1, 'Pet: hunger (0 to 6)', 6),
      (r + 0x1D, 1, 'Pet: happiness (0 to 20)', 20),
      (r + (neon ? 0x3D : 0x3C), 1, 'Pet: poops on the field', 8),
      (block + level, 1, 'Planet level (low half)', 255),
      (block + 12, 4, 'Clock: day the date counts from', 0xFFFFFFFF),
      (block + 16, 4, 'Clock: second of that day', 86399),
    ];
  }

  (int, int, String, int)? _knownAt(int off) {
    if (_mapAreas.isEmpty || _mapAreas[_mapArea].$2 != 0) return null;
    for (final k in _known) {
      if (off >= k.$1 && off < k.$1 + k.$2) return k;
    }
    return null;
  }

  void _mapRefresh() {
    final h = _h;
    if (h == null || _tabs.index != 0 || _mapBusy || _mapAreas.isEmpty) return;
    final (_, region, start, len) = _mapAreas[_mapArea];
    final now = h.memRead(region, start, len);
    if (_mapHeat.length != now.length) _mapHeat = Uint8List(now.length);
    final old = _mapNow.length == now.length ? _mapNow : now;
    final rows = (now.length + _mapCols - 1) ~/ _mapCols;
    final px = Uint8List(_mapCols * rows * 4);
    final known = region == 0 ? _known : const <(int, int, String, int)>[];
    for (var i = 0; i < now.length; i++) {
      final v = now[i];
      var heat = _mapHeat[i];
      if (v != old[i]) {
        heat = 255;
      } else if (heat > 0) {
        heat = heat > 24 ? heat - 24 : 0;
      }
      _mapHeat[i] = heat;
      // quiet bytes: dark blue to pale by value; a byte that just changed glows orange and fades
      final o = i * 4;
      final r = 10 + (v * 70 >> 8), g = 14 + (v * 150 >> 8), b = 30 + (v * 200 >> 8);
      px[o] = r + ((255 - r) * heat >> 8);
      px[o + 1] = g + ((150 - g) * heat >> 8);
      px[o + 2] = b + ((20 - b) * heat >> 8);
      px[o + 3] = 255;
    }
    // the places with a name are marked green
    for (final k in known) {
      for (var i = k.$1; i < k.$1 + k.$2 && i < now.length; i++) {
        px[i * 4] = 60;
        px[i * 4 + 1] = 255;
        px[i * 4 + 2] = 120;
      }
    }
    for (final m in _marks) {
      final i = m.addr - start;
      if (m.region == region && i >= 0 && i < now.length) {
        px[i * 4] = 255;
        px[i * 4 + 1] = 80;
        px[i * 4 + 2] = 255;
      }
    }
    _mapNow = now;
    _mapBusy = true;
    ui.decodeImageFromPixels(px, _mapCols, rows, ui.PixelFormat.rgba8888, (img) {
      _mapBusy = false;
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _mapPic?.dispose();
        _mapPic = img;
      });
    });
    // the game's screen next to it
    final m = widget.machine;
    if (m.frame != _mapSeenFrame) {
      _mapSeenFrame = m.frame;
      final g = Uint8List(m.screen.length * 4);
      for (var i = 0; i < m.screen.length; i++) {
        final p = m.screen[i];
        g[i * 4] = ((p >> 11) & 31) * 255 ~/ 31;
        g[i * 4 + 1] = ((p >> 5) & 63) * 255 ~/ 63;
        g[i * 4 + 2] = (p & 31) * 255 ~/ 31;
        g[i * 4 + 3] = 255;
      }
      ui.decodeImageFromPixels(g, m.width, m.height, ui.PixelFormat.rgba8888, (img) {
        if (!mounted) {
          img.dispose();
          return;
        }
        setState(() {
          _gamePic?.dispose();
          _gamePic = img;
        });
      });
    }
  }

  void _mapStep(int off, int by) {
    final (_, region, start, _) = _mapAreas[_mapArea];
    final k = _knownAt(off);
    final at = k?.$1 ?? off, size = k == null ? _Size.u8 : (k.$2 == 1 ? _Size.u8 : (k.$2 == 2 ? _Size.u16 : _Size.u32));
    final max = k?.$4 ?? 255;
    final v = (_read(region, start + at, size) + by).clamp(0, max);
    _write(region, start + at, v, size);
  }

  Widget _mapKey(String label, int pin) => Listener(
        onPointerDown: (_) => widget.machine.press(pin),
        onPointerUp: (_) => widget.machine.release(pin),
        onPointerCancel: (_) => widget.machine.release(pin),
        child: Container(
          width: 44,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(8)),
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      );

  Widget _mapView() {
    final areas = _mapAreas;
    if (areas.isEmpty) return const Center(child: Text('The game is not running.'));
    final (_, region, start, len) = areas[_mapArea];
    final base = _regions[region].base + start;
    final sel = _mapSel != null && _mapSel! < len ? _mapSel : null;
    final k = sel == null ? null : _knownAt(sel);
    final rows = (len + _mapCols - 1) ~/ _mapCols;
    const mono = TextStyle(fontFamily: 'Menlo', fontFamilyFallback: ['monospace'], fontSize: 12);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Column(children: [
            Container(
              width: 128,
              height: 128 * widget.machine.height / widget.machine.width,
              color: Colors.black,
              child: _gamePic == null ? null : RawImage(image: _gamePic, filterQuality: FilterQuality.none, fit: BoxFit.fill),
            ),
            const SizedBox(height: 6),
            Row(children: [
              _mapKey('A', ParadiseHandle.pinA),
              const SizedBox(width: 4),
              _mapKey('B', ParadiseHandle.pinB),
              const SizedBox(width: 4),
              _mapKey('C', ParadiseHandle.pinC),
            ]),
          ]),
          const SizedBox(width: 12),
          Expanded(
            child: sel == null
                ? const Text(
                    'Every square is one byte: darker is a small value, paler a large one. A byte glows orange the moment the game '
                    'changes it. Green: places this app knows. Pink: places you kept.\n\nPlay with A B C and watch what lights up, '
                    'then tap a square to read and change it. Two fingers zoom.',
                    style: TextStyle(fontSize: 12, color: Colors.white70))
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(k?.$3 ?? 'Byte', style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text('0x${_hex(base + (k?.$1 ?? sel), 8)}', style: mono),
                    const SizedBox(height: 4),
                    Text(
                        k != null
                            ? '${_read(region, start + k.$1, k.$2 == 1 ? _Size.u8 : (k.$2 == 2 ? _Size.u16 : _Size.u32))}'
                            : '${_mapNow.length > sel ? _mapNow[sel] : 0}   0x${_hex(_mapNow.length > sel ? _mapNow[sel] : 0, 2)}'
                                '   16-bit ${_read(region, start + sel, _Size.u16)}',
                        style: const TextStyle(fontSize: 18)),
                    const SizedBox(height: 4),
                    Wrap(spacing: 6, runSpacing: 4, children: [
                      IconButton.filledTonal(visualDensity: VisualDensity.compact, icon: const Icon(Icons.remove), onPressed: () => _mapStep(sel, -1)),
                      IconButton.filledTonal(visualDensity: VisualDensity.compact, icon: const Icon(Icons.add), onPressed: () => _mapStep(sel, 1)),
                      OutlinedButton(
                        onPressed: () => _edit(region, start + (k?.$1 ?? sel),
                            size: k == null || k.$2 == 1 ? _Size.u8 : (k.$2 == 2 ? _Size.u16 : _Size.u32), title: k?.$3),
                        child: const Text('Set, hold, name'),
                      ),
                      TextButton(
                        onPressed: () {
                          _show(region, (start + sel) & ~15);
                          _tabs.animateTo(1);
                        },
                        child: const Text('As numbers'),
                      ),
                    ]),
                  ]),
          ),
        ]),
      ),
      SizedBox(
        height: 40,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          for (var i = 0; i < areas.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(areas[i].$1),
                selected: _mapArea == i,
                onSelected: (_) => setState(() {
                  _mapArea = i;
                  _mapSel = null;
                  _mapNow = Uint8List(0);
                  _mapZoom.value = Matrix4.identity();
                  _mapRefresh();
                }),
              ),
            ),
          if (region == 0)
            for (final f in _known)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(label: Text(f.$3.replaceFirst('Pet: ', '')), onPressed: () => setState(() => _mapSel = f.$1)),
              ),
        ]),
      ),
      Expanded(
        child: LayoutBuilder(builder: (context, box) {
          final cell = box.maxWidth / _mapCols;
          return ClipRect(
            child: InteractiveViewer(
              transformationController: _mapZoom,
              minScale: 1,
              maxScale: 40,
              constrained: false,
              child: GestureDetector(
                onTapUp: (d) {
                  final x = (d.localPosition.dx / cell).floor().clamp(0, _mapCols - 1), y = (d.localPosition.dy / cell).floor();
                  final off = y * _mapCols + x;
                  if (off >= 0 && off < len) setState(() => _mapSel = off);
                },
                child: SizedBox(
                  width: box.maxWidth,
                  height: rows * cell,
                  child: CustomPaint(
                    foregroundPainter: _MapMark(sel, cell, _mapCols),
                    child: _mapPic == null ? null : RawImage(image: _mapPic, filterQuality: FilterQuality.none, fit: BoxFit.fill),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    ]);
  }

  // ---- search (work RAM) ----

  Uint8List _ram() => _h!.memRead(0, 0, _h!.memSize(0));

  int _at(Uint8List ram, int o) {
    final d = ByteData.sublistView(ram);
    return switch (_size) {
      _Size.u8 => d.getUint8(o),
      _Size.u16 => o + 1 < ram.length ? d.getUint16(o, Endian.little) : 0,
      _Size.u32 => o + 3 < ram.length ? d.getUint32(o, Endian.little) : 0,
    };
  }

  void _newSearch() {
    if (_h == null) return;
    final ram = _ram();
    final want = _parse(_value.text);
    final step = _bytes(_size);
    final hits = <int>[];
    final last = <int, int>{};
    for (var o = 0; o + step <= ram.length; o += 1) {
      final v = _at(ram, o);
      if (want == null || v == want) {
        hits.add(o);
        last[o] = v;
      }
    }
    setState(() {
      _hits = hits;
      _last = last;
    });
  }

  void _narrow(_Narrow how) {
    final hits = _hits;
    if (hits == null || _h == null) return;
    final ram = _ram();
    final want = _parse(_value.text);
    final keep = <int>[];
    final last = <int, int>{};
    for (final o in hits) {
      final v = _at(ram, o), was = _last[o] ?? v;
      final ok = switch (how) {
        _Narrow.equal => want != null && v == want,
        _Narrow.changed => v != was,
        _Narrow.same => v == was,
        _Narrow.up => v > was,
        _Narrow.down => v < was,
      };
      if (ok) {
        keep.add(o);
        last[o] = v;
      }
    }
    setState(() {
      _hits = keep;
      _last = last;
    });
  }

  // ---- views ----

  Widget _hexView() {
    final base = _regions[_region].base;
    final mono = const TextStyle(fontFamily: 'Menlo', fontFamilyFallback: ['monospace', 'Courier'], fontSize: 12.5);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Row(children: [
          DropdownButton<int>(
            value: _region,
            items: [for (final r in _regions) DropdownMenuItem(value: r.id, child: Text(r.name))],
            onChanged: (v) => _show(v ?? 0, 0),
          ),
          const Spacer(),
          IconButton(tooltip: 'Up a page', icon: const Icon(Icons.keyboard_double_arrow_up), onPressed: () => _show(_region, _top - 16 * _rows)),
          IconButton(tooltip: 'Down a page', icon: const Icon(Icons.keyboard_double_arrow_down), onPressed: () => _show(_region, _top + 16 * _rows)),
          IconButton(tooltip: 'Go to address', icon: const Icon(Icons.pin_drop_outlined), onPressed: _goTo),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(_regions[_region].help, style: const TextStyle(fontSize: 12, color: Colors.white60)),
      ),
      if (_region == 1)
        Wrap(spacing: 6, children: [
          ActionChip(label: const Text('Save 0x1000'), onPressed: () => _show(1, 0x1000)),
          ActionChip(label: const Text('Settings 0xEFE000'), onPressed: () => _show(1, 0xEFE000)),
        ]),
      Expanded(
        child: ListView.builder(
          itemCount: (_view.length / 16).ceil(),
          itemBuilder: (_, row) {
            final o = row * 16;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
              child: Row(children: [
                Text(_hex(base + _top + o, 8), style: mono.copyWith(color: Colors.white54)),
                const SizedBox(width: 6),
                for (var i = 0; i < 16 && o + i < _view.length; i++)
                  InkWell(
                    onTap: () => _edit(_region, _top + o + i),
                    child: Padding(
                      padding: EdgeInsets.only(right: i == 7 ? 7 : 3),
                      child: Text(
                        _hex(_view[o + i], 2),
                        style: mono.copyWith(
                          color: _before != null && _before!.length > o + i && _before![o + i] != _view[o + i]
                              ? Colors.amberAccent
                              : (_view[o + i] == 0 ? Colors.white30 : Colors.white),
                        ),
                      ),
                    ),
                  ),
              ]),
            );
          },
        ),
      ),
    ]);
  }

  Widget _searchView() {
    final hits = _hits;
    return ListView(padding: const EdgeInsets.all(12), children: [
      const Text('Find a value in work RAM: search for what the game shows (or leave the value empty to take everything), '
          'change it in the game, then narrow down. Tap a result to change or hold it.', style: TextStyle(color: Colors.white70)),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: TextField(controller: _value, keyboardType: TextInputType.text, decoration: const InputDecoration(labelText: 'Value', hintText: 'e.g. 6, or 0x1A'))),
        const SizedBox(width: 8),
        DropdownButton<_Size>(
          value: _size,
          items: const [
            DropdownMenuItem(value: _Size.u8, child: Text('8-bit')),
            DropdownMenuItem(value: _Size.u16, child: Text('16-bit')),
            DropdownMenuItem(value: _Size.u32, child: Text('32-bit')),
          ],
          onChanged: (v) => setState(() {
            _size = v ?? _Size.u8;
            _hits = null;
          }),
        ),
      ]),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 4, children: [
        FilledButton(onPressed: _newSearch, child: const Text('New search')),
        if (hits != null) ...[
          OutlinedButton(onPressed: () => _narrow(_Narrow.equal), child: const Text('= value')),
          OutlinedButton(onPressed: () => _narrow(_Narrow.changed), child: const Text('Changed')),
          OutlinedButton(onPressed: () => _narrow(_Narrow.same), child: const Text('Same')),
          OutlinedButton(onPressed: () => _narrow(_Narrow.up), child: const Text('Went up')),
          OutlinedButton(onPressed: () => _narrow(_Narrow.down), child: const Text('Went down')),
        ],
      ]),
      const SizedBox(height: 8),
      if (hits != null) Text('${hits.length} places', style: Theme.of(context).textTheme.titleSmall),
      if (hits != null)
        for (final o in hits.take(200))
          ListTile(
            dense: true,
            title: Text('0x${_hex(0x18000000 + o, 8)}', style: const TextStyle(fontFamily: 'Menlo', fontFamilyFallback: ['monospace'])),
            trailing: Text('${_read(0, o, _size)}'),
            onTap: () => _edit(0, o, size: _size),
            onLongPress: () => _show(0, o),
          ),
      if (hits != null && hits.length > 200) const Text('Narrow down to see the rest.', style: TextStyle(color: Colors.white54)),
    ]);
  }

  Widget _savedView() {
    if (_marks.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Nothing kept yet. Give a place a name when you change it, or hold it, and it shows up here.', textAlign: TextAlign.center),
        ),
      );
    }
    return ListView(children: [
      for (final m in _marks)
        ListTile(
          title: Text(m.name),
          subtitle: Text('${_regions[m.region].name} 0x${_hex(_regions[m.region].base + m.addr, 8)} · now ${_read(m.region, m.addr, m.size)}'
              '${m.held != null ? ' · held at ${m.held}' : ''}'),
          leading: Icon(m.held != null ? Icons.lock : Icons.bookmark_outline, color: m.held != null ? Colors.amberAccent : null),
          onTap: () => _edit(m.region, m.addr, size: m.size, title: m.name),
          trailing: PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'hold':
                  _hold(m, _read(m.region, m.addr, m.size));
                case 'free':
                  _letGo(m);
                case 'show':
                  _show(m.region, m.addr);
                case 'copy':
                  await Clipboard.setData(ClipboardData(text: '0x${_hex(_regions[m.region].base + m.addr, 8)}'));
                case 'del':
                  _letGo(m);
                  _marks.remove(m);
              }
              await _save();
              if (mounted) setState(() {});
            },
            itemBuilder: (_) => [
              if (m.held == null) const PopupMenuItem(value: 'hold', child: Text('Hold at the current value')),
              if (m.held != null) const PopupMenuItem(value: 'free', child: Text('Let go')),
              const PopupMenuItem(value: 'show', child: Text('Show in memory')),
              const PopupMenuItem(value: 'copy', child: Text('Copy the address')),
              const PopupMenuItem(value: 'del', child: Text('Forget')),
            ],
          ),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Memory'),
        actions: [
          IconButton(
            tooltip: 'Let go of everything held',
            icon: const Icon(Icons.lock_open),
            onPressed: () async {
              _h?.memUnfreezeAll();
              for (final m in _marks) {
                m.held = null;
              }
              await _save();
              if (mounted) setState(() {});
            },
          ),
        ],
        bottom: TabBar(controller: _tabs, tabs: const [Tab(text: 'Map'), Tab(text: 'Memory'), Tab(text: 'Find'), Tab(text: 'Saved')]),
      ),
      body: TabBarView(controller: _tabs, physics: const NeverScrollableScrollPhysics(), children: [_mapView(), _hexView(), _searchView(), _savedView()]),
    );
  }
}

/// The chosen byte on the map: a frame around it and hair lines to find it when zoomed out.
class _MapMark extends CustomPainter {
  _MapMark(this.sel, this.cell, this.cols);
  final int? sel;
  final double cell;
  final int cols;

  @override
  void paint(Canvas canvas, Size size) {
    final s = sel;
    if (s == null) return;
    final x = (s % cols) * cell, y = (s ~/ cols) * cell;
    final line = Paint()
      ..color = Colors.white38
      ..strokeWidth = cell / 6;
    canvas.drawLine(Offset(0, y + cell / 2), Offset(size.width, y + cell / 2), line);
    canvas.drawLine(Offset(x + cell / 2, 0), Offset(x + cell / 2, size.height), line);
    canvas.drawRect(
        Rect.fromLTWH(x - cell / 2, y - cell / 2, cell * 2, cell * 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..color = Colors.white
          ..strokeWidth = cell / 3);
  }

  @override
  bool shouldRepaint(_MapMark old) => old.sel != sel || old.cell != cell;
}
