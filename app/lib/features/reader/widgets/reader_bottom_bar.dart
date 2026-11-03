library;

/// L7 Dumb UI Widget: Reader Bottom Bar
///
/// Isolated footer bar placed BELOW the Expanded PageView/ListView inside a Column.
/// NEVER floats inside a Stack over the text. Zero overlap with card content.
///
/// Height: 60dp fixed. Contains:
/// - Previous/Next navigation buttons (chevron icons)
/// - Progress indicator: "1 / 857" or "Context · #3"
/// - Optional: + Context Card / Ask button (on-demand)

import 'package:flutter/material.dart';
import 'package:athena/core/theme/reader_theme.dart';
import 'package:athena/models/document.dart';

class ReaderBottomBar extends StatelessWidget {
  final int currentIndex;
  final int totalItems;
  final List<ReaderItem> feedItems;
  final List<ReaderItem> readingChunks;
  final ReaderThemeConfig theme;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onJumpToChapter;
  final VoidCallback? onAsk;
  final VoidCallback? onGenerateCard;

  const ReaderBottomBar({
    super.key,
    required this.currentIndex,
    required this.totalItems,
    required this.feedItems,
    required this.readingChunks,
    required this.theme,
    this.onPrevious,
    this.onNext,
    this.onJumpToChapter,
    this.onAsk,
    this.onGenerateCard,
  });

  @override
  Widget build(BuildContext context) {
    final currentItem = (currentIndex >= 0 && currentIndex < feedItems.length)
        ? feedItems[currentIndex]
        : null;

    final String counterLabel = _buildCounterLabel(currentItem);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8.0, top: 4.0),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: theme.isDark
                  ? const Color(0xFF1E221E)
                  : const Color(0xFF141714),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.16),
                width: 1.0,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x38000000),
                  blurRadius: 22,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Previous button
                IconButton(
                  icon: const Icon(Icons.chevron_left_rounded,
                      color: Colors.white, size: 22),
                  tooltip: 'Previous card (Up Arrow / Scroll Up)',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  onPressed: currentIndex > 0 ? onPrevious : null,
                ),
                const SizedBox(width: 4),

                // Progress counter
                Text(
                  counterLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    letterSpacing: 0.3,
                  ),
                ),

                const SizedBox(width: 4),

                // Next button
                IconButton(
                  icon: const Icon(Icons.chevron_right_rounded,
                      color: Colors.white, size: 22),
                  tooltip: 'Next card (Down Arrow / Space / Scroll Down)',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  onPressed: currentIndex < totalItems - 1 ? onNext : null,
                ),

                // Optional: Jump to chapter / Ask / Generate Card
                if (onJumpToChapter != null || onAsk != null || onGenerateCard != null) ...[
                  const SizedBox(width: 8),
                  _buildActionButtons(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _buildCounterLabel(ReaderItem? currentItem) {
    if (currentItem != null && currentItem.isReadingChunk) {
      final currentSeq = currentItem.sequence ?? (currentIndex + 1);
      return '$currentSeq / ${readingChunks.length}';
    } else if (currentItem != null && currentItem.isContextCard) {
      final targetSeq = currentItem.sequence ?? '';
      return targetSeq != '' ? 'Context · #$targetSeq' : 'Context';
    } else {
      return '${(currentIndex + 1).clamp(1, totalItems)} / $totalItems';
    }
  }

  Widget _buildActionButtons() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onJumpToChapter != null)
          _ActionIconButton(
            icon: Icons.menu_book_rounded,
            tooltip: 'Table of Contents',
            onPressed: onJumpToChapter!,
          ),
        if (onGenerateCard != null)
          _ActionIconButton(
            icon: Icons.auto_awesome_rounded,
            tooltip: 'Generate Context Card',
            onPressed: onGenerateCard!,
          ),
        if (onAsk != null)
          _ActionIconButton(
            icon: Icons.chat_bubble_outline_rounded,
            tooltip: 'Ask Athena',
            onPressed: onAsk!,
          ),
      ],
    );
  }
}

class _ActionIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _ActionIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, color: Colors.white, size: 20),
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      onPressed: onPressed,
    );
  }
}
