import 'dart:async';

import 'package:flutter/material.dart';

import 'services/engine.dart';
import 'services/notification_service.dart';
import 'ui/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Eagerly load the Rust engine + log its version so any FFI / jniLibs
  // misconfiguration shows up under the `flutter:` logcat tag before
  // the first schema parse rather than at the first form open.
  try {
    final engine = getEngine();
    // ignore: avoid_print
    print('[airledger.engine] loaded: ${engine.version}');
  } catch (e, st) {
    // ignore: avoid_print
    print('[airledger.engine] load failed: $e\n$st');
  }
  // Local notifications (post-log nudges + rest-timer-done). Best-effort —
  // init swallows failures so the app never blocks on it.
  unawaited(NotificationService.init());
  runApp(const LedgerApp());
}

/// Palette inspired by Linear / Vercel / shadcn-dark. Primary is near-white
/// (drives buttons and the FAB so they stay high-contrast on black);
/// the brand blue is the secondary accent, reserved for focus rings,
/// links, and selection states.
class _C {
  // Layered surfaces — only a few shades to keep the UI calm.
  static const bg = Color(0xFF0A0A0A);
  static const surface1 = Color(0xFF131313);
  static const surface2 = Color(0xFF161616);
  static const surface3 = Color(0xFF1B1B1B);
  static const surface4 = Color(0xFF1F1F1F);

  // Text.
  static const fg = Color(0xFFF5F5F5);
  static const fgMuted = Color(0xFFA1A1AA);

  // Hairline borders — very subtle.
  static const border = Color(0x14FFFFFF); // rgba(255,255,255, 0.08)
  static const borderStrong = Color(0x24FFFFFF); // rgba(255,255,255, 0.14)

  // Accents.
  static const primary = Color(0xFFFAFAFA); // buttons, FAB
  static const onPrimary = Color(0xFF0A0A0A);
  static const accent = Color(0xFF7C8DFF); // brand blue, lighter
  static const onAccent = Color(0xFF0A0A0A);
  static const error = Color(0xFFFB7185);
  static const onError = Color(0xFF0A0A0A);
}

class LedgerApp extends StatelessWidget {
  const LedgerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ledger',
      themeMode: ThemeMode.dark,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: const HomeScreen(),
    );
  }

  ThemeData _theme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = isDark
        ? const ColorScheme.dark(
            brightness: Brightness.dark,
            primary: _C.primary,
            onPrimary: _C.onPrimary,
            secondary: _C.accent,
            onSecondary: _C.onAccent,
            tertiary: _C.accent,
            onTertiary: _C.onAccent,
            surface: _C.bg,
            onSurface: _C.fg,
            surfaceTint: Colors.transparent,
            surfaceContainerLowest: _C.bg,
            surfaceContainerLow: _C.surface1,
            surfaceContainer: _C.surface2,
            surfaceContainerHigh: _C.surface3,
            surfaceContainerHighest: _C.surface4,
            onSurfaceVariant: _C.fgMuted,
            outline: _C.border,
            outlineVariant: _C.borderStrong,
            error: _C.error,
            onError: _C.onError,
            // Selected chip / inverse surface use the accent so it shows.
            primaryContainer: Color(0xFF1F2440),
            onPrimaryContainer: _C.accent,
          )
        : ColorScheme.fromSeed(seedColor: _C.accent);

    // Pick the brightness-appropriate base (white text for dark mode) AND
    // recolor it to our scheme. Crucial: any later `copyWith` must reference
    // this `tt`, not the un-applied original, or per-style colors revert
    // to black.
    final typography = Typography.material2021(platform: TargetPlatform.android);
    final tt = (isDark ? typography.white : typography.black).apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: NoSplash.splashFactory,
      // Flatten AppBar — merges visually with the body, like Linear.
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 16,
        toolbarHeight: 56,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          height: 1.2,
        ),
        iconTheme: IconThemeData(
          color: scheme.onSurfaceVariant,
          size: 22,
        ),
        actionsIconTheme: IconThemeData(
          color: scheme.onSurfaceVariant,
          size: 22,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainer,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: scheme.outline, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outline,
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          minimumSize: const Size(0, 40),
          textStyle: const TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.1,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: scheme.outlineVariant),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          minimumSize: const Size(0, 40),
          textStyle: const TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w500,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.onSurface,
          textStyle: const TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w500,
          ),
          minimumSize: const Size(0, 36),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: scheme.onSurfaceVariant,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.secondary, width: 1.5),
        ),
        hintStyle: TextStyle(
          color: scheme.onSurface.withValues(alpha: 0.32),
          fontStyle: FontStyle.italic,
          fontSize: 15,
        ),
        labelStyle: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 15,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        contentTextStyle: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 15,
          height: 1.45,
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 15,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.1,
        ),
        subtitleTextStyle: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 13,
          height: 1.35,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        minVerticalPadding: 12,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        contentTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 14.5,
        ),
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: scheme.outline),
        ),
      ),
      // Subdued ripples — splashFactory: NoSplash above kills them entirely
      // but we keep the hover overlay tone for IconButton focus.
      hoverColor: scheme.surfaceContainerHigh,
      highlightColor: Colors.transparent,
      typography: typography,
      textTheme: tt.copyWith(
        titleLarge: tt.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
        ),
        titleMedium: tt.titleMedium?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.15,
        ),
        titleSmall: tt.titleSmall?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.1,
        ),
        bodyLarge: tt.bodyLarge?.copyWith(
          fontSize: 16,
          letterSpacing: -0.1,
        ),
        bodyMedium: tt.bodyMedium?.copyWith(
          fontSize: 15,
          letterSpacing: -0.05,
        ),
        bodySmall: tt.bodySmall?.copyWith(
          fontSize: 13,
          color: scheme.onSurfaceVariant,
        ),
        labelMedium: tt.labelMedium?.copyWith(
          fontSize: 13,
          letterSpacing: 0.1,
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w500,
        ),
        labelSmall: tt.labelSmall?.copyWith(
          fontSize: 12,
          letterSpacing: 0.2,
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
