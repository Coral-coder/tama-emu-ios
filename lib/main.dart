import 'package:material_ui/material_ui.dart';

import 'services/app_state.dart';
import 'ui/about_screen.dart';
import 'ui/device_screen.dart';
import 'ui/library_screen.dart';
import 'ui/link_screen.dart';
import 'ui/play_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // In release builds a failing widget is a grey box; show what went wrong instead.
  ErrorWidget.builder = (d) => Material(
        color: const Color(0xFF2A0D0D),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText('Something went wrong here:\n\n${d.exceptionAsString()}', style: const TextStyle(color: Colors.white, fontSize: 13)),
        ),
      );
  runApp(const TamaApp());
  try {
    await AppState.instance.init();
  } catch (e, s) {
    debugPrint('init: $e\n$s');
  }
}

class TamaApp extends StatelessWidget {
  const TamaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tama',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      darkTheme: buildTheme(),
      themeMode: ThemeMode.dark,
      home: const Shell(),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  final _built = <int>{0};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final app = AppState.instance;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        app.onBackground();
      case AppLifecycleState.resumed:
        app.onForeground();
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return ValueListenableBuilder<int>(
      valueListenable: app.page,
      builder: (context, page, _) {
        _built.add(page);
        Widget lazy(int i, Widget w) => _built.contains(i) ? w : const SizedBox.shrink();
        return Scaffold(
          body: IndexedStack(index: page, children: [
            const PlayScreen(),
            lazy(1, const DeviceScreen()),
            lazy(2, const LibraryScreen()),
            lazy(3, const LinkScreen()),
            lazy(4, const AboutScreen()),
          ]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: page,
            onDestinationSelected: (i) => app.page.value = i,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: const [
              NavigationDestination(icon: Icon(Icons.egg_outlined), selectedIcon: Icon(Icons.egg), label: 'Play'),
              NavigationDestination(icon: Icon(Icons.usb), label: 'Paramix'),
              NavigationDestination(icon: Icon(Icons.auto_fix_high_outlined), label: 'ROMs'),
              NavigationDestination(icon: Icon(Icons.hub_outlined), label: 'Link'),
              NavigationDestination(icon: Icon(Icons.tune), label: 'More'),
            ],
          ),
        );
      },
    );
  }
}
