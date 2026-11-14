/// Document data model with hand-written fromJson (no freezed/build_runner per §4).
class Document {
  final String id;
  final String title;
  final String filename;
  final String status;
  final String? stage;
  final String? stageLabel;
  final int? percent;
  final int pageCount;
  final String? layoutWarning;
  final String? contextStatus;
  final String? errorCode;
  final String? errorMessage;
  final String createdAt;
  final String updatedAt;

  const Document({
    required this.id,
    required this.title,
    required this.filename,
    required this.status,
    this.stage,
    this.stageLabel,
    this.percent,
    required this.pageCount,
    this.layoutWarning,
    this.contextStatus,
    this.errorCode,
    this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Document.fromJson(Map<String, dynamic> json) {
    return Document(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? json['filename'] as String? ?? '',
      filename: json['filename'] as String? ?? '',
      status: json['status'] as String? ?? 'queued',
      stage: json['stage'] as String?,
      stageLabel: json['stage_label'] as String?,
      percent: json['percent'] as int?,
      pageCount: json['page_count'] as int? ?? 0,
      layoutWarning: json['layout_warning'] as String?,
      contextStatus: json['context_status'] as String?,
      errorCode: json['error_code'] as String?,
      errorMessage: json['error_message'] as String?,
      createdAt: json['created_at'] as String? ?? '',
      updatedAt: json['updated_at'] as String? ?? '',
    );
  }

  bool get isReady => status == 'ready';
  bool get isFailed => status == 'failed';
  bool get isUnsupported => status == 'unsupported';
  bool get isPartiallyReadable => status == 'partially_readable';
  bool get isPaused => status == 'paused';
  bool get isInterrupted => status == 'interrupted';
  bool get isReadable => status == 'ready' || status == 'partially_readable';
  bool get isProcessing => status == 'processing' || status == 'queued' || status == 'partially_readable';
}

/// Status polling response from GET /api/documents/{id}/status.
class DocumentStatus {
  final String documentId;
  final String status;
  final String stage;
  final String stageLabel;
  final int percent;
  final int processedPage;
  final int lastCheckpointPage;
  final int pageCount;
  final String? errorCode;
  final String? errorMessage;
  final String? contextStatus;

  const DocumentStatus({
    required this.documentId,
    required this.status,
    required this.stage,
    required this.stageLabel,
    required this.percent,
    this.processedPage = 0,
    this.lastCheckpointPage = 0,
    this.pageCount = 0,
    this.errorCode,
    this.errorMessage,
    this.contextStatus,
  });

  factory DocumentStatus.fromJson(Map<String, dynamic> json) {
    final error = json['error'] as Map<String, dynamic>?;
    return DocumentStatus(
      documentId: json['document_id'] as String? ?? '',
      status: json['status'] as String? ?? 'queued',
      stage: json['stage'] as String? ?? 'validating',
      stageLabel: json['stage_label'] as String? ?? 'Processing...',
      percent: json['percent'] as int? ?? 0,
      processedPage: (json['processed_page'] as num?)?.toInt() ?? 0,
      lastCheckpointPage: (json['last_checkpoint_page'] as num?)?.toInt() ?? 0,
      pageCount: (json['page_count'] as num?)?.toInt() ?? 0,
      errorCode: error?['code'] as String?,
      errorMessage: error?['message'] as String?,
      contextStatus: json['context_status'] as String?,
    );
  }

  bool get isReady => status == 'ready';
  bool get isFailed => status == 'failed';
  bool get isUnsupported => status == 'unsupported';
  bool get isPartiallyReadable => status == 'partially_readable';
  bool get isPaused => status == 'paused';
  bool get isInterrupted => status == 'interrupted';
  bool get isReadable => status == 'ready' || status == 'partially_readable';
  bool get isDone =>
      isReady || isFailed || isUnsupported || isPaused || isInterrupted;
}

/// A single item in the reader response (reading_chunk or context_card).
class ReaderItem {
  final String type;
  final String id;
  final int? sequence;
  final String? text;
  final String? pageReference;
  final String? sectionTitle;
  final String? sectionRole;
  // Context card fields (Phase 5)
  final String? insertAfter;
  final String? sourceChunkId;
  final String? cardType;
  final String? title;
  final String? body;
  final String? whyHere;
  final String? generationMode;
  final bool? saved;
  final String? exactQuote;
  final String? supportStatus;
  final String? supportTier;
  final String? boundaryMethod;
  final List<Map<String, dynamic>>? citations;
  final bool isSpeculativeDraft;
  final bool? verified;

  const ReaderItem({
    required this.type,
    required this.id,
    this.sequence,
    this.text,
    this.pageReference,
    this.sectionTitle,
    this.sectionRole,
    this.insertAfter,
    this.sourceChunkId,
    this.cardType,
    this.title,
    this.body,
    this.whyHere,
    this.generationMode,
    this.saved,
    this.exactQuote,
    this.supportStatus,
    this.supportTier,
    this.boundaryMethod,
    this.citations,
    this.isSpeculativeDraft = false,
    this.verified,
  });

  bool get isReadingChunk => type == 'reading_chunk';
  bool get isContextCard => type == 'context_card';
  String get rawText => text ?? '';
  bool get isVerified => verified == true || supportStatus == 'verified';
  bool get isVerifiedExternal =>
      supportTier == 'verified_external' || (isVerified && supportTier != 'single_source' && supportTier != 'internal_extractive');
  bool get isSingleSource => supportTier == 'single_source';
  bool get isInternalExtractive => supportTier == 'internal_extractive';
  String get sourceUrl {
    if (citations != null && citations!.isNotEmpty) {
      return (citations!.first['url'] ?? '').toString();
    }
    return '';
  }

  ReaderItem copyWith({
    String? type,
    String? id,
    int? sequence,
    String? text,
    String? pageReference,
    String? sectionTitle,
    String? sectionRole,
    String? insertAfter,
    String? sourceChunkId,
    String? cardType,
    String? title,
    String? body,
    String? whyHere,
    String? generationMode,
    bool? saved,
    String? exactQuote,
    String? supportStatus,
    String? supportTier,
    String? boundaryMethod,
    List<Map<String, dynamic>>? citations,
    bool? isSpeculativeDraft,
    bool? verified,
  }) {
    return ReaderItem(
      type: type ?? this.type,
      id: id ?? this.id,
      sequence: sequence ?? this.sequence,
      text: text ?? this.text,
      pageReference: pageReference ?? this.pageReference,
      sectionTitle: sectionTitle ?? this.sectionTitle,
      sectionRole: sectionRole ?? this.sectionRole,
      insertAfter: insertAfter ?? this.insertAfter,
      sourceChunkId: sourceChunkId ?? this.sourceChunkId,
      cardType: cardType ?? this.cardType,
      title: title ?? this.title,
      body: body ?? this.body,
      whyHere: whyHere ?? this.whyHere,
      generationMode: generationMode ?? this.generationMode,
      saved: saved ?? this.saved,
      exactQuote: exactQuote ?? this.exactQuote,
      supportStatus: supportStatus ?? this.supportStatus,
      supportTier: supportTier ?? this.supportTier,
      boundaryMethod: boundaryMethod ?? this.boundaryMethod,
      citations: citations ?? this.citations,
      isSpeculativeDraft: isSpeculativeDraft ?? this.isSpeculativeDraft,
      verified: verified ?? this.verified,
    );
  }

  factory ReaderItem.fromJson(Map<String, dynamic> json) {
    final insertAfter = (json['insert_after'] ?? json['source_chunk_id'])?.toString();
    final sourceChunkId = (json['source_chunk_id'] ?? json['insert_after'])?.toString();
    return ReaderItem(
      type: json['type']?.toString() ?? 'reading_chunk',
      id: json['id']?.toString() ?? '',
      sequence: (json['sequence'] as num?)?.toInt(),
      text: json['text']?.toString(),
      pageReference: json['page_reference']?.toString(),
      sectionTitle: json['section_title']?.toString(),
      sectionRole: json['section_role']?.toString() ?? json['sectionRole']?.toString(),
      insertAfter: insertAfter,
      sourceChunkId: sourceChunkId,
      cardType: json['card_type']?.toString(),
      title: json['title']?.toString(),
      body: json['body']?.toString(),
      whyHere: json['why_here']?.toString(),
      generationMode: json['generation_mode']?.toString(),
      saved: json['saved'] == true || json['saved'] == 1,
      exactQuote: json['exact_quote']?.toString(),
      supportStatus: json['support_status']?.toString(),
      supportTier: json['support_tier']?.toString() ?? json['supportTier']?.toString(),
      boundaryMethod: json['boundary_method']?.toString(),
      isSpeculativeDraft: json['is_speculative_draft'] == true ||
          json['isSpeculativeDraft'] == true ||
          json['generation_mode'] == 'speculative_draft',
      verified: json['verified'] == 1 ||
          json['verified'] == true ||
          json['support_status'] == 'verified',
      citations: (json['citations'] as List?)
          ?.whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .toList(),
    );
  }
}

/// Explicit Reader viewport load state to prevent infinite spinners on empty/failed books.
enum ReaderLoadState {
  loading,
  empty,
  error,
  ready,
}

/// Reader response from GET /api/documents/{id}/reader.
class ReaderData {
  final String docId;
  final String title;
  final String status;
  final int pageCount;
  final int? processedPages;
  final String? layoutWarning;
  final String? contextStatus;
  final bool integrityVerified;
  final String? originalChecksum;
  final String? reconstructedChecksum;
  final int chunkCount;
  final int? currentChunkIndex;
  final String? readingMode;
  final List<ReaderItem> items;
  final List<ReaderItem> cards;
  final Map<String, Map<String, dynamic>> chunkEditsMap;

  const ReaderData({
    required this.docId,
    required this.title,
    this.status = 'ready',
    required this.pageCount,
    this.processedPages,
    this.layoutWarning,
    this.contextStatus,
    required this.integrityVerified,
    this.originalChecksum,
    this.reconstructedChecksum,
    required this.chunkCount,
    this.currentChunkIndex,
    this.readingMode,
    required this.items,
    this.cards = const [],
    this.chunkEditsMap = const {},
  });

  ReaderData copyWith({
    String? docId,
    String? title,
    String? status,
    int? pageCount,
    int? processedPages,
    String? layoutWarning,
    String? contextStatus,
    bool? integrityVerified,
    String? originalChecksum,
    String? reconstructedChecksum,
    int? chunkCount,
    int? currentChunkIndex,
    String? readingMode,
    List<ReaderItem>? items,
    List<ReaderItem>? cards,
    Map<String, Map<String, dynamic>>? chunkEditsMap,
  }) {
    return ReaderData(
      docId: docId ?? this.docId,
      title: title ?? this.title,
      status: status ?? this.status,
      pageCount: pageCount ?? this.pageCount,
      processedPages: processedPages ?? this.processedPages,
      layoutWarning: layoutWarning ?? this.layoutWarning,
      contextStatus: contextStatus ?? this.contextStatus,
      integrityVerified: integrityVerified ?? this.integrityVerified,
      originalChecksum: originalChecksum ?? this.originalChecksum,
      reconstructedChecksum: reconstructedChecksum ?? this.reconstructedChecksum,
      chunkCount: chunkCount ?? this.chunkCount,
      currentChunkIndex: currentChunkIndex ?? this.currentChunkIndex,
      readingMode: readingMode ?? this.readingMode,
      items: items ?? this.items,
      cards: cards ?? this.cards,
      chunkEditsMap: chunkEditsMap ?? this.chunkEditsMap,
    );
  }

  factory ReaderData.fromJson(Map<String, dynamic> json) {
    final doc = (json['document'] is Map)
        ? (json['document'] as Map).map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final integrity = (doc['integrity'] is Map)
        ? (doc['integrity'] as Map).map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final rawItems = json['items'] as List? ?? [];
    final rawCards = json['cards'] as List? ?? [];
    final rawEdits = json['chunk_edits'] as Map? ?? {};
    final chunkEditsMap = <String, Map<String, dynamic>>{};
    for (final entry in rawEdits.entries) {
      if (entry.value is Map) {
        chunkEditsMap[entry.key.toString()] =
            Map<String, dynamic>.from(entry.value as Map);
      }
    }

    return ReaderData(
      docId: doc['id']?.toString() ?? '',
      title: doc['title']?.toString() ?? '',
      status: doc['status']?.toString() ?? 'ready',
      pageCount: (doc['page_count'] as num?)?.toInt() ?? 0,
      processedPages: (doc['processed_pages'] as num?)?.toInt() ??
          (doc['processed_page'] as num?)?.toInt(),
      layoutWarning: doc['layout_warning']?.toString(),
      contextStatus: doc['context_status']?.toString(),
      integrityVerified: integrity['verified'] as bool? ?? false,
      originalChecksum: integrity['original_checksum']?.toString(),
      reconstructedChecksum: integrity['reconstructed_checksum']?.toString(),
      chunkCount: (integrity['chunk_count'] as num?)?.toInt() ?? 0,
      currentChunkIndex: (doc['current_chunk_index'] as num?)?.toInt(),
      readingMode: doc['reading_mode']?.toString(),
      items: rawItems
          .whereType<Map>()
          .map((e) =>
              ReaderItem.fromJson(e.map((k, v) => MapEntry(k.toString(), v))))
          .toList(),
      cards: rawCards
          .whereType<Map>()
          .map((e) =>
              ReaderItem.fromJson(e.map((k, v) => MapEntry(k.toString(), v))))
          .toList(),
      chunkEditsMap: chunkEditsMap,
    );
  }
}
