import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:athena/core/theme/theme.dart';

/// Full-width Stripe Press / Tufte editorial bottom bar:
/// - Crisp, full-width bottom shelf (#FBF9F5 in light mode, #141413 in dark mode)
/// - 1px solid top hairline border (#E2DDD5 / #282828)
/// - Sharp 4px-radius editorial action tabs and buttons (zero puffy bubbles)
class AthenaBottomNav extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback? onAddPressed;

  const AthenaBottomNav({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.onAddPressed,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF141413) : const Color(0xFFFBF9F5),
        border: Border(
          top: BorderSide(
            color: isDark ? const Color(0xFF282828) : const Color(0xFFE2DDD5),
            width: 1.0,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Container(
          height: 58,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Tab 0: Library
              _EditorialNavTab(
                label: 'LIBRARY',
                icon: selectedIndex == 0
                    ? Icons.auto_stories_rounded
                    : Icons.auto_stories_outlined,
                isSelected: selectedIndex == 0,
                onTap: () {
                  HapticFeedback.selectionClick();
                  onDestinationSelected(0);
                },
              ),

              // Center Action: Crisp 4px Editorial Button
              if (onAddPressed != null)
                _CenterActionButton(
                  onPressed: onAddPressed!,
                ),

              // Tab 1: Saved / Vault
              _EditorialNavTab(
                label: 'SAVED',
                icon: selectedIndex == 1
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_outline_rounded,
                isSelected: selectedIndex == 1,
                onTap: () {
                  HapticFeedback.selectionClick();
                  onDestinationSelected(1);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditorialNavTab extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _EditorialNavTab({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark ? const Color(0xFF222221) : const Color(0xFFEBE7DF))
              : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: isSelected
                ? (isDark ? const Color(0xFF333331) : const Color(0xFFD6D0C5))
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected
                  ? (isDark ? Colors.white : AppTheme.ink)
                  : (isDark ? const Color(0xFF888884) : const Color(0xFF767672)),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontFamily: AppTheme.fontUI,
                color: isSelected
                    ? (isDark ? Colors.white : AppTheme.ink)
                    : (isDark ? const Color(0xFF888884) : const Color(0xFF767672)),
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CenterActionButton extends StatefulWidget {
  final VoidCallback onPressed;

  const _CenterActionButton({required this.onPressed});

  @override
  State<_CenterActionButton> createState() => _CenterActionButtonState();
}

class _CenterActionButtonState extends State<_CenterActionButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        HapticFeedback.lightImpact();
        widget.onPressed();
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedScale(
        scale: _isPressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOutCubic,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: isDark ? Colors.white : const Color(0xFF161615),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: isDark ? const Color(0xFFE2DDD5) : const Color(0xFF161615),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.add_rounded,
                size: 15,
                color: isDark ? const Color(0xFF161615) : const Color(0xFFFBF9F5),
              ),
              const SizedBox(width: 6),
              Text(
                'ADD BOOK',
                style: TextStyle(
                  fontFamily: AppTheme.fontUI,
                  color: isDark ? const Color(0xFF161615) : const Color(0xFFFBF9F5),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
