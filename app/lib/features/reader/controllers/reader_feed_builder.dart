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
    final seq = _resolveCardSequence(card, chunkSeqById);
    if (seq != null && seq > 0) {
      cardsBySeq.putIfAbsent(seq, () => []).add(card);
      assignedCardIds.add(card.id);
    }
  }

  // 3b. Process dynamic cards (from SSE/polling)
  for (final entry in dynamicCardsBySeq.entries) {
    final seq = entry.key;
    final card = entry.value;
    if (!assignedCardIds.contains(card.id)) {
      if (seq > 0 && seq <= chunks.length) {
        cardsBySeq.putIfAbsent(seq, () => []).add(card);
        assignedCardIds.add(card.id);
      }
    }
  }

  // 4. Handle UNASSIGNED cards - deterministically attach to prevent orphans
  final unassignedCards = rawCards.where((c) => !assignedCardIds.contains(c.id)).toList();
  for (final entry in dynamicCardsBySeq.entries) {
    if (!assignedCardIds.contains(entry.value.id) && !unassignedCards.any((c) => c.id == entry.value.id)) {
      unassignedCards.add(entry.value);
    }
  }
  int unassignedIdx = 0;

  // 5. Build the interleaved feed
  final feedItems = <ReaderItem>[];

  for (final chunk in chunks) {
    final raw = chunk.rawText;
    final beats = _splitChunkIntoMicroBeats(raw, maxChars: maxCharsPerBeat);

    // Add chunk (or its micro-beats)
    if (beats.length <= 1) {
      feedItems.add(chunk);
    } else {
      for (int bIdx = 0; bIdx < beats.length; bIdx++) {
        feedItems.add(chunk.copyWith(
          id: '${chunk.id}_beat_$bIdx',
          text: beats[bIdx],
          pageReference: chunk.pageReference != null
              ? '${chunk.pageReference} (${bIdx + 1}/${beats.length})'
              : null,
        ));
      }
    }

    final seq = chunk.sequence ?? 0;

    // 5a. Add matched cards for this chunk sequence
    final matchedCards = cardsBySeq[seq];
    if (matchedCards != null && showContextCards) {
      for (final card in matchedCards) {
        if (!dismissedCardIds.contains(card.id)) {
          feedItems.add(card);
        }
      }
    }
    // 5b. If no matched cards, try to place an unassigned card (respecting min gap)
    else if (showContextCards &&
             unassignedIdx < unassignedCards.length &&
             (seq % minChunkGapBetweenCards == 0 || seq == minChunkGapBetweenCards - 1)) {
      final card = unassignedCards[unassignedIdx++];
      if (!dismissedCardIds.contains(card.id)) {
        feedItems.add(card);
      }
    }
  }

  // 5c. Fallback for any remaining unassigned cards: attach so no cards are lost
  if (showContextCards) {
    while (unassignedIdx < unassignedCards.length) {
      final card = unassignedCards[unassignedIdx++];
      if (!dismissedCardIds.contains(card.id) && !feedItems.any((c) => c.id == card.id)) {
        feedItems.add(card);
      }
    }
    for (final entry in cardsBySeq.entries) {
      if (entry.key > chunks.length || entry.key <= 0) {
        for (final card in entry.value) {
          if (!dismissedCardIds.contains(card.id) && !feedItems.any((c) => c.id == card.id)) {
            feedItems.add(card);
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
int? _resolveCardSequence(ReaderItem card, Map<String, int> chunkSeqById) {
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

  return null;
}

/// Split a chunk's text into micro-beats for Feed Mode (vertical page-snapping)
///
/// Each beat <= maxChars characters, split at sentence boundaries when possible.
/// This ensures one vertical swipe = one readable page in Feed Mode.
List<String> _splitChunkIntoMicroBeats(String text, {int maxChars = 380}) {
  if (text.length <= maxChars) return [text];

  final sentences = text.split(RegExp(r'(?<=[.!?])\s+'));

  // If only one sentence or no sentence boundaries, hard-split by words
  if (sentences.length <= 1) {
    final words = text.split(RegExp(r'\s+'));
    final parts = <String>[];
    var current = StringBuffer();
    for (final w in words) {
      if (current.isNotEmpty && current.length + w.length + 1 > maxChars) {
        parts.add(current.toString().trim());
        current = StringBuffer();
      }
      if (current.isNotEmpty) current.write(' ');
      current.write(w);
    }
    if (current.isNotEmpty) parts.add(current.toString().trim());
    return parts.isNotEmpty ? parts : [text];
  }

  // Split at sentence boundaries
  final beats = <String>[];
  var currentBeat = StringBuffer();
  for (final s in sentences) {
    final trimmed = s.trim();
    if (trimmed.isEmpty) continue;
    if (currentBeat.isNotEmpty && currentBeat.length + trimmed.length + 1 > maxChars) {
      beats.add(currentBeat.toString().trim());
      currentBeat = StringBuffer();
    }
    if (currentBeat.isNotEmpty) currentBeat.write(' ');
    currentBeat.write(trimmed);
  }
  if (currentBeat.isNotEmpty) {
    // Merge tiny trailing beat into previous
    if (beats.isNotEmpty && currentBeat.length < 80 &&
        (beats.last.length + currentBeat.length + 1) <= maxChars + 60) {
      beats[beats.length - 1] = '${beats.last} ${currentBeat.toString().trim()}';
    } else {
      beats.add(currentBeat.toString().trim());
    }
  }
  return beats.isNotEmpty ? beats : [text];
}
