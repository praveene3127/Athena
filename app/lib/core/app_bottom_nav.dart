import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme.dart';

/// Floating Obsidian Navigation Dock inspired by Juno 365:
/// - Floating obsidian pill detached from screen bottom
/// - Pure black & white palette per ATHENA-BRAND-GUIDE.md
/// - High-contrast editorial typography in Geist
/// - Sleek micro-interactions with haptic feedback
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
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: 1.0,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Container(
              // Outer Shell (Double-Bezel)
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: const Color(0xFF141714),
                borderRadius: BorderRadius.circular(32),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.14),
                  width: 1.0,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x38000000),
                    blurRadius: 24,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Container(
                // Inner Core
                height: 54,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF1B1E1B),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Tab 0: Library
                    _EditorialNavTab(
                      label: 'Library',
                      icon: selectedIndex == 0
                          ? Icons.auto_stories_rounded
                          : Icons.auto_stories_outlined,
                      isSelected: selectedIndex == 0,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        onDestinationSelected(0);
                      },
                    ),

                    // Center Action: Button-in-Button CTA
                    if (onAddPressed != null)
                      _CenterActionButton(
                        onPressed: onAddPressed!,
                      ),

                    // Tab 1: Saved / Vault
                    _EditorialNavTab(
                      label: 'Saved',
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.white.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
          border: isSelected
              ? Border.all(
                  color: Colors.white.withValues(alpha: 0.18),
                  width: 1,
                )
              : Border.all(color: Colors.transparent, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 17,
              color: isSelected ? Colors.white : const Color(0xFF9E9E9E),
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                fontFamily: AppTheme.fontUI,
                color: isSelected ? Colors.white : const Color(0xFF9E9E9E),
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                letterSpacing: 0.2,
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
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        HapticFeedback.lightImpact();
        widget.onPressed();
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedScale(
        scale: _isPressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            boxShadow: const [
              BoxShadow(
                color: Color(0x22000000),
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Add Book',
                style: TextStyle(
                  fontFamily: AppTheme.fontUI,
                  color: Color(0xFF141714),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.1,
                ),
              ),
              const SizedBox(width: 8),
              // Nested button-in-button circular icon
              Container(
                width: 26,
                height: 26,
                decoration: const BoxDecoration(
                  color: Color(0xFF141714),
                  shape: BoxShape.circle,
                ),
                child: const Center(
                  child: Icon(
                    Icons.add_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
