import 'dart:typed_data';

/// How the 128 x 128 screen is enlarged.
enum Upscale {
  pixel('Pixel (sharp)'),
  smooth('Smooth'),
  scale2x('Scale2x'),
  scale4x('Scale4x'),
  scale6x('Scale6x'),
  scale8x('Scale8x'),
  hq('Scale2x + smooth');

  const Upscale(this.label);
  final String label;
}

/// What is laid over the picture.
enum ScreenFilter {
  none('None'),
  lcd('LCD grid'),
  scanlines('Scanlines'),
  crt('CRT'),
  vivid('Vivid'),
  pastel('Pastel'),
  retro('Retro green'),
  sepia('Sepia'),
  night('Night (dim, warm)');

  const ScreenFilter(this.label);
  final String label;
}

/// A processed frame: RGBA pixels and their size.
class Frame {
  Frame(this.rgba, this.w, this.h);
  final Uint8List rgba;
  final int w, h;
}

/// Scale2x (EPX): doubles the picture, keeping edges crisp without blurring them.
Frame scale2x(Frame f) {
  final w = f.w, h = f.h, s = Uint32List.view(f.rgba.buffer, f.rgba.offsetInBytes, w * h);
  final out = Uint32List(w * h * 4);
  final ow = w * 2;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = s[y * w + x];
      final a = y > 0 ? s[(y - 1) * w + x] : p;
      final b = x < w - 1 ? s[y * w + x + 1] : p;
      final c = x > 0 ? s[y * w + x - 1] : p;
      final d = y < h - 1 ? s[(y + 1) * w + x] : p;
      var e0 = p, e1 = p, e2 = p, e3 = p;
      if (c == a && c != d && a != b) e0 = a;
      if (a == b && a != c && b != d) e1 = b;
      if (d == c && d != b && c != a) e2 = c;
      if (b == d && b != a && d != c) e3 = d;
      final o = (y * 2) * ow + x * 2;
      out[o] = e0;
      out[o + 1] = e1;
      out[o + ow] = e2;
      out[o + ow + 1] = e3;
    }
  }
  return Frame(out.buffer.asUint8List(), ow, h * 2);
}

/// Scale3x (AdvMAME3x): triples the picture, keeping edges crisp.
Frame scale3x(Frame f) {
  final w = f.w, h = f.h, s = Uint32List.view(f.rgba.buffer, f.rgba.offsetInBytes, w * h);
  final ow = w * 3;
  final out = Uint32List(w * h * 9);
  int at(int x, int y) => s[(y < 0 ? 0 : (y >= h ? h - 1 : y)) * w + (x < 0 ? 0 : (x >= w ? w - 1 : x))];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final a = at(x - 1, y - 1), b = at(x, y - 1), c = at(x + 1, y - 1);
      final d = at(x - 1, y), e = s[y * w + x], ff = at(x + 1, y);
      final g = at(x - 1, y + 1), hh = at(x, y + 1), i = at(x + 1, y + 1);
      var e0 = e, e1 = e, e2 = e, e3 = e, e5 = e, e6 = e, e7 = e, e8 = e;
      if (b != hh && d != ff) {
        e0 = d == b ? d : e;
        e1 = (d == b && e != c) || (b == ff && e != a) ? b : e;
        e2 = b == ff ? ff : e;
        e3 = (d == b && e != g) || (d == hh && e != a) ? d : e;
        e5 = (b == ff && e != i) || (hh == ff && e != c) ? ff : e;
        e6 = d == hh ? d : e;
        e7 = (d == hh && e != i) || (hh == ff && e != g) ? hh : e;
        e8 = hh == ff ? ff : e;
      }
      final o = (y * 3) * ow + x * 3;
      out[o] = e0;
      out[o + 1] = e1;
      out[o + 2] = e2;
      out[o + ow] = e3;
      out[o + ow + 1] = e;
      out[o + ow + 2] = e5;
      out[o + 2 * ow] = e6;
      out[o + 2 * ow + 1] = e7;
      out[o + 2 * ow + 2] = e8;
    }
  }
  return Frame(out.buffer.asUint8List(), ow, h * 3);
}

int _clamp(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());

/// Applies the colour part of a filter in place (the grid and line parts are drawn on top).
void colourFilter(Frame f, ScreenFilter k) {
  final d = f.rgba;
  switch (k) {
    case ScreenFilter.none:
    case ScreenFilter.lcd:
    case ScreenFilter.scanlines:
      return;
    case ScreenFilter.crt:
      // a little more contrast and a warm tint
      for (var i = 0; i < d.length; i += 4) {
        d[i] = _clamp((d[i] - 128) * 1.15 + 134);
        d[i + 1] = _clamp((d[i + 1] - 128) * 1.15 + 128);
        d[i + 2] = _clamp((d[i + 2] - 128) * 1.15 + 120);
      }
    case ScreenFilter.vivid:
      for (var i = 0; i < d.length; i += 4) {
        final l = 0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2];
        d[i] = _clamp(l + (d[i] - l) * 1.45);
        d[i + 1] = _clamp(l + (d[i + 1] - l) * 1.45);
        d[i + 2] = _clamp(l + (d[i + 2] - l) * 1.45);
      }
    case ScreenFilter.pastel:
      for (var i = 0; i < d.length; i += 4) {
        d[i] = _clamp(d[i] * 0.7 + 255 * 0.3);
        d[i + 1] = _clamp(d[i + 1] * 0.7 + 255 * 0.3);
        d[i + 2] = _clamp(d[i + 2] * 0.7 + 255 * 0.3);
      }
    case ScreenFilter.retro:
      // four shades of green, like an old handheld
      const pal = [
        [15, 56, 15],
        [48, 98, 48],
        [139, 172, 15],
        [155, 188, 15],
      ];
      for (var i = 0; i < d.length; i += 4) {
        final l = (0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2]) / 256;
        final c = pal[(l * 4).floor().clamp(0, 3)];
        d[i] = c[0];
        d[i + 1] = c[1];
        d[i + 2] = c[2];
      }
    case ScreenFilter.sepia:
      for (var i = 0; i < d.length; i += 4) {
        final r = d[i], g = d[i + 1], b = d[i + 2];
        d[i] = _clamp(r * 0.393 + g * 0.769 + b * 0.189);
        d[i + 1] = _clamp(r * 0.349 + g * 0.686 + b * 0.168);
        d[i + 2] = _clamp(r * 0.272 + g * 0.534 + b * 0.131);
      }
    case ScreenFilter.night:
      for (var i = 0; i < d.length; i += 4) {
        d[i] = _clamp(d[i] * 0.75);
        d[i + 1] = _clamp(d[i + 1] * 0.6);
        d[i + 2] = _clamp(d[i + 2] * 0.4);
      }
  }
}

/// Filters that are drawn over the picture (the others change its colours).
bool isOverlay(ScreenFilter f) => f == ScreenFilter.lcd || f == ScreenFilter.scanlines || f == ScreenFilter.crt;

/// The screen as it is shown: coloured by every chosen filter in turn (they stack), then upscaled.
/// Colouring first is 64 times less work at 8x.
Frame processFrame(Uint8List rgba128, Upscale up, List<ScreenFilter> filters) {
  var f = Frame(Uint8List.fromList(rgba128), 128, 128);
  for (final k in filters) {
    colourFilter(f, k);
  }
  switch (up) {
    case Upscale.scale2x:
    case Upscale.hq:
      f = scale2x(f);
    case Upscale.scale4x:
      f = scale2x(scale2x(f));
    case Upscale.scale6x:
      f = scale2x(scale3x(f));
    case Upscale.scale8x:
      f = scale2x(scale2x(scale2x(f)));
    case Upscale.pixel:
    case Upscale.smooth:
      break;
  }
  return f;
}
