import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/core/theme/reader_theme.dart';
import 'package:athena/models/document.dart';

/// L7 Dumb UI Widget: Reader Bottom Bar.
///
/// Isolated footer bar strictly positioned BELOW the viewport in a Column.
/// Fixed 60dp height. Zero overlap with cards.
///
/// Contains:
/// - Tabular progress navigation: < 1 / N >
/// - Quick jump sheet trigger
/// - Inline Edit / Note toggle
/// - + Context / Ask Athena buttons
class ReaderBottomBar extends StatelessWidget {
  final int currentIndex;
  final int totalItems;
  final List<ReaderItem> feedItems;
  final List<ReaderItem> readingChunks;
  final ReaderThemeConfig theme;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onJumpToChapter;
  final VoidCallback? onEditNote;
  final VoidCallback? onGenerateCard;
  final VoidCallback? onAsk;

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
    this.onEditNote,
    this.onGenerateCard,
    this.onAsk,
  });

  @override
  Widget build(BuildContext context) {
    final currentItem = (currentIndex >= 0 && currentIndex < feedItems.length)
        ? feedItems[currentIndex]
        : null;

    final String counterLabel = _buildCounterLabel(currentItem);

    return Container(
      height: 60,
      width: double.infinity,
      color: theme.scaffoldBackground,
      child: Center(
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: theme.innerCardColor,
            borderRadius: BorderRadius.circular(8), // 8px architectural radius
            border: Border.all(
              color: theme.borderColor,
              width: 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: theme.isDark
                    ? const Color(0x33000000)
                    : const Color(0x0A000000),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Previous button
              IconButton(
                icon: Icon(
                  Icons.chevron_left_rounded,
                  color: currentIndex > 0 ? theme.textColor : theme.textMutedColor,
                  size: 22,
                ),
                tooltip: 'Previous card',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: currentIndex > 0
                    ? () {
                        HapticFeedback.selectionClick();
                        onPrevious?.call();
                      }
                    : null,
              ),

              // Tabular figures counter
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: onJumpToChapter != null
                    ? () {
                        HapticFeedback.selectionClick();
                        onJumpToChapter!();
                      }
                    : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    counterLabel,
                    style: TextStyle(
                      fontFamily: AppTheme.fontMono,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: theme.textColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 11.5,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),

              // Next button
              IconButton(
                icon: Icon(
                  Icons.chevron_right_rounded,
                  color: currentIndex < totalItems - 1 ? theme.textColor : theme.textMutedColor,
                  size: 22,
                ),
                tooltip: 'Next card',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: currentIndex < totalItems - 1
                    ? () {
                        HapticFeedback.selectionClick();
                        onNext?.call();
                      }
                    : null,
              ),

              // Divider
              Container(
                height: 18,
                width: 1,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                color: theme.borderColor,
              ),

              // Inline Edit / Note button
              if (onEditNote != null)
                IconButton(
                  icon: Icon(
                    Icons.edit_note_rounded,
                    color: theme.textColor,
                    size: 20,
                  ),
                  tooltip: 'Edit / Personal Note',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    onEditNote!();
                  },
                ),

              // + Context Card trigger
              if (onGenerateCard != null)
                IconButton(
                  icon: Icon(
                    Icons.menu_book_outlined,
                    color: theme.accentColor,
                    size: 18,
                  ),
                  tooltip: '+ Context Card',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    onGenerateCard!();
                  },
                ),

              // Ask Athena trigger
              if (onAsk != null)
                IconButton(
                  icon: Icon(
                    Icons.chat_bubble_outline_rounded,
                    color: theme.textColor,
                    size: 18,
                  ),
                  tooltip: 'Ask Athena',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    onAsk!();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _buildCounterLabel(ReaderItem? currentItem) {
    if (currentItem != null && currentItem.isReadingChunk) {
      final currentSeq = currentItem.sequence ?? (currentIndex + 1);
      final total = readingChunks.isNotEmpty ? readingChunks.length : totalItems;
      return '$currentSeq / $total';
    } else if (currentItem != null && currentItem.isContextCard) {
      final total = readingChunks.isNotEmpty ? readingChunks.length : totalItems;
      int? anchorSeq;
      if (currentItem.sourceChunkId != null) {
        final match = readingChunks.where((c) => c.id == currentItem.sourceChunkId).firstOrNull;
        anchorSeq = match?.sequence;
      }
      if (anchorSeq == null && currentItem.insertAfter != null) {
        final match = readingChunks.where((c) => c.id == currentItem.insertAfter).firstOrNull;
        anchorSeq = match?.sequence;
      }
      if (anchorSeq == null) {
        for (int i = currentIndex - 1; i >= 0; i--) {
          if (feedItems[i].isReadingChunk && feedItems[i].sequence != null) {
            anchorSeq = feedItems[i].sequence;
            break;
          }
        }
      }
      final seqStr = anchorSeq != null ? '$anchorSeq' : '${(currentIndex + 1).clamp(1, totalItems)}';
      return '$seqStr / $total · CARD';
    } else {
      return '${(currentIndex + 1).clamp(1, totalItems)} / $totalItems';
    }
  }
}
