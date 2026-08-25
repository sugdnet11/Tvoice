import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import 'controllers/app_controller.dart';
import 'screens/android_home_shell.dart';
import 'screens/android_login_screen.dart';
import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'screens/windows_home_shell.dart';
import 'services/desktop_window_controller.dart';
import 'theme/desktop_design.dart';
import 'widgets/tvoice_logo.dart';

class TvoiceApp extends StatefulWidget {
  const TvoiceApp({super.key, required this.controller});
  final AppController controller;

  @override
  State<TvoiceApp> createState() => _TvoiceAppState();
}

class _TvoiceAppState extends State<TvoiceApp> {
  bool _splashMinimumElapsed = false;
  DesktopWindowMode? _scheduledWindowMode;

  bool get _usesAndroidDesign =>
      defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_controllerChanged);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => DesktopWindowController.show(DesktopWindowMode.splash),
    );
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => _splashMinimumElapsed = true);
      _scheduleWindowMode();
    });
  }

  @override
  void didUpdateWidget(covariant TvoiceApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_controllerChanged);
    widget.controller.addListener(_controllerChanged);
    _scheduleWindowMode();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    super.dispose();
  }

  void _controllerChanged() => _scheduleWindowMode();

  DesktopWindowMode get _windowMode {
    if (!_splashMinimumElapsed || !widget.controller.initialized) {
      return DesktopWindowMode.splash;
    }
    return widget.controller.signedIn
        ? DesktopWindowMode.main
        : DesktopWindowMode.login;
  }

  void _scheduleWindowMode() {
    final mode = _windowMode;
    if (_scheduledWindowMode == mode) return;
    _scheduledWindowMode = mode;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) DesktopWindowController.show(mode);
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Tvoice',
      themeMode: widget.controller.themeMode,
      theme: defaultTargetPlatform == TargetPlatform.windows
          ? tvoiceDesktopTheme(Brightness.light)
          : _theme(Brightness.light),
      darkTheme: defaultTargetPlatform == TargetPlatform.windows
          ? tvoiceDesktopTheme(Brightness.dark)
          : _theme(Brightness.dark),
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 190),
        reverseDuration: const Duration(milliseconds: 170),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: _buildHome(),
      ),
    ),
  );

  Widget _buildHome() {
    _scheduleWindowMode();
    if (!_splashMinimumElapsed || !widget.controller.initialized) {
      return _usesAndroidDesign
          ? const AndroidSplashScreen(key: ValueKey('android-splash'))
          : const DesktopSplashScreen(key: ValueKey('desktop-splash'));
    }
    if (widget.controller.signedIn) {
      if (defaultTargetPlatform == TargetPlatform.windows) {
        return WindowsHomeShell(
          key: const ValueKey('windows-home'),
          controller: widget.controller,
        );
      }
      return _usesAndroidDesign
          ? AndroidHomeShell(
              key: const ValueKey('android-home'),
              controller: widget.controller,
            )
          : HomeShell(
              key: const ValueKey('home'),
              controller: widget.controller,
            );
    }
    return _usesAndroidDesign
        ? AndroidLoginScreen(
            key: const ValueKey('android-login'),
            controller: widget.controller,
          )
        : LoginScreen(
            key: const ValueKey('desktop-login'),
            controller: widget.controller,
          );
  }

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff087dff),
      brightness: brightness,
      surface: dark ? const Color(0xff11151c) : const Color(0xfff6f7f9),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 24,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.7,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: dark ? const Color(0xff1a2029) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xff1a2029) : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: .45),
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 16,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 70,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class DesktopSplashScreen extends StatelessWidget {
  const DesktopSplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final windows = defaultTargetPlatform == TargetPlatform.windows;
    final content = Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            TvoiceLogo(
              size: 72,
              showWordmark: false,
              showShadow: !windows,
            ),
            const SizedBox(height: 12),
            const Text(
              'Tvoice',
              style: TextStyle(
                color: TvColors.navy,
                fontSize: 32,
                height: 1,
                fontWeight: FontWeight.w800,
                letterSpacing: -1.2,
              ),
            ),
            const SizedBox(height: 22),
            const Text(
              'Добро пожаловать в Tvoice',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: TvColors.navy,
                fontSize: 21,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: const Text(
                'Звонки, сообщения и видеоконференции в одном рабочем пространстве',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: TvColors.textSecondary,
                  fontSize: 15,
                  height: 1.35,
                ),
              ),
            ),
          ],
    );
    return Scaffold(
      backgroundColor: windows
          ? Colors.white
          : Theme.of(context).colorScheme.surfaceContainerLow,
      body: Center(
        child: windows
            ? content
            : Container(
                margin: const EdgeInsets.all(18),
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  boxShadow: const [TvShadows.soft],
                ),
                child: content,
              ),
      ),
    );
  }
}
