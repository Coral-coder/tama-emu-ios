import 'package:material_ui/material_ui.dart';

const Color kAmber = Color(0xFFFFB000);
const Color kInk = Color(0xFF0E0F0A);
const Color kPanel = Color(0xFF16171A);
const Color kLcdBg = Color(0xFFB9C3A3);
const Color kLcdOn = Color(0xFF1C2316);
const Color kLcdOff = Color(0x14000000);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: kAmber, brightness: Brightness.dark).copyWith(
    primary: kAmber,
    onPrimary: Colors.black,
    surface: const Color(0xFF101114),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFF0A0B0D),
    appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF0A0B0D), centerTitle: false),
    cardTheme: const CardThemeData(color: kPanel, margin: EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xFF0D0E10),
      indicatorColor: kAmber.withValues(alpha: 0.22),
    ),
  );
}
