import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/core/theme/reader_theme.dart';

/// L7 Modular Sheet: Typography and Appearance Sheet.
///
/// Provides fine controls for:
/// - Reading Theme (Paper, Sepia, Night, Obsidian)
/// - Font Size (14px - 26px)
/// - Font Family (Georgia, Literata, Bookerly, Inter, Monospace)
/// - Line Height (1.4 - 2.0)
/// - Bionic Focus Reading
class TypographySheet extends StatelessWidget {
  final String currentThemeId;
  final double currentFontSize;
  final String currentFontFamily;
  final double currentLineHeight;
  final bool currentBionic;
  final ValueChanged<String> onThemeChanged;
  final ValueChanged<double> onFontSizeChanged;
  final ValueChanged<String> onFontFamilyChanged;
  final ValueChanged<double> onLineHeightChanged;
  final ValueChanged<bool> onBionicChanged;

  const TypographySheet({
    super.key,
    required this.currentThemeId,
    required this.currentFontSize,
    required this.currentFontFamily,
    required this.currentLineHeight,
    required this.currentBionic,
    required this.onThemeChanged,
    required this.onFontSizeChanged,
    required this.onFontFamilyChanged,
    required this.onLineHeightChanged,
    required this.onBionicChanged,
  });

  static Future<void> show(
    BuildContext context, {
    required String themeId,
    required double fontSize,
    required String fontFamily,
    required double lineHeight,
    required bool bionic,
    required ValueChanged<String> onThemeChanged,
    required ValueChanged<double> onFontSizeChanged,
    required ValueChanged<String> onFontFamilyChanged,
    required ValueChanged<double> onLineHeightChanged,
    required ValueChanged<bool> onBionicChanged,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => TypographySheet(
        currentThemeId: themeId,
        currentFontSize: fontSize,
        currentFontFamily: fontFamily,
        currentLineHeight: lineHeight,
        currentBionic: bionic,
        onThemeChanged: onThemeChanged,
        onFontSizeChanged: onFontSizeChanged,
        onFontFamilyChanged: onFontFamilyChanged,
        onLineHeightChanged: onLineHeightChanged,
        onBionicChanged: onBionicChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ReaderThemeConfig.getById(currentThemeId);

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      decoration: BoxDecoration(
        color: theme.scaffoldBackground,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        border: Border.all(color: theme.borderColor),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.borderColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    'Typography & Appearance',
                    style: TextStyle(
                      fontFamily: AppTheme.fontDisplay,
                      fontSize: 18,
                      fontWeight: FontWeight.w400,
                      color: theme.textColor,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.close_rounded, size: 20, color: theme.textMutedColor),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Theme Selector
              Text('THEME', style: _headerStyle(theme)),
              const SizedBox(height: 8),
              Row(
                children: ReaderThemeConfig.all.map((t) {
                  final selected = t.id == currentThemeId;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: InkWell(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onThemeChanged(t.id);
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          height: 44,
                          decoration: BoxDecoration(
                            color: t.scaffoldBackground,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: selected ? t.accentColor : t.borderColor,
                              width: selected ? 2.0 : 1.0,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            t.name,
                            style: TextStyle(
                              fontFamily: AppTheme.fontUI,
                              color: t.textColor,
                              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),

              // Font Size Slider
              Text('TYPE SIZE', style: _headerStyle(theme)),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text('A', style: TextStyle(fontFamily: currentFontFamily, fontSize: 13, color: theme.textColor)),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: theme.accentColor,
                        thumbColor: theme.accentColor,
                      ),
                      child: Slider(
                        value: currentFontSize.clamp(14.0, 26.0),
                        min: 14.0,
                        max: 26.0,
                        divisions: 12,
                        label: '${currentFontSize.toInt()}pt',
                        onChanged: (val) {
                          onFontSizeChanged(val);
                        },
                      ),
                    ),
                  ),
                  Text('A', style: TextStyle(fontFamily: currentFontFamily, fontSize: 22, fontWeight: FontWeight.bold, color: theme.textColor)),
                ],
              ),
              const SizedBox(height: 14),

              // Font Family Selector
              Text('FONT', style: _headerStyle(theme)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: ['Georgia', 'Literata', 'Bookerly', 'Inter', 'JetBrains Mono'].map((f) {
                  final selected = currentFontFamily == f;
                  return ChoiceChip(
                    label: Text(f, style: TextStyle(fontFamily: f == 'JetBrains Mono' ? AppTheme.fontMono : f)),
                    selected: selected,
                    selectedColor: theme.accentColor.withValues(alpha: 0.15),
                    backgroundColor: theme.innerCardColor,
                    labelStyle: TextStyle(
                      color: selected ? theme.accentColor : theme.textColor,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                      fontSize: 12,
                    ),
                    side: BorderSide(
                      color: selected ? theme.accentColor : theme.borderColor,
                    ),
                    onSelected: (val) {
                      if (val) {
                        HapticFeedback.selectionClick();
                        onFontFamilyChanged(f);
                      }
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),

              // Bionic Focus Toggle
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeTrackColor: theme.accentColor,
                title: Text(
                  'Bionic Focus',
                  style: TextStyle(
                    fontFamily: AppTheme.fontUI,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: theme.textColor,
                  ),
                ),
                subtitle: Text(
                  'Guides eyes through text with highlighted fixation points',
                  style: TextStyle(fontSize: 12, color: theme.textMutedColor),
                ),
                value: currentBionic,
                onChanged: onBionicChanged,
              ),
            ],
          ),
        ),
      ),
    );
  }

  TextStyle _headerStyle(ReaderThemeConfig theme) => TextStyle(
        fontFamily: AppTheme.fontMono,
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: theme.textMutedColor,
      );
}
