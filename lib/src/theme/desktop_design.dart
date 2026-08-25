import 'package:flutter/material.dart';

/// Shared visual tokens for the Windows desktop client.
abstract final class TvColors {
  static const appBackground = Color(0xfff7f9fc);
  static const panel = Color(0xffffffff);
  static const subtle = Color(0xfff1f5fa);
  static const selected = Color(0xffeaf3ff);
  static const blue = Color(0xff0a84ff);
  static const blueHover = Color(0xff0077eb);
  static const bluePressed = Color(0xff0068d6);
  static const navy = Color(0xff0b2345);
  static const textPrimary = Color(0xff10233f);
  static const textSecondary = Color(0xff6f7f97);
  static const iconMuted = Color(0xff7888a2);
  static const border = Color(0xffe4eaf2);
  static const green = Color(0xff22c55e);
  static const red = Color(0xffff3b30);
  static const orange = Color(0xfff59e0b);
  static const videoOverlay = Color(0x6b0d1c32);
  static const lightOverlay = Color(0xe0ffffff);
}

abstract final class TvSizes {
  static const sidebar = 72.0;
  static const sidebarAction = 48.0;
  static const sidebarIcon = 22.0;
  static const contentPadding = 22.0;
  static const columnGap = 16.0;
  static const listRow = 74.0;
  static const avatar = 48.0;
  static const smallAvatar = 38.0;
  static const profileAvatar = 88.0;
  static const searchHeight = 44.0;
  static const action = 48.0;
  static const radius = 12.0;
  static const panelRadius = 16.0;
  static const floatingRadius = 20.0;
}

abstract final class TvShadows {
  static const soft = BoxShadow(
    color: Color(0x1a19345a),
    blurRadius: 20,
    offset: Offset(0, 6),
  );
  static const floating = BoxShadow(
    color: Color(0x290f2341),
    blurRadius: 32,
    offset: Offset(0, 10),
  );
}

ThemeData tvoiceDesktopTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = dark
      ? ColorScheme.fromSeed(
          seedColor: TvColors.blue,
          brightness: brightness,
          surface: const Color(0xff111827),
        )
      : const ColorScheme.light(
          primary: TvColors.blue,
          onPrimary: Colors.white,
          primaryContainer: TvColors.selected,
          onPrimaryContainer: TvColors.navy,
          secondary: TvColors.navy,
          onSecondary: Colors.white,
          error: TvColors.red,
          onError: Colors.white,
          surface: TvColors.panel,
          onSurface: TvColors.textPrimary,
          onSurfaceVariant: TvColors.textSecondary,
          outline: TvColors.iconMuted,
          outlineVariant: TvColors.border,
          surfaceContainerLowest: TvColors.panel,
          surfaceContainerLow: TvColors.appBackground,
          surfaceContainer: TvColors.subtle,
          surfaceContainerHigh: TvColors.panel,
        );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: 'Inter',
    colorScheme: scheme,
    scaffoldBackgroundColor: dark
        ? const Color(0xff0f172a)
        : TvColors.appBackground,
    dividerColor: dark ? Colors.white12 : TvColors.border,
    visualDensity: VisualDensity.standard,
    splashFactory: InkSparkle.splashFactory,
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      showDuration: const Duration(seconds: 3),
      decoration: BoxDecoration(
        color: TvColors.navy,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12),
    ),
    textTheme: ThemeData(brightness: brightness).textTheme.apply(
      fontFamily: 'Inter',
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xff172033) : TvColors.panel,
      hintStyle: const TextStyle(color: TvColors.textSecondary, fontSize: 14),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(TvSizes.radius),
        borderSide: const BorderSide(color: TvColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(TvSizes.radius),
        borderSide: const BorderSide(color: TvColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(TvSizes.radius),
        borderSide: const BorderSide(color: TvColors.blue, width: 2),
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(TvSizes.panelRadius),
        side: BorderSide(color: dark ? Colors.white12 : TvColors.border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(TvSizes.radius),
          ),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(0, 46)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        iconSize: const WidgetStatePropertyAll(22),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return TvColors.iconMuted.withValues(alpha: .45);
          }
          if (states.contains(WidgetState.hovered)) return TvColors.blueHover;
          return TvColors.iconMuted;
        }),
      ),
    ),
  );
}
