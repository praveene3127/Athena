import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/theme.dart';
import '../../core/reader_theme.dart';
import '../../core/errors.dart';
import '../../models/document.dart';
import '../library/library_screen.dart';
import 'chunk_widget.dart';
import 'context_card_widget.dart';
import 'original_page_sheet.dart';
import '../saved/saved_screen.dart';
import '../ask/ask_sheet.dart';
import '../settings/byok_settings_sheet.dart';

/// Provider for loading ReaderData for a given documentId.
final readerDataProvider =
    FutureProvider.family.autoDispose<ReaderData, String>((ref, id) async {
  final client = ref.watch(apiClientProvider);
  final json = await client.getReader(id);
  return ReaderData.fromJson(json);
});

class ReaderScreen extends ConsumerStatefulWidget {
  final String documentId;
  final String? initialChunkId;

  const ReaderScreen({
    super.key,
    required this.documentId,
    this.initialChunkId,
  });

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  PageController? _pageController;

  double _fontSize = 19.5;
  String _fontFamily = 'Georgia';
  double _lineHeight = 1.72;
  String _themeId = 'paper';
  bool _showContextCards = true;
  bool _restoredPosition = false;
  int _lastVisibleIndex = 0;
  Timer? _saveDebounce;
  Timer? _activeSyncTimer;
  DateTime? _lastScrollTime;
  StreamSubscription? _sseSubscription;

  // Set of dismissed card IDs in the current session
  final Set<String> _dismissedCardIds = {};
  // In-stream cards indexed by chunk sequence number (1-based)
  final Map<int, ReaderItem> _cardsByChunkSeq = {};
  // In-flight chunk sequence numbers currently being researched by Gemini
  final Set<int> _inFlightChunkSeqs = {};

  // Anti-Doomscroll Engine State (Sprints 2, 3, 4, 5)
  bool _bionicFocusEnabled = false;
  Timer? _dwellStallTimer;
  final Set<int> _stalledChunkSeqs = {};
  final Set<int> _loadingVibeSeqs = {};
  final Map<int, Map<String, String>> _vibeChecksBySeq = {};
  final List<Map<String, dynamic>> _brainDeckCards = [];
  List<Map<String, dynamic>> _chapters = [];
  bool _showPreviouslyOnBanner = true;
  int? _initialResumedIndex;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _loadPreferences();
    _setupSseStream();
    ref.read(apiClientProvider).getChapters(widget.documentId).then((ch) {
      if (mounted) setState(() => _chapters = ch);
    }).catchError((_) {});
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) {
        _checkAIKeyConfigured();
        final client = ref.read(apiClientProvider);
        _lastScrollTime = DateTime.now();
        final res = await client.syncReadingProgress(
          widget.documentId,
          _lastVisibleIndex + 1,
          readingMode: 'feed',
        );
        _applySyncResponse(res);
        _startActiveSyncTimer();
      }
    });
  }

  Future<void> _checkAIKeyConfigured() async {
    try {
      final client = ref.read(apiClientProvider);
      final prefs = await SharedPreferences.getInstance();
      final localKey = prefs.getString('athena_ai_primary_api_key');

      final config = await client.getAIConfig();
      final bool isConfigured = config.isConfigured ||
          (config.primaryApiKeyMasked != null &&
              config.primaryApiKeyMasked!.isNotEmpty) ||
          (localKey != null && localKey.isNotEmpty);

      if (!isConfigured && mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppTheme.surfaceWarm,
            title: const Text(
              'API Key Required',
              style: TextStyle(
                  fontFamily: AppTheme.fontDisplay,
                  fontWeight: FontWeight.w600),
            ),
            content: const Text(
              'Athena requires an AI API key (Gemini, OpenRouter, Groq, etc.) to analyze context, generate marginalia, and explain concepts.',
              style: TextStyle(fontFamily: AppTheme.fontUI, fontSize: 13.5),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  if (context.canPop()) {
                    context.pop();
                  } else {
                    context.go('/library');
                  }
                },
                child: const Text('Return to Library'),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  BYOKSettingsSheet.show(
                    context,
                    apiClient: client,
                    onConfigSaved: () {
                      _checkAIKeyConfigured();
                    },
                  );
                },
                child: const Text('Configure API Key'),
              ),
            ],
          ),
        );
      } else if (!config.isConfigured && localKey != null && localKey.isNotEmpty) {
        final localProvider = prefs.getString('athena_ai_primary_provider') ?? 'gemini';
        client.saveAIConfig(
          primaryProvider: localProvider,
          primaryApiKey: localKey,
          primaryModel: prefs.getString('athena_ai_primary_model'),
          primaryBaseUrl: prefs.getString('athena_ai_primary_base_url'),
        ).catchError((_) => <String, dynamic>{});
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _activeSyncTimer?.cancel();
    _dwellStallTimer?.cancel();
    _sseSubscription?.cancel();
    _pageController?.dispose();
    super.dispose();
  }

  void _applySyncResponse(Map<String, dynamic> data) {
    if (!mounted || data.isEmpty) return;
    bool changed = false;

    final inFlightList = data['in_flight'] as List?;
    final newInFlight = inFlightList != null
        ? inFlightList
            .map((e) => (e is num) ? e.toInt() : int.tryParse(e.toString()))
            .whereType<int>()
            .toSet()
        : <int>{};
    if (_inFlightChunkSeqs.length != newInFlight.length ||
        !_inFlightChunkSeqs.containsAll(newInFlight)) {
      _inFlightChunkSeqs.clear();
      _inFlightChunkSeqs.addAll(newInFlight);
      changed = true;
    }

    final cardsList = data['cards'] as List?;
    if (cardsList != null) {
      for (final rawItem in cardsList) {
        if (rawItem is Map) {
          final cardJson = rawItem.map((k, v) => MapEntry(k.toString(), v));
          final card = ReaderItem.fromJson(cardJson);
          int? seq = (cardJson['seq_num'] as num?)?.toInt() ??
              (cardJson['sequence'] as num?)?.toInt() ??
              card.sequence;
          if (seq == null && card.insertAfter != null) {
            final m = RegExp(r'-c(\d+)$').firstMatch(card.insertAfter!);
            if (m != null) {
              seq = int.tryParse(m.group(1)!);
            }
          }
          if (seq != null) {
            final existing = _cardsByChunkSeq[seq];
            if (existing == null ||
                existing.id != card.id ||
                existing.saved != card.saved) {
              _cardsByChunkSeq[seq] = card;
              _inFlightChunkSeqs.remove(seq);
              changed = true;
            }
          }
        }
      }
    }

    if (changed && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  void _startActiveSyncTimer() {
    _activeSyncTimer?.cancel();
    _activeSyncTimer =
        Timer.periodic(const Duration(milliseconds: 2500), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final bool hasInFlight = _inFlightChunkSeqs.isNotEmpty;
      final bool recentlyScrolled = _lastScrollTime != null &&
          DateTime.now().difference(_lastScrollTime!).inSeconds < 12;

      if (!hasInFlight && !recentlyScrolled) {
        timer.cancel();
        _activeSyncTimer = null;
        return;
      }

      final client = ref.read(apiClientProvider);
      final chunkIdx = _lastVisibleIndex + 1;
      final res = await client.syncReadingProgress(
        widget.documentId,
        chunkIdx,
        readingMode: 'feed',
      );
      _applySyncResponse(res);
    });
  }

  void _setupSseStream() {
    if (kIsWeb) return;
    final client = ref.read(apiClientProvider);
    client.dio
        .get<ResponseBody>(
      '/api/documents/${widget.documentId}/events',
      options: Options(responseType: ResponseType.stream),
    )
        .then((response) {
      final stream = response.data?.stream;
      if (stream == null) return;
      _sseSubscription = stream
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.startsWith('data: ')) {
          try {
            final jsonStr = line.substring(6).trim();
            final event = jsonDecode(jsonStr) as Map<String, dynamic>;
            if (event['type'] == 'card_ready') {
              final chunkIndex = event['chunk_index'] as int?;
              final cardData = event['card'] as Map<String, dynamic>?;
              if (chunkIndex != null && cardData != null) {
                final card = ReaderItem.fromJson(cardData);
                if (mounted) {
                  setState(() {
                    _cardsByChunkSeq[chunkIndex] = card;
                    _inFlightChunkSeqs.remove(chunkIndex);
                  });
                }
              }
              if (mounted) {
                ref.invalidate(readerDataProvider(widget.documentId));
              }
            }
          } catch (_) {}
        }
      }, onError: (_) {});
    }).catchError((_) {});
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final savedFontSize = prefs.getDouble('reader_font_size');
    final savedFontFamily = prefs.getString('reader_font_family');
    final savedLineHeight = prefs.getDouble('reader_line_height');
    final savedTheme = prefs.getString('reader_theme');
    final savedShowCards = prefs.getBool('reader_show_context_cards');
    final savedBionic = prefs.getBool('athena_bionic_focus_enabled');
    String? brainDeckJson = prefs.getString('athena_saved_notes_v1');
    if (brainDeckJson == null || brainDeckJson.isEmpty) {
      final legacy = prefs.getString('athena_brain_deck_cards_v1') ??
          prefs.getString('athena_brain_deck_v1');
      if (legacy != null && legacy.isNotEmpty) {
        brainDeckJson = legacy;
        await prefs.setString('athena_saved_notes_v1', legacy);
        await prefs.remove('athena_brain_deck_cards_v1');
        await prefs.remove('athena_brain_deck_v1');
      }
    }
    List<Map<String, dynamic>> loadedCards = [];
    if (brainDeckJson != null && brainDeckJson.isNotEmpty) {
      try {
        final decoded = json.decode(brainDeckJson);
        if (decoded is List) {
          loadedCards = decoded
              .whereType<Map>()
              .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
              .toList();
        }
      } catch (_) {
        prefs.remove('athena_saved_notes_v1');
      }
    }
    if (mounted) {
      setState(() {
        if (savedFontSize != null) _fontSize = savedFontSize;
        if (savedFontFamily != null && savedFontFamily.isNotEmpty) {
          _fontFamily = savedFontFamily;
        }
        if (savedLineHeight != null) _lineHeight = savedLineHeight;
        if (savedTheme != null && savedTheme.isNotEmpty) {
          _themeId = savedTheme;
        }
        if (savedShowCards != null) _showContextCards = savedShowCards;
        if (savedBionic != null) _bionicFocusEnabled = savedBionic;
        _brainDeckCards.clear();
        _brainDeckCards.addAll(loadedCards);
      });
    }
  }

  List<ReaderItem> _getFeedItems(List<ReaderItem> rawItems) {
    final chunks = rawItems.where((it) => it.isReadingChunk).toList();
    final feedItems = <ReaderItem>[];
    for (final chunk in chunks) {
      feedItems.add(chunk);
      final seq = chunk.sequence ?? 0;
      final card = _cardsByChunkSeq[seq];
      if (card != null &&
          _showContextCards &&
          !_dismissedCardIds.contains(card.id)) {
        feedItems.add(card);
      }
    }
    return feedItems;
  }

  Future<void> _updateFontSize(double delta) async {
    final newSize = (_fontSize + delta).clamp(13.0, 26.0);
    setState(() => _fontSize = newSize);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('reader_font_size', newSize);
  }

  void _nextCard(int total) {
    if (_lastVisibleIndex < total) {
      _pageController?.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _previousCard() {
    if (_lastVisibleIndex > 0) {
      _pageController?.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  DateTime _lastWheelTime = DateTime.now();

  void _handlePointerSignal(PointerSignalEvent event, int total) {
    if (event is PointerScrollEvent) {
      final now = DateTime.now();
      if (now.difference(_lastWheelTime).inMilliseconds < 260) return;
      if (event.scrollDelta.dy > 12) {
        _lastWheelTime = now;
        _nextCard(total);
      } else if (event.scrollDelta.dy < -12) {
        _lastWheelTime = now;
        _previousCard();
      }
    }
  }

  int _parsePageNumber(String? pageReference) {
    if (pageReference == null || pageReference.isEmpty) return 1;
    // Extract first integer from "Page 4" or "Pages 4–5"
    final match = RegExp(r'\d+').firstMatch(pageReference);
    if (match != null) {
      return int.tryParse(match.group(0)!) ?? 1;
    }
    return 1;
  }

  void _restoreReadingPosition(
    List<ReaderItem> feedItems, {
    int? backendChunkIndex,
  }) async {
    if (_restoredPosition) return;
    _restoredPosition = true;

    int targetIndex = 0;

    if (widget.initialChunkId != null) {
      final idx =
          feedItems.indexWhere((it) => it.id == widget.initialChunkId);
      if (idx != -1) targetIndex = idx;
    } else {
      final prefs = await SharedPreferences.getInstance();
      final savedPos = prefs.getInt('reader_pos_${widget.documentId}');
      if (savedPos != null && savedPos >= 0 && savedPos < feedItems.length) {
        targetIndex = savedPos;
      } else if (backendChunkIndex != null && backendChunkIndex > 0) {
        final idx = feedItems.indexWhere(
            (it) => it.isReadingChunk && it.sequence == backendChunkIndex);
        if (idx != -1) {
          targetIndex = idx;
        } else {
          targetIndex = (backendChunkIndex - 1)
              .clamp(0, feedItems.isNotEmpty ? feedItems.length - 1 : 0);
        }
      }
    }

    _lastVisibleIndex = targetIndex;

    if (targetIndex >= 5) {
      _initialResumedIndex = targetIndex;
      _showPreviouslyOnBanner = true;
    }

    if (mounted) {
      setState(() {
        if (_pageController != null && _pageController!.hasClients) {
          _pageController!.jumpToPage(targetIndex);
        } else {
          _pageController = PageController(initialPage: targetIndex);
        }
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pageController != null && _pageController!.hasClients) {
        _pageController!.jumpToPage(targetIndex);
      }
    });
  }

  // --- Anti-Doomscroll Engine Implementations (Sprints 2, 3, 4, 5) ---

  void _armDwellStallTimer(int seq, [int wordCount = 60]) {
    if (_vibeChecksBySeq.containsKey(seq) || _stalledChunkSeqs.contains(seq)) {
      return;
    }
    final stallSecs = (2.2 * (wordCount / 4.0)).round().clamp(15, 28);
    _dwellStallTimer?.cancel();
    _dwellStallTimer = Timer(Duration(seconds: stallSecs), () {
      if (mounted) {
        setState(() {
          _stalledChunkSeqs.add(seq);
        });
        HapticFeedback.lightImpact();
      }
    });
  }

  Future<void> _fetchAndUnlockVibeCheck(int seq) async {
    if (_loadingVibeSeqs.contains(seq)) return;
    setState(() {
      _loadingVibeSeqs.add(seq);
    });
    HapticFeedback.lightImpact();
    try {
      final client = ref.read(apiClientProvider);
      final res = await client.fetchVibeCheck(widget.documentId, seq);
      if (mounted) {
        setState(() {
          _loadingVibeSeqs.remove(seq);
          _stalledChunkSeqs.remove(seq);
          _vibeChecksBySeq[seq] = {
            'plain_take': res['plain_take']?.toString() ?? '',
            'analogy': res['analogy']?.toString() ?? '',
          };
        });
        HapticFeedback.mediumImpact();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingVibeSeqs.remove(seq);
          _stalledChunkSeqs.remove(seq);
          _vibeChecksBySeq[seq] = {
            'plain_take':
                'Unable to connect to AI service. Tap retry when connected.',
            'analogy': '',
          };
        });
      }
    }
  }

  Widget _buildVibeCheckSlot(int seq) {
    if (_vibeChecksBySeq.containsKey(seq)) {
      final data = _vibeChecksBySeq[seq]!;
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF141714),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppTheme.lime, width: 1.2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.16),
              blurRadius: 18,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppTheme.lime,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.short_text_rounded,
                          size: 13, color: AppTheme.figmaBlack),
                      SizedBox(width: 4),
                      Text(
                        'PASSAGE SYNTHESIS',
                        style: TextStyle(
                          color: AppTheme.figmaBlack,
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon:
                      const Icon(Icons.close, size: 16, color: Colors.white60),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () {
                    setState(() {
                      _vibeChecksBySeq.remove(seq);
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'SUMMARY',
              style: TextStyle(
                color: AppTheme.lime,
                fontSize: 9.5,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              data['plain_take'] ?? '',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                height: 1.45,
              ),
            ),
            if (data['analogy'] != null &&
                data['analogy']!.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'ANALOGY',
                style: TextStyle(
                  color: Color(0xFF00C4B4),
                  fontSize: 9.5,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.lightbulb_outline,
                        size: 14, color: Color(0xFF00C4B4)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        data['analogy']!,
                        style: const TextStyle(
                          color: Color(0xFFEDF7DB),
                          fontSize: 12.5,
                          fontStyle: FontStyle.italic,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      );
    }

    if (_stalledChunkSeqs.contains(seq) || _loadingVibeSeqs.contains(seq)) {
      final isLoading = _loadingVibeSeqs.contains(seq);
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: isLoading ? null : () => _fetchAndUnlockVibeCheck(seq),
          icon: isLoading
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppTheme.cyan),
                )
              : const Icon(Icons.short_text_rounded,
                  size: 16, color: AppTheme.cyan),
          label: Text(
            isLoading ? 'Synthesizing passage...' : 'Simplify this passage',
            style: const TextStyle(
              color: AppTheme.cyan,
              fontSize: 12.5,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.3,
            ),
          ),
          style: OutlinedButton.styleFrom(
            backgroundColor: AppTheme.cyan.withValues(alpha: 0.08),
            side: BorderSide(
              color: AppTheme.cyan.withValues(alpha: 0.40),
              width: 1.2,
            ),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Future<void> _toggleBionicFocus() async {
    final next = !_bionicFocusEnabled;
    setState(() => _bionicFocusEnabled = next);
    HapticFeedback.selectionClick();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('athena_bionic_focus_enabled', next);
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

  Widget _buildZeigarnikWhisper(
      int targetSeq, ReaderItem targetCard, int currentIndex) {
    final rawTitle = targetCard.title ?? 'Context';
    final cleanTitle = _stripEmojis(rawTitle);

    return InkWell(
      onTap: () {
        _nextCard(_lastVisibleIndex + 3);
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFF141714).withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: const Color(0xFF00C4B4).withValues(alpha: 0.35),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: Color(0xFF00C4B4),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'UPCOMING CONTEXT · $cleanTitle',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.figmaBlack,
                  letterSpacing: 0.4,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.arrow_forward_ios,
                size: 10, color: AppTheme.textMuted),
          ],
        ),
      ),
    );
  }

  Widget _buildZeigarnikIfEligible(
      List<ReaderItem> chunks, int index, int seq) {
    if (!_cardsByChunkSeq.containsKey(seq) &&
        !_cardsByChunkSeq.containsKey(seq + 1) &&
        _cardsByChunkSeq.containsKey(seq + 2)) {
      final targetCard = _cardsByChunkSeq[seq + 2]!;
      return _buildZeigarnikWhisper(seq + 2, targetCard, index);
    }
    return const SizedBox.shrink();
  }

  bool _isCardInBrainDeck(String cardId) {
    return _brainDeckCards.any((c) => c['id'] == cardId);
  }

  Future<void> _toggleBrainDeck(
      ReaderItem card, String docTitle, int chunkSeq) async {
    final existingIndex = _brainDeckCards.indexWhere((c) => c['id'] == card.id);
    final prefs = await SharedPreferences.getInstance();
    final client = ref.read(apiClientProvider);
    final isSaving = existingIndex < 0;

    setState(() {
      if (existingIndex >= 0) {
        _brainDeckCards.removeAt(existingIndex);
        if (_cardsByChunkSeq.containsKey(chunkSeq)) {
          _cardsByChunkSeq[chunkSeq] =
              _cardsByChunkSeq[chunkSeq]!.copyWith(saved: false);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Removed from Saved Notes'),
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        _brainDeckCards.add({
          'id': card.id,
          'docId': widget.documentId,
          'docTitle': docTitle,
          'chunkSeq': chunkSeq,
          'title': _stripEmojis(card.title ?? 'Context'),
          'body': card.body ?? '',
          'exactQuote': card.exactQuote ?? '',
          'citations': card.citations ?? [],
          'savedAt': DateTime.now().toIso8601String(),
        });
        if (_cardsByChunkSeq.containsKey(chunkSeq)) {
          _cardsByChunkSeq[chunkSeq] =
              _cardsByChunkSeq[chunkSeq]!.copyWith(saved: true);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Saved to notes'),
            duration: Duration(seconds: 2),
            backgroundColor: AppTheme.figmaBlack,
          ),
        );
      }
    });

    await prefs.setString(
        'athena_saved_notes_v1', json.encode(_brainDeckCards));

    // Persist to backend and invalidate saved cards provider so Saved Ideas tab is always in sync
    try {
      if (isSaving) {
        await client.saveCard(card.id);
      } else {
        await client.unsaveCard(card.id);
      }
      ref.invalidate(savedCardsProvider);
    } catch (_) {}
  }

  void _showBrainDeckSheet(BuildContext context, String docTitle) {
    final totalCitations = _brainDeckCards.fold<int>(
      0,
      (sum, c) => sum + ((c['citations'] as List?)?.length ?? 0),
    );

    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return SafeArea(
            child: Container(
              height: MediaQuery.of(ctx).size.height * 0.85,
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: AppTheme.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      const Icon(Icons.bookmarks_outlined,
                          color: AppTheme.figmaBlack, size: 22),
                      const SizedBox(width: 8),
                      const Text(
                        'Saved Notes & Citations',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.figmaBlack,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: [
                      Chip(
                        label: Text('${_brainDeckCards.length} Saved Notes'),
                        backgroundColor: AppTheme.background,
                        side: BorderSide(
                            color: AppTheme.border.withValues(alpha: 0.8)),
                      ),
                      Chip(
                        label: Text('$totalCitations Citations'),
                        backgroundColor: AppTheme.cyan.withValues(alpha: 0.12),
                        side: BorderSide(
                            color: AppTheme.cyan.withValues(alpha: 0.30)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _brainDeckCards.isEmpty
                          ? null
                          : () {
                              final buffer = StringBuffer();
                              buffer.writeln(
                                  '# Athena — Saved Notes & Citations');
                              buffer.writeln(
                                  '*Exported on ${DateTime.now().toLocal().toString().split(".")[0]}*\n');
                              for (final c in _brainDeckCards) {
                                buffer.writeln(
                                    '### ${_stripEmojis(c['title'] ?? 'Note')}');
                                if (c['exactQuote'] != null &&
                                    c['exactQuote'].toString().isNotEmpty) {
                                  buffer.writeln('> "${c['exactQuote']}"\n');
                                }
                                buffer.writeln('${c['body']}\n');
                                final cites = c['citations'] as List?;
                                if (cites != null && cites.isNotEmpty) {
                                  buffer.writeln('**Sources:**');
                                  for (final cit in cites) {
                                    buffer.writeln(
                                        '- [${cit['title'] ?? 'Source'}](${cit['url'] ?? '#'})');
                                  }
                                  buffer.writeln();
                                }
                                buffer.writeln('---\n');
                              }
                              Clipboard.setData(
                                  ClipboardData(text: buffer.toString()));
                              Navigator.of(ctx).pop();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                      'Notes copied as Markdown to clipboard'),
                                  backgroundColor: AppTheme.figmaBlack,
                                ),
                              );
                            },
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      label: const Text('Copy All as Markdown'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.figmaBlack,
                        foregroundColor: AppTheme.lime,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Divider(color: AppTheme.border, height: 1),
                  const SizedBox(height: 10),
                  Expanded(
                    child: _brainDeckCards.isEmpty
                        ? const Center(
                            child: Text(
                              'No notes saved yet.\nTap "Save Note" on any context card to save citations here.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: AppTheme.textMuted, fontSize: 13),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _brainDeckCards.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 10),
                            itemBuilder: (ctx, i) {
                              final item = _brainDeckCards[i];
                              final cleanItemTitle =
                                  _stripEmojis(item['title'] ?? 'Note');
                              return Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppTheme.background,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: AppTheme.border),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            cleanItemTitle,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.bold,
                                              color: AppTheme.figmaBlack,
                                            ),
                                          ),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete_outline,
                                              size: 18,
                                              color: Colors.redAccent),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                          onPressed: () {
                                            setState(() {
                                              _brainDeckCards.removeAt(i);
                                            });
                                            setSheetState(() {});
                                            SharedPreferences.getInstance()
                                                .then((prefs) {
                                              prefs.setString(
                                                  'athena_saved_notes_v1',
                                                  json.encode(_brainDeckCards));
                                            });
                                          },
                                        ),
                                      ],
                                    ),
                                    if (item['exactQuote'] != null &&
                                        item['exactQuote']
                                            .toString()
                                            .isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        '"${item['exactQuote']}"',
                                        style: const TextStyle(
                                          fontStyle: FontStyle.italic,
                                          fontSize: 12,
                                          color: AppTheme.textMuted,
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 6),
                                    Text(
                                      item['body'] ?? '',
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: AppTheme.textPrimary,
                                        height: 1.4,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPreviouslyOnBanner(List<ReaderItem> chunks) {
    if (!_showPreviouslyOnBanner ||
        (_initialResumedIndex == null || _initialResumedIndex! < 5)) {
      return const SizedBox.shrink();
    }

    ReaderItem? lastCard;
    for (int s = _initialResumedIndex! + 1; s >= 1; s--) {
      if (_cardsByChunkSeq.containsKey(s)) {
        lastCard = _cardsByChunkSeq[s];
        break;
      }
    }

    final rawCardTitle = lastCard?.title ?? 'Core Argument';
    final cardTitle = _stripEmojis(rawCardTitle);
    final cardQuote =
        (lastCard?.exactQuote != null && lastCard!.exactQuote!.isNotEmpty)
            ? '"${lastCard.exactQuote!}"'
            : 'Key premise established in the previous section.';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF141714),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.lime, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history_rounded, size: 15, color: AppTheme.lime),
              const SizedBox(width: 8),
              const Text(
                'PREVIOUS CONTEXT',
                style: TextStyle(
                  color: AppTheme.lime,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close, size: 16, color: Colors.white70),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () =>
                    setState(() => _showPreviouslyOnBanner = false),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            cardTitle,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13.5,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            cardQuote,
            style: const TextStyle(
              color: Color(0xFFEDF7DB),
              fontSize: 12.5,
              fontStyle: FontStyle.italic,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  void _dismissCard(ReaderItem card) {
    final client = ref.read(apiClientProvider);
    client.dismissCard(card.id);
    setState(() => _dismissedCardIds.add(card.id));

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Context card "${card.title ?? 'Excerpt'}" hidden'),
        backgroundColor: AppTheme.figmaBlack,
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'UNDO',
          textColor: AppTheme.lime,
          onPressed: () {
            client.restoreCard(card.id);
            setState(() => _dismissedCardIds.remove(card.id));
          },
        ),
      ),
    );
  }

  void _showIntegrityDialog(ReaderData data) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: AppTheme.border),
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Row(
          children: [
            Icon(Icons.verified, color: Color(0xFF005E54), size: 22),
            SizedBox(width: 8),
            Text('Cryptographic Integrity', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This check confirms that chunking preserved every extracted character in order. It cannot guarantee that PDF extraction or reading order was perfect; use the original page to verify complex layouts.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 16),
            _infoRow(
                'Status',
                data.integrityVerified ? 'Verified' : 'Unverified',
                data.integrityVerified
                    ? const Color(0xFF005E54)
                    : Colors.redAccent),
            _infoRow(
                'Total Chunks', '${data.chunkCount}', AppTheme.textPrimary),
            const SizedBox(height: 8),
            const Text(
              'Original SHA-256:',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
            ),
            SelectableText(
              data.originalChecksum ?? 'N/A',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: AppTheme.cyan,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Reconstructed SHA-256:',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
            ),
            SelectableText(
              data.reconstructedChecksum ?? 'N/A',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: AppTheme.cyan,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('CLOSE', style: TextStyle(color: AppTheme.cyan)),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 13)),
          Text(
            value,
            style: TextStyle(
                color: color, fontWeight: FontWeight.bold, fontSize: 13),
          ),
        ],
      ),
    );
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: AppTheme.border),
          borderRadius: BorderRadius.circular(20),
        ),
        title: const Text('About Athena', style: TextStyle(fontSize: 16)),
        content: const Text(
          'Athena preserves source text fidelity with grounded AI context.\n\n'
          'Extracted text is partitioned strictly into contiguous slices without rewriting. '
          'AI context cards provide explanatory notes without modifying source material.',
          style: TextStyle(
              color: AppTheme.textPrimary, fontSize: 13, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child:
                const Text('DISMISS', style: TextStyle(color: AppTheme.cyan)),
          ),
        ],
      ),
    );
  }

  void _openAskSheet(ReaderItem chunk) {
    final client = ref.read(apiClientProvider);
    AskSheet.show(
      context,
      documentId: widget.documentId,
      chunk: chunk,
      apiClient: client,
    );
  }

  void _openAskSheetForCard(ReaderItem card, List<ReaderItem> items) {
    final client = ref.read(apiClientProvider);
    final sourceChunk = items.firstWhere(
      (it) =>
          it.isReadingChunk &&
          (it.id == card.insertAfter ||
              (card.sequence != null && it.sequence == card.sequence)),
      orElse: () => items.firstWhere(
        (it) => it.isReadingChunk,
        orElse: () => card,
      ),
    );
    final initialQuery =
        'Explain "${card.title}" in simpler terms with real-world context';
    final cardExcerpt = (card.body != null && card.body!.trim().isNotEmpty)
        ? card.body!
        : (card.exactQuote ?? card.title ?? '');

    AskSheet.show(
      context,
      documentId: widget.documentId,
      chunk: sourceChunk,
      selectedText: cardExcerpt,
      initialQuestion: initialQuery,
      autoSubmit: true,
      apiClient: client,
    );
  }

  Widget _buildChaptersDrawer(
    BuildContext context,
    List<ReaderItem> feedItems,
    int totalChunks,
    ReaderThemeConfig theme,
  ) {
    final client = ref.read(apiClientProvider);

    // Determine current chunk sequence
    int currentChunkSeq = 1;
    if (_lastVisibleIndex >= 0 && _lastVisibleIndex < feedItems.length) {
      final currentItem = feedItems[_lastVisibleIndex];
      if (currentItem.isReadingChunk) {
        currentChunkSeq = currentItem.sequence ?? (_lastVisibleIndex + 1);
      } else if (currentItem.isContextCard) {
        currentChunkSeq = currentItem.sequence ?? 1;
      }
    }

    return Drawer(
      backgroundColor: theme.innerCardColor,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: [
                  Icon(Icons.menu_book_rounded,
                      color: theme.accentColor, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Table of Contents',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: theme.textColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$totalChunks document chunks',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: theme.textMutedColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, size: 20, color: theme.textMutedColor),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(color: theme.borderColor, height: 1),
            Expanded(
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: _chapters.isNotEmpty
                    ? Future.value(_chapters)
                    : client.getChapters(widget.documentId),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting &&
                      _chapters.isEmpty) {
                    return Center(
                      child: CircularProgressIndicator(color: theme.accentColor),
                    );
                  }
                  final chapters = (snapshot.data != null && snapshot.data!.isNotEmpty)
                      ? snapshot.data!
                      : _chapters;
                  if (chapters.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.auto_stories_outlined,
                                size: 32, color: theme.textMutedColor),
                            const SizedBox(height: 12),
                            Text(
                              'Document sections are being indexed.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: theme.textMutedColor, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  // Find active chapter
                  int activeChapterIndex = 0;
                  for (int i = 0; i < chapters.length; i++) {
                    final startChunk = chapters[i]['start_chunk_index'] as int? ?? 1;
                    if (startChunk <= currentChunkSeq) {
                      activeChapterIndex = i;
                    } else {
                      break;
                    }
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: chapters.length,
                    separatorBuilder: (_, __) => Divider(
                      color: theme.borderColor.withValues(alpha: 0.5),
                      height: 1,
                      indent: 16,
                      endIndent: 16,
                    ),
                    itemBuilder: (context, index) {
                      final ch = chapters[index];
                      final title = ch['title'] as String? ?? 'Chapter ${index + 1}';
                      final level = ch['level'] as int? ?? 1;
                      final startChunk = ch['start_chunk_index'] as int? ?? 1;
                      final startPage = (ch['start_page'] as int? ?? 0) + 1;
                      final isActive = index == activeChapterIndex;

                      return Container(
                        color: isActive
                            ? theme.accentColor.withValues(alpha: 0.10)
                            : Colors.transparent,
                        child: ListTile(
                          contentPadding: EdgeInsets.only(
                            left: 16.0 + (level - 1) * 12.0,
                            right: 16.0,
                          ),
                          dense: true,
                          leading: isActive
                              ? Container(
                                  width: 4,
                                  height: 24,
                                  decoration: BoxDecoration(
                                    color: theme.accentColor,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                )
                              : null,
                          title: Text(
                            title,
                            style: TextStyle(
                              fontSize: level == 1 ? 14 : 13,
                              fontWeight: isActive
                                  ? FontWeight.w700
                                  : (level == 1 ? FontWeight.w600 : FontWeight.normal),
                              color: isActive ? theme.accentColor : theme.textColor,
                            ),
                          ),
                          trailing: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: theme.outerCardColor,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: theme.borderColor),
                            ),
                            child: Text(
                              'p. $startPage',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: isActive ? FontWeight.w700 : FontWeight.normal,
                                color: isActive ? theme.accentColor : theme.textMutedColor,
                              ),
                            ),
                          ),
                          onTap: () {
                            Navigator.of(context).pop();
                            final targetItemIndex = feedItems.indexWhere(
                              (it) => it.isReadingChunk && it.sequence == startChunk,
                            );
                            if (targetItemIndex != -1) {
                              setState(() => _lastVisibleIndex = targetItemIndex);
                              _pageController?.jumpToPage(targetItemIndex);
                              client.syncReadingProgress(
                                widget.documentId,
                                startChunk,
                                readingMode: 'feed',
                              );
                            } else {
                              final fallbackIdx = (startChunk - 1)
                                  .clamp(0, feedItems.isNotEmpty ? feedItems.length - 1 : 0);
                              setState(() => _lastVisibleIndex = fallbackIdx);
                              _pageController?.jumpToPage(fallbackIdx);
                            }
                          },
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final readerAsync = ref.watch(readerDataProvider(widget.documentId));
    final apiClient = ref.read(apiClientProvider);

    final theme = ReaderThemeConfig.getById(_themeId);

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: theme.scaffoldBackground,
      drawer: readerAsync.maybeWhen(
        data: (d) {
          final feedItems = _getFeedItems(d.items);
          final totalChunks = d.items.where((it) => it.isReadingChunk).length;
          return _buildChaptersDrawer(context, feedItems, totalChunks, theme);
        },
        orElse: () => null,
      ),
      appBar: AppBar(
        backgroundColor: theme.scaffoldBackground,
        elevation: 0,
        leading: Container(
          margin: const EdgeInsets.only(left: 14),
          child: IconButton(
            icon: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: theme.innerCardColor,
                shape: BoxShape.circle,
                border: Border.all(color: theme.borderColor),
              ),
              child: Icon(Icons.arrow_back_rounded,
                  color: theme.textColor, size: 18),
            ),
            tooltip: 'Back to Library',
            onPressed: () => context.go('/'),
          ),
        ),
        title: readerAsync.when(
          data: (data) => Text(
            data.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: AppTheme.fontDisplay,
              fontSize: 18,
              fontWeight: FontWeight.w400,
              color: theme.textColor,
              letterSpacing: 0.1,
            ),
          ),
          loading: () => Text('Loading reader...',
              style: TextStyle(color: theme.textColor)),
          error: (_, __) =>
              Text('Reader', style: TextStyle(color: theme.textColor)),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: readerAsync.maybeWhen(
            data: (data) {
              final total = data.items.length;
              final progress =
                  total > 0 ? (_lastVisibleIndex / total).clamp(0.0, 1.0) : 0.0;
              return LinearProgressIndicator(
                value: progress,
                backgroundColor: theme.borderColor,
                color: theme.accentColor,
                minHeight: 2,
              );
            },
            orElse: () => const SizedBox.shrink(),
          ),
        ),
        actions: [
          // 1. Table of Contents Drawer Button (ALWAYS VISIBLE)
          IconButton(
            icon: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: theme.innerCardColor,
                shape: BoxShape.circle,
                border: Border.all(color: theme.borderColor),
              ),
              child: Icon(Icons.menu_book_rounded,
                  color: theme.textColor, size: 18),
            ),
            tooltip: 'Table of Contents',
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          ),
          // 2. Saved Notes Vault Button (only show if count > 0)
          if (_brainDeckCards.isNotEmpty)
            Tooltip(
              message: 'Saved Notes',
              child: InkWell(
                onTap: () {
                  final docTitle = readerAsync.valueOrNull?.title ?? 'Document';
                  _showBrainDeckSheet(context, docTitle);
                },
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  margin:
                      const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: theme.innerCardColor,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: theme.accentColor.withValues(alpha: 0.6),
                      width: 1.0,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.bookmarks_outlined,
                          size: 13, color: theme.accentColor),
                      const SizedBox(width: 5),
                      Text(
                        '${_brainDeckCards.length}',
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          color: theme.textColor,
                          fontWeight: FontWeight.w700,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // 3. Single Aa Appearance Button
          IconButton(
            tooltip: 'Appearance & Reading Options',
            icon: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: theme.innerCardColor,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: theme.borderColor),
              ),
              child: Text(
                'Aa',
                style: TextStyle(
                  fontFamily: AppTheme.fontUI,
                  color: theme.textColor,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ),
            onPressed: () => _showAppearanceSheet(context),
          ),
          // 4. Quick Theme Switcher Button
          Consumer(
            builder: (context, ref, _) {
              final isAppDark = Theme.of(context).brightness == Brightness.dark;
              return IconButton(
                tooltip: isAppDark ? 'Switch to Light Theme' : 'Switch to Dark Theme',
                icon: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: theme.innerCardColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: theme.borderColor),
                  ),
                  child: Icon(
                    isAppDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                    size: 16,
                    color: isAppDark ? Colors.amberAccent : theme.textColor,
                  ),
                ),
                onPressed: () {
                  HapticFeedback.selectionClick();
                  ref.read(themeModeProvider.notifier).toggleTheme();
                  if (!isAppDark) {
                    if (_themeId == 'paper' || _themeId == 'sepia') {
                      setState(() => _themeId = 'night');
                    }
                  } else {
                    if (_themeId == 'night' || _themeId == 'obsidian') {
                      setState(() => _themeId = 'paper');
                    }
                  }
                },
              );
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: readerAsync.when(
        data: (data) {
          final items = data.items;
          final chunks = items.where((it) => it.isReadingChunk).toList();

          if (chunks.isEmpty) {
            Timer(const Duration(seconds: 2), () {
              if (mounted) {
                ref.invalidate(readerDataProvider(widget.documentId));
              }
            });
            return _buildExtractingState();
          }

          // Seed cards from initial payload
          for (final it in items) {
            if (it.isContextCard) {
              int? seq = it.sequence;
              if (seq == null && it.insertAfter != null) {
                final m = RegExp(r'-c(\d+)$').firstMatch(it.insertAfter!);
                if (m != null) seq = int.tryParse(m.group(1)!);
              }
              if (seq != null && !_cardsByChunkSeq.containsKey(seq)) {
                _cardsByChunkSeq[seq] = it;
              }
            }
          }

          // Feed mode item list (chunks interleaved with ready cards)
          final feedItems = _getFeedItems(items);

          // Initial scroll restoration
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _restoreReadingPosition(
              feedItems,
              backendChunkIndex: data.currentChunkIndex,
            );
          });

          return Column(
            children: [
              // Reader Body: Feed Mode (Doom-Scroll) as the sole, polished reading experience
              Expanded(
                child: Focus(
                  autofocus: true,
                  onKeyEvent: (node, event) {
                    if (ModalRoute.of(context)?.isCurrent != true) {
                      return KeyEventResult.ignored;
                    }
                    final primaryFocus =
                        FocusManager.instance.primaryFocus;
                    if (primaryFocus != null &&
                        primaryFocus.context?.widget is EditableText) {
                      return KeyEventResult.ignored;
                    }
                    if (event is KeyDownEvent) {
                      if (event.logicalKey ==
                              LogicalKeyboardKey.arrowDown ||
                          event.logicalKey == LogicalKeyboardKey.space ||
                          event.logicalKey ==
                              LogicalKeyboardKey.pageDown ||
                          event.logicalKey == LogicalKeyboardKey.keyJ) {
                        _nextCard(feedItems.length);
                        return KeyEventResult.handled;
                      } else if (event.logicalKey ==
                              LogicalKeyboardKey.arrowUp ||
                          event.logicalKey == LogicalKeyboardKey.pageUp ||
                          event.logicalKey == LogicalKeyboardKey.keyK) {
                        _previousCard();
                        return KeyEventResult.handled;
                      }
                    }
                    return KeyEventResult.ignored;
                  },
                  child: Stack(
                    children: [
                      Listener(
                        onPointerSignal: (event) =>
                            _handlePointerSignal(event, feedItems.length),
                        child: PageView.builder(
                          scrollDirection: Axis.vertical,
                          controller: _pageController,
                          physics: const PageScrollPhysics(
                              parent: BouncingScrollPhysics()),
                          onPageChanged: (index) {
                            setState(() => _lastVisibleIndex = index);
                            final currentItem = index < feedItems.length
                                ? feedItems[index]
                                : null;
                            if (currentItem != null && currentItem.isReadingChunk) {
                              final seq = currentItem.sequence ?? (index + 1);
                              final wordCount = currentItem.rawText.split(RegExp(r'\s+')).length;
                              _armDwellStallTimer(seq, wordCount);
                            }
                            _saveDebounce?.cancel();
                            _saveDebounce =
                                Timer(const Duration(milliseconds: 600),
                                    () async {
                              final prefs =
                                  await SharedPreferences.getInstance();
                              await prefs.setInt(
                                  'reader_pos_${widget.documentId}',
                                  index);
                              if (mounted) {
                                final item = index < feedItems.length
                                    ? feedItems[index]
                                    : null;
                                final chunkIdx =
                                    (item != null && item.isReadingChunk)
                                        ? (item.sequence ?? (index + 1))
                                        : index + 1;

                                final client =
                                    ref.read(apiClientProvider);
                                final resp =
                                    await client.syncReadingProgress(
                                  widget.documentId,
                                  chunkIdx,
                                  readingMode: 'feed',
                                );
                                if (mounted) {
                                  _applySyncResponse(resp);
                                  _startActiveSyncTimer();
                                }
                              }
                            });
                          },
                          itemCount: feedItems.length + 1,
                          itemBuilder: (context, index) {
                            if (index == feedItems.length) {
                              // Celebratory End-of-Document Bento Card
                              return Center(
                                child: ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 680),
                                  child: Container(
                                    margin: const EdgeInsets.fromLTRB(
                                        16, 8, 16, 68),
                                    padding: const EdgeInsets.all(32),
                                    decoration: BoxDecoration(
                                      color: theme.innerCardColor,
                                      borderRadius:
                                          BorderRadius.circular(28),
                                      border: Border.all(
                                          color: theme.borderColor,
                                          width: 1.5),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                              alpha: theme.isDark ? 0.35 : 0.05),
                                          blurRadius: 20,
                                          offset: const Offset(0, 8),
                                        ),
                                      ],
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          padding:
                                              const EdgeInsets.all(16),
                                          decoration: BoxDecoration(
                                            color: theme.accentColor
                                                .withValues(alpha: 0.15),
                                            shape: BoxShape.circle,
                                          ),
                                          child: Icon(
                                              Icons.verified,
                                              color: theme.accentColor,
                                              size: 40),
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          'End of document',
                                          style: TextStyle(
                                            color: theme.textColor,
                                            fontWeight: FontWeight.w800,
                                            fontSize: 20,
                                            letterSpacing: -0.3,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          'All ${data.chunkCount} chunks read with verified cryptographic fidelity.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                              color: theme.textMutedColor,
                                              fontSize: 13.5,
                                              height: 1.4),
                                        ),
                                        const SizedBox(height: 24),
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            OutlinedButton.icon(
                                              onPressed: () {
                                                _pageController
                                                    ?.jumpToPage(0);
                                              },
                                              icon: const Icon(
                                                  Icons.replay,
                                                  size: 16),
                                              label: const Text(
                                                  'Read again'),
                                            ),
                                            const SizedBox(width: 12),
                                            ElevatedButton.icon(
                                              onPressed: () =>
                                                  context.go('/'),
                                              icon: const Icon(
                                                  Icons.library_books,
                                                  size: 16),
                                              label: const Text(
                                                  'Back to Library'),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            }

                            final item = feedItems[index];

                            if (item.isReadingChunk) {
                              final seq = item.sequence ?? (index + 1);
                              return SizedBox.expand(
                                child: SingleChildScrollView(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (_showPreviouslyOnBanner &&
                                          seq ==
                                              (_initialResumedIndex !=
                                                      null
                                                  ? (_initialResumedIndex! +
                                                      1)
                                                  : -1))
                                        _buildPreviouslyOnBanner(chunks),
                                      _buildZeigarnikIfEligible(
                                          chunks, index, seq),
                                      ChunkWidget(
                                        chunk: item,
                                        fontSize: _fontSize,
                                        fontFamily: _fontFamily,
                                        lineHeight: _lineHeight,
                                        themeId: _themeId,
                                        isFeedMode: true,
                                        bionicFocusEnabled:
                                            _bionicFocusEnabled,
                                        layoutWarning: data.layoutWarning,
                                        onViewOriginalPage: () {
                                          final pageNum =
                                              _parsePageNumber(
                                                  item.pageReference);
                                          OriginalPageSheet.show(
                                            context,
                                            documentId: widget.documentId,
                                            pageNumber: pageNum,
                                            pageReference:
                                                item.pageReference,
                                            apiClient: apiClient,
                                          );
                                        },
                                        onAsk: () => _openAskSheet(item),
                                      ),
                                      AnimatedSize(
                                        duration: const Duration(
                                            milliseconds: 300),
                                        curve: Curves.easeOutCubic,
                                        child: _buildVibeCheckSlot(seq),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            } else if (item.isContextCard) {
                              return ContextCardWidget(
                                card: item,
                                isFeedMode: true,
                                isBrainDeckSaved:
                                    _isCardInBrainDeck(item.id),
                                onToggleBrainDeck: () => _toggleBrainDeck(
                                  item,
                                  data.title,
                                  item.sequence ?? 1,
                                ),
                                onToggleSave: () async {
                                  final currentlySaved =
                                      item.saved ?? false;
                                  if (currentlySaved) {
                                    await apiClient.unsaveCard(item.id);
                                  } else {
                                    await apiClient.saveCard(item.id);
                                  }
                                  ref.invalidate(readerDataProvider(
                                      widget.documentId));
                                },
                                onDismiss: () => _dismissCard(item),
                                onAskAthena: () =>
                                    _openAskSheetForCard(item, feedItems),
                              );
                            }

                            return const SizedBox.shrink();
                          },
                        ),
                      ),

                      // Single Minimal Bottom Pill: < 1 / 857 >
                      Positioned(
                        bottom:
                            18 + MediaQuery.of(context).padding.bottom,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: theme.isDark
                                  ? const Color(0xFF1E221E)
                                  : const Color(0xFF141714),
                              borderRadius: BorderRadius.circular(32),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.16),
                                width: 1.0,
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x38000000),
                                  blurRadius: 22,
                                  offset: Offset(0, 6),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(
                                      Icons.chevron_left_rounded,
                                      color: Colors.white,
                                      size: 22),
                                  tooltip:
                                      'Previous card (Up Arrow / Scroll Up)',
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                      minWidth: 44, minHeight: 44),
                                  onPressed: _lastVisibleIndex > 0
                                      ? _previousCard
                                      : null,
                                ),
                                const SizedBox(width: 4),
                                Builder(
                                  builder: (context) {
                                    final currentItem =
                                        (_lastVisibleIndex >= 0 &&
                                                _lastVisibleIndex <
                                                    feedItems.length)
                                            ? feedItems[_lastVisibleIndex]
                                            : null;
                                    final String counterLabel;
                                    if (currentItem != null &&
                                        currentItem.isReadingChunk) {
                                      final currentSeq =
                                          currentItem.sequence ??
                                              (_lastVisibleIndex + 1);
                                      counterLabel =
                                          '$currentSeq / ${chunks.length}';
                                    } else if (currentItem != null &&
                                        currentItem.isContextCard) {
                                      final targetSeq =
                                          currentItem.sequence ?? '';
                                      counterLabel = targetSeq != ''
                                          ? 'Context · #$targetSeq'
                                          : 'Context';
                                    } else {
                                      counterLabel =
                                          '${(_lastVisibleIndex + 1).clamp(1, feedItems.length)} / ${feedItems.length}';
                                    }
                                    return Text(
                                      counterLabel,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 12,
                                        letterSpacing: 0.3,
                                      ),
                                    );
                                  },
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  icon: const Icon(
                                      Icons.chevron_right_rounded,
                                      color: Colors.white,
                                      size: 22),
                                  tooltip:
                                      'Next card (Down Arrow / Space / Scroll Down)',
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                      minWidth: 44, minHeight: 44),
                                  onPressed: _lastVisibleIndex <
                                          feedItems.length
                                      ? () => _nextCard(feedItems.length)
                                      : null,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
        loading: () => const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: AppTheme.lime),
              SizedBox(height: 16),
              Text(
                'Opening document...',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 14),
              ),
            ],
          ),
        ),
        error: (err, stack) {
          final message = err is AppError ? err.message : err.toString();
          final isNotReady = (err is AppError && err.code == 'CONFLICT') ||
              message.toLowerCase().contains('not ready') ||
              message.toLowerCase().contains('processing');

          if (isNotReady) {
            Timer(const Duration(seconds: 2), () {
              if (mounted) {
                ref.invalidate(readerDataProvider(widget.documentId));
              }
            });
            return _buildExtractingState();
          }

          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline,
                      color: Colors.redAccent, size: 48),
                  const SizedBox(height: 16),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: () =>
                        ref.invalidate(readerDataProvider(widget.documentId)),
                    child: const Text('Retry'),
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: () => context.go('/'),
                    child: const Text('Back to Library',
                        style: TextStyle(color: AppTheme.textMuted)),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildExtractingState() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: AppTheme.figmaBlack,
            ),
          ),
          SizedBox(height: 18),
          Text(
            'Finishing PDF extraction...',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 6),
          Text(
            'Chunks are being verified and prepared for reading.',
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  void _showAppearanceSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final currentTheme = ReaderThemeConfig.getById(_themeId);
            final readerData =
                ref.read(readerDataProvider(widget.documentId)).valueOrNull;
            final docTitle = readerData?.title ?? 'Document';

            return Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.88,
              ),
              decoration: BoxDecoration(
                color: currentTheme.scaffoldBackground,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(24)),
                border: Border.all(color: currentTheme.borderColor),
              ),
              child: SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: currentTheme.borderColor,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Text(
                            'Appearance & Options',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: currentTheme.textColor,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: Icon(Icons.close,
                                size: 20, color: currentTheme.textMutedColor),
                            onPressed: () => Navigator.of(ctx).pop(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // 1. Whole-App Theme Selection (System / Light / Dark)
                      Text(
                        'APP THEME',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: currentTheme.textMutedColor,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Consumer(
                        builder: (context, ref, _) {
                          final currentMode = ref.watch(themeModeProvider);
                          return Container(
                            decoration: BoxDecoration(
                              color: currentTheme.outerCardColor,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: currentTheme.borderColor),
                            ),
                            padding: const EdgeInsets.all(4),
                            child: Row(
                              children: [
                                _buildAppThemeOption(
                                  title: 'System',
                                  icon: Icons.brightness_auto_rounded,
                                  mode: ThemeMode.system,
                                  selected: currentMode == ThemeMode.system,
                                  currentTheme: currentTheme,
                                  setSheetState: setSheetState,
                                ),
                                _buildAppThemeOption(
                                  title: 'Light',
                                  icon: Icons.light_mode_rounded,
                                  mode: ThemeMode.light,
                                  selected: currentMode == ThemeMode.light,
                                  currentTheme: currentTheme,
                                  setSheetState: setSheetState,
                                ),
                                _buildAppThemeOption(
                                  title: 'Dark',
                                  icon: Icons.dark_mode_rounded,
                                  mode: ThemeMode.dark,
                                  selected: currentMode == ThemeMode.dark,
                                  currentTheme: currentTheme,
                                  setSheetState: setSheetState,
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 20),

                      // 2. Reading Theme Selection
                      Text(
                        'READING THEME',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: currentTheme.textMutedColor,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: ReaderThemeConfig.all.map((t) {
                          final isSelected = t.id == _themeId;
                          return Expanded(
                            child: GestureDetector(
                              onTap: () async {
                                setState(() => _themeId = t.id);
                                setSheetState(() {});
                                HapticFeedback.selectionClick();
                                final prefs =
                                    await SharedPreferences.getInstance();
                                await prefs.setString('reader_theme', t.id);
                              },
                              child: Container(
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                padding: const EdgeInsets.symmetric(
                                    vertical: 10, horizontal: 6),
                                decoration: BoxDecoration(
                                  color: t.scaffoldBackground,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: isSelected
                                        ? t.accentColor
                                        : t.borderColor,
                                    width: isSelected ? 2.0 : 1.0,
                                  ),
                                  boxShadow: isSelected
                                      ? [
                                          BoxShadow(
                                            color: t.accentColor
                                                .withValues(alpha: 0.25),
                                            blurRadius: 8,
                                            offset: const Offset(0, 2),
                                          )
                                        ]
                                      : null,
                                ),
                                child: Column(
                                  children: [
                                    Container(
                                      width: 24,
                                      height: 24,
                                      decoration: BoxDecoration(
                                        color: t.outerCardColor,
                                        shape: BoxShape.circle,
                                        border:
                                            Border.all(color: t.borderColor),
                                      ),
                                      child: Center(
                                        child: Text(
                                          'Aa',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: t.textColor,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      t.name,
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: isSelected
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                        color: t.textColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 20),

                      // 2. Typography Selection
                      Text(
                        'TYPOGRAPHY',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: currentTheme.textMutedColor,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildFontChip('Georgia', 'Serif', currentTheme,
                              setSheetState),
                          _buildFontChip('Geist', 'Sans', currentTheme,
                              setSheetState),
                          _buildFontChip('DM Serif Display', 'Editorial',
                              currentTheme, setSheetState),
                          _buildFontChip('Courier New', 'Mono', currentTheme,
                              setSheetState),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // 3. Line Spacing Selection
                      Text(
                        'LINE SPACING',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: currentTheme.textMutedColor,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          _buildSpacingChip('Compact', 1.50, currentTheme,
                              setSheetState),
                          const SizedBox(width: 8),
                          _buildSpacingChip('Standard', 1.72, currentTheme,
                              setSheetState),
                          const SizedBox(width: 8),
                          _buildSpacingChip('Relaxed', 2.00, currentTheme,
                              setSheetState),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // 4. Text Size Control
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'TEXT SIZE',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                              color: currentTheme.textMutedColor,
                            ),
                          ),
                          Text(
                            '${_fontSize.toStringAsFixed(1)} pt',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: currentTheme.textColor,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          IconButton(
                            icon: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: currentTheme.outerCardColor,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: currentTheme.borderColor),
                              ),
                              child: Text(
                                'A-',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: currentTheme.textColor,
                                ),
                              ),
                            ),
                            onPressed: () {
                              _updateFontSize(-1.0);
                              setSheetState(() {});
                            },
                          ),
                          Expanded(
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                activeTrackColor: currentTheme.accentColor,
                                inactiveTrackColor: currentTheme.borderColor,
                                thumbColor: currentTheme.accentColor,
                                overlayColor: currentTheme.accentColor
                                    .withValues(alpha: 0.2),
                                trackHeight: 3,
                              ),
                              child: Slider(
                                value: _fontSize,
                                min: 13.0,
                                max: 26.0,
                                divisions: 26,
                                onChanged: (val) {
                                  setState(() => _fontSize = val);
                                  setSheetState(() {});
                                  SharedPreferences.getInstance().then(
                                      (prefs) => prefs.setDouble(
                                          'reader_font_size', val));
                                },
                              ),
                            ),
                          ),
                          IconButton(
                            icon: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: currentTheme.outerCardColor,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: currentTheme.borderColor),
                              ),
                              child: Text(
                                'A+',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                  color: currentTheme.textColor,
                                ),
                              ),
                            ),
                            onPressed: () {
                              _updateFontSize(1.0);
                              setSheetState(() {});
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Divider(color: currentTheme.borderColor, height: 1),
                      const SizedBox(height: 12),

                      // 5. Reading Aids & Options
                      Text(
                        'READING AIDS',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: currentTheme.textMutedColor,
                        ),
                      ),
                      const SizedBox(height: 6),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          'Focus Mode (Bionic Reading)',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: currentTheme.textColor,
                          ),
                        ),
                        subtitle: Text(
                          'Emboldens word fixations to accelerate reading flow.',
                          style: TextStyle(
                              fontSize: 12,
                              color: currentTheme.textMutedColor),
                        ),
                        value: _bionicFocusEnabled,
                        activeTrackColor: currentTheme.accentColor,
                        onChanged: (val) {
                          _toggleBionicFocus();
                          setSheetState(() {});
                        },
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          'Context Marginalia Cards',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: currentTheme.textColor,
                          ),
                        ),
                        subtitle: Text(
                          'Displays grounded AI commentary and historical context between chunks.',
                          style: TextStyle(
                              fontSize: 12,
                              color: currentTheme.textMutedColor),
                        ),
                        value: _showContextCards,
                        activeTrackColor: currentTheme.accentColor,
                        onChanged: (val) async {
                          setState(() => _showContextCards = val);
                          setSheetState(() {});
                          final prefs =
                              await SharedPreferences.getInstance();
                          await prefs.setBool(
                              'reader_show_context_cards', val);
                        },
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.bookmarks_outlined,
                            color: currentTheme.accentColor),
                        title: Text(
                          'Saved Notes Vault',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: currentTheme.textColor,
                          ),
                        ),
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: currentTheme.outerCardColor,
                            borderRadius: BorderRadius.circular(12),
                            border:
                                Border.all(color: currentTheme.borderColor),
                          ),
                          child: Text(
                            '${_brainDeckCards.length}',
                            style: TextStyle(
                              color: currentTheme.accentColor,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          _showBrainDeckSheet(context, docTitle);
                        },
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.verified_outlined,
                            color: currentTheme.accentColor),
                        title: Text(
                          'Cryptographic Integrity Status',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: currentTheme.textColor,
                          ),
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          if (readerData != null) {
                            _showIntegrityDialog(readerData);
                          }
                        },
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.info_outline,
                            color: currentTheme.textMutedColor),
                        title: Text(
                          'About Athena',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: currentTheme.textColor,
                          ),
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          _showAboutDialog();
                        },
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildFontChip(String family, String label, ReaderThemeConfig theme,
      StateSetter setSheetState) {
    final isSelected = _fontFamily == family;
    return GestureDetector(
      onTap: () async {
        setState(() => _fontFamily = family);
        setSheetState(() {});
        HapticFeedback.selectionClick();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('reader_font_family', family);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? theme.outerCardColor : theme.innerCardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? theme.accentColor : theme.borderColor,
            width: isSelected ? 1.6 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Aa',
              style: TextStyle(
                fontFamily: family,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: isSelected ? theme.accentColor : theme.textColor,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? theme.accentColor : theme.textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpacingChip(String label, double height,
      ReaderThemeConfig theme, StateSetter setSheetState) {
    final isSelected = (_lineHeight - height).abs() < 0.05;
    return Expanded(
      child: GestureDetector(
        onTap: () async {
          setState(() => _lineHeight = height);
          setSheetState(() {});
          HapticFeedback.selectionClick();
          final prefs = await SharedPreferences.getInstance();
          await prefs.setDouble('reader_line_height', height);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? theme.outerCardColor : theme.innerCardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? theme.accentColor : theme.borderColor,
              width: isSelected ? 1.6 : 1.0,
            ),
          ),
          child: Column(
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? theme.accentColor : theme.textColor,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${height.toStringAsFixed(2)}x',
                style: TextStyle(
                  fontSize: 10,
                  color: isSelected ? theme.accentColor : theme.textMutedColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppThemeOption({
    required String title,
    required IconData icon,
    required ThemeMode mode,
    required bool selected,
    required ReaderThemeConfig currentTheme,
    required StateSetter setSheetState,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          ref.read(themeModeProvider.notifier).setThemeMode(mode);
          if (mode == ThemeMode.dark && (_themeId == 'paper' || _themeId == 'sepia')) {
            setState(() => _themeId = 'night');
          } else if (mode == ThemeMode.light && (_themeId == 'night' || _themeId == 'obsidian')) {
            setState(() => _themeId = 'paper');
          }
          setSheetState(() {});
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? currentTheme.innerCardColor : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    )
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 15,
                color: selected ? currentTheme.accentColor : currentTheme.textMutedColor,
              ),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  fontFamily: AppTheme.fontUI,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? currentTheme.textColor : currentTheme.textMutedColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
