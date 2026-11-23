import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../paradise/paradise_machine.dart';
import '../services/app_state.dart';
import 'screen_filters.dart';

/// The colour screen of one running Paradise (used for the second console of a link).
class ParadiseScreen extends StatefulWidget {
  const ParadiseScreen({super.key, required this.machine});
  final ParadiseMachine machine;

  @override
  State<ParadiseScreen> createState() => _ParadiseScreenState();
}

class _ParadiseScreenState extends State<ParadiseScreen> {
  ui.Image? _img;
  bool _decoding = false;
  int _shown = -1;
  final Uint8List _rgba = Uint8List(128 * 128 * 4);

  @override
  void initState() {
    super.initState();
    widget.machine.addListener(_onFrame);
    _onFrame();
  }

  @override
  void didUpdateWidget(ParadiseScreen old) {
    super.didUpdateWidget(old);
    if (old.machine != widget.machine) {
      old.machine.removeListener(_onFrame);
      widget.machine.addListener(_onFrame);
      _shown = -1;
      _onFrame();
    }
  }

  @override
  void dispose() {
    widget.machine.removeListener(_onFrame);
    _img?.dispose();
    super.dispose();
  }

  void _onFrame() {
    final m = widget.machine;
    if (m.frame == _shown) return;
    if (_decoding) return; // big upscales: one picture at a time, the next tick takes the newest
    _shown = m.frame;
    final s = m.screen;
    for (var i = 0; i < s.length; i++) {
      final v = s[i];
      _rgba[i * 4] = ((v >> 11) & 31) * 255 ~/ 31;
      _rgba[i * 4 + 1] = ((v >> 5) & 63) * 255 ~/ 63;
      _rgba[i * 4 + 2] = (v & 31) * 255 ~/ 31;
      _rgba[i * 4 + 3] = 255;
    }
    final app = AppState.instance;
    final f = processFrame(_rgba, app.upscale, app.filters);
    _decoding = true;
    ui.decodeImageFromPixels(f.rgba, f.w, f.h, ui.PixelFormat.rgba8888, (im) {
      _decoding = false;
      if (!mounted) return;
      setState(() {
        _img?.dispose();
        _img = im;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return _img == null
        ? const ColoredBox(color: Colors.black)
        : RawImage(
            image: _img,
            fit: BoxFit.fill,
            filterQuality: app.upscale == Upscale.smooth || app.upscale == Upscale.hq ? FilterQuality.medium : FilterQuality.none,
          );
  }
}
