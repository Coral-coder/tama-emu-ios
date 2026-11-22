---
name: vfd-theme
description: The "Amber VFD" theme (vacuum-fluorescent dot-matrix display) for iOS apps. Use whenever the user asks for "vfd", a VFD theme, an amber/dot-matrix/VFD look, or a pixel-matrix display style. Defines the look, glyph font, renderer, user-selectable base colour and the preview-first workflow.
---

# Amber VFD theme

Add an "Amber VFD" theme to this iOS app: the screen should look like an old vacuum-fluorescent
dot-matrix display. Make it a selectable theme alongside the existing look
(Settings → Appearance), persisted in user settings.

## Look (non-negotiable)

- The whole screen is ONE pixel matrix: a grid of identical square cells. Every visible thing
  (text, numbers, boxes, dividers, bars, charts, icons, tab bar, headers, buttons) is drawn by
  lighting whole cells on that grid. Nothing smooth, nothing anti-aliased, nothing placed between
  cells.
- Cell pitch = 5 device pixels (1.667 pt on 3x screens; use 4 px = 2 pt on 2x screens). A lit
  pixel fills 4×4 device pixels and leaves a 1-pixel black gap, so the grid is visible.
- Background is pure black (#000). No glow, no shadows, no blur, no vignette, no gradients. Unlit
  cells are drawn in near-black neutral grey (#090909) so the matrix is faintly visible up close.
- Palette: amber #FFB014 for live readings and highlights; warm white #FFE8C4 for normal text;
  dim amber #966428 for labels, units, tracks and borders; red-orange #FF5028 for alarms.
  Nothing else. (Amber is the default base colour; see **Base colour** below.)
- Text is uppercase-leaning and monospaced, drawn from bitmap glyphs:
  - small = 5×7 pixels (+2 descender rows), 6-cell advance, for labels and body text
  - mid = 10×14 pixels, for titles and secondary values
  - big = 15×21 pixels, for hero readouts
  - Bigger text uses MORE pixels, never bigger pixels. The pixel size is universal.
- Inverted highlights: the selected tab, selected option and status banners are solid amber
  blocks with the text "cut out", i.e. those cells are left unlit.
- Panels are 1-cell amber or dim borders. Progress and target indicators are LED bars: a dotted
  dim track, a lit zone, and a 3×6-cell marker or a solid fill. Charts are single-cell lines on
  the grid with a dotted dim baseline.

## Base colour (user-selectable)

The user can pick a base colour to replace amber. Amber stays the default.

- Settings → Appearance shows, under the VFD theme, a **BASE COLOUR** selector drawn the VFD way:
  `[OPTION]` selectors for presets, the selected one inverted, plus a **CUSTOM** entry that opens
  the system colour picker (stop-gap UI is fine) and stores the chosen RGB.
- Presets: **AMBER** #FFB014 (default), **GREEN** #3CFF6E, **CYAN** #30E8FF (classic blue-green
  VFD), **BLUE** #4CA0FF, **RED** #FF4030, **WHITE** #F0F0F0.
- Persist the choice (preset name or custom RGB) in user settings next to the theme selection.
- The **AMBER** preset uses the exact colours from **Look** above. For every other base colour
  the palette is derived from it, so everything stays consistent:
  - **highlight** (live readings, inverted blocks, selected items, amber borders) = base
  - **dim** (labels, units, tracks, dim borders) = 59% base + 41% #000, plus a 15% pull toward
    grey to soften it (`dim = 0.59 × (0.85 × base + 0.15 × luma(base))`), where luma is the
    base's Rec. 709 luminance
  - **text** (normal text) = 75% #FFFFFF + 25% base, mixed per channel
  - **alarm** stays red-orange #FF5028. If the base is red-ish (hue within 25° of the alarm),
    draw alarms as inverted blocks (base-coloured block, text cut out) blinking at 1 Hz so they
    remain distinguishable.
  - **unlit** #090909 and background #000 never change.
- Glyphs, grid and renderer are colour-agnostic: they only ever use palette indices
  (0 unlit, 1 highlight, 2 text, 3 dim, 4 alarm), so changing the base colour is a palette swap
  with no layout change. The preview renderer takes the base colour as a parameter too.

## Glyphs

Write an original 5×7 bitmap font as a table of 7 rows × 5 columns ("#" = lit) for ASCII 32–126
plus ° µ Δ ± · × ÷ – — → ← … ✓ ² ³ Ω ≤ ≥ ≈ and the curly quotes. Give g j p q y µ 2 descender
rows. Generate the mid and big sets from the 5×7 set with the Scale2x (EPX) and Scale3x pixel-art
algorithms, not plain pixel doubling, so diagonals get smoothed with more pixels. Write a script
(Python is fine) that emits:

1. A Swift file with the bitmaps: `[UInt32 scalar: [UInt32 rows]]`, bit 0 = leftmost pixel.
2. Optionally, TTF versions (fontTools: square pixel contours, 100 units per pixel, monospaced)
   for any place that must stay a native Text.

## Renderer

Do NOT post-process or point-sample the normal UI; that gives blurry text.

- Build a frame buffer: cols = floor(screenWidth / pitch), rows = floor(screenHeight / pitch),
  one byte per cell = palette index (0 = unlit).
- Drawing API in whole cells: set, fill, hline/vline (with a step for dotted lines), box,
  text(col, row, string, size, color) returning the end column, textRight, truncated text with …,
  word-wrapped paragraph, LED bar, line chart.
- Paint the buffer in ONE full-screen SwiftUI Canvas anchored at screen (0,0), ignoring safe
  areas, so the grid lines up with the device pixels:
  - Draw the unlit grid as a tiled 1-cell image.
  - Draw one Path of rects per palette colour for the lit cells.
- Screens are immediate-mode functions that draw into the buffer from app state, and register tap
  rectangles in cell coordinates with closures.
- Interaction:
  - One gesture on the canvas maps the touch point to a cell and runs the topmost hit.
  - Vertical drag scrolls the content region in whole cells; the header and tab bar stay fixed.
  - Redraw on state changes and on a ~1 s timeline for live data.
- Replace system chrome in this theme: your own pixel tab bar (inverted selected item), pixel
  header with title and a "< BACK" button, pixel ON/OFF toggles, [OPTION] selectors,
  [-] value [+] steppers. Number entry can use a system alert with a TextField. Screens not yet
  converted can open in a sheet with the normal UI as a stop-gap.
- Leave the safe-area rows (status bar, home indicator) empty.

## Workflow

Before touching the app, write a local preview renderer (e.g. Python + PIL) that uses the same
glyph data, grid and palette, and render the main screens at iPhone resolution (1206×2622 for
iPhone 17 Pro). Iterate the layout on those previews and show them to the user for approval
before building the app, so we don't burn CI builds on visual tweaks. Render the previews in
amber, plus one other base colour, to show the palette swap works. Lay screens out with
proportional column positions so they work at both 241-cell (3x) and ~207-cell (2x) widths. Put
units in the label row ("SUCTION PSI") rather than after values, so columns never collide.
