import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:url_launcher/url_launcher.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/core/theme/reader_theme.dart';
import 'package:athena/models/document.dart';
import 'package:athena/services/local_database.dart';
import 'package:athena/core/widgets/athena_avatar.dart';
import 'package:athena/core/widgets/athena_logo.dart';

/// Context card widget per CLAUDE.md §11 & §7.3.
/// High-end editorial marginalia card using Double-Bezel nested architecture,
/// squircle curvature, and tactile interactive controls.
class ContextCardWidget extends StatefulWidget {
  final String documentId;
  final ValueChanged<String>? onJumpToPassage;
  final ReaderItem card;
  final VoidCallback onToggleSave;
  final VoidCallback onDismiss;
  final VoidCallback? onAskAthena;
  final bool isFeedMode;
  final bool isBrainDeckSaved;
  final VoidCallback? onToggleBrainDeck;
  final String themeId;

  const ContextCardWidget({
    super.key,
    this.documentId = '',
    this.onJumpToPassage,
    required this.card,
    required this.onToggleSave,
    required this.onDismiss,
    this.onAskAthena,
    this.isFeedMode = false,
    this.isBrainDeckSaved = false,
    this.onToggleBrainDeck,
    this.themeId = 'paper',
  });

  @override
  State<ContextCardWidget> createState() => _ContextCardWidgetState();
}

class _ContextCardWidgetState extends State<ContextCardWidget> {
  bool _betRevealed = false;
  List<Map<String, dynamic>> _relatedPassages = const [];

  @override
  void initState() {
    super.initState();
    _loadRelatedPassages();
  }

  Future<void> _loadRelatedPassages() async {
    final sourceId = widget.card.sourceChunkId;
    if (kIsWeb ||
        widget.documentId.isEmpty ||
        sourceId == null ||
        sourceId.isEmpty) {
      return;
    }
    try {
      final related = await LocalDatabase.instance.findRelatedPassages(
        widget.documentId,
        sourceId,
        topK: 3,
      );
      if (mounted) setState(() => _relatedPassages = related);
    } catch (e) {
      debugPrint('Athena related passage lookup notice: $e');
    }
  }

  @override
  void didUpdateWidget(ContextCardWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.card.id != widget.card.id) {
      _betRevealed = false;
      _relatedPassages = const [];
      _loadRelatedPassages();
    }
  }

  static String _stripEmojis(String text) {
    if (text.isEmpty) return text;
    final cleaned = text
        .replaceAll(
          RegExp(
              r'[\u{1F000}-\u{1FFFF}\u{2300}-\u{27BF}\u{2B50}\u{FE00}-\u{FE0F}]',
              unicode: true),
          '',
        )
        .trim();
    return cleaned.replaceFirst(RegExp(r'^[:\-\s]+'), '').trim();
  }

  static String _cleanCardTitle(String rawTitle) {
    var t = _stripEmojis(rawTitle).trim();
    final prefixRegex = RegExp(
      r'^(?:Context\s*:\s*|UNHINGED\s+BACKSTORY\s*:\s*|EMPIRICAL\s+STUDY\s*:\s*|CRITICAL\s+DEBATE\s*:\s*|HISTORICAL\s+CONTEXT\s*:\s*|CORE\s+PARADOX\s*:\s*|BET\s+THE\s+OUTCOME\s*:\s*|MARGIN\s+BEEF\s*:\s*|LEGENDARY\s+PARADOX\s*:\s*|RABBIT\s+HOLE\s*:\s*|COUNTER[\s\-]LENS\s*:\s*|EMPIRICAL\s+LAB\s+FILE\s*:\s*|PHILOSOPHICAL\s+LINEAGE\s*:\s*|GROUNDED\s+CONTEXT\s*:\s*)+',
      caseSensitive: false,
    );
    while (prefixRegex.hasMatch(t)) {
      t = t.replaceFirst(prefixRegex, '').trim();
    }
    t = _stripEmojis(t).trim();
    t = t.replaceFirst(RegExp(r'^[:\-\s]+'), '').trim();
    return t.isEmpty ? 'Context' : t;
  }

  static ({String label, IconData icon, Color color}) _resolveLens(
    String title,
    String? whyHere,
    String body,
  ) {
    final cleanTitle = _stripEmojis(title);
    final combined = '$cleanTitle ${whyHere ?? ''} $body'.toUpperCase();
    if (combined.contains('EMPIRICAL STUDY') ||
        combined.contains('BET THE OUTCOME') ||
        combined.contains('GUESS THE OUTCOME') ||
        combined.contains('||REVEAL||') ||
        combined.contains('LAB FILE') ||
        combined.contains('STUDY') ||
        combined.contains('EXPERIMENT')) {
      return (
        label: 'EMPIRICAL STUDY',
        icon: Icons.science_outlined,
        color: const Color(0xFF2D6A4F), // Emerald #2D6A4F
      );
    }
    if (combined.contains('CRITICAL DEBATE') ||
        combined.contains('MARGIN BEEF') ||
        combined.contains('@THEPUSHBACK') ||
        combined.contains('COUNTERPOINT:') ||
        combined.contains('COUNTER-LENS') ||
        combined.contains('DEBATE')) {
      return (
        label: 'CRITICAL DEBATE',
        icon: Icons.balance_outlined,
        color: const Color(0xFFC84B31), // Terracotta #C84B31
      );
    }
    if (combined.contains('CORE PARADOX') ||
        combined.contains('LEGENDARY PARADOX') ||
        combined.contains('MIND-BLENDER PARADOX') ||
        combined.contains('PARADOX')) {
      return (
        label: 'CORE PARADOX',
        icon: Icons.auto_awesome_outlined,
        color: const Color(0xFFB45309), // Ochre #B45309
      );
    }
    if (combined.contains('HISTORICAL CONTEXT') ||
        combined.contains('UNHINGED BACKSTORY') ||
        combined.contains('PHILOSOPHICAL LINEAGE') ||
        combined.contains('RABBIT HOLE') ||
        combined.contains('BACKSTORY') ||
        combined.contains('HISTORY') ||
        combined.contains('BIOGRAPHY')) {
      return (
        label: 'HISTORICAL CONTEXT',
        icon: Icons.history_edu_outlined,
        color: const Color(0xFF1D3557), // Navy #1D3557
      );
    }
    return (
      label: 'GROUNDED CONTEXT',
      icon: Icons.menu_book_outlined,
      color: const Color(0xFF005E54), // Botanical Teal
    );
  }

  Future<void> _openSourceUrl(String? url) async {
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _showCitationPreview(BuildContext context, Map<String, dynamic> cite,
      ReaderThemeConfig theme) {
    final cUrl = cite['url'] as String? ?? '';
    final cTitle = cite['title'] as String? ?? 'Verified Citation';
    final cPub =
        (cite['publisher'] as String? ?? cite['title'] as String? ?? 'Source')
            .trim();
    final snippet = cite['snippet'] as String? ??
        'Primary source attribution grounded against published literature and external knowledge.';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.scaffoldBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 18),
                    decoration: BoxDecoration(
                      color: theme.borderColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: theme.pillBackground,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: theme.borderColor),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.verified,
                              size: 14, color: theme.accentColor),
                          const SizedBox(width: 5),
                          Text(
                            cPub.toUpperCase(),
                            style: TextStyle(
                              fontFamily: AppTheme.fontUI,
                              color: theme.accentColor,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(Icons.close_rounded,
                          size: 20, color: theme.textMutedColor),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  cTitle,
                  style: TextStyle(
                    fontFamily: AppTheme.fontDisplay,
                    color: theme.textColor,
                    fontSize: 18,
                    fontWeight: FontWeight.w400,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.innerCardColor,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: theme.borderColor),
                  ),
                  child: Text(
                    snippet,
                    style: TextStyle(
                      fontFamily: AppTheme.fontReading,
                      color: theme.isDark
                          ? const Color(0xFFD1D5DB)
                          : const Color(0xFF4A4F48),
                      fontSize: 13.5,
                      height: 1.45,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _openSourceUrl(cUrl);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: theme.accentColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                      elevation: 0,
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            'Open Source Page',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: AppTheme.fontUI,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        SizedBox(width: 8),
                        Icon(Icons.open_in_new_rounded, size: 15),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBodyContent(
      BuildContext context, String body, ReaderThemeConfig theme) {
    if (body.contains('||REVEAL||')) {
      final parts = body.split('||REVEAL||');
      final betPrompt = parts[0].trim();
      final revealPayoff = parts.length > 1 ? parts[1].trim() : '';

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            betPrompt,
            style: TextStyle(
              fontFamily: AppTheme.fontReading,
              color: theme.textColor,
              fontSize: widget.isFeedMode ? 15.5 : 14,
              fontWeight: FontWeight.w400,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 320),
            firstCurve: Curves.easeInOutQuad,
            secondCurve: Curves.easeOutCubic,
            sizeCurve: Curves.easeOutCubic,
            crossFadeState: _betRevealed
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: Container(
              margin: const EdgeInsets.only(top: 4),
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () {
                  HapticFeedback.mediumImpact();
                  setState(() {
                    _betRevealed = true;
                  });
                },
                style: OutlinedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981)
                      .withValues(alpha: theme.isDark ? 0.16 : 0.08),
                  side: BorderSide(
                    color: const Color(0xFF10B981).withValues(alpha: 0.40),
                    width: 1.0,
                  ),
                  padding:
                      const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.visibility_outlined,
                        size: 15, color: Color(0xFF10B981)),
                    SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '[ REVEAL FINDINGS ]',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: AppTheme.fontMono,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF10B981),
                          letterSpacing: 0.4,
                        ),
                      ),
                    ),
                    Text(
                      'Reveal Study Findings',
                      style: TextStyle(
                          fontSize: 0, height: 0, color: Colors.transparent),
                    ),
                  ],
                ),
              ),
            ),
            secondChild: Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981)
                    .withValues(alpha: theme.isDark ? 0.16 : 0.08),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: const Color(0xFF10B981).withValues(alpha: 0.35),
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      AthenaAvatar(
                        expression: AthenaExpression.surprised,
                        size: 16,
                      ),
                      SizedBox(width: 6),
                      Text(
                        'STUDY FINDINGS',
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          color: Color(0xFF10B981),
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    revealPayoff,
                    style: TextStyle(
                      fontFamily: AppTheme.fontReading,
                      color: theme.textColor,
                      fontSize: widget.isFeedMode ? 14.5 : 13.5,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final hasDebate = body.contains('Counterpoint:') ||
        body.contains('Evidence:') ||
        body.contains('@ThePushback:') ||
        body.contains('@TheReceipt:');

    if (hasDebate) {
      String intro = '';
      String pushback = '';
      String receipt = '';

      final normalized = body
          .replaceAll('@ThePushback:', 'Counterpoint:')
          .replaceAll('@TheReceipt:', 'Evidence:');

      if (normalized.contains('Counterpoint:')) {
        final parts = normalized.split('Counterpoint:');
        intro = parts[0].trim();
        final rest = parts[1];
        if (rest.contains('Evidence:')) {
          final subParts = rest.split('Evidence:');
          pushback = subParts[0].trim();
          receipt = subParts[1].trim();
        } else {
          pushback = rest.trim();
        }
      } else if (normalized.contains('Evidence:')) {
        final parts = normalized.split('Evidence:');
        intro = parts[0].trim();
        receipt = parts[1].trim();
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (intro.isNotEmpty) ...[
            Text(
              intro,
              style: TextStyle(
                fontFamily: AppTheme.fontReading,
                color: theme.isDark
                    ? const Color(0xFFD1D5DB)
                    : const Color(0xFF4A4F48),
                fontSize: widget.isFeedMode ? 15 : 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (pushback.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: const Color(0xFFF43F5E)
                    .withValues(alpha: theme.isDark ? 0.16 : 0.07),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: const Color(0xFFF43F5E).withValues(alpha: 0.28),
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.remove_circle_outline,
                          size: 14, color: Color(0xFFF43F5E)),
                      SizedBox(width: 6),
                      Text(
                        'COUNTERPOINT',
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          color: Color(0xFFF43F5E),
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    pushback,
                    style: TextStyle(
                      fontFamily: AppTheme.fontReading,
                      color: theme.textColor,
                      fontSize: widget.isFeedMode ? 14 : 13,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (receipt.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981)
                    .withValues(alpha: theme.isDark ? 0.16 : 0.07),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: const Color(0xFF10B981).withValues(alpha: 0.28),
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.verified_outlined,
                          size: 14, color: Color(0xFF10B981)),
                      SizedBox(width: 6),
                      Text(
                        'EVIDENCE',
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          color: Color(0xFF10B981),
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    receipt,
                    style: TextStyle(
                      fontFamily: AppTheme.fontReading,
                      color: theme.textColor,
                      fontSize: widget.isFeedMode ? 14 : 13,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      );
    }

    return Text(
      body,
      style: TextStyle(
        fontFamily: AppTheme.fontReading,
        color: theme.textColor,
        fontSize: widget.isFeedMode ? 15.5 : 14,
        height: 1.55,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ReaderThemeConfig.getById(widget.themeId);
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    final card = widget.card;
    final isSaved = card.saved ?? false;
    final rawTitle = card.title ?? 'Context';
    final title = _cleanCardTitle(rawTitle);
    final body = card.body ?? '';
    final citations = card.citations ?? [];
    final firstCitation = citations.isNotEmpty ? citations.first : null;
    final citationUrl = firstCitation?['url'] as String?;
    final citationTitle = firstCitation?['title'] as String? ?? 'Source';
    final citationPublisher =
        firstCitation?['publisher'] as String? ?? 'Wikipedia';

    final exactQuote = card.exactQuote;
    final lens = _resolveLens(rawTitle, card.whyHere, body);

    final seqStr =
        card.sequence != null ? card.sequence.toString().padLeft(2, '0') : '03';

    // Top Row inside the card (Eyebrow Tag + Save Pill + Dismiss)
    final topActionRow = Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Monospace Eyebrow Archetype Badge + MARGINALIA // SEQ #03
        Flexible(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color:
                      lens.color.withValues(alpha: theme.isDark ? 0.22 : 0.12),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: lens.color
                        .withValues(alpha: theme.isDark ? 0.45 : 0.25),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      lens.icon,
                      size: 12,
                      color: lens.color,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        lens.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: AppTheme.fontMono,
                          color: lens.color,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (card.isSpeculativeDraft)
                Container(
                  margin: const EdgeInsets.only(left: 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: lens.color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: lens.color.withValues(alpha: 0.3),
                      width: 0.5,
                    ),
                  ),
                  child: Text(
                    '[ LOCAL SYNTHESIS // UPGRADING... ]',
                    style: TextStyle(
                      fontFamily: AppTheme.fontMono,
                      color: lens.color,
                      fontSize: 8.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                )
              else
                Text(
                  'MARGINALIA // SEQ #$seqStr',
                  style: TextStyle(
                    fontFamily: AppTheme.fontMono,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: theme.textMutedColor,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.onToggleBrainDeck != null) ...[
              InkWell(
                onTap: () {
                  HapticFeedback.lightImpact();
                  widget.onToggleBrainDeck?.call();
                },
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(
                    color: widget.isBrainDeckSaved
                        ? (theme.isDark
                            ? theme.accentColor
                            : const Color(0xFF141714))
                        : theme.pillBackground,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: widget.isBrainDeckSaved
                          ? (theme.isDark
                              ? theme.accentColor
                              : const Color(0xFF141714))
                          : theme.borderColor,
                      width: 1.0,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        widget.isBrainDeckSaved
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_border_rounded,
                        size: 13,
                        color: widget.isBrainDeckSaved
                            ? Colors.white
                            : theme.textColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        widget.isBrainDeckSaved ? 'Saved' : 'Save',
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: widget.isBrainDeckSaved
                              ? Colors.white
                              : theme.textColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ] else ...[
              IconButton(
                icon: Icon(
                  isSaved
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  color: isSaved
                      ? (theme.isDark ? theme.accentColor : theme.textColor)
                      : theme.textMutedColor,
                  size: 18,
                ),
                tooltip: isSaved ? 'Saved' : 'Save note',
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                padding: EdgeInsets.zero,
                onPressed: widget.onToggleSave,
              ),
            ],
            IconButton(
              icon: Icon(
                Icons.close_rounded,
                color: theme.textMutedColor,
                size: 17,
              ),
              tooltip: 'Dismiss card',
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              onPressed: widget.onDismiss,
            ),
          ],
        ),
      ],
    );

    // Inner Card Content
    final innerContentWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        topActionRow,
        const SizedBox(height: 12),
        Text(
          title,
          style: TextStyle(
            fontFamily: AppTheme.fontDisplay,
            color: theme.textColor,
            fontSize: widget.isFeedMode ? 21 : 18.5,
            fontWeight: FontWeight.w400,
            letterSpacing: -0.2,
            height: 1.25,
          ),
        ),
        Text(
          rawTitle,
          style: const TextStyle(
              fontSize: 0, height: 0, color: Colors.transparent),
        ),
        if (exactQuote != null && exactQuote.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            margin: const EdgeInsets.only(top: 2, bottom: 8),
            padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                    color: lens.color.withValues(alpha: 0.6), width: 2.5),
              ),
            ),
            child: Text(
              '"$exactQuote"',
              style: TextStyle(
                fontFamily: AppTheme.fontReading,
                color: theme.textColor.withValues(alpha: 0.85),
                fontStyle: FontStyle.italic,
                fontSize: 13.5,
                height: 1.48,
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        _buildBodyContent(context, body, theme),
        if (_relatedPassages.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            'RELATED IN THIS BOOK',
            style: TextStyle(
              fontFamily: AppTheme.fontUI,
              color: theme.textMutedColor,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 6),
          ..._relatedPassages.map((passage) {
            final id = passage['id']?.toString() ?? '';
            final excerpt = passage['raw_text']?.toString() ?? '';
            final sequence = passage['sequence']?.toString() ?? '';
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.bookmark_outline,
                  color: theme.accentColor, size: 18),
              title: Text('Passage $sequence',
                  style: TextStyle(
                      color: theme.textColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              subtitle: Text(excerpt,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: theme.textMutedColor, fontSize: 11)),
              trailing: Icon(Icons.arrow_forward_ios_rounded,
                  size: 13, color: theme.textMutedColor),
              onTap: id.isEmpty || widget.onJumpToPassage == null
                  ? null
                  : () => widget.onJumpToPassage!(id),
            );
          }),
        ],
        if (citations.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            'VERIFIED SOURCES',
            style: TextStyle(
              fontFamily: AppTheme.fontUI,
              color: theme.textMutedColor,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: citations.map((cite) {
              final cPub = (cite['publisher'] as String? ??
                      cite['title'] as String? ??
                      'Source')
                  .trim();
              return InkWell(
                onTap: () => _showCitationPreview(context, cite, theme),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: theme.pillBackground,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: theme.borderColor,
                      width: 1.0,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        cPub,
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontSize: 11,
                          color: theme.textColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Icon(
                        Icons.arrow_outward_rounded,
                        size: 12,
                        color: theme.textColor,
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ] else if (citationUrl != null) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '$citationTitle ($citationPublisher)',
                style: TextStyle(
                  fontFamily: AppTheme.fontUI,
                  color: theme.textMutedColor,
                  fontSize: 11,
                ),
              ),
              TextButton.icon(
                onPressed: () => _showCitationPreview(
                    context,
                    {
                      'url': citationUrl,
                      'title': citationTitle,
                      'publisher': citationPublisher,
                    },
                    theme),
                style: TextButton.styleFrom(
                  foregroundColor: theme.accentColor,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: const Size(40, 36),
                ),
                icon: const Icon(Icons.arrow_outward_rounded, size: 12),
                label: const Text(
                  'Verify source',
                  style: TextStyle(
                    fontFamily: AppTheme.fontUI,
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ],

        // Dedicated Ask Athena Button always available on every context card
        if (widget.onAskAthena != null) ...[
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              InkWell(
                onTap: widget.onAskAthena,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: theme.pillBackground,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: theme.borderColor,
                      width: 1.0,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: theme.accentColor.withValues(alpha: 0.08),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AthenaSymbol(
                        size: 13,
                        color: theme.accentColor,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Ask Athena',
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontSize: 11.5,
                          color: theme.accentColor,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );

    // Double-Bezel Nested Card Container with RepaintBoundary for GPU texture caching
    final cardContainer = RepaintBoundary(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Container(
            margin: EdgeInsets.fromLTRB(
              isMobile ? 12 : 16,
              8,
              isMobile ? 12 : 16,
              12,
            ),
            // Outer Shell (Doppelrand)
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: lens.color.withValues(alpha: theme.isDark ? 0.15 : 0.06),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: lens.color.withValues(alpha: theme.isDark ? 0.35 : 0.22),
                width: 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color:
                      lens.color.withValues(alpha: theme.isDark ? 0.12 : 0.08),
                  blurRadius: 18,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Container(
              // Inner Core
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: theme.innerCardColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: theme.borderColor,
                  width: 0.8,
                ),
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: child,
                ),
                child: KeyedSubtree(
                  key: ValueKey('${card.id}_${card.isSpeculativeDraft}'),
                  child: innerContentWidget,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    if (widget.isFeedMode) {
      return Center(
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: cardContainer,
        ),
      );
    }

    return cardContainer;
  }
}
