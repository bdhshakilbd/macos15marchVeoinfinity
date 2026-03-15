import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;

/// App-wide Theme Provider with Dark/Light mode support
/// Inspired by Antigravity's sleek dark theme aesthetic
class ThemeProvider extends ChangeNotifier {
  static final ThemeProvider _instance = ThemeProvider._internal();
  factory ThemeProvider() => _instance;
  ThemeProvider._internal();

  bool _isDarkMode = false;
  bool get isDarkMode => _isDarkMode;

  /// Toggle between light and dark mode
  void toggleTheme() {
    _isDarkMode = !_isDarkMode;
    notifyListeners();
    _saveThemePreference();
  }

  /// Set dark mode explicitly
  void setDarkMode(bool value) {
    if (_isDarkMode != value) {
      _isDarkMode = value;
      notifyListeners();
    }
  }

  // ─── DARK THEME COLORS (Monochrome twilight — clean & restful) ───

  /// Background colors — warm charcoal, NOT pure black
  Color get scaffoldBg => _isDarkMode ? const Color(0xFF1C1E26) : Colors.grey.shade100;
  Color get surfaceBg => _isDarkMode ? const Color(0xFF232530) : Colors.white;
  Color get cardBg => _isDarkMode ? const Color(0xFF282A36) : Colors.white;
  Color get headerBg => _isDarkMode ? const Color(0xFF20222C) : Colors.white;
  Color get sidebarBg => _isDarkMode ? const Color(0xFF20222C) : Colors.white;
  Color get dialogBg => _isDarkMode ? const Color(0xFF282A36) : Colors.white;
  Color get inputBg => _isDarkMode ? const Color(0xFF2E3140) : Colors.grey.shade50;
  Color get hoverBg => _isDarkMode ? const Color(0xFF2E3140) : Colors.grey.shade50;

  /// Text colors — soft cream/silver, NOT bright white
  Color get textPrimary => _isDarkMode ? const Color(0xFFCACDD5) : Colors.black87;
  Color get textSecondary => _isDarkMode ? const Color(0xFF8B91A5) : Colors.grey.shade600;
  Color get textTertiary => _isDarkMode ? const Color(0xFF5F657A) : Colors.grey.shade400;
  Color get textOnSurface => _isDarkMode ? const Color(0xFFB5B9C6) : Colors.black87;

  /// Border colors — subtle, blended with background
  Color get borderColor => _isDarkMode ? const Color(0xFF33364A) : Colors.grey.shade200;
  Color get borderLight => _isDarkMode ? const Color(0xFF3D4155) : Colors.grey.shade300;
  Color get dividerColor => _isDarkMode ? const Color(0xFF2D3044) : Colors.grey.shade200;

  /// Accent & brand colors — MONOCHROME in dark mode
  Color get accentBlue => _isDarkMode ? const Color(0xFF9BA3B5) : const Color(0xFF2563EB);
  Color get accentGreen => _isDarkMode ? const Color(0xFF9BA3B5) : const Color(0xFF10B981);
  Color get accentPurple => _isDarkMode ? const Color(0xFF9BA3B5) : const Color(0xFF8B5CF6);
  Color get accentOrange => _isDarkMode ? const Color(0xFF9BA3B5) : const Color(0xFFF59E0B);
  Color get accentTeal => _isDarkMode ? const Color(0xFF9BA3B5) : const Color(0xFF0D9488);
  Color get accentPink => _isDarkMode ? const Color(0xFF9BA3B5) : Colors.pink;
  Color get accentRed => _isDarkMode ? const Color(0xFF9BA3B5) : Colors.red;

  /// Shadow & elevation — very subtle, minimal
  Color get shadowColor => _isDarkMode ? Colors.black.withOpacity(0.15) : Colors.black.withOpacity(0.03);
  Color get elevatedShadow => _isDarkMode ? Colors.black.withOpacity(0.25) : Colors.black.withOpacity(0.1);

  /// Icon colors — monochrome
  Color get iconDefault => _isDarkMode ? const Color(0xFF7A8194) : Colors.grey.shade600;
  Color get iconActive => _isDarkMode ? const Color(0xFFB5B9C6) : Colors.blue;

  /// Nav tab colors — monochrome
  Color get navInactiveBorder => _isDarkMode ? const Color(0xFF3D4155) : Colors.grey.shade300;
  Color get navInactiveIcon => _isDarkMode ? const Color(0xFF8B91A5) : Colors.grey.shade600;
  Color get navInactiveText => _isDarkMode ? const Color(0xFF9399AD) : Colors.grey.shade600;

  /// Status/Badge colors — monochrome soft fills
  Color get successBg => _isDarkMode ? const Color(0xFF9BA3B5).withOpacity(0.10) : const Color(0xFF10B981).withOpacity(0.1);
  Color get errorBg => _isDarkMode ? const Color(0xFF9BA3B5).withOpacity(0.10) : Colors.red.withOpacity(0.1);
  Color get warningBg => _isDarkMode ? const Color(0xFF9BA3B5).withOpacity(0.10) : Colors.orange.withOpacity(0.1);

  /// App bar theme colors
  Color get appBarBg => _isDarkMode ? const Color(0xFF20222C) : Colors.white;
  Color get appBarText => _isDarkMode ? const Color(0xFFCACDD5) : Colors.black87;

  /// Tab bar colors — monochrome
  Color get tabBarBg => _isDarkMode ? const Color(0xFF232530) : Colors.white;
  Color get tabIndicator => _isDarkMode ? const Color(0xFFB5B9C6) : Colors.blue;
  Color get tabLabelActive => _isDarkMode ? const Color(0xFFCACDD5) : Colors.blue;
  Color get tabLabelInactive => _isDarkMode ? const Color(0xFF5F657A) : Colors.grey;

  /// Dropdown/Select colors
  Color get dropdownBg => _isDarkMode ? const Color(0xFF2E3140) : Colors.white;
  Color get dropdownBorder => _isDarkMode ? const Color(0xFF3D4155) : Colors.grey.shade300;

  /// Button colors — monochrome
  Color get buttonPrimaryBg => _isDarkMode ? const Color(0xFF4A4F63) : const Color(0xFF2563EB);
  Color get buttonSecondaryBg => _isDarkMode ? const Color(0xFF2E3140) : Colors.grey.shade100;
  Color get buttonDangerBg => _isDarkMode ? const Color(0xFF5A5E6F) : Colors.red;
  Color get buttonText => Colors.white;

  /// Chip/Tag colors
  Color get chipBg => _isDarkMode ? const Color(0xFF2E3140) : Colors.grey.shade100;
  Color get chipText => _isDarkMode ? const Color(0xFFB5B9C6) : Colors.grey.shade700;

  /// Scrollbar colors
  Color get scrollbarThumb => _isDarkMode ? const Color(0xFF3D4155) : Colors.grey.shade400;
  Color get scrollbarTrack => _isDarkMode ? const Color(0xFF232530) : Colors.grey.shade200;

  /// Build MaterialApp ThemeData
  ThemeData get themeData {
    if (_isDarkMode) {
      return ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: scaffoldBg,
        colorScheme: ColorScheme.dark(
          primary: accentBlue,
          secondary: accentPurple,
          surface: surfaceBg,
          onSurface: textPrimary,
          error: accentRed,
        ),
        useMaterial3: true,
        cardColor: cardBg,
        dividerColor: dividerColor,
        dialogBackgroundColor: dialogBg,
        appBarTheme: AppBarTheme(
          backgroundColor: appBarBg,
          foregroundColor: appBarText,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
        drawerTheme: DrawerThemeData(
          backgroundColor: sidebarBg,
        ),
        popupMenuTheme: PopupMenuThemeData(
          color: cardBg,
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: dialogBg,
          titleTextStyle: TextStyle(color: textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
          contentTextStyle: TextStyle(color: textSecondary, fontSize: 14),
        ),
        inputDecorationTheme: InputDecorationTheme(
          fillColor: inputBg,
          filled: true,
          border: OutlineInputBorder(
            borderSide: BorderSide(color: borderColor),
            borderRadius: BorderRadius.circular(8),
          ),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: borderColor),
            borderRadius: BorderRadius.circular(8),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: accentBlue),
            borderRadius: BorderRadius.circular(8),
          ),
          labelStyle: TextStyle(color: textSecondary),
          hintStyle: TextStyle(color: textTertiary),
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: cardBg,
          contentTextStyle: TextStyle(color: textPrimary),
        ),
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: borderColor),
          ),
          textStyle: TextStyle(color: textPrimary, fontSize: 12),
        ),
        checkboxTheme: CheckboxThemeData(
          fillColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return accentBlue;
            return borderColor;
          }),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return accentBlue;
            return textTertiary;
          }),
          trackColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return accentBlue.withOpacity(0.4);
            return borderColor;
          }),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: accentBlue),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: accentBlue,
            foregroundColor: Colors.white,
          ),
        ),
      );
    } else {
      return ThemeData(
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      );
    }
  }

  // ─── PERSISTENCE ───

  String? _prefsPath;

  Future<void> initialize() async {
    try {
      final exePath = Platform.resolvedExecutable;
      final exeDir = path.dirname(exePath);
      _prefsPath = path.join(exeDir, 'theme_preferences.json');
      
      final file = File(_prefsPath!);
      if (await file.exists()) {
        final content = await file.readAsString();
        final data = jsonDecode(content) as Map<String, dynamic>;
        if (data['isDarkMode'] != null) {
          _isDarkMode = data['isDarkMode'] as bool;
          notifyListeners();
        }
      }
    } catch (e) {
      print('[ThemeProvider] Error loading theme preference: $e');
    }
  }

  Future<void> _saveThemePreference() async {
    try {
      if (_prefsPath == null) return;
      final file = File(_prefsPath!);
      await file.writeAsString(jsonEncode({
        'isDarkMode': _isDarkMode,
        'savedAt': DateTime.now().toIso8601String(),
      }));
    } catch (e) {
      print('[ThemeProvider] Error saving theme preference: $e');
    }
  }
}
