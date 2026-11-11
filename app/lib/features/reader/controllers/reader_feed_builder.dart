library;

/// L6 Pure Logic: Deterministic Feed Building
///
/// This module contains ZERO Flutter UI imports. It only depends on models.
/// Produces the exact `feedItems` list (interleaving ReadingChunk and ContextCard items)
/// that the L7 UI widgets will render.

import 'package:athena/models/document.dart';

/// Configuration for feed building behavior
class FeedBuilderConfig {
  final bool showContextCards;
  final int minChunkGapBetweenCards;
  final int maxCharsPerBeat;

  const FeedBuilderConfig({
    this.showContextCards = true,
    this.minChunkGapBetweenCards = 3,
    this.maxCharsPerBeat = 380,
  });
}

/// Result of feed building containing the interleaved items and metadata
class FeedBuildResult {
  final List<ReaderItem> feedItems;
  final List<ReaderItem> readingChunks;
  final Map<int, ReaderItem> cardsByChunkSeq;
  final Set<String> dismissedCardIds;

  const FeedBuildResult({
    required this.feedItems,
    required this.readingChunks,
    required this.cardsByChunkSeq,
    required this.dismissedCardIds,
  });
}

/// Pure function: Build interleaved feed items list from raw items and dynamic cards.
///
/// Single source of truth for chunk and card interleaving.
List<ReaderItem> buildInterleavedFeed({
  required List<ReaderItem> rawItems,
  required Map<int, ReaderItem> dynamicCardsBySeq,
  required Set<String> dismissedCardIds,
  required bool showContextCards,
  int minChunkGapBetweenCards = 3,
  int maxCharsPerBeat = 380,
}) {
  return buildFeedResult(
    rawItems: rawItems,
    dynamicCardsBySeq: dynamicCardsBySeq,
    dismissedCardIds: dismissedCardIds,
    showContextCards: showContextCards,
    minChunkGapBetweenCards: minChunkGapBetweenCards,
    maxCharsPerBeat: maxCharsPerBeat,
  ).feedItems;
}

/// Pure function: Build full feed result containing feed items and metadata.
FeedBuildResult buildFeedResult({
  required List<ReaderItem> rawItems,
  required Map<int, ReaderItem> dynamicCardsBySeq,
  required Set<String> dismissedCardIds,
  required bool showContextCards,
  int minChunkGapBetweenCards = 3,
  int maxCharsPerBeat = 380,
}) {
  // 1. Separate chunks and raw cards
  final chunks = rawItems.where((it) => it.isReadingChunk).toList();
  final rawCards = rawItems.where((it) => it.isContextCard).toList();

  // 2. Build chunk ID -> sequence lookup
  final chunkSeqById = {for (final c in chunks) c.id: c.sequence ?? 0};

  // 3. Collect ALL cards (from raw items + dynamic cards) by their matched chunk sequence
  final cardsBySeq = <int, List<ReaderItem>>{};
  final assignedCardIds = <String>{};

  // 3a. Process raw cards from API response
  for (final card in rawCards) {
    final seq = _resolveCardSequence(card, chunkSeqById, chunks);
    if (seq != null && seq > 0) {
      cardsBySeq.putIfAbsent(seq, () => []).add(card);
      assignedCardIds.add(card.id);
    }
  }

  // 3b. Process dynamic cards (from SSE/polling)
  for (final entry in dynamicCardsBySeq.entries) {
    final card = entry.value;
    if (assignedCardIds.contains(card.id)) continue;

    var seq = entry.key;
    if (seq <= 0 || seq > chunks.length) {
      seq = _resolveCardSequence(card, chunkSeqById, chunks) ?? 0;
    }

    if (seq > 0 && seq <= chunks.length) {
      cardsBySeq.putIfAbsent(seq, () => []).add(card);
      assignedCardIds.add(card.id);
    }
  }

  // 4. Build feed items strictly anchored to matching chunks
  // Orphan cards without matching chunk anchors are quarantined and never misassigned
  final feedItems = <ReaderItem>[];
  int lastCardChunkSeq = -999;

  for (final chunk in chunks) {
    // 1-to-1 canonical ReadingChunk mapping (F21)
    feedItems.add(chunk);

    final seq = chunk.sequence ?? 0;

    final matchedCards = cardsBySeq[seq];
    if (matchedCards != null && showContextCards) {
      // GAP-02: Enforce minChunkGapBetweenCards
      final gap = seq - lastCardChunkSeq;
      if (gap >= minChunkGapBetweenCards) {
        for (final card in matchedCards) {
          if (!dismissedCardIds.contains(card.id)) {
            feedItems.add(card);
            lastCardChunkSeq = seq;
          }
        }
      }
    }
  }

  return FeedBuildResult(
    feedItems: feedItems,
    readingChunks: chunks,
    cardsByChunkSeq: cardsBySeq.map((k, v) => MapEntry(k, v.first)),
    dismissedCardIds: dismissedCardIds,
  );
}

/// Resolve the chunk sequence number for a context card
///
/// Priority:
/// 1. insertAfter -> chunkSeqById lookup
/// 2. card.sequence
/// 3. Regex suffix on insertAfter: (?:-c|_)(0*\d+)$
/// 4. Exact-quote text anchor resolution (RC-10)
int? _resolveCardSequence(ReaderItem card, Map<String, int> chunkSeqById, [List<ReaderItem>? chunks]) {
  // Tier 1: Try insertAfter or sourceChunkId -> chunk ID lookup
  final targetId = card.insertAfter ?? card.sourceChunkId;
  if (targetId != null && chunkSeqById.containsKey(targetId)) {
    final mapped = chunkSeqById[targetId]!;
    if (mapped > 0) return mapped;
  }
  if (card.sourceChunkId != null && chunkSeqById.containsKey(card.sourceChunkId)) {
    final mapped = chunkSeqById[card.sourceChunkId]!;
    if (mapped > 0) return mapped;
  }

  // Tier 2: Try card.sequence
  if (card.sequence != null && card.sequence! > 0) {
    return card.sequence;
  }

  // Tier 2b: Try regex suffix on insertAfter or sourceChunkId: (?:-c|_)(0*\d+)$
  if (targetId != null) {
    final m = RegExp(r'(?:-c|_)(0*\d+)$').firstMatch(targetId);
    if (m != null) {
      return int.tryParse(m.group(1)!);
    }
  }
  if (card.sourceChunkId != null) {
    final m = RegExp(r'(?:-c|_)(0*\d+)$').firstMatch(card.sourceChunkId!);
    if (m != null) {
      return int.tryParse(m.group(1)!);
    }
  }

  // Tier 3: Exact-quote text anchor resolution (RC-10)
  final quote = card.exactQuote?.trim();
  if (quote != null && quote.length >= 10 && chunks != null) {
    for (final chunk in chunks) {
      if (chunk.rawText.contains(quote)) {
        return chunk.sequence;
      }
    }
  }

  return null;
}
