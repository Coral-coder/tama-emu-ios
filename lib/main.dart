import 'package:material_ui/material_ui.dart';

import 'services/app_state.dart';
import 'services/updater.dart';
import 'ui/play_screen.dart';
import 'ui/theme.dart';
import 'ui/tools_screen.dart';

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
    final app = AppState.instance;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => MaterialApp(
        title: 'Tama',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(app.currentTheme),
        darkTheme: buildTheme(app.currentTheme),
        themeMode: ThemeMode.dark,
        home: const Shell(),
      ),
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
  DateTime _lastCheck = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Android: a newer release on GitHub is offered once the app is up
    if (Updater.instance.supported) {
      Future<void>.delayed(const Duration(seconds: 4), () {
        if (mounted) Updater.instance.offer(context);
      });
    }
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
        // back after a while: look for an update again (at most every 6 hours)
        if (Updater.instance.supported && DateTime.now().difference(_lastCheck).inHours >= 6) {
          _lastCheck = DateTime.now();
          Updater.instance.offer(context);
        }
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
          body: IndexedStack(index: page.clamp(0, 1), children: [
            const PlayScreen(),
            lazy(1, const ToolsScreen()),
          ]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: page.clamp(0, 1),
            onDestinationSelected: (i) => app.page.value = i,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: const [
              NavigationDestination(icon: Icon(Icons.egg_outlined), selectedIcon: Icon(Icons.egg), label: 'Play'),
              NavigationDestination(icon: Icon(Icons.grid_view_outlined), selectedIcon: Icon(Icons.grid_view_rounded), label: 'Tools'),
            ],
          ),
        );
      },
    );
  }
}
