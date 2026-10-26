import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A selectable accent colour, matching the web app's options.
class AccentOption {
  const AccentOption({
    required this.id,
    required this.name,
    required this.description,
    required this.color,
  });

  final String id;
  final String name;
  final String description;
  final Color color;
}

const List<AccentOption> kAccentOptions = [
  AccentOption(
    id: 'mint',
    name: 'Mint Green',
    description: "ArcheSpace's signature accent, a refined mint green.",
    color: Color(0xFF32D3AA),
  ),
  AccentOption(
    id: 'lavender',
    name: 'Lavender Indigo',
    description: 'A cool indigo-violet with a fresh, modern feel.',
    color: Color(0xFF7C6AF7),
  ),
  AccentOption(
    id: 'amber',
    name: 'Amber Gold',
    description: 'A warm gold accent with a calm, focused feel.',
    color: Color(0xFFF6B84B),
  ),
  AccentOption(
    id: 'sky',
    name: 'Sky Blue',
    description: 'A clear azure blue with a bright, calm feel.',
    color: Color(0xFF38A5F0),
  ),
  AccentOption(
    id: 'rose',
    name: 'Rose',
    description: 'A warm rose pink with a soft, friendly feel.',
    color: Color(0xFFF56B8A),
  ),
];

const String kDefaultAccentId = 'mint';

/// Holds theme mode + accent colour, persisted with shared_preferences and
/// applied by [ArcheApp]. Matches the web app's appearance options.
class AppearanceController extends ChangeNotifier {
  AppearanceController._();
  static final AppearanceController instance = AppearanceController._();

  static const String _kMode = 'appearance_theme_mode';
  static const String _kAccent = 'appearance_accent';

  ThemeMode _themeMode = ThemeMode.system;
  String _accentId = kDefaultAccentId;

  ThemeMode get themeMode => _themeMode;
  String get accentId => _accentId;

  Color get accent => kAccentOptions
      .firstWhere((a) => a.id == _accentId, orElse: () => kAccentOptions.first)
      .color;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = prefs.getString(_kMode);
    _themeMode = ThemeMode.values.firstWhere(
      (m) => m.name == mode,
      orElse: () => ThemeMode.system,
    );
    final accent = prefs.getString(_kAccent);
    if (accent != null && kAccentOptions.any((a) => a.id == accent)) {
      _accentId = accent;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == _themeMode) return;
    _themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMode, mode.name);
  }

  Future<void> setAccent(String id) async {
    if (id == _accentId) return;
    _accentId = id;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAccent, id);
  }
}
