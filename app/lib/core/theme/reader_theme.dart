import 'package:flutter/material.dart';
import 'package:athena/core/theme/theme.dart';

class ReaderThemeConfig {
  final String id;
  final String name;
  final Color scaffoldBackground;
  final Color outerCardColor;
  final Color innerCardColor;
  final Color borderColor;
  final Color textColor;
  final Color textMutedColor;
  final Color accentColor;
  final Color pillBackground;
  final Color pillText;
  final bool isDark;

  const ReaderThemeConfig({
    required this.id,
    required this.name,
    required this.scaffoldBackground,
    required this.outerCardColor,
    required this.innerCardColor,
    required this.borderColor,
    required this.textColor,
    required this.textMutedColor,
    required this.accentColor,
    required this.pillBackground,
    required this.pillText,
    required this.isDark,
  });

  static const ReaderThemeConfig paper = ReaderThemeConfig(
    id: 'paper',
    name: 'Paper',
    scaffoldBackground: Color(0xFFFBF9F5),
    outerCardColor: Color(0xFFF2EFE9),
    innerCardColor: Color(0xFFFFFFFF),
    borderColor: Color(0xFFE6E1D6),
    textColor: Color(0xFF161615),
    textMutedColor: Color(0xFF6E6E6B),
    accentColor: Color(0xFF2D6A4F),
    pillBackground: Color(0xFFF2EFE9),
    pillText: Color(0xFF2D6A4F),
    isDark: false,
  );

  static const ReaderThemeConfig sepia = ReaderThemeConfig(
    id: 'sepia',
    name: 'Sepia',
    scaffoldBackground: Color(0xFFF4ECD8),
    outerCardColor: Color(0xFFEAE0C8),
    innerCardColor: Color(0xFFFAF4E4),
    borderColor: Color(0xFFDCD0B8),
    textColor: Color(0xFF2C221E),
    textMutedColor: Color(0xFF6E5D53),
    accentColor: Color(0xFF8C4A27),
    pillBackground: Color(0xFFEAE0C8),
    pillText: Color(0xFF8C4A27),
    isDark: false,
  );

  static const ReaderThemeConfig charcoal = ReaderThemeConfig(
    id: 'charcoal',
    name: 'Charcoal',
    scaffoldBackground: Color(0xFF121316),
    outerCardColor: Color(0xFF22252A),
    innerCardColor: Color(0xFF1A1C20),
    borderColor: Color(0xFF2A2E35),
    textColor: Color(0xFFECEAE4),
    textMutedColor: Color(0xFF9CA0A8),
    accentColor: Color(0xFF34D399),
    pillBackground: Color(0xFF22252A),
    pillText: Color(0xFF34D399),
    isDark: true,
  );

  static const ReaderThemeConfig oled = ReaderThemeConfig(
    id: 'oled',
    name: 'OLED',
    scaffoldBackground: Color(0xFF000000),
    outerCardColor: Color(0xFF121215),
    innerCardColor: Color(0xFF0A0A0C),
    borderColor: Color(0xFF1F1F24),
    textColor: Color(0xFFF5F5F0),
    textMutedColor: Color(0xFF8E8E93),
    accentColor: Color(0xFF34D399),
    pillBackground: Color(0xFF121215),
    pillText: Color(0xFF34D399),
    isDark: true,
  );

  static ReaderThemeConfig get night => charcoal;
  static ReaderThemeConfig get obsidian => oled;

  static const List<ReaderThemeConfig> all = [paper, sepia, charcoal, oled];
  static const List<ReaderThemeConfig> defaults = all;

  static ReaderThemeConfig fromId(String id) => getById(id);

  AthenaAppearance toAppearance() {
    switch (id) {
      case 'sepia':
        return AthenaAppearance.sepia;
      case 'charcoal':
        return AthenaAppearance.charcoal;
      case 'oled':
        return AthenaAppearance.oled;
      case 'paper':
      default:
        return AthenaAppearance.paper;
    }
  }

  static ReaderThemeConfig getById(String id) {
    switch (id.toLowerCase()) {
      case 'sepia':
        return sepia;
      case 'charcoal':
      case 'night':
        return charcoal;
      case 'oled':
      case 'obsidian':
        return oled;
      case 'paper':
      default:
        return paper;
    }
  }
}
