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
    scaffoldBackground: Color(0xFFFBFBF9),
    outerCardColor: Color(0xFFF4F3EE),
    innerCardColor: Color(0xFFFCFBF7),
    borderColor: Color(0xFFE5E4DC),
    textColor: Color(0xFF141714),
    textMutedColor: Color(0xFF6B7280),
    accentColor: Color(0xFF005E54),
    pillBackground: Color(0xFFF2F4EB),
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
    scaffoldBackground: Color(0xFF141714),
    outerCardColor: Color(0xFF1A1D1A),
    innerCardColor: Color(0xFF222622),
    borderColor: Color(0xFF2D332D),
    textColor: Color(0xFFE3E7E3),
    textMutedColor: Color(0xFF8E958E),
    accentColor: Color(0xFF52B788),
    pillBackground: Color(0xFF2D332D),
    pillText: Color(0xFF52B788),
    isDark: true,
  );

  static const ReaderThemeConfig obsidian = ReaderThemeConfig(
    id: 'obsidian',
    name: 'Obsidian',
    scaffoldBackground: Color(0xFF000000),
    outerCardColor: Color(0xFF0B0B0B),
    innerCardColor: Color(0xFF121212),
    borderColor: Color(0xFF222222),
    textColor: Color(0xFFE0E0E0),
    textMutedColor: Color(0xFF757575),
    accentColor: Color(0xFF2A9D8F),
    pillBackground: Color(0xFF1A1A1A),
    pillText: Color(0xFF2A9D8F),
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
