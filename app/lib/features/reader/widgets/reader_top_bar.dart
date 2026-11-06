import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/core/theme/reader_theme.dart';

/// L7 Dumb UI Widget: Reader Top Navigation Bar.
///
/// Implements PreferredSizeWidget (56dp fixed height) using clean editorial typography.
/// Provides back navigation, truncated book title, FEED | FLOW toggle, search, and typography settings.
class ReaderTopBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final String readingMode;
  final ReaderThemeConfig theme;
  final VoidCallback onBack;
  final ValueChanged<String> onReadingModeChanged;
  final VoidCallback onSearch;
  final VoidCallback onOpenToc;
  final VoidCallback onOpenTypography;
  final VoidCallback onToggleTheme;
  final bool isDark;
  final double progress;

  const ReaderTopBar({
    super.key,
    required this.title,
    required this.readingMode,
    required this.theme,
    required this.onBack,
    required this.onReadingModeChanged,
    required this.onSearch,
    required this.onOpenToc,
    required this.onOpenTypography,
    required this.onToggleTheme,
    required this.isDark,
    this.progress = 0.0,
  });

  @override
  Size get preferredSize => const Size.fromHeight(56.0);

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 600;

    return AppBar(
      backgroundColor: theme.scaffoldBackground,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleSpacing: isMobile ? 4 : 8,
      toolbarHeight: 56,
      leadingWidth: isMobile ? 44 : 52,
      leading: Padding(
        padding: EdgeInsets.only(left: isMobile ? 4 : 10),
        child: IconButton(
          icon: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: theme.innerCardColor,
              shape: BoxShape.circle,
              border: Border.all(color: theme.borderColor),
            ),
            child: Icon(
              Icons.arrow_back_rounded,
              color: theme.textColor,
              size: 16,
            ),
          ),
          tooltip: 'Back to Library',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          onPressed: onBack,
        ),
      ),
      title: Text(
        title.isNotEmpty ? title : 'Reader',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: AppTheme.fontDisplay,
          fontSize: isMobile ? 15 : 17,
          fontWeight: FontWeight.w400,
          color: theme.textColor,
          letterSpacing: -0.2,
        ),
      ),
      actions: [
        // FEED | FLOW Segmented Toggle
        Center(
          child: Container(
            height: 28,
            margin: const EdgeInsets.only(right: 4),
            decoration: BoxDecoration(
              color: theme.innerCardColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: theme.borderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildModeTab('feed', 'FEED'),
                _buildModeTab('flow', 'FLOW'),
              ],
            ),
          ),
        ),

        // Search icon
        IconButton(
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          icon: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: theme.innerCardColor,
              shape: BoxShape.circle,
              border: Border.all(color: theme.borderColor),
            ),
            child: Icon(Icons.search_rounded, color: theme.textColor, size: 15),
          ),
          tooltip: 'Search in book',
          onPressed: onSearch,
        ),

        // Aa Typography button
        IconButton(
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          tooltip: 'Typography & Appearance',
          icon: Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.innerCardColor,
              shape: BoxShape.circle,
              border: Border.all(color: theme.borderColor),
            ),
            child: Text(
              'Aa',
              style: TextStyle(
                fontFamily: AppTheme.fontUI,
                color: theme.textColor,
                fontWeight: FontWeight.w700,
                fontSize: 11.5,
              ),
            ),
          ),
          onPressed: onOpenTypography,
        ),
        const SizedBox(width: 6),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(2),
        child: LinearProgressIndicator(
          value: progress.clamp(0.0, 1.0),
          backgroundColor: theme.borderColor.withValues(alpha: 0.3),
          color: theme.accentColor,
          minHeight: 2,
        ),
      ),
    );
  }

  Widget _buildModeTab(String mode, String label) {
    final isSelected = readingMode == mode;
    return InkWell(
      onTap: () {
        if (!isSelected) {
          HapticFeedback.selectionClick();
          onReadingModeChanged(mode);
        }
      },
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: isSelected ? theme.accentColor : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: AppTheme.fontUI,
            color: isSelected ? Colors.white : theme.textColor,
            fontWeight: FontWeight.w700,
            fontSize: 9.5,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}
