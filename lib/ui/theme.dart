import 'package:material_ui/material_ui.dart';

import 'shell_theme.dart';

const Color kAmber = Color(0xFFFFB000);
const Color kInk = Color(0xFF0E0F0A);
const Color kPanel = Color(0xFF16171A);
const Color kLcdBg = Color(0xFFB9C3A3);
const Color kLcdOn = Color(0xFF1C2316);
const Color kLcdOff = Color(0x14000000);

/// The app's look, from the shell theme: its buttons colour leads, its shell tints the panels.
ThemeData buildTheme([ShellTheme? t]) {
  final accent = t?.buttons ?? kAmber;
  final tint = t?.shell ?? const Color(0xFF101114);
  final surface = Color.lerp(const Color(0xFF101114), tint, 0.12)!;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark).copyWith(
    primary: accent,
    onPrimary: accent.computeLuminance() > 0.45 ? Colors.black : Colors.white,
    surface: surface,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Color.lerp(const Color(0xFF0A0B0D), tint, 0.08),
    appBarTheme: AppBarTheme(backgroundColor: Color.lerp(const Color(0xFF0A0B0D), tint, 0.08), centerTitle: false),
    cardTheme: CardThemeData(color: Color.lerp(kPanel, tint, 0.10), margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Color.lerp(const Color(0xFF0D0E10), tint, 0.10),
      indicatorColor: accent.withValues(alpha: 0.28),
    ),
  );
}
