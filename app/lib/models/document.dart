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
  bool get isProcessing => status == 'processing' || status == 'queued';
}

/// Status polling response from GET /api/documents/{id}/status.
class DocumentStatus {
  final String documentId;
  final String status;
  final String stage;
  final String stageLabel;
  final int percent;
  final String? errorCode;
  final String? errorMessage;
  final String? contextStatus;

  const DocumentStatus({
    required this.documentId,
    required this.status,
    required this.stage,
    required this.stageLabel,
    required this.percent,
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
      errorCode: error?['code'] as String?,
      errorMessage: error?['message'] as String?,
      contextStatus: json['context_status'] as String?,
    );
  }

  bool get isReady => status == 'ready';
  bool get isFailed => status == 'failed';
  bool get isUnsupported => status == 'unsupported';
  bool get isDone => isReady || isFailed || isUnsupported;
}

/// A single item in the reader response (reading_chunk or context_card).
class ReaderItem {
  final String type;
  final String id;
  final int? sequence;
  final String? text;
  final String? pageReference;
  final String? sectionTitle;
  // Context card fields (Phase 5)
  final String? insertAfter;
  final String? cardType;
  final String? title;
  final String? body;
  final String? whyHere;
  final String? generationMode;
  final bool? saved;
  final String? exactQuote;
  final String? supportStatus;
  final String? boundaryMethod;
  final List<Map<String, dynamic>>? citations;

  const ReaderItem({
    required this.type,
    required this.id,
    this.sequence,
    this.text,
    this.pageReference,
    this.sectionTitle,
    this.insertAfter,
    this.cardType,
    this.title,
    this.body,
    this.whyHere,
    this.generationMode,
    this.saved,
    this.exactQuote,
    this.supportStatus,
    this.boundaryMethod,
    this.citations,
  });

  bool get isReadingChunk => type == 'reading_chunk';
  bool get isContextCard => type == 'context_card';
  String get rawText => text ?? '';

  ReaderItem copyWith({
    String? type,
    String? id,
    int? sequence,
    String? text,
    String? pageReference,
    String? sectionTitle,
    String? insertAfter,
    String? cardType,
    String? title,
    String? body,
    String? whyHere,
    String? generationMode,
    bool? saved,
    String? exactQuote,
    String? supportStatus,
    String? boundaryMethod,
    List<Map<String, dynamic>>? citations,
  }) {
    return ReaderItem(
      type: type ?? this.type,
      id: id ?? this.id,
      sequence: sequence ?? this.sequence,
      text: text ?? this.text,
      pageReference: pageReference ?? this.pageReference,
      sectionTitle: sectionTitle ?? this.sectionTitle,
      insertAfter: insertAfter ?? this.insertAfter,
      cardType: cardType ?? this.cardType,
      title: title ?? this.title,
      body: body ?? this.body,
      whyHere: whyHere ?? this.whyHere,
      generationMode: generationMode ?? this.generationMode,
      saved: saved ?? this.saved,
      exactQuote: exactQuote ?? this.exactQuote,
      supportStatus: supportStatus ?? this.supportStatus,
      boundaryMethod: boundaryMethod ?? this.boundaryMethod,
      citations: citations ?? this.citations,
    );
  }

  factory ReaderItem.fromJson(Map<String, dynamic> json) {
    return ReaderItem(
      type: json['type']?.toString() ?? 'reading_chunk',
      id: json['id']?.toString() ?? '',
      sequence: (json['sequence'] as num?)?.toInt(),
      text: json['text']?.toString(),
      pageReference: json['page_reference']?.toString(),
      sectionTitle: json['section_title']?.toString(),
      insertAfter: json['insert_after']?.toString(),
      cardType: json['card_type']?.toString(),
      title: json['title']?.toString(),
      body: json['body']?.toString(),
      whyHere: json['why_here']?.toString(),
      generationMode: json['generation_mode']?.toString(),
      saved: json['saved'] as bool?,
      exactQuote: json['exact_quote']?.toString(),
      supportStatus: json['support_status']?.toString(),
      boundaryMethod: json['boundary_method']?.toString(),
      citations: (json['citations'] as List?)
          ?.whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .toList(),
    );
  }
}

/// Reader response from GET /api/documents/{id}/reader.
class ReaderData {
  final String docId;
  final String title;
  final int pageCount;
  final String? layoutWarning;
  final String? contextStatus;
  final bool integrityVerified;
  final String? originalChecksum;
  final String? reconstructedChecksum;
  final int chunkCount;
  final int? currentChunkIndex;
  final String? readingMode;
  final List<ReaderItem> items;

  const ReaderData({
    required this.docId,
    required this.title,
    required this.pageCount,
    this.layoutWarning,
    this.contextStatus,
    required this.integrityVerified,
    this.originalChecksum,
    this.reconstructedChecksum,
    required this.chunkCount,
    this.currentChunkIndex,
    this.readingMode,
    required this.items,
  });

  factory ReaderData.fromJson(Map<String, dynamic> json) {
    final doc = (json['document'] is Map)
        ? (json['document'] as Map).map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final integrity = (doc['integrity'] is Map)
        ? (doc['integrity'] as Map).map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final rawItems = json['items'] as List? ?? [];

    return ReaderData(
      docId: doc['id']?.toString() ?? '',
      title: doc['title']?.toString() ?? '',
      pageCount: (doc['page_count'] as num?)?.toInt() ?? 0,
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
    );
  }
}
