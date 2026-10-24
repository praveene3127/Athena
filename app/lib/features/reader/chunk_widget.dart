import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../core/reader_theme.dart';
import '../../models/document.dart';
import '../../widgets/athena_logo.dart';

/// Renders a single lossless source chunk with high-end editorial paper aesthetic.
/// Complies with Double-Bezel nested architecture, squircle curvature,
/// and literary typography.
class ChunkWidget extends StatelessWidget {
  final ReaderItem chunk;
  final double fontSize;
  final VoidCallback onViewOriginalPage;
  final VoidCallback onAsk;
  final bool isFeedMode;
  final bool bionicFocusEnabled;
  final String? layoutWarning;
  final String fontFamily;
  final double lineHeight;
  final String themeId;

  const ChunkWidget({
    super.key,
    required this.chunk,
    required this.fontSize,
    required this.onViewOriginalPage,
    required this.onAsk,
    this.isFeedMode = true,
    this.bionicFocusEnabled = false,
    this.layoutWarning,
    this.fontFamily = 'Georgia',
    this.lineHeight = 1.72,
    this.themeId = 'paper',
  });

  static final RegExp _chapterHeadingRegex = RegExp(
    r'^((?:CHAPTER\s+[\dIVXLCDM]+[^\r\n]*|PART\s+[\dIVXLCDM]+[^\r\n]*|INTRODUCTION[^\r\n]*|PROLOGUE[^\r\n]*))(?:\r?\n+)',
    caseSensitive: false,
  );

  static final Set<String> _stopwords = {
    'the',
    'and',
    'of',
    'to',
    'in',
    'a',
    'is',
    'it',
    'that',
    'by',
    'as',
    'at',
    'or',
    'on',
    'for',
    'with',
    'an',
    'be',
    'this',
    'which',
    'from',
    'but'
  };

  static List<TextSpan> _buildBionicSpans(
    String text,
    double size, {
    String fontFamily = 'Georgia',
    double lineHeight = 1.72,
    Color textColor = const Color(0xFF141714),
    Color textMutedColor = const Color(0xFF6B7280),
  }) {
    if (text.isEmpty) return const [];
    final List<TextSpan> spans = [];
    final regex = RegExp(r'(\w+)|([^\w]+)');
    for (final match in regex.allMatches(text)) {
      final word = match.group(1);
      final nonWord = match.group(2);
      if (word != null) {
        final lower = word.toLowerCase();
        final len = word.length;
        if (_stopwords.contains(lower) || len == 0) {
          spans.add(TextSpan(
            text: word,
            style: TextStyle(
              fontFamily: fontFamily,
              fontWeight: FontWeight.w400,
              fontSize: size,
              height: lineHeight,
              color: textColor,
            ),
          ));
        } else {
          final boldLen = (len <= 3 ? 1 : (len * 0.45).ceil()).clamp(1, len);
          final prefix = word.substring(0, boldLen);
          final suffix = word.substring(boldLen);
          spans.add(TextSpan(
            text: prefix,
            style: TextStyle(
              fontFamily: fontFamily,
              fontWeight: FontWeight.w700,
              fontSize: size,
              height: lineHeight,
              color: textColor,
            ),
          ));
          if (suffix.isNotEmpty) {
            spans.add(TextSpan(
              text: suffix,
              style: TextStyle(
                fontFamily: fontFamily,
                fontWeight: FontWeight.w400,
                fontSize: size,
                height: lineHeight,
                color: textMutedColor,
              ),
            ));
          }
        }
      } else if (nonWord != null) {
        spans.add(TextSpan(
          text: nonWord,
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: size,
            height: lineHeight,
            color: textColor,
          ),
        ));
      }
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final theme = ReaderThemeConfig.getById(themeId);
    final pageLabel = chunk.pageReference ?? 'Page ?';
    final sectionTitle = chunk.sectionTitle;

    final cleanTitle = sectionTitle?.trim() ?? '';
    final rawText = chunk.text ?? '';
    final firstLine = rawText.trimLeft().split('\n').first.trim();

    String norm(String s) => s.replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
    final normTitle = norm(cleanTitle);
    final normFirst = norm(firstLine);

    final titleDuplicatesFirstLine = normTitle.isNotEmpty &&
        (normFirst == normTitle ||
            normFirst.startsWith(normTitle) ||
            normTitle.startsWith(normFirst) ||
            rawText
                .toLowerCase()
                .trimLeft()
                .startsWith(cleanTitle.toLowerCase()));

    final shouldShowSectionTitle =
        cleanTitle.isNotEmpty && !titleDuplicatesFirstLine;

    // Seamless Top Row inside the card
    final headerRow = Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onViewOriginalPage,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
              decoration: BoxDecoration(
                color: theme.pillBackground,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: theme.borderColor, width: 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.menu_book_rounded,
                    size: 13,
                    color: theme.accentColor,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    pageLabel,
                    style: TextStyle(
                      fontFamily: AppTheme.fontUI,
                      color: theme.pillText,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          if (chunk.sequence != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: theme.pillBackground,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: theme.borderColor, width: 1),
              ),
              child: Text(
                '#${chunk.sequence}',
                style: TextStyle(
                  fontFamily: AppTheme.fontUI,
                  color: theme.pillText,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
            ),
        ],
      ),
    );

    final titleWidget = shouldShowSectionTitle
        ? Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Container(
                  width: 3.5,
                  height: 16,
                  decoration: BoxDecoration(
                    color: theme.accentColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    cleanTitle,
                    style: TextStyle(
                      fontFamily: AppTheme.fontDisplay,
                      color: theme.textColor,
                      fontSize: fontSize + 2.5,
                      fontWeight: FontWeight.w400,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
              ],
            ),
          )
        : const SizedBox.shrink();

    final chapterMatch = _chapterHeadingRegex.firstMatch(rawText);
    final hasChapterHeading = chapterMatch != null;
    final String headingText =
        hasChapterHeading ? chapterMatch.group(1)!.trim() : '';
    final String bodyText =
        hasChapterHeading ? rawText.substring(chapterMatch.end) : rawText;

    final effectiveFontSize = isFeedMode ? (fontSize + 0.5) : fontSize;

    final List<TextSpan> textSpans = [];

    if (hasChapterHeading) {
      textSpans.add(
        TextSpan(
          text: '$headingText\n\n',
          style: TextStyle(
            fontFamily: AppTheme.fontDisplay,
            fontSize: 24,
            fontWeight: FontWeight.w400,
            letterSpacing: -0.3,
            color: theme.textColor,
            height: 1.25,
          ),
        ),
      );
    }

    if (bionicFocusEnabled) {
      textSpans.addAll(_buildBionicSpans(
        bodyText,
        effectiveFontSize,
        fontFamily: fontFamily,
        lineHeight: lineHeight,
        textColor: theme.textColor,
        textMutedColor: theme.textMutedColor,
      ));
    } else {
      textSpans.add(
        TextSpan(
          text: bodyText,
          style: TextStyle(
            fontFamily: fontFamily,
            color: theme.textColor,
            fontSize: effectiveFontSize,
            height: lineHeight,
            letterSpacing: 0.12,
          ),
        ),
      );
    }

    final bodyTextWidget = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isFeedMode ? 26 : 22,
        vertical: isFeedMode ? 18 : 14,
      ),
      child: SelectableText.rich(
        TextSpan(
          style: TextStyle(
            fontFamily: fontFamily,
            color: theme.textColor,
            fontSize: effectiveFontSize,
            height: lineHeight,
          ),
          children: textSpans,
        ),
      ),
    );

    final actionRowWidget = Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Align(
        alignment: Alignment.centerRight,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onAsk,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: theme.pillBackground,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: theme.borderColor,
                width: 1,
              ),
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
                    fontWeight: FontWeight.w600,
                    color: theme.textColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // Double-Bezel nested architecture
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Container(
          margin: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            isFeedMode ? 68 : 10,
          ),
          // Outer Shell (Doppelrand)
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: theme.outerCardColor,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
              color: theme.borderColor,
              width: 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: theme.isDark
                    ? const Color(0x33000000)
                    : const Color(0x06141714),
                blurRadius: 18,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Container(
            // Inner Core
            decoration: BoxDecoration(
              color: theme.innerCardColor,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                headerRow,
                if (shouldShowSectionTitle) titleWidget,
                bodyTextWidget,
                actionRowWidget,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

