import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/core/theme/reader_theme.dart';
import 'package:athena/models/document.dart';
import 'package:athena/services/local_database.dart';

/// L7 Editorial Print & Monospace Reading Card.
///
/// Designed with architectural 8px corner radii, crisp 1px structural hairline borders,
/// tabular monospace metadata headers, high-contrast serif prose, code block isolation,
/// and interactive inline text/code delta editing with personal note callouts.
class ChunkWidget extends StatefulWidget {
  final ReaderItem chunk;
  final double fontSize;
  final VoidCallback onViewOriginalPage;
  final VoidCallback onAsk;
  final void Function([String? selectedText])? onSaveQuote;
  final VoidCallback? onDeepDive;
  final VoidCallback? onGenerateCard;
  final bool isFeedMode;
  final bool bionicFocusEnabled;
  final String? layoutWarning;
  final String fontFamily;
  final double lineHeight;
  final String themeId;
  final String? initialEditedText;
  final String? initialUserNote;
  final void Function(String chunkId, String? editedText, String? userNote)? onEditSaved;

  const ChunkWidget({
    super.key,
    required this.chunk,
    required this.fontSize,
    required this.onViewOriginalPage,
    required this.onAsk,
    this.onSaveQuote,
    this.onDeepDive,
    this.onGenerateCard,
    this.isFeedMode = true,
    this.bionicFocusEnabled = false,
    this.layoutWarning,
    this.fontFamily = 'Georgia',
    this.lineHeight = 1.62,
    this.themeId = 'paper',
    this.initialEditedText,
    this.initialUserNote,
    this.onEditSaved,
  });

  @override
  State<ChunkWidget> createState() => _ChunkWidgetState();
}

class _ChunkWidgetState extends State<ChunkWidget> {
  bool _isEditing = false;
  late TextEditingController _textController;
  late TextEditingController _noteController;
  String? _editedText;
  String? _userNote;

  @override
  void initState() {
    super.initState();
    _editedText = widget.initialEditedText;
    _userNote = widget.initialUserNote;
    _textController = TextEditingController(text: _editedText ?? widget.chunk.rawText);
    _noteController = TextEditingController(text: _userNote ?? '');
  }

  @override
  void didUpdateWidget(covariant ChunkWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chunk.id != widget.chunk.id ||
        oldWidget.initialEditedText != widget.initialEditedText ||
        oldWidget.initialUserNote != widget.initialUserNote) {
      _editedText = widget.initialEditedText;
      _userNote = widget.initialUserNote;
      _textController.text = _editedText ?? widget.chunk.rawText;
      _noteController.text = _userNote ?? '';
      _isEditing = false;
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _saveEdit() async {
    final newText = _textController.text.trim();
    final newNote = _noteController.text.trim();
    final docId = widget.chunk.id.contains('-c')
        ? widget.chunk.id.split('-c').first
        : (widget.chunk.id.contains('chunk_') ? widget.chunk.id.split('_')[1] : 'default_doc');

    final effectiveEditedText = newText != widget.chunk.rawText ? newText : null;
    final effectiveNote = newNote.isNotEmpty ? newNote : null;

    try {
      await LocalDatabase.instance.saveChunkEdit(
        widget.chunk.id,
        docId,
        editedText: effectiveEditedText,
        userNote: effectiveNote,
      );
    } catch (e) {
      debugPrint('[Athena] LocalDatabase saveChunkEdit error: $e');
    }

    if (mounted) {
      setState(() {
        _editedText = effectiveEditedText;
        _userNote = effectiveNote;
        _isEditing = false;
      });
    }

    widget.onEditSaved?.call(widget.chunk.id, effectiveEditedText, effectiveNote);
  }

  Future<void> _resetToOriginal() async {
    final docId = widget.chunk.id.contains('-c')
        ? widget.chunk.id.split('-c').first
        : 'default_doc';

    try {
      await LocalDatabase.instance.saveChunkEdit(
        widget.chunk.id,
        docId,
        editedText: null,
        userNote: null,
      );
    } catch (e) {
      debugPrint('[Athena] LocalDatabase reset edit error: $e');
    }

    if (mounted) {
      setState(() {
        _editedText = null;
        _userNote = null;
        _textController.text = widget.chunk.rawText;
        _noteController.clear();
        _isEditing = false;
      });
    }

    widget.onEditSaved?.call(widget.chunk.id, null, null);
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    final theme = ReaderThemeConfig.getById(widget.themeId);
    final rawText = _editedText ?? widget.chunk.text ?? '';
    final hasCode = _isCodeBlock(rawText);

    return RepaintBoundary(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Container(
            margin: EdgeInsets.symmetric(
              horizontal: isMobile ? 14 : 24,
              vertical: widget.isFeedMode ? 10 : 12,
            ),
            decoration: BoxDecoration(
              color: theme.innerCardColor, // #14161B dark, #FCFBF7 paper
              borderRadius: BorderRadius.circular(8), // Architectural 8px corner radius
              border: Border.all(
                color: theme.borderColor, // #262932 hairline dark, #E2DEC9 stone
                width: 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: theme.isDark ? const Color(0x33000000) : const Color(0x06141714),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Top Metadata Row inside Card (Fixed outside scroll area)
                _buildMetadataHeader(theme),

                // Card Body: Scrollable middle prose area wrapped in Flexible + SingleChildScrollView
                Flexible(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_isEditing)
                          _buildInlineEditor(theme, hasCode)
                        else ...[
                          _buildReadingContent(theme, rawText, hasCode),
                          if (_userNote != null && _userNote!.isNotEmpty)
                            _buildNoteCallout(theme),
                        ],
                      ],
                    ),
                  ),
                ),

                // Card Footer Actions (Fixed outside scroll area, 100% visible)
                if (!_isEditing) _buildCardFooter(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMetadataHeader(ReaderThemeConfig theme) {
    final pageLabel = widget.chunk.pageReference ?? 'Page ?';
    final sectionTitle = widget.chunk.sectionTitle?.trim();
    final seq = widget.chunk.sequence;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 16, 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.borderColor.withValues(alpha: 0.5),
            width: 0.7,
          ),
        ),
      ),
      child: Row(
        children: [
          // Left: Chapter / Section / Indicator
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    sectionTitle != null && sectionTitle.isNotEmpty
                        ? sectionTitle.toUpperCase()
                        : (seq != null ? 'CHAPTER PASSAGE · #$seq' : 'PASSAGE'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: AppTheme.fontMono,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                      color: theme.textMutedColor,
                    ),
                  ),
                ),
                if (_editedText != null) ...[
                  const SizedBox(width: 8),
                  _buildBadge('EDITED', const Color(0xFFD97706)),
                ],
                if (_userNote != null && _userNote!.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  _buildBadge('NOTE', theme.accentColor),
                ],
              ],
            ),
          ),

          // Right: Page Reference & Edit Toggle
          InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              widget.onViewOriginalPage();
            },
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text(
                pageLabel.toUpperCase(),
                style: TextStyle(
                  fontFamily: AppTheme.fontMono,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                  color: theme.accentColor,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(
              _isEditing ? Icons.close_rounded : Icons.edit_note_rounded,
              size: 18,
              color: _isEditing ? const Color(0xFFEF4444) : theme.textMutedColor,
            ),
            tooltip: _isEditing ? 'Cancel Editing' : 'Edit Passage / Add Note',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: () {
              HapticFeedback.selectionClick();
              setState(() => _isEditing = !_isEditing);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 0.8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: AppTheme.fontMono,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: color,
        ),
      ),
    );
  }

  double _getIdealFontSize(String text, double baseFontSize) {
    final delta = baseFontSize - 18.0;
    final len = text.length;
    if (len < 220) {
      return 19.0 + delta;
    } else if (len <= 320) {
      return 17.5 + delta;
    } else {
      return 16.0 + delta;
    }
  }

  Widget _buildReadingContent(ReaderThemeConfig theme, String text, bool hasCode) {
    final cleanText = text;

    if (hasCode) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
        child: _buildCodeContainer(cleanText, theme),
      );
    }

    final effectiveFontSize = _getIdealFontSize(cleanText, widget.fontSize);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
      child: SelectableText(
        cleanText,
        style: TextStyle(
          fontFamily: widget.fontFamily,
          fontSize: effectiveFontSize,
          height: widget.lineHeight,
          letterSpacing: 0.15,
          color: theme.textColor,
        ),
        contextMenuBuilder: (context, editableTextState) {
          final buttonItems = editableTextState.contextMenuButtonItems;
          final selectedText = editableTextState.textEditingValue.selection
              .textInside(editableTextState.textEditingValue.text);
          if (selectedText.trim().isNotEmpty) {
            buttonItems.insert(
              0,
              ContextMenuButtonItem(
                label: 'Save Quote',
                onPressed: () {
                  editableTextState.hideToolbar();
                  widget.onSaveQuote?.call(selectedText.trim());
                },
              ),
            );
            buttonItems.insert(
              1,
              ContextMenuButtonItem(
                label: 'Ask Athena',
                onPressed: () {
                  editableTextState.hideToolbar();
                  widget.onAsk();
                },
              ),
            );
          }
          return AdaptiveTextSelectionToolbar.buttonItems(
            anchors: editableTextState.contextMenuAnchors,
            buttonItems: buttonItems,
          );
        },
      ),
    );
  }

  Widget _buildCodeContainer(String code, ReaderThemeConfig theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.isDark ? const Color(0xFF1A1D24) : const Color(0xFFF3F1E8),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: theme.borderColor,
          width: 1.0,
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: SelectableText(
          code,
          style: TextStyle(
            fontFamily: AppTheme.fontMono,
            fontSize: (widget.fontSize - 3).clamp(13.0, 16.0),
            height: 1.45,
            color: theme.isDark ? const Color(0xFF38BDF8) : const Color(0xFF0F766E),
          ),
        ),
      ),
    );
  }

  Widget _buildInlineEditor(ReaderThemeConfig theme, bool isCode) {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'EDIT PASSAGE / CODE',
            style: TextStyle(
              fontFamily: AppTheme.fontMono,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: theme.textMutedColor,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _textController,
            maxLines: null,
            minLines: 3,
            style: TextStyle(
              fontFamily: isCode ? AppTheme.fontMono : widget.fontFamily,
              fontSize: widget.fontSize - 1,
              height: widget.lineHeight,
              color: theme.textColor,
            ),
            decoration: InputDecoration(
              filled: true,
              fillColor: theme.outerCardColor,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: theme.borderColor),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: theme.accentColor, width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'PERSONAL ANNOTATION / NOTE',
            style: TextStyle(
              fontFamily: AppTheme.fontMono,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: theme.textMutedColor,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _noteController,
            maxLines: null,
            minLines: 1,
            style: TextStyle(
              fontFamily: AppTheme.fontUI,
              fontSize: 13.5,
              color: theme.textColor,
            ),
            decoration: InputDecoration(
              hintText: 'Add personal thought, question, or reference...',
              hintStyle: TextStyle(color: theme.textMutedColor, fontSize: 13),
              filled: true,
              fillColor: theme.outerCardColor,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: theme.borderColor),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: theme.accentColor, width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              if (_editedText != null || (_userNote != null && _userNote!.isNotEmpty))
                TextButton(
                  onPressed: _resetToOriginal,
                  child: const Text('Reset to Original', style: TextStyle(color: Color(0xFFEF4444), fontSize: 12)),
                ),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() => _isEditing = false),
                child: Text('Cancel', style: TextStyle(color: theme.textMutedColor, fontSize: 12)),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _saveEdit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.accentColor,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
                child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNoteCallout(ReaderThemeConfig theme) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.outerCardColor,
        borderRadius: BorderRadius.circular(6),
        border: Border(
          left: BorderSide(color: theme.accentColor, width: 3),
          top: BorderSide(color: theme.borderColor, width: 0.8),
          right: BorderSide(color: theme.borderColor, width: 0.8),
          bottom: BorderSide(color: theme.borderColor, width: 0.8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.sticky_note_2_rounded, size: 13, color: theme.accentColor),
              const SizedBox(width: 5),
              Text(
                'YOUR NOTE',
                style: TextStyle(
                  fontFamily: AppTheme.fontMono,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: theme.accentColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _userNote!,
            style: TextStyle(
              fontFamily: AppTheme.fontUI,
              fontSize: 13,
              height: 1.45,
              color: theme.textColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCardFooter(ReaderThemeConfig theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 16, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (widget.onDeepDive != null) ...[
            _buildActionPill(
              label: 'Fact-Check',
              icon: Icons.bolt_rounded,
              color: const Color(0xFFD97706),
              theme: theme,
              onTap: widget.onDeepDive!,
            ),
            const SizedBox(width: 8),
          ],
          _buildActionPill(
            label: 'Ask Athena',
            icon: Icons.chat_bubble_outline_rounded,
            color: theme.accentColor,
            theme: theme,
            onTap: widget.onAsk,
          ),
        ],
      ),
    );
  }

  Widget _buildActionPill({
    required String label,
    required IconData icon,
    required Color color,
    required ReaderThemeConfig theme,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: theme.outerCardColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: theme.borderColor, width: 1.0),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontFamily: AppTheme.fontUI,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: theme.textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _isCodeBlock(String text) {
    final trimmed = text.trim();
    if (trimmed.startsWith('```') || trimmed.contains('\n```')) return true;
    final lines = trimmed.split('\n');
    if (lines.length >= 2) {
      final codeLines = lines.where((l) {
        final t = l.trimLeft();
        return t.startsWith('def ') ||
            t.startsWith('class ') ||
            t.startsWith('import ') ||
            t.startsWith('from ') ||
            t.startsWith('fn ') ||
            t.startsWith('const ') ||
            t.startsWith('let ') ||
            t.startsWith('var ') ||
            t.startsWith('return ') ||
            t.startsWith('if (') ||
            t.startsWith('public ') ||
            t.endsWith(';') ||
            t.endsWith('{') ||
            t.endsWith('}');
      }).length;
      if (codeLines / lines.length > 0.4) return true;
    }
    return false;
  }
}
