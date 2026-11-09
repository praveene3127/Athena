import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/core/theme/reader_theme.dart';
import 'package:athena/models/document.dart';

/// Distinct visual card layout archetypes (§ Reading Psychology Mandate).
enum CardLayoutVariant {
  storyBehindIt, // Variant A: Warm Editorial Aside
  psychologicalLens, // Variant B: Minimalist Pull-Quote (Left Accent)
  sharpDetail, // Variant C: Compact Margin Note
}

/// Instant-read editorial fact Context Card (3 distinct visual variants, zero reveals, zero Q&A).
class ContextCardWidget extends StatelessWidget {
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

  static CardLayoutVariant resolveVariant(ReaderItem item, String body) {
    final upTitle = (item.title ?? '').toUpperCase();
    final upType = (item.cardType ?? item.type).toUpperCase();
    final int seq = item.sequence ?? 0;

    if (upTitle.contains('PSYCHOLOGICAL') ||
        upTitle.contains('PARADOX') ||
        upTitle.contains('MECHANISM') ||
        upType.contains('PHILOSOPHY') ||
        (seq % 3 == 1)) {
      return CardLayoutVariant.psychologicalLens;
    }

    if (upTitle.contains('SHARP DETAIL') ||
        upTitle.contains('COUNTER') ||
        (seq % 3 == 2)) {
      return CardLayoutVariant.sharpDetail;
    }

    if (upTitle.contains('BEHIND THE SCENE') ||
        upTitle.contains('STORY') ||
        upTitle.contains('STUDY') ||
        (seq % 3 == 0)) {
      return CardLayoutVariant.storyBehindIt;
    }

    final wordCount =
        body.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    if (wordCount <= 35) {
      return CardLayoutVariant.sharpDetail;
    }

    return CardLayoutVariant.storyBehindIt;
  }

  static CardLayoutVariant _resolveVariant(ReaderItem item, String body) =>
      resolveVariant(item, body);

  static ({String label, IconData icon, Color color}) _resolveLens(
      String rawTitle, String body) {
    final upTitle = rawTitle.toUpperCase();
    if (upTitle.contains('EMPIRICAL STUDY') ||
        upTitle.contains('REAL-WORLD STUDY')) {
      return (
        label: 'REAL-WORLD STUDY',
        icon: Icons.science_outlined,
        color: const Color(0xFF2D6A4F), // Emerald #2D6A4F
      );
    }
    if (upTitle.contains('COUNTER-INTUITIVE') ||
        upTitle.contains('COUNTERPOINT') ||
        upTitle.contains('CRITICAL DEBATE')) {
      return (
        label: 'COUNTER-INTUITIVE FACT',
        icon: Icons.balance_outlined,
        color: const Color(0xFFC84B31), // Terracotta #C84B31
      );
    }
    if (upTitle.contains('HISTORICAL BACKSTORY') ||
        upTitle.contains('HISTORICAL CONTEXT') ||
        upTitle.contains('HISTORICAL CASE') ||
        upTitle.contains('BEHIND THE SCENE')) {
      return (
        label: 'HISTORICAL BACKSTORY',
        icon: Icons.history_edu_outlined,
        color: const Color(0xFF1D3557), // Navy #1D3557
      );
    }
    if (upTitle.contains('THE HIDDEN MECHANISM') ||
        upTitle.contains('PHILOSOPHY PARADOX') ||
        upTitle.contains('CORE PARADOX') ||
        upTitle.contains('PSYCHOLOGICAL LENS')) {
      return (
        label: 'THE HIDDEN MECHANISM',
        icon: Icons.menu_book_outlined,
        color: const Color(0xFFB45309), // Ochre #B45309
      );
    }

    final combined = '$rawTitle $body'.toUpperCase();
    if (combined.contains('EMPIRICAL') ||
        combined.contains('TRIAL') ||
        combined.contains('FINDING')) {
      return (
        label: 'REAL-WORLD STUDY',
        icon: Icons.science_outlined,
        color: const Color(0xFF2D6A4F),
      );
    }
    if (combined.contains('HISTORICAL') ||
        combined.contains('BACKSTORY') ||
        combined.contains('BIOGRAPHY') ||
        combined.contains('ORIGIN')) {
      return (
        label: 'HISTORICAL BACKSTORY',
        icon: Icons.history_edu_outlined,
        color: const Color(0xFF1D3557),
      );
    }
    if (combined.contains('COUNTER') ||
        combined.contains('DEBATE') ||
        combined.contains('PUSHBACK') ||
        combined.contains('CONTRARIAN')) {
      return (
        label: 'COUNTER-INTUITIVE FACT',
        icon: Icons.balance_outlined,
        color: const Color(0xFFC84B31),
      );
    }
    if (combined.contains('MECHANISM') ||
        combined.contains('PARADOX') ||
        combined.contains('SYSTEM') ||
        combined.contains('LAW')) {
      return (
        label: 'THE HIDDEN MECHANISM',
        icon: Icons.menu_book_outlined,
        color: const Color(0xFFB45309),
      );
    }
    return (
      label: 'REAL-WORLD STUDY',
      icon: Icons.science_outlined,
      color: const Color(0xFF2D6A4F),
    );
  }

  static String _cleanTitle(String rawTitle) {
    var t = rawTitle
        .replaceAll(
          RegExp(
            r'[\u{1F000}-\u{1FFFF}\u{2300}-\u{27BF}\u{2B50}\u{FE00}-\u{FE0F}]',
            unicode: true,
          ),
          '',
        )
        .trim();
    return t.isEmpty ? 'Context Insight' : t;
  }

  static String _cleanBody(String rawBody) {
    var b = rawBody.replaceAll('||REVEAL||', ' ');
    b = b.replaceAll(
        RegExp(
            r'^(?:Question|Q):\s*.*?\n+(?:Answer|A|Evidence|Finding|Result):\s*',
            caseSensitive: false),
        '');
    b = b.replaceAll(
        RegExp(r'^\s*(?:Question|Q):\s*', caseSensitive: false), '');
    b = b.replaceAll(
        RegExp(r'^\s*(?:Counterpoint|Evidence):\s*', caseSensitive: false), '');
    b = b.replaceAll(
        RegExp(
            r'^(?:In this passage[,\s]+|This passage discusses[,\s]+|This excerpt explains[,\s]+)',
            caseSensitive: false),
        '');
    b = b.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return b;
  }

  static Map<String, String>? _extractSource(ReaderItem item) {
    if (item.citations != null && item.citations!.isNotEmpty) {
      try {
        final first = item.citations!.first;
        final pub =
            (first['publisher'] ?? first['title'] ?? '').toString().trim();
        final url = (first['url'] ?? '').toString().trim();
        if (pub.isNotEmpty || url.isNotEmpty) {
          return {
            'publisher': pub.isNotEmpty ? pub : 'External Reference',
            'url': url,
          };
        }
      } catch (e) {
        debugPrint('[Athena ContextCard] Failed to parse sources: $e');
      }
    }
    return null;
  }

  Future<void> _openUrl(String? url) async {
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ReaderThemeConfig.getById(themeId);
    final lens = _resolveLens(card.title ?? '', card.body ?? '');
    final displayTitle = _cleanTitle(card.title ?? 'Context Insight');
    final displayBody = _cleanBody(card.body ?? '');
    final sourceInfo = _extractSource(card);
    final isSaved = card.saved == true;
    final exactQuote = card.exactQuote?.trim() ?? '';
    final variant = _resolveVariant(card, displayBody);

    switch (variant) {
      case CardLayoutVariant.psychologicalLens:
        return _buildPsychologicalLens(
          context,
          theme,
          lens,
          displayTitle,
          displayBody,
          sourceInfo,
          isSaved,
          exactQuote,
        );
      case CardLayoutVariant.sharpDetail:
        return _buildSharpDetail(
          context,
          theme,
          lens,
          displayTitle,
          displayBody,
          sourceInfo,
          isSaved,
          exactQuote,
        );
      case CardLayoutVariant.storyBehindIt:
        return _buildStoryBehindIt(
          context,
          theme,
          lens,
          displayTitle,
          displayBody,
          sourceInfo,
          isSaved,
          exactQuote,
        );
    }
  }

  // --- VARIANT A: THE STORY BEHIND IT (Warm Editorial Aside) ---
  Widget _buildStoryBehindIt(
    BuildContext context,
    ReaderThemeConfig theme,
    ({String label, IconData icon, Color color}) lens,
    String displayTitle,
    String displayBody,
    Map<String, String>? sourceInfo,
    bool isSaved,
    String exactQuote,
  ) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      constraints: const BoxConstraints(maxWidth: 580),
      decoration: BoxDecoration(
        color: theme.innerCardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.isDark ? Colors.white12 : theme.borderColor,
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: theme.isDark ? 0.35 : 0.05),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildTopRow(theme, lens, isSaved),
              const SizedBox(height: 12),
              if (exactQuote.isNotEmpty) ...[
                _buildAnchorQuote(theme, exactQuote),
                const SizedBox(height: 14),
              ],
              Text(
                displayTitle,
                style: TextStyle(
                  fontFamily: AppTheme.fontDisplay,
                  fontSize: 18.5,
                  fontWeight: FontWeight.w700,
                  color: theme.textColor,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                displayBody,
                style: TextStyle(
                  fontFamily: AppTheme.fontReading,
                  fontSize: 16.5,
                  height: 1.58,
                  color: theme.textColor.withValues(alpha: 0.92),
                  fontWeight: FontWeight.w400,
                ),
              ),
              const SizedBox(height: 16),
              _buildSourceFooter(theme, sourceInfo),
            ],
          ),
        ),
      ),
    );
  }

  // --- VARIANT B: THE PSYCHOLOGICAL LENS (Minimalist Pull-Quote / Left Accent) ---
  Widget _buildPsychologicalLens(
    BuildContext context,
    ReaderThemeConfig theme,
    ({String label, IconData icon, Color color}) lens,
    String displayTitle,
    String displayBody,
    Map<String, String>? sourceInfo,
    bool isSaved,
    String exactQuote,
  ) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      constraints: const BoxConstraints(maxWidth: 580),
      decoration: BoxDecoration(
        color: theme.isDark
            ? theme.innerCardColor
            : theme.scaffoldBackground.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: theme.isDark
              ? Colors.white12
              : theme.borderColor.withValues(alpha: 0.7),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: lens.color.withValues(alpha: theme.isDark ? 0.20 : 0.06),
            blurRadius: 14,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 4.5,
                color: lens.color,
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 18, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildTopRow(theme, lens, isSaved),
                      const SizedBox(height: 12),
                      if (exactQuote.isNotEmpty) ...[
                        _buildAnchorQuote(theme, exactQuote),
                        const SizedBox(height: 12),
                      ],
                      Text(
                        displayTitle,
                        style: TextStyle(
                          fontFamily: AppTheme.fontDisplay,
                          fontSize: 18.0,
                          fontStyle: FontStyle.italic,
                          fontWeight: FontWeight.w700,
                          color: theme.textColor,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        displayBody,
                        style: TextStyle(
                          fontFamily: AppTheme.fontReading,
                          fontSize: 17.0,
                          fontStyle: FontStyle.italic,
                          height: 1.62,
                          color: theme.textColor.withValues(alpha: 0.94),
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 14),
                      _buildSourceFooter(theme, sourceInfo),
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

  // --- VARIANT C: THE SHARP DETAIL (Compact Margin Note) ---
  Widget _buildSharpDetail(
    BuildContext context,
    ReaderThemeConfig theme,
    ({String label, IconData icon, Color color}) lens,
    String displayTitle,
    String displayBody,
    Map<String, String>? sourceInfo,
    bool isSaved,
    String exactQuote,
  ) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      constraints: const BoxConstraints(maxWidth: 580),
      decoration: BoxDecoration(
        color: theme.innerCardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.isDark
              ? Colors.white12
              : theme.borderColor.withValues(alpha: 0.9),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: theme.isDark ? 0.25 : 0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildTopRow(theme, lens, isSaved),
              const SizedBox(height: 10),
              if (exactQuote.isNotEmpty) ...[
                _buildAnchorQuote(theme, exactQuote),
                const SizedBox(height: 10),
              ],
              Text(
                displayTitle,
                style: TextStyle(
                  fontFamily: AppTheme.fontUI,
                  fontSize: 16.0,
                  fontWeight: FontWeight.w700,
                  color: theme.textColor,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                displayBody,
                style: TextStyle(
                  fontFamily: AppTheme.fontReading,
                  fontSize: 15.0,
                  height: 1.48,
                  color: theme.textColor.withValues(alpha: 0.90),
                  fontWeight: FontWeight.w400,
                ),
              ),
              const SizedBox(height: 12),
              _buildSourceFooter(theme, sourceInfo),
            ],
          ),
        ),
      ),
    );
  }

  // --- REUSABLE CARD CHROME ---

  Widget _buildTopRow(
    ReaderThemeConfig theme,
    ({String label, IconData icon, Color color}) lens,
    bool isSaved,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 4,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: lens.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: lens.color.withValues(alpha: 0.3),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(lens.icon, size: 13, color: lens.color),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        lens.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: lens.color,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: Icon(
            isSaved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
            size: 20,
            color: isSaved ? theme.accentColor : theme.textMutedColor,
          ),
          tooltip: isSaved ? 'Saved' : 'Save Fact',
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          onPressed: () {
            HapticFeedback.lightImpact();
            onToggleSave();
          },
        ),
        IconButton(
          icon: Icon(Icons.close_rounded,
              size: 20, color: theme.textMutedColor),
          tooltip: 'Dismiss',
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          onPressed: () {
            HapticFeedback.lightImpact();
            onDismiss();
          },
        ),
      ],
    );
  }

  Widget _buildAnchorQuote(ReaderThemeConfig theme, String exactQuote) {
    return GestureDetector(
      onTap: () {
        final srcId = card.sourceChunkId;
        if (srcId != null && onJumpToPassage != null) {
          onJumpToPassage!(srcId);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: theme.scaffoldBackground.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: theme.borderColor.withValues(alpha: 0.5),
            width: 0.8,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Re: ',
              style: TextStyle(
                fontFamily: AppTheme.fontUI,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: theme.accentColor,
              ),
            ),
            Expanded(
              child: Text(
                '"$exactQuote"',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: AppTheme.fontReading,
                  fontSize: 12.5,
                  fontStyle: FontStyle.italic,
                  color: theme.textMutedColor,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceFooter(
      ReaderThemeConfig theme, Map<String, String>? sourceInfo) {
    final hasVerifiedSource =
        card.isVerifiedExternal && card.sourceUrl.isNotEmpty && sourceInfo != null;
    final isSingleSource =
        card.isSingleSource && card.sourceUrl.isNotEmpty && sourceInfo != null;

    return Row(
      children: [
        if (hasVerifiedSource)
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _openUrl(sourceInfo['url']),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.pillBackground,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.borderColor.withValues(alpha: 0.8),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.verified_rounded,
                        size: 14, color: theme.accentColor),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'VERIFIED SOURCE: ${sourceInfo['publisher']!.toUpperCase()}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                          color: theme.accentColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.open_in_new_rounded,
                        size: 12, color: theme.accentColor),
                  ],
                ),
              ),
            ),
          )
        else if (isSingleSource)
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _openUrl(sourceInfo['url']),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.pillBackground,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.borderColor.withValues(alpha: 0.8),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.menu_book_rounded,
                        size: 14, color: theme.accentColor),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'CONTEXTUAL NOTE: ${sourceInfo['publisher']!.toUpperCase()}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                          color: theme.accentColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.open_in_new_rounded,
                        size: 12, color: theme.accentColor),
                  ],
                ),
              ),
            ),
          )
        else
          Expanded(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: theme.pillBackground,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: theme.borderColor.withValues(alpha: 0.8),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_stories_rounded,
                      size: 14, color: theme.accentColor),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'BOOK CROSS-REFERENCE / CONCEPT NOTE',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: AppTheme.fontUI,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                        color: theme.accentColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (onAskAthena != null) ...[
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(Icons.chat_bubble_outline_rounded,
                size: 18, color: theme.accentColor),
            tooltip: 'Ask Athena About This Fact',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () {
              HapticFeedback.lightImpact();
              onAskAthena!();
            },
          ),
        ],
      ],
    );
  }
}
