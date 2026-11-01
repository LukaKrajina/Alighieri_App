import 'package:flutter/material.dart';

import '../src/rust/domain/theme.dart';

/// `#rrggbb` / `#rrggbbaa` -> Color。
///
/// Rust 侧的配色引擎给出的是 8 位或 6 位 hex（带 alpha 的用于玻璃边与高光），
/// 这里两种都要认，否则玻璃令牌会解析成一块结结实实的砖。
Color hexColor(String s) {
  final v = s.trim().replaceFirst('#', '');
  if (v.length == 6) {
    return Color(int.parse('FF$v', radix: 16));
  }
  if (v.length == 8) {
    // Rust 写 #rrggbbaa，Flutter 要 0xAABBGGRR —— 两边都没错，只是方向不同。
    final rgb = v.substring(0, 6);
    final aa = v.substring(6, 8);
    return Color(int.parse('$aa$rgb', radix: 16));
  }
  return const Color(0xFF000000);
}

/// 由 Rust 算出的整套设计令牌 -> ThemeData。
///
/// 颜色只从 `Palette` 来：界面里不再出现任何写死的色值，
/// 这样用户换主色时，强调色和边框会一起换装，不会有人掉队。
ThemeData buildTheme(
  Palette p, {
  required bool dark,
  required double fontScale,
  double glass = 0,
}) {
  final base = dark ? ThemeData.dark(useMaterial3: true) : ThemeData.light(useMaterial3: true);
  final bg = hexColor(p.background);
  final fg = hexColor(p.foreground);
  final surface = hexColor(p.surface);
  final primary = hexColor(p.primary);
  // 通透度：最左是纯色；往右让卡片逐渐透出背景。
  // 不引入 BackdropFilter —— 模糊很好看，但手机不一定同意；纯色端才是对比度底线。
  final glassAlpha = (1 - glass.clamp(0.0, 1.0) * 0.22).toDouble();
  final cardSurface = surface.withValues(alpha: glassAlpha);

  final scheme = ColorScheme(
    brightness: dark ? Brightness.dark : Brightness.light,
    primary: primary,
    onPrimary: _bestOn(primary),
    primaryContainer: hexColor(p.primarySoft),
    onPrimaryContainer: hexColor(p.primaryStrong),
    secondary: hexColor(p.accent),
    onSecondary: _bestOn(hexColor(p.accent)),
    secondaryContainer: hexColor(p.accentSoft),
    onSecondaryContainer: hexColor(p.foreground),
    surface: bg,
    onSurface: fg,
    surfaceContainerHighest: surface,
    onSurfaceVariant: hexColor(p.muted),
    error: hexColor(p.danger),
    onError: _bestOn(hexColor(p.danger)),
    outline: hexColor(p.border),
    outlineVariant: hexColor(p.borderStrong),
  );

  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    canvasColor: bg,
    cardColor: cardSurface,
    dividerColor: hexColor(p.border),
    textTheme: base.textTheme.apply(
      bodyColor: fg,
      displayColor: fg,
      fontSizeFactor: fontScale,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: hexColor(p.headerBg),
      foregroundColor: fg,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      indicatorColor: hexColor(p.primarySoft2),
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 12 * fontScale, color: fg),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: surface,
      selectedIconTheme: IconThemeData(color: primary),
      selectedLabelTextStyle: TextStyle(color: primary, fontSize: 12 * fontScale),
      unselectedLabelTextStyle: TextStyle(color: hexColor(p.muted), fontSize: 12 * fontScale),
      indicatorColor: hexColor(p.primarySoft),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: _bestOn(primary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: fg,
        side: BorderSide(color: hexColor(p.borderStrong)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: hexColor(p.border)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: hexColor(p.border)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: primary, width: 2),
      ),
    ),
    cardTheme: CardThemeData(
      color: cardSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: hexColor(p.border)),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: hexColor(p.surface2),
      selectedColor: hexColor(p.primarySoft),
      labelStyle: TextStyle(color: fg, fontSize: 13 * fontScale),
      side: BorderSide(color: hexColor(p.border)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: hexColor(p.primaryStrong),
      contentTextStyle: TextStyle(color: _bestOn(hexColor(p.primaryStrong))),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

/// 在给定底色上挑一个读得清的前景色（WCAG 相对亮度）
Color _bestOn(Color c) {
  final l = c.computeLuminance();
  return l > 0.45 ? Colors.black : Colors.white;
}
