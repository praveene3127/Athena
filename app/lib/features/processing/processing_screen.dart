import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/config.dart';
import '../../core/theme.dart';
import '../../core/errors.dart';
import '../../models/document.dart';
import '../../widgets/athena_avatar.dart';
import '../library/library_screen.dart';

class StageInfo {
  final String key;
  final String title;
  final String description;
  final IconData icon;

  const StageInfo({
    required this.key,
    required this.title,
    required this.description,
    required this.icon,
  });
}

const _stageDetails = [
  StageInfo(
    key: 'validating',
    title: 'Reading & Validating PDF',
    description: 'Scanning header bytes, page structure & size constraints',
    icon: Icons.picture_as_pdf_rounded,
  ),
  StageInfo(
    key: 'extracting',
    title: 'Extracting Raw Text',
    description: 'Parsing deterministic text blocks and character streams',
    icon: Icons.text_snippet_rounded,
  ),
  StageInfo(
    key: 'cleaning',
    title: 'Preserving Document Order',
    description:
        'Normalizing whitespace and multi-column flow without text loss',
    icon: Icons.format_align_left_rounded,
  ),
  StageInfo(
    key: 'chunking',
    title: 'Creating Reading Chunks',
    description: 'Slicing contiguous character offsets with zero omitted text',
    icon: Icons.view_headline_rounded,
  ),
  StageInfo(
    key: 'verifying',
    title: 'Verifying Text Preservation',
    description:
        'Checking that every extracted character is preserved in order',
    icon: Icons.verified_user_rounded,
  ),
  StageInfo(
    key: 'finding_concepts',
    title: 'Extracting Key Concepts',
    description: 'Identifying technical terms and acronyms across passages',
    icon: Icons.psychology_rounded,
  ),
  StageInfo(
    key: 'preparing_context',
    title: 'Preparing Grounded Context',
    description: 'Retrieving authoritative explanations with distance spacing',
    icon: Icons.auto_awesome_rounded,
  ),
  StageInfo(
    key: 'done',
    title: 'Ready to Read',
    description: 'Source text preserved verbatim. Context cards active.',
    icon: Icons.menu_book_rounded,
  ),
];

class ProcessingScreen extends ConsumerStatefulWidget {
  final String documentId;
  const ProcessingScreen({super.key, required this.documentId});

  @override
  ConsumerState<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends ConsumerState<ProcessingScreen>
    with WidgetsBindingObserver {
  Timer? _pollTimer;
  DocumentStatus? _status;
  bool _backendUnreachable = false;
  bool _isRetrying = false;
  bool _pollInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    ref.invalidate(documentsProvider);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPolling();
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _poll();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: AppConfig.statusPollMs),
      (_) => _poll(),
    );
  }

  Future<void> _poll() async {
    if (_pollInFlight) return;
    _pollInFlight = true;
    try {
      final client = ref.read(apiClientProvider);
      final data = await client.getDocumentStatus(widget.documentId);
      final status = DocumentStatus.fromJson(data);
      if (mounted) {
        setState(() {
          _status = status;
          _backendUnreachable = false;
        });

        if (status.isDone) {
          _pollTimer?.cancel();
        }
      }
    } on AppError catch (_) {
      if (mounted) {
        setState(() => _backendUnreachable = true);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _backendUnreachable = true);
      }
    } finally {
      _pollInFlight = false;
    }
  }

  Future<void> _retry() async {
    setState(() => _isRetrying = true);
    try {
      final client = ref.read(apiClientProvider);
      await client.retryDocument(widget.documentId);
      _pollTimer?.cancel();
      _startPolling();
    } on AppError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: Colors.redAccent),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Could not retry this book. Check the backend and try again.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isRetrying = false);
    }
  }

  Future<void> _forceIngest() async {
    setState(() => _isRetrying = true);
    try {
      final client = ref.read(apiClientProvider);
      await client.forceIngestDocument(widget.documentId);
      _pollTimer?.cancel();
      _startPolling();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not start raw processing. Please try again.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isRetrying = false);
    }
  }

  Future<void> _removeDocument() async {
    try {
      final client = ref.read(apiClientProvider);
      await client.deleteDocument(widget.documentId);
      if (mounted) context.go('/');
    } catch (_) {
      if (mounted) context.go('/');
    }
  }

  int _currentStageIndex() {
    final stage = _status?.stage ?? 'validating';
    final idx = _stageDetails.indexWhere((s) => s.key == stage);
    return idx >= 0 ? idx : 0;
  }

  @override
  Widget build(BuildContext context) {
    final stageIdx = _currentStageIndex();
    final percent = _status?.percent ?? 0;
    final isReady = (_status?.isReady ?? false) && percent >= 100;
    final isDone = isReady;
    final isFailed = _status?.isFailed ?? false;
    final isUnsupported = _status?.isUnsupported ?? false;

    if (isUnsupported && _status != null) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          backgroundColor: AppTheme.background,
          elevation: 0,
          leading: Container(
            margin: const EdgeInsets.only(left: 16),
            child: IconButton(
              icon: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppTheme.border),
                ),
                child: const Icon(Icons.arrow_back_rounded,
                    color: AppTheme.textPrimary, size: 20),
              ),
              onPressed: () => context.go('/'),
            ),
          ),
          title: const Text(
            'Document Admission',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
        ),
        body: SafeArea(
          child: _buildUnsupportedState(_status!),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        elevation: 0,
        leading: Container(
          margin: const EdgeInsets.only(left: 16),
          child: IconButton(
            icon: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppTheme.surface,
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.border),
              ),
              child: const Icon(Icons.arrow_back_rounded,
                  color: AppTheme.textPrimary, size: 20),
            ),
            onPressed: () => context.go('/'),
          ),
        ),
        title: const Text(
          'Processing Paper',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Column(
                children: [
                  // --- Backend Unreachable Warning ---
                  if (_backendUnreachable)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withValues(alpha: 0.1),
                        border: Border.all(color: Colors.redAccent, width: 1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.cloud_off_rounded,
                              color: Colors.redAccent, size: 20),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              "Checking local PDF processing...",
                              style: TextStyle(
                                  color: Colors.redAccent,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                          TextButton(
                            onPressed: _poll,
                            style: TextButton.styleFrom(
                                foregroundColor: AppTheme.figmaBlack),
                            child: const Text('Retry',
                                style: TextStyle(fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ),
                    ),

                  // --- Double-Bezel Hero Card ---
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF7F6F2),
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: const Color(0xFFE5E7DC)),
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: const Color(0xFFECEEE4)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              AthenaAvatar(
                                expression: isDone
                                    ? AthenaExpression.happy
                                    : isFailed
                                        ? AthenaExpression.surprised
                                        : AthenaExpression.thinking,
                                size: 38,
                                isBreathing: !isDone && !isFailed,
                                showBezel: true,
                              ),
                              const SizedBox(width: 14),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'ATHENA INGESTION ENGINE',
                                      style: TextStyle(
                                        color: Color(0xFF005E54),
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 1.1,
                                      ),
                                    ),
                                    SizedBox(height: 2),
                                    Text(
                                      'Fidelity & Context Preservation',
                                      style: TextStyle(
                                        color: Color(0xFF888888),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                '$percent%',
                                style: const TextStyle(
                                  fontFamily: 'DM Serif Display',
                                  color: Color(0xFF141714),
                                  fontSize: 26,
                                  letterSpacing: -0.5,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: LinearProgressIndicator(
                              value: percent / 100.0,
                              backgroundColor: const Color(0xFFECEEE4),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                isFailed
                                    ? Colors.redAccent
                                    : const Color(0xFF005E54),
                              ),
                              minHeight: 8,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            isDone
                                ? 'Your paper is ready to read.'
                                : isFailed
                                    ? 'Could not finish processing this paper.'
                                    : _stageDetails[stageIdx].title,
                            style: const TextStyle(
                              fontFamily: 'DM Serif Display',
                              color: Color(0xFF141714),
                              fontSize: 21,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            isDone
                                ? 'Original text kept intact verbatim. Grounded context cards are active.'
                                : isFailed
                                    ? (_status?.errorMessage ??
                                        'An error occurred during extraction.')
                                    : 'Preserving verbatim source text without hallucinated summaries.',
                            style: const TextStyle(
                              color: Color(0xFF666666),
                              fontSize: 12.5,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  // --- Stages List ---
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.only(top: 6, bottom: 16),
                      itemCount: _stageDetails.length,
                      itemBuilder: (ctx, i) {
                        final stage = _stageDetails[i];
                        final isActive = i == stageIdx && !isDone && !isFailed;
                        final isComplete = isReady || (!isDone && i < stageIdx);
                        final isFailedHere = i == stageIdx && isFailed;

                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                          decoration: BoxDecoration(
                            color: isActive
                                ? AppTheme.surface
                                : (isComplete
                                    ? AppTheme.surface
                                    : AppTheme.surface.withValues(alpha: 0.65)),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: isActive
                                  ? AppTheme.figmaBlack
                                  : (isComplete
                                      ? AppTheme.lime.withValues(alpha: 0.5)
                                      : AppTheme.border),
                              width: isActive ? 1.5 : 1,
                            ),
                            boxShadow: isActive
                                ? [
                                    BoxShadow(
                                      color:
                                          Colors.black.withValues(alpha: 0.06),
                                      blurRadius: 12,
                                      offset: const Offset(0, 4),
                                    ),
                                  ]
                                : null,
                          ),
                          child: Row(
                            children: [
                              // Status icon badge: Lime tick for complete, spinner for active, circle for pending
                              if (isComplete)
                                Container(
                                  width: 32,
                                  height: 32,
                                  decoration: const BoxDecoration(
                                    color: AppTheme.lime,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.check_rounded,
                                    color: AppTheme.figmaBlack,
                                    size: 20,
                                  ),
                                )
                              else if (isActive)
                                Container(
                                  width: 32,
                                  height: 32,
                                  padding: const EdgeInsets.all(6),
                                  decoration: const BoxDecoration(
                                    color: AppTheme.figmaBlack,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                        AppTheme.lime),
                                  ),
                                )
                              else if (isFailedHere)
                                Container(
                                  width: 32,
                                  height: 32,
                                  decoration: const BoxDecoration(
                                    color: Colors.redAccent,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.close_rounded,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                                )
                              else
                                Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: AppTheme.textMuted
                                          .withValues(alpha: 0.4),
                                      width: 1.5,
                                    ),
                                  ),
                                  child: Icon(
                                    stage.icon,
                                    size: 16,
                                    color: AppTheme.textMuted
                                        .withValues(alpha: 0.4),
                                  ),
                                ),

                              const SizedBox(width: 14),

                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      stage.title,
                                      style: TextStyle(
                                        color: isComplete || isActive
                                            ? AppTheme.textPrimary
                                            : AppTheme.textMuted,
                                        fontSize: 14,
                                        fontWeight: isActive
                                            ? FontWeight.w800
                                            : (isComplete
                                                ? FontWeight.w700
                                                : FontWeight.w500),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      stage.description,
                                      style: TextStyle(
                                        color: isActive
                                            ? AppTheme.textPrimary
                                                .withValues(alpha: 0.8)
                                            : AppTheme.textMuted,
                                        fontSize: 11,
                                        height: 1.3,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Trailing status tag
                              if (isComplete)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color:
                                        AppTheme.lime.withValues(alpha: 0.25),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Text(
                                    'Done',
                                    style: TextStyle(
                                      color: AppTheme.figmaBlack,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                )
                              else if (isActive)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: AppTheme.figmaBlack,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Text(
                                    'Working',
                                    style: TextStyle(
                                      color: AppTheme.lime,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                )
                              else if (isFailedHere)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.redAccent
                                        .withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Text(
                                    'Failed',
                                    style: TextStyle(
                                      color: Colors.redAccent,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),

                  // --- Bottom Action Button ---
                  const SizedBox(height: 14),
                  if (isDone)
                    InkWell(
                      onTap: () => context.go('/reader/${widget.documentId}'),
                      borderRadius: BorderRadius.circular(28),
                      child: Container(
                        width: double.infinity,
                        height: 54,
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        decoration: BoxDecoration(
                          color: const Color(0xFF005E54),
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF005E54)
                                  .withValues(alpha: 0.22),
                              blurRadius: 14,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text(
                              'Open in Reader',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.2,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.2),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.arrow_forward_rounded,
                                size: 16,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else if (isFailed)
                    InkWell(
                      onTap: _isRetrying ? null : _retry,
                      borderRadius: BorderRadius.circular(28),
                      child: Container(
                        width: double.infinity,
                        height: 54,
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        decoration: BoxDecoration(
                          color: const Color(0xFF141714),
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.15),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              _isRetrying
                                  ? 'Retrying Processing…'
                                  : 'Retry Processing',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.15),
                                shape: BoxShape.circle,
                              ),
                              child: _isRetrying
                                  ? const Padding(
                                      padding: EdgeInsets.all(6),
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                                Colors.white),
                                      ),
                                    )
                                  : const Icon(
                                      Icons.refresh_rounded,
                                      size: 16,
                                      color: Colors.white,
                                    ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7F6F2),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: const Color(0xFFE5E7DC)),
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            vertical: 12, horizontal: 14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFECEEE4)),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.shield_outlined,
                                color: Color(0xFF005E54), size: 18),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Local Device Processing · Zero third-party telemetry. Background tasks automatically resume from last saved offset.',
                                style: TextStyle(
                                  color: Color(0xFF666666),
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w500,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUnsupportedState(DocumentStatus status) {
    String displayLabel = 'Out of Scope Document';
    String reason =
        'Athena is built for continuous long-form reading (books, essays, and research papers). Slide decks, invoices, resumes, and forms do not have the narrative flow needed for deep reading.';
    final rawMsg = status.errorMessage ?? '';
    if (rawMsg.contains('||')) {
      final parts = rawMsg.split('||');
      if (parts[0].trim().isNotEmpty) displayLabel = parts[0].trim();
      if (parts.length > 1 && parts[1].trim().isNotEmpty) {
        reason = parts[1].trim();
      }
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: const Color(0xFFFCFBF7),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppTheme.figmaBlack, width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Kicker badge
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: AppTheme.figmaBlack,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'NOT A LONG-FORM READING DOCUMENT',
                  style: TextStyle(
                    color: Color(0xFFFCFBF7),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              // Headline
              Text(
                'Detected: $displayLabel',
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 12),
              // Body
              Text(
                reason,
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 14.5,
                  height: 1.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 28),
              // Primary Dark Button (#141714): Remove from Library
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: _removeDocument,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.figmaBlack,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text(
                    'Remove from Library',
                    style:
                        TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // Secondary Text Button: Process Anyway
              Center(
                child: TextButton.icon(
                  onPressed: _isRetrying ? null : _forceIngest,
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.textPrimary,
                  ),
                  icon: _isRetrying
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppTheme.figmaBlack),
                        )
                      : const Icon(Icons.lock_open_rounded, size: 16),
                  label: Text(
                    _isRetrying
                        ? 'Processing anyway…'
                        : 'Process Anyway (Open Raw View)',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.underline,
                    ),
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
