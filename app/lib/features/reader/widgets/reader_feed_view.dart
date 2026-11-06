import 'package:flutter/material.dart';
import 'package:athena/models/document.dart';
import 'package:athena/features/reader/widgets/chunk_widget.dart';
import 'package:athena/features/reader/widgets/context_card_widget.dart';

/// L7 Modular View: Reader Feed View (Strict 1-Swipe = 1-Card Snapping).
///
/// Implements vertical PageView with PageScrollPhysics and allowImplicitScrolling
/// for GPU pre-rasterization. Card widgets rendered inside never intercept vertical drag gestures.
class ReaderFeedView extends StatelessWidget {
  final PageController pageController;
  final List<ReaderItem> feedItems;
  final String themeId;
  final double fontSize;
  final String fontFamily;
  final double lineHeight;
  final bool bionicFocusEnabled;
  final String? layoutWarning;
  final ValueChanged<int> onPageChanged;
  final void Function(ReaderItem chunk) onViewOriginalPage;
  final void Function(ReaderItem chunk) onAsk;
  final void Function(ReaderItem chunk, [String? quote]) onSaveQuote;
  final void Function(ReaderItem chunk)? onDeepDive;
  final void Function(ReaderItem card) onToggleSaveCard;
  final void Function(ReaderItem card) onDismissCard;
  final void Function(ReaderItem card) onAskAthenaForCard;
  final Map<String, String>? chunkEdits;
  final Map<String, String>? chunkNotes;
  final void Function(String chunkId, String? editedText, String? userNote)? onEditSaved;

  const ReaderFeedView({
    super.key,
    required this.pageController,
    required this.feedItems,
    required this.themeId,
    required this.fontSize,
    required this.fontFamily,
    required this.lineHeight,
    required this.bionicFocusEnabled,
    this.layoutWarning,
    required this.onPageChanged,
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
    if (feedItems.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return PageView.builder(
      scrollDirection: Axis.vertical,
      controller: pageController,
      physics: const PageScrollPhysics(), // Strict discrete 1-by-1 snapping
      allowImplicitScrolling: true, // GPU pre-rasterization for zero-jank 60fps
      itemCount: feedItems.length,
      onPageChanged: onPageChanged,
      itemBuilder: (context, index) {
        final item = feedItems[index];

        if (item.isReadingChunk) {
          return Center(
            child: ChunkWidget(
              chunk: item,
              fontSize: fontSize,
              fontFamily: fontFamily,
              lineHeight: lineHeight,
              themeId: themeId,
              isFeedMode: true,
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
              themeId: themeId,
              isFeedMode: true,
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
