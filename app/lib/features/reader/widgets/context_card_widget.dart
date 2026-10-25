import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/models/document.dart';
import 'package:athena/core/widgets/athena_avatar.dart';
import 'package:athena/core/widgets/athena_logo.dart';

/// Context card widget per CLAUDE.md §11 & §7.3.
/// High-end editorial marginalia card using Double-Bezel nested architecture,
/// squircle curvature, and tactile interactive controls.
class ContextCardWidget extends StatefulWidget {
  final ReaderItem card;
  final VoidCallback onToggleSave;
  final VoidCallback onDismiss;
  final VoidCallback? onAskAthena;
  final bool isFeedMode;
  final bool isBrainDeckSaved;
  final VoidCallback? onToggleBrainDeck;

  const ContextCardWidget({
    super.key,
    required this.card,
    required this.onToggleSave,
    required this.onDismiss,
    this.onAskAthena,
    this.isFeedMode = false,
    this.isBrainDeckSaved = false,
    this.onToggleBrainDeck,
  });

  @override
  State<ContextCardWidget> createState() => _ContextCardWidgetState();
}

class _ContextCardWidgetState extends State<ContextCardWidget> {
  bool _betRevealed = false;

  @override
  void didUpdateWidget(ContextCardWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.card.id != widget.card.id) {
      _betRevealed = false;
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
        color: const Color(0xFF10B981), // Emerald
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
        color: const Color(0xFFF43F5E), // Rose
      );
    }
    if (combined.contains('CORE PARADOX') ||
        combined.contains('LEGENDARY PARADOX') ||
        combined.contains('MIND-BLENDER PARADOX') ||
        combined.contains('PARADOX')) {
      return (
        label: 'CORE PARADOX',
        icon: Icons.auto_awesome_outlined,
        color: const Color(0xFFD97706), // Rich Amber
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
        color: const Color(0xFF7C3AED), // Violet
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

  void _showCitationPreview(BuildContext context, Map<String, dynamic> cite) {
    final cUrl = cite['url'] as String? ?? '';
    final cTitle = cite['title'] as String? ?? 'Verified Citation';
    final cPub =
        (cite['publisher'] as String? ?? cite['title'] as String? ?? 'Source')
            .trim();
    final snippet = cite['snippet'] as String? ??
        'Primary source attribution grounded against published literature and external knowledge.';

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
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
                    color: const Color(0xFFE5E7DC),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF7F6F2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFFE5E7DC)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.verified,
                            size: 14, color: Color(0xFF005E54)),
                        const SizedBox(width: 5),
                        Text(
                          cPub.toUpperCase(),
                          style: const TextStyle(
                            fontFamily: AppTheme.fontUI,
                            color: Color(0xFF005E54),
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
                    icon: const Icon(Icons.close_rounded, size: 20),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                cTitle,
                style: const TextStyle(
                  fontFamily: AppTheme.fontDisplay,
                  color: AppTheme.ink,
                  fontSize: 18,
                  fontWeight: FontWeight.w400,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF7F6F2),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE8EAE0)),
                ),
                child: Text(
                  snippet,
                  style: const TextStyle(
                    fontFamily: AppTheme.fontReading,
                    color: Color(0xFF4A4F48),
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
                    backgroundColor: const Color(0xFF141714),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    elevation: 0,
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Open Source Page',
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
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
    );
  }

  Widget _buildBodyContent(BuildContext context, String body) {
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
              color: const Color(0xFF141714),
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
                  backgroundColor:
                      const Color(0xFF10B981).withValues(alpha: 0.08),
                  side: BorderSide(
                    color: const Color(0xFF10B981).withValues(alpha: 0.40),
                    width: 1.0,
                  ),
                  padding:
                      const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22),
                  ),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.visibility_outlined,
                        size: 16, color: Color(0xFF10B981)),
                    SizedBox(width: 8),
                    Text(
                      'Reveal Study Findings',
                      style: TextStyle(
                        fontFamily: AppTheme.fontUI,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF10B981),
                        letterSpacing: 0.2,
                      ),
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
                color: const Color(0xFF10B981).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(16),
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
                      color: const Color(0xFF141714),
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
                color: const Color(0xFF4A4F48),
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
                color: const Color(0xFFF43F5E).withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(16),
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
                      color: const Color(0xFF141714),
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
                color: const Color(0xFF10B981).withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(16),
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
                      color: const Color(0xFF141714),
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
        color: const Color(0xFF141714),
        fontSize: widget.isFeedMode ? 15.5 : 14,
        height: 1.55,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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

    // Top Row inside the card (Eyebrow Tag + Save Pill + Dismiss)
    final topActionRow = Row(
      children: [
        // Microscopic Eyebrow Archetype Badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: lens.color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: lens.color.withValues(alpha: 0.22),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                lens.icon,
                size: 13,
                color: lens.color,
              ),
              const SizedBox(width: 6),
              Text(
                lens.label,
                style: TextStyle(
                  fontFamily: AppTheme.fontUI,
                  color: lens.color,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        if (widget.onToggleBrainDeck != null) ...[
          InkWell(
            onTap: () {
              HapticFeedback.lightImpact();
              widget.onToggleBrainDeck?.call();
            },
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: widget.isBrainDeckSaved
                    ? const Color(0xFF141714)
                    : const Color(0xFFF7F6F2),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: widget.isBrainDeckSaved
                      ? const Color(0xFF141714)
                      : const Color(0xFFE5E7DC),
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
                    color:
                        widget.isBrainDeckSaved ? Colors.white : AppTheme.ink,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    widget.isBrainDeckSaved ? 'Saved' : 'Save Note',
                    style: TextStyle(
                      fontFamily: AppTheme.fontUI,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color:
                          widget.isBrainDeckSaved ? Colors.white : AppTheme.ink,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ] else ...[
          IconButton(
            icon: Icon(
              isSaved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
              color: isSaved ? AppTheme.ink : AppTheme.textMuted,
              size: 19,
            ),
            tooltip: isSaved ? 'Saved' : 'Save note',
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            onPressed: widget.onToggleSave,
          ),
        ],
        IconButton(
          icon: const Icon(
            Icons.close_rounded,
            color: AppTheme.textMuted,
            size: 17,
          ),
          tooltip: 'Dismiss card',
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
          onPressed: widget.onDismiss,
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
            color: AppTheme.ink,
            fontSize: widget.isFeedMode ? 21 : 18.5,
            fontWeight: FontWeight.w400,
            letterSpacing: -0.2,
            height: 1.25,
          ),
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
              style: const TextStyle(
                fontFamily: AppTheme.fontReading,
                color: Color(0xFF4A4F48),
                fontStyle: FontStyle.italic,
                fontSize: 13.5,
                height: 1.48,
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        _buildBodyContent(context, body),
        if (citations.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            'VERIFIED SOURCES',
            style: TextStyle(
              fontFamily: AppTheme.fontUI,
              color: AppTheme.textMuted,
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
                onTap: () => _showCitationPreview(context, cite),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7F6F2),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0xFFE5E7DC),
                      width: 1.0,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        cPub,
                        style: const TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontSize: 11,
                          color: Color(0xFF141714),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 5),
                      const Icon(
                        Icons.arrow_outward_rounded,
                        size: 12,
                        color: Color(0xFF141714),
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
                style: const TextStyle(
                  fontFamily: AppTheme.fontUI,
                  color: AppTheme.textMuted,
                  fontSize: 11,
                ),
              ),
              TextButton.icon(
                onPressed: () => _showCitationPreview(context, {
                  'url': citationUrl,
                  'title': citationTitle,
                  'publisher': citationPublisher,
                }),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF005E54),
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
                    color: const Color(0xFFE8F8F2),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0xFFBBE5D8),
                      width: 1.0,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF005E54).withValues(alpha: 0.08),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AthenaSymbol(
                        size: 13,
                        color: Color(0xFF005E54),
                      ),
                      SizedBox(width: 6),
                      Text(
                        'Ask Athena',
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontSize: 11.5,
                          color: Color(0xFF005E54),
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

    // Double-Bezel Nested Card Container
    final cardContainer = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Container(
          margin: EdgeInsets.fromLTRB(
            isMobile ? 12 : 16,
            8,
            isMobile ? 12 : 16,
            widget.isFeedMode ? 68 : 10,
          ),
          // Outer Shell (Doppelrand)
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: lens.color.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
              color: lens.color.withValues(alpha: 0.22),
              width: 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: lens.color.withValues(alpha: 0.08),
                blurRadius: 18,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Container(
            // Inner Core
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFFFCFBF7), // Warm editorial paper
              borderRadius: BorderRadius.circular(22),
            ),
            child: innerContentWidget,
          ),
        ),
      ),
    );

    if (widget.isFeedMode) {
      return SizedBox.expand(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: cardContainer,
        ),
      );
    }

    return cardContainer;
  }
}
