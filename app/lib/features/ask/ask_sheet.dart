import 'package:flutter/material.dart';
import '../../core/errors.dart';
import '../../models/document.dart';
import '../../services/api_client.dart';
import '../../widgets/athena_avatar.dart';
import '../settings/byok_settings_sheet.dart';

const _kPromptChips = [
  'Explain this simply',
  'Give me an example',
  'What is the key term here?',
  'How does this connect to the previous section?',
];

/// Modal bottom sheet allowing the reader to ask grounded questions about a passage.
/// Complies with CLAUDE.md §8 & §11.
class AskSheet extends StatefulWidget {
  final String documentId;
  final ReaderItem chunk;
  final String? selectedText;
  final String? initialQuestion;
  final bool autoSubmit;
  final ApiClient apiClient;

  const AskSheet({
    super.key,
    required this.documentId,
    required this.chunk,
    this.selectedText,
    this.initialQuestion,
    this.autoSubmit = false,
    required this.apiClient,
  });

  static Future<void> show(
    BuildContext context, {
    required String documentId,
    required ReaderItem chunk,
    String? selectedText,
    String? initialQuestion,
    bool autoSubmit = false,
    required ApiClient apiClient,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFFCFBF7),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: AskSheet(
          documentId: documentId,
          chunk: chunk,
          selectedText: selectedText,
          initialQuestion: initialQuestion,
          autoSubmit: autoSubmit,
          apiClient: apiClient,
        ),
      ),
    );
  }

  @override
  State<AskSheet> createState() => _AskSheetState();
}

class _AskSheetState extends State<AskSheet> {
  late final TextEditingController _questionController;
  bool _loading = false;
  String? _status;
  String? _answer;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _questionController =
        TextEditingController(text: widget.initialQuestion ?? '');
    if (widget.autoSubmit &&
        widget.initialQuestion != null &&
        widget.initialQuestion!.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _submitQuestion(widget.initialQuestion!);
        }
      });
    }
  }

  @override
  void dispose() {
    _questionController.dispose();
    super.dispose();
  }

  Future<void> _submitQuestion(String question) async {
    final trimmed = question.trim();
    if (trimmed.isEmpty) return;

    setState(() {
      _loading = true;
      _status = null;
      _answer = null;
      _errorMessage = null;
    });

    try {
      final res = await widget.apiClient.askAboutPassage(
        documentId: widget.documentId,
        chunkId: widget.chunk.id,
        question: trimmed,
        selectedText: widget.selectedText,
      );

      final status = res['status'] as String? ?? 'unavailable';
      final answer = res['answer'] as String?;
      final message = res['message'] as String?;

      if (mounted) {
        setState(() {
          _status = status;
          _answer = answer;
          _errorMessage = message;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'unavailable';
          _errorMessage =
              e is AppError ? e.message : 'Unable to complete request.';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final passage = widget.selectedText ?? widget.chunk.text ?? '';
    final isNotConfigured = _status == 'not_configured';

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 12.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Tactile Drag Handle Indicator
              Center(
                child: Container(
                  width: 44,
                  height: 4.5,
                  margin: const EdgeInsets.only(top: 2, bottom: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD8DEC8),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),

              // Header Row
              Row(
                children: [
                  const AthenaAvatar(
                    expression: AthenaExpression.thinking,
                    size: 26,
                    showBezel: true,
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'ASK ATHENA · PASSAGE',
                    style: TextStyle(
                      color: Color(0xFF141714),
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      letterSpacing: 1.0,
                    ),
                  ),
                  const Spacer(),
                  InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF2F0E8),
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFFE5E7DC)),
                      ),
                      child: const Icon(Icons.close_rounded,
                          color: Color(0xFF555555), size: 18),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Double-Bezel Passage Excerpt Box
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: const Color(0xFFF7F6F2),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: const Color(0xFFE5E7DC)),
                ),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFECEEE4)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFF005E54)
                                  .withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              (widget.chunk.pageReference ?? 'Source passage')
                                  .toUpperCase(),
                              style: const TextStyle(
                                color: Color(0xFF005E54),
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ),
                          const Spacer(),
                          const Text(
                            'Verbatim Context',
                            style: TextStyle(
                              color: Color(0xFF888888),
                              fontSize: 11,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        passage,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF141714),
                          fontFamily: 'Newsreader',
                          fontSize: 14,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Quick Prompt Chips (Squircle Pill styling)
              const Text(
                'SUGGESTED INQUIRIES',
                style: TextStyle(
                  color: Color(0xFF777777),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _kPromptChips.map((chipText) {
                  return InkWell(
                    onTap: _loading || isNotConfigured
                        ? null
                        : () {
                            _questionController.text = chipText;
                            _submitQuestion(chipText);
                          },
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7F6F2),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFFE5E7DC)),
                      ),
                      child: Text(
                        chipText,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF141714),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),

              // Question input box
              TextField(
                controller: _questionController,
                maxLength: 300,
                maxLines: 2,
                enabled: !_loading && !isNotConfigured,
                style: const TextStyle(color: Color(0xFF141714), fontSize: 14),
                decoration: InputDecoration(
                  hintText: isNotConfigured
                      ? 'AI Proxy not configured (Add key in Settings)'
                      : 'Ask a specific question about this excerpt...',
                  hintStyle:
                      const TextStyle(color: Color(0xFF999999), fontSize: 13),
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: Color(0xFFE5E7DC)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: Color(0xFFE5E7DC)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide:
                        const BorderSide(color: Color(0xFF005E54), width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // Button-in-Button CTA
              Align(
                alignment: Alignment.centerRight,
                child: InkWell(
                  onTap: _loading || isNotConfigured
                      ? null
                      : () => _submitQuestion(_questionController.text),
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: isNotConfigured
                          ? const Color(0xFFD8DEC8)
                          : const Color(0xFF005E54),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color:
                              const Color(0xFF005E54).withValues(alpha: 0.18),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _loading ? 'Consulting...' : 'Ask Athena',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: _loading
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                        Colors.white),
                                  ),
                                )
                              : const Icon(Icons.arrow_upward_rounded,
                                  size: 14, color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Answer or Status Panel
              if (_loading)
                Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
                  alignment: Alignment.center,
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AthenaAvatar(
                        expression: AthenaExpression.thinking,
                        size: 44,
                        isBreathing: true,
                        showBezel: true,
                      ),
                      SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              color: Color(0xFF005E54),
                              strokeWidth: 2,
                            ),
                          ),
                          SizedBox(width: 10),
                          Text(
                            'Grounding answer in passage text...',
                            style: TextStyle(
                              color: Color(0xFF005E54),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                )
              else if (_status != null)
                _buildStatusPanel(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusPanel() {
    if (_status == 'ok' && _answer != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: const Color(0xFFEBF5F3),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: const Color(0xFFBCE3DB)),
        ),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFD5EBE5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  AthenaAvatar(
                    expression: AthenaExpression.focused,
                    size: 24,
                    showBezel: true,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'AI VERIFIED ANSWER · GROUNDED IN PASSAGE',
                    style: TextStyle(
                      color: Color(0xFF005E54),
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SelectableText(
                _answer!,
                style: const TextStyle(
                  color: Color(0xFF141714),
                  fontFamily: 'Newsreader',
                  fontSize: 14.5,
                  height: 1.55,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Status message mappings
    String title = 'Notice';
    String message = '';
    Color accentColor = const Color(0xFF777777);
    IconData icon = Icons.info_outline;

    switch (_status) {
      case 'unverified':
        title = 'Unverified in passage';
        message = 'Athena could not verify an answer from this passage alone.';
        accentColor = const Color(0xFFD97706);
        icon = Icons.warning_amber_rounded;
        break;
      case 'not_configured':
        title = 'AI Proxy not configured';
        message =
            'Passage inquiry needs an API key. Add GEMINI_API_KEY to backend/.env or configure in Settings.';
        accentColor = const Color(0xFF777777);
        icon = Icons.key_off_rounded;
        break;
      case 'rate_limited':
        title = 'Rate limit reached';
        message =
            'Too many requests. Please wait a brief moment before asking again.';
        accentColor = const Color(0xFFD97706);
        icon = Icons.hourglass_empty_rounded;
        break;
      case 'unavailable':
      default:
        title = 'Service unavailable';
        message = _errorMessage ??
            'AI service is currently unavailable. Please verify backend connection.';
        accentColor = const Color(0xFFDC2626);
        icon = Icons.error_outline_rounded;
        break;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F6F2),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accentColor.withValues(alpha: 0.3)),
      ),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE5E7DC)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: accentColor, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: accentColor,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message,
                    style: const TextStyle(
                      color: Color(0xFF333333),
                      fontSize: 12.5,
                      height: 1.4,
                    ),
                  ),
                  if (_status == 'not_configured') ...[
                    const SizedBox(height: 10),
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        BYOKSettingsSheet.show(context, apiClient: widget.apiClient);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF005E54),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        elevation: 0,
                      ),
                      icon: const Icon(Icons.key_rounded, size: 14),
                      label: const Text('Configure AI Key', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
