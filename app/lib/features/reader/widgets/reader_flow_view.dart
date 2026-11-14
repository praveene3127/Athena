import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:athena/core/theme/reader_theme.dart';
import 'package:athena/models/document.dart';
import 'package:athena/features/reader/widgets/chunk_widget.dart';
import 'package:athena/features/reader/widgets/context_card_widget.dart';

/// L7 Modular View: Reader Flow View (Continuous Scrollable Reading).
///
/// Implements ScrollablePositionedList with ClampingScrollPhysics for
/// smooth, continuous chapter reading without card-snapping constraints.
class ReaderFlowView extends StatelessWidget {
  final String documentId;
  final ValueChanged<String> onJumpToPassage;
  final ItemScrollController itemScrollController;
  final ItemPositionsListener itemPositionsListener;
  final List<ReaderItem> feedItems;
  final int initialIndex;
  final String themeId;
  final double fontSize;
  final String fontFamily;
  final double lineHeight;
  final bool bionicFocusEnabled;
  final String? layoutWarning;
  final void Function(ReaderItem chunk) onViewOriginalPage;
  final void Function(ReaderItem chunk) onAsk;
  final void Function(ReaderItem chunk, [String? quote]) onSaveQuote;
  final void Function(ReaderItem chunk)? onDeepDive;
  final void Function(ReaderItem card) onToggleSaveCard;
  final void Function(ReaderItem card) onDismissCard;
  final void Function(ReaderItem card) onAskAthenaForCard;
  final ReaderLoadState loadState;
  final Map<String, String>? chunkEdits;
  final Map<String, String>? chunkNotes;
  final void Function(String chunkId, String? editedText, String? userNote)?
      onEditSaved;

  const ReaderFlowView({
    super.key,
    required this.documentId,
    required this.onJumpToPassage,
    required this.itemScrollController,
    required this.itemPositionsListener,
    required this.feedItems,
    required this.initialIndex,
    required this.themeId,
    required this.fontSize,
    required this.fontFamily,
    required this.lineHeight,
    required this.bionicFocusEnabled,
    this.layoutWarning,
    this.loadState = ReaderLoadState.ready,
    required this.onViewOriginalPage,
    required this.onAsk,
    required this.onSaveQuote,
    this.onDeepDive,
    required this.onToggleSaveCard,
    required this.onDismissCard,
    required this.onAskAthenaForCard,
    this.chunkEdits,
    this.chunkNotes,
    this.onEditSaved,
  });

  @override
  Widget build(BuildContext context) {
    final theme = ReaderThemeConfig.getById(themeId);

    if (feedItems.isEmpty) {
      if (loadState == ReaderLoadState.loading) {
        return const Center(child: CircularProgressIndicator());
      }
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: theme.innerCardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.borderColor),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book_outlined, size: 40, color: theme.accentColor),
              const SizedBox(height: 16),
              Text(
                'No Readable Content Found',
                style: TextStyle(
                  fontFamily: fontFamily,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: theme.textColor,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'This document has no extracted chunks yet or ingestion was interrupted.',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.textMutedColor, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return ScrollablePositionedList.builder(
      itemScrollController: itemScrollController,
      itemPositionsListener: itemPositionsListener,
      initialScrollIndex: initialIndex.clamp(0, feedItems.length - 1),
      physics:
          const ClampingScrollPhysics(), // Smooth continuous scroll in flow mode
      itemCount: feedItems.length + 1,
      itemBuilder: (context, index) {
        if (index == feedItems.length) {
          return Center(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: theme.innerCardColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.borderColor),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.verified_rounded,
                      color: theme.accentColor, size: 28),
                  const SizedBox(height: 8),
                  Text(
                    'End of Document',
                    style: TextStyle(
                      fontFamily: fontFamily,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: theme.textColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'All chunks rendered with verified lossless fidelity.',
                    style: TextStyle(color: theme.textMutedColor, fontSize: 12),
                  ),
                ],
              ),
            ),
          );
        }

        final item = feedItems[index];

        if (item.isReadingChunk) {
          return Center(
            child: ChunkWidget(
              documentId: documentId,
              chunk: item,
              fontSize: fontSize,
              fontFamily: fontFamily,
              lineHeight: lineHeight,
              themeId: themeId,
              isFeedMode: false,
              bionicFocusEnabled: bionicFocusEnabled,
              layoutWarning: layoutWarning,
              initialEditedText: chunkEdits?[item.id],
              initialUserNote: chunkNotes?[item.id],
              onEditSaved: onEditSaved,
              onViewOriginalPage: () => onViewOriginalPage(item),
              onAsk: () => onAsk(item),
              onSaveQuote: ([q]) => onSaveQuote(item, q),
              onDeepDive: onDeepDive != null ? () => onDeepDive!(item) : null,
            ),
          );
        } else if (item.isContextCard) {
          return Center(
            child: ContextCardWidget(
              card: item,
              documentId: documentId,
              onJumpToPassage: onJumpToPassage,
              themeId: themeId,
              isFeedMode: false,
              onToggleSave: () => onToggleSaveCard(item),
              onDismiss: () => onDismissCard(item),
              onAskAthena: () => onAskAthenaForCard(item),
            ),
          );
        }

        return const SizedBox.shrink();
      },
    );
  }
}
