import 'package:flutter/material.dart';

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
    scaffoldBackground: Color(0xFFF6F3EC), // Warm archival paper
    outerCardColor: Color(0xFFEFECE2),
    innerCardColor: Color(0xFFFCFBF7), // Crisp archival card surface
    borderColor: Color(0xFFE2DEC9), // 1px stone border
    textColor: Color(0xFF1A1917), // Deep charcoal ink
    textMutedColor: Color(0xFF6B665E),
    accentColor: Color(0xFF005E54),
    pillBackground: Color(0xFFEFECE2),
    pillText: Color(0xFF005E54),
    isDark: false,
  );

  static const ReaderThemeConfig sepia = ReaderThemeConfig(
    id: 'sepia',
    name: 'Sepia',
    scaffoldBackground: Color(0xFFF2ECE1),
    outerCardColor: Color(0xFFE8DFCE),
    innerCardColor: Color(0xFFF9F5EC),
    borderColor: Color(0xFFD8CCB5),
    textColor: Color(0xFF382C1E),
    textMutedColor: Color(0xFF7D6B58),
    accentColor: Color(0xFF7A4E1D),
    pillBackground: Color(0xFFE8DFCE),
    pillText: Color(0xFF7A4E1D),
    isDark: false,
  );

  static const ReaderThemeConfig night = ReaderThemeConfig(
    id: 'night',
    name: 'Night',
    scaffoldBackground: Color(0xFF0D0E11), // Deep ink
    outerCardColor: Color(0xFF111317),
    innerCardColor: Color(0xFF14161B), // Crisp dark card surface
    borderColor: Color(0xFF262932), // Hairline border
    textColor: Color(0xFFE5E7EB),
    textMutedColor: Color(0xFF9CA3AF),
    accentColor: Color(0xFF2DD4BF),
    pillBackground: Color(0xFF1E2129),
    pillText: Color(0xFF2DD4BF),
    isDark: true,
  );

  static const ReaderThemeConfig obsidian = ReaderThemeConfig(
    id: 'obsidian',
    name: 'Obsidian',
    scaffoldBackground: Color(0xFF070709),
    outerCardColor: Color(0xFF0D0E11),
    innerCardColor: Color(0xFF14161B),
    borderColor: Color(0xFF262932),
    textColor: Color(0xFFEDEDED),
    textMutedColor: Color(0xFF888888),
    accentColor: Color(0xFF2DD4BF),
    pillBackground: Color(0xFF181A20),
    pillText: Color(0xFF2DD4BF),
    isDark: true,
  );

  static const List<ReaderThemeConfig> all = [paper, sepia, night, obsidian];

  static ReaderThemeConfig getById(String id) {
    switch (id) {
      case 'sepia':
        return sepia;
      case 'night':
        return night;
      case 'obsidian':
        return obsidian;
      case 'paper':
      default:
        return paper;
    }
  }
}
