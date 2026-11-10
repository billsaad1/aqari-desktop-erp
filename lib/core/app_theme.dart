import 'package:flutter/material.dart';

/// Palette used by the desktop ERP shell and shared Material components.
abstract final class AppPalette {
  static const navy = Color(0xFF16324F);
  static const deepNavy = Color(0xFF10263D);
  static const emerald = Color(0xFF16856B);
  static const emeraldDark = Color(0xFF116B57);
  static const canvas = Color(0xFFF3F6F8);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceTint = Color(0xFFF7FAFC);
  static const outline = Color(0xFFD8E0E7);
  static const mutedText = Color(0xFF64748B);
  static const danger = Color(0xFFB54745);
}

abstract final class AppTheme {
  static const _radius = 14.0;

  static ThemeData light() {
    final colors =
        ColorScheme.fromSeed(
          seedColor: AppPalette.navy,
          brightness: Brightness.light,
        ).copyWith(
          primary: AppPalette.navy,
          onPrimary: Colors.white,
          secondary: AppPalette.emerald,
          onSecondary: Colors.white,
          tertiary: AppPalette.emeraldDark,
          surface: AppPalette.surface,
          onSurface: AppPalette.deepNavy,
          error: AppPalette.danger,
          outline: AppPalette.outline,
          surfaceContainerLowest: AppPalette.surface,
          surfaceContainerLow: AppPalette.surfaceTint,
        );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      fontFamily: 'Cairo',
      scaffoldBackgroundColor: AppPalette.canvas,
      hoverColor: AppPalette.emerald.withValues(alpha: 0.08),
      focusColor: AppPalette.emerald.withValues(alpha: 0.14),
      splashColor: AppPalette.emerald.withValues(alpha: 0.09),
      visualDensity: VisualDensity.standard,
    );
    final text = base.textTheme.apply(
      fontFamily: 'Cairo',
      bodyColor: AppPalette.deepNavy,
      displayColor: AppPalette.deepNavy,
    );
    final roundedButton = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );
    final pointer = WidgetStateProperty.resolveWith<MouseCursor?>((states) {
      if (states.contains(WidgetState.disabled))
        return SystemMouseCursors.basic;
      return SystemMouseCursors.click;
    });

    return base.copyWith(
      textTheme: text.copyWith(
        headlineLarge: text.headlineLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        headlineMedium: text.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        headlineSmall: text.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: AppPalette.surface,
        foregroundColor: AppPalette.navy,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge?.copyWith(
          color: AppPalette.navy,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppPalette.surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: AppPalette.navy.withValues(alpha: 0.07),
        elevation: 1.5,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radius),
          side: BorderSide(color: AppPalette.outline.withValues(alpha: 0.75)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppPalette.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titleTextStyle: text.titleLarge?.copyWith(
          color: AppPalette.navy,
          fontWeight: FontWeight.w700,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppPalette.surface,
        contentPadding: const EdgeInsetsDirectional.fromSTEB(16, 15, 16, 15),
        labelStyle: text.bodyMedium?.copyWith(color: AppPalette.mutedText),
        hintStyle: text.bodyMedium?.copyWith(color: AppPalette.mutedText),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppPalette.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppPalette.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppPalette.emerald, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppPalette.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppPalette.danger, width: 1.6),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          mouseCursor: pointer,
          minimumSize: const WidgetStatePropertyAll(Size(40, 44)),
          padding: const WidgetStatePropertyAll(
            EdgeInsetsDirectional.symmetric(horizontal: 18, vertical: 12),
          ),
          shape: WidgetStatePropertyAll(roundedButton),
          textStyle: WidgetStatePropertyAll(
            text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          mouseCursor: pointer,
          minimumSize: const WidgetStatePropertyAll(Size(40, 44)),
          padding: const WidgetStatePropertyAll(
            EdgeInsetsDirectional.symmetric(horizontal: 18, vertical: 12),
          ),
          shape: WidgetStatePropertyAll(roundedButton),
          elevation: const WidgetStatePropertyAll(1),
          textStyle: WidgetStatePropertyAll(
            text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          mouseCursor: pointer,
          minimumSize: const WidgetStatePropertyAll(Size(40, 44)),
          padding: const WidgetStatePropertyAll(
            EdgeInsetsDirectional.symmetric(horizontal: 18, vertical: 12),
          ),
          shape: WidgetStatePropertyAll(roundedButton),
          side: const WidgetStatePropertyAll(
            BorderSide(color: AppPalette.outline),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          mouseCursor: pointer,
          shape: WidgetStatePropertyAll(roundedButton),
          padding: const WidgetStatePropertyAll(
            EdgeInsetsDirectional.symmetric(horizontal: 14, vertical: 10),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          mouseCursor: pointer,
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          foregroundColor: const WidgetStatePropertyAll(AppPalette.navy),
          overlayColor: WidgetStatePropertyAll(
            AppPalette.emerald.withValues(alpha: 0.10),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        mouseCursor: pointer,
        minTileHeight: 48,
        contentPadding: const EdgeInsetsDirectional.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        selectedTileColor: AppPalette.emerald.withValues(alpha: 0.12),
        selectedColor: AppPalette.emeraldDark,
        iconColor: AppPalette.mutedText,
        titleTextStyle: text.bodyMedium?.copyWith(color: AppPalette.deepNavy),
      ),
      dataTableTheme: DataTableThemeData(
        decoration: BoxDecoration(
          color: AppPalette.surface,
          borderRadius: BorderRadius.circular(_radius),
          border: Border.all(color: AppPalette.outline.withValues(alpha: 0.75)),
        ),
        headingRowColor: const WidgetStatePropertyAll(AppPalette.surfaceTint),
        dataRowColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered)) {
            return AppPalette.emerald.withValues(alpha: 0.055);
          }
          if (states.contains(WidgetState.selected)) {
            return AppPalette.emerald.withValues(alpha: 0.10);
          }
          return null;
        }),
        headingRowHeight: 54,
        dataRowMinHeight: 50,
        dataRowMaxHeight: 66,
        horizontalMargin: 20,
        columnSpacing: 26,
        dividerThickness: 0.6,
        headingTextStyle: text.labelLarge?.copyWith(
          color: AppPalette.navy,
          fontWeight: FontWeight.w700,
        ),
        dataTextStyle: text.bodyMedium?.copyWith(color: AppPalette.deepNavy),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: AppPalette.navy,
        unselectedLabelColor: AppPalette.mutedText,
        indicatorColor: AppPalette.emerald,
        dividerColor: AppPalette.outline.withValues(alpha: 0.65),
        labelStyle: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        unselectedLabelStyle: text.titleSmall,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppPalette.deepNavy,
        contentTextStyle: text.bodyMedium?.copyWith(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: AppPalette.deepNavy,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: text.bodySmall?.copyWith(color: Colors.white),
        waitDuration: const Duration(milliseconds: 450),
      ),
      dividerTheme: DividerThemeData(
        color: AppPalette.outline.withValues(alpha: 0.75),
        thickness: 0.8,
        space: 1,
      ),
      scrollbarTheme: ScrollbarThemeData(
        radius: const Radius.circular(20),
        thickness: const WidgetStatePropertyAll(8),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          final alpha = states.contains(WidgetState.hovered) ? 0.60 : 0.30;
          return AppPalette.navy.withValues(alpha: alpha);
        }),
      ),
    );
  }
}
