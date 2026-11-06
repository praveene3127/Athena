import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'package:athena/core/theme/theme.dart';
import 'package:athena/core/theme/reader_theme.dart';
import 'package:athena/core/config/config.dart';
import 'package:athena/models/document.dart';
import 'package:athena/services/local_database.dart';
import 'package:athena/services/local_context_service.dart';
import 'package:athena/features/library/screens/library_screen.dart';
import 'package:athena/features/reader/controllers/reader_feed_builder.dart';
import 'package:athena/features/reader/controllers/kinematic_scroll_governor.dart';
import 'package:athena/features/reader/widgets/reader_top_bar.dart';
import 'package:athena/features/reader/widgets/reader_bottom_bar.dart';
import 'package:athena/features/reader/widgets/reader_feed_view.dart';
import 'package:athena/features/reader/widgets/reader_flow_view.dart';
import 'package:athena/features/reader/widgets/typography_sheet.dart';
import 'package:athena/features/reader/widgets/reader_search_sheet.dart';
import 'package:athena/features/reader/widgets/chapters_drawer.dart';
import 'package:athena/features/reader/widgets/original_page_sheet.dart';
import 'package:athena/features/ask/widgets/ask_sheet.dart';

/// Provider for loading ReaderData for a given documentId.
final readerDataProvider =
    FutureProvider.family.autoDispose<ReaderData, String>((ref, id) async {
  final client = ref.watch(apiClientProvider);
  final json = await client.getReader(id);
  return ReaderData.fromJson(json);
});

/// L6 Modular Reader Screen.
///
/// Implements strict Column layout with zero Stack overlap:
/// 1) ReaderTopBar (56px fixed)
/// 2) Expanded Viewport (ReaderFeedView or ReaderFlowView)
/// 3) ReaderBottomBar (60px fixed)
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
  late PageController _pageController;
  late ItemScrollController _flowScrollController;
  late ItemPositionsListener _flowPositionsListener;
  late final KinematicScrollGovernor _governor;

  String _readingMode = 'feed'; // 'feed' (1-swipe=1-card) or 'flow' (continuous)
  String _themeId = 'paper';
  double _fontSize = 18.0;
  String _fontFamily = 'Georgia';
  double _lineHeight = 1.62;
  bool _bionic = false;
  int _currentIndex = 0;

  final Map<int, ReaderItem> _cardsByChunkSeq = {};
  final Set<String> _dismissedCardIds = {};
  final Map<String, String> _chunkEdits = {};
  final Map<String, String> _chunkNotes = {};

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: 0);
    _flowScrollController = ItemScrollController();
    _flowPositionsListener = ItemPositionsListener.create();

    _governor = KinematicScrollGovernor(
      localDwellDuration: const Duration(milliseconds: 450),
      aiDwellDuration: const Duration(milliseconds: 1500),
      onLocalDwell: (index) {
        SharedPreferences.getInstance().then((prefs) {
          prefs.setInt('reader_pos_${widget.documentId}', index);
        });
        if (AppConfig.apiBaseUrl.isNotEmpty) {
          ref.read(apiClientProvider).syncReadingProgress(widget.documentId, index);
        }
      },
      onAiDwell: (index) {
        debugPrint('[Athena Governor] User dwelled on index $index (>= 1500ms). Background AI synthesis permitted.');
      },
    );

    _loadPreferences();
    _loadChunkEdits();
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedMode = prefs.getString('reader_mode_${widget.documentId}');
      final savedTheme = prefs.getString('reader_theme');
      final savedSize = prefs.getDouble('reader_font_size');
      final savedFont = prefs.getString('reader_font_family');
      final savedPos = prefs.getInt('reader_pos_${widget.documentId}');

      if (mounted) {
        setState(() {
          if (savedMode != null) {
            _readingMode = savedMode;
          }
          if (savedTheme != null) {
            _themeId = savedTheme;
          }
          if (savedSize != null) {
            _fontSize = savedSize;
          }
          if (savedFont != null) {
            _fontFamily = savedFont;
          }
          if (savedPos != null && savedPos > 0) {
            _currentIndex = savedPos;
          }
        });
        if (savedPos != null && savedPos > 0 && _pageController.hasClients) {
          _pageController.jumpToPage(savedPos);
        }
      }
    } catch (e) {
      debugPrint('[Athena] Reader preferences load notice: $e');
    }
  }

  Future<void> _loadChunkEdits() async {
    try {
      final edits = await LocalDatabase.instance.getChunkEdits(widget.documentId);
      if (mounted && edits.isNotEmpty) {
        setState(() {
          for (final entry in edits.entries) {
            final text = entry.value['edited_text'] as String?;
            final note = entry.value['user_note'] as String?;
            if (text != null) {
              _chunkEdits[entry.key] = text;
            }
            if (note != null) {
              _chunkNotes[entry.key] = note;
            }
          }
        });
      }
    } catch (e) {
      debugPrint('[Athena] Chunk edits load notice: $e');
    }
  }

  @override
  void dispose() {
    _governor.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() => _currentIndex = index);
    _governor.onPageTurn(index);
  }

  void _jumpTo(int index, int total) {
    final target = index.clamp(0, total - 1);
    if (_readingMode == 'feed') {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(target);
      }
    } else {
      if (_flowScrollController.isAttached) {
        _flowScrollController.jumpTo(index: target);
      }
    }
    _onPageChanged(target);
  }

  KeyEventResult _handleKeyEvent(KeyEvent event, int totalItems) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
          event.logicalKey == LogicalKeyboardKey.space ||
          event.logicalKey == LogicalKeyboardKey.keyJ) {
        if (_currentIndex < totalItems - 1) {
          _jumpTo(_currentIndex + 1, totalItems);
          return KeyEventResult.handled;
        }
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
          event.logicalKey == LogicalKeyboardKey.keyK) {
        if (_currentIndex > 0) {
          _jumpTo(_currentIndex - 1, totalItems);
          return KeyEventResult.handled;
        }
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final readerAsync = ref.watch(readerDataProvider(widget.documentId));
    final theme = ReaderThemeConfig.getById(_themeId);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: theme.scaffoldBackground,
      drawer: readerAsync.maybeWhen(
        data: (d) => ChaptersDrawer(
          title: d.title,
          feedItems: _buildFeed(d),
          theme: theme,
          onSelectIndex: (idx) => _jumpTo(idx, d.items.length),
        ),
        orElse: () => null,
      ),
      appBar: ReaderTopBar(
        title: readerAsync.value?.title ?? '',
        readingMode: _readingMode,
        theme: theme,
        isDark: isDark,
        progress: readerAsync.value != null && readerAsync.value!.items.isNotEmpty
            ? (_currentIndex + 1) / readerAsync.value!.items.length
            : 0.0,
        onBack: () => context.go('/'),
        onReadingModeChanged: (mode) {
          setState(() => _readingMode = mode);
          SharedPreferences.getInstance().then((p) => p.setString('reader_mode_${widget.documentId}', mode));
        },
        onSearch: () {
          final items = readerAsync.value != null ? _buildFeed(readerAsync.value!) : <ReaderItem>[];
          ReaderSearchSheet.show(
            context,
            documentId: widget.documentId,
            themeId: _themeId,
            feedItems: items,
            onJumpToItemIndex: (idx) => _jumpTo(idx, items.length),
          );
        },
        onOpenToc: () => _scaffoldKey.currentState?.openDrawer(),
        onOpenTypography: () => TypographySheet.show(
          context,
          themeId: _themeId,
          fontSize: _fontSize,
          fontFamily: _fontFamily,
          lineHeight: _lineHeight,
          bionic: _bionic,
          onThemeChanged: (t) => setState(() => _themeId = t),
          onFontSizeChanged: (s) => setState(() => _fontSize = s),
          onFontFamilyChanged: (f) => setState(() => _fontFamily = f),
          onLineHeightChanged: (lh) => setState(() => _lineHeight = lh),
          onBionicChanged: (b) => setState(() => _bionic = b),
        ),
        onToggleTheme: () => ref.read(themeModeProvider.notifier).toggleTheme(),
      ),
      body: SafeArea(
        top: false,
        child: readerAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error loading reader: $e', style: TextStyle(color: theme.textColor))),
          data: (data) {
            final feedItems = _buildFeed(data);
            final chunks = feedItems.where((it) => it.isReadingChunk).toList();

            return Column(
              children: [
                // 1) Viewport (Expanded, zero stack overlap)
                Expanded(
                  child: Focus(
                    autofocus: true,
                    onKeyEvent: (_, event) => _handleKeyEvent(event, feedItems.length),
                    child: _readingMode == 'feed'
                        ? ReaderFeedView(
                            pageController: _pageController,
                            feedItems: feedItems,
                            themeId: _themeId,
                            fontSize: _fontSize,
                            fontFamily: _fontFamily,
                            lineHeight: _lineHeight,
                            bionicFocusEnabled: _bionic,
                            layoutWarning: data.layoutWarning,
                            chunkEdits: _chunkEdits,
                            chunkNotes: _chunkNotes,
                            onEditSaved: (id, text, note) {
                              setState(() {
                                if (text != null) {
                                  _chunkEdits[id] = text;
                                } else {
                                  _chunkEdits.remove(id);
                                }
                                if (note != null) {
                                  _chunkNotes[id] = note;
                                } else {
                                  _chunkNotes.remove(id);
                                }
                              });
                            },
                            onPageChanged: _onPageChanged,
                            onViewOriginalPage: (c) => _showOriginalPage(c),
                            onAsk: (c) => _openAsk(c),
                            onSaveQuote: (c, [q]) => _saveQuote(c, q),
                            onToggleSaveCard: (card) => _toggleSaveCard(card),
                            onDismissCard: (card) => setState(() => _dismissedCardIds.add(card.id)),
                            onAskAthenaForCard: (card) => _openAsk(card),
                          )
                        : ReaderFlowView(
                            itemScrollController: _flowScrollController,
                            itemPositionsListener: _flowPositionsListener,
                            feedItems: feedItems,
                            initialIndex: _currentIndex,
                            themeId: _themeId,
                            fontSize: _fontSize,
                            fontFamily: _fontFamily,
                            lineHeight: _lineHeight,
                            bionicFocusEnabled: _bionic,
                            layoutWarning: data.layoutWarning,
                            chunkEdits: _chunkEdits,
                            chunkNotes: _chunkNotes,
                            onEditSaved: (id, text, note) {
                              setState(() {
                                if (text != null) {
                                  _chunkEdits[id] = text;
                                } else {
                                  _chunkEdits.remove(id);
                                }
                                if (note != null) {
                                  _chunkNotes[id] = note;
                                } else {
                                  _chunkNotes.remove(id);
                                }
                              });
                            },
                            onViewOriginalPage: (c) => _showOriginalPage(c),
                            onAsk: (c) => _openAsk(c),
                            onSaveQuote: (c, [q]) => _saveQuote(c, q),
                            onToggleSaveCard: (card) => _toggleSaveCard(card),
                            onDismissCard: (card) => setState(() => _dismissedCardIds.add(card.id)),
                            onAskAthenaForCard: (card) => _openAsk(card),
                          ),
                  ),
                ),

                // 2) ReaderBottomBar (Fixed 60px height at bottom of Column, NEVER inside a Stack)
                ReaderBottomBar(
                  currentIndex: _currentIndex,
                  totalItems: feedItems.length,
                  feedItems: feedItems,
                  readingChunks: chunks,
                  theme: theme,
                  onPrevious: _currentIndex > 0 ? () => _jumpTo(_currentIndex - 1, feedItems.length) : null,
                  onNext: _currentIndex < feedItems.length - 1 ? () => _jumpTo(_currentIndex + 1, feedItems.length) : null,
                  onJumpToChapter: () => _scaffoldKey.currentState?.openDrawer(),
                  onAsk: chunks.isNotEmpty ? () => _openAsk(chunks[_currentIndex.clamp(0, chunks.length - 1)]) : null,
                  onGenerateCard: () => _handleGenerateCard(feedItems, chunks),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  List<ReaderItem> _buildFeed(ReaderData data) {
    for (final it in data.cards) {
      final seq = it.sequence;
      if (seq != null && seq > 0) {
        _cardsByChunkSeq[seq] = it;
      }
    }

    return buildInterleavedFeed(
      rawItems: data.items,
      dynamicCardsBySeq: _cardsByChunkSeq,
      dismissedCardIds: _dismissedCardIds,
      showContextCards: true,
    );
  }

  void _showOriginalPage(ReaderItem chunk) {
    int page = 1;
    final m = RegExp(r'\d+').firstMatch(chunk.pageReference ?? '');
    if (m != null) {
      page = int.tryParse(m.group(0)!) ?? 1;
    }

    OriginalPageSheet.show(
      context,
      documentId: widget.documentId,
      pageNumber: page,
      pageReference: chunk.pageReference,
      apiClient: ref.read(apiClientProvider),
    );
  }

  void _openAsk(ReaderItem item) {
    AskSheet.show(
      context,
      documentId: widget.documentId,
      chunk: item,
      apiClient: ref.read(apiClientProvider),
    );
  }

  void _saveQuote(ReaderItem chunk, [String? quote]) {
    final text = quote ?? chunk.rawText;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Quote saved: "${text.length > 40 ? '${text.substring(0, 40)}...' : text}"')),
    );
  }

  void _toggleSaveCard(ReaderItem card) async {
    final client = ref.read(apiClientProvider);
    final wasSaved = card.saved ?? false;
    try {
      if (wasSaved) {
        await client.unsaveCard(card.id);
      } else {
        await client.saveCard(card.id);
      }
      ref.invalidate(readerDataProvider(widget.documentId));
    } catch (e) {
      debugPrint('[Athena] Toggle save card notice: $e');
    }
  }

  Future<void> _handleGenerateCard(List<ReaderItem> feedItems, List<ReaderItem> chunks) async {
    if (chunks.isEmpty) return;
    final currentItem = (_currentIndex >= 0 && _currentIndex < feedItems.length)
        ? feedItems[_currentIndex]
        : null;
    final currentChunk = (currentItem != null && currentItem.isReadingChunk)
        ? currentItem
        : chunks.first;
    final chunkSeq = currentChunk.sequence ?? 1;

    final service = LocalContextService();
    final chunkMap = {
      'id': currentChunk.id,
      'raw_text': currentChunk.rawText,
      'sequence': chunkSeq,
    };

    // Stage 1: Instant Local Structural Draft (< 1ms)
    final draftMap = service.generateSpeculativeDraftCard(
      widget.documentId,
      chunkMap,
      _cardsByChunkSeq.length,
    );
    final draftItem = ReaderItem.fromJson({
      ...draftMap,
      'type': 'context_card',
      'insert_after': currentChunk.id,
      'source_chunk_id': currentChunk.id,
      'sequence': chunkSeq,
      'is_speculative_draft': true,
    });

    setState(() => _cardsByChunkSeq[chunkSeq] = draftItem);
    HapticFeedback.lightImpact();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _currentIndex + 1 < feedItems.length + 1) {
        _jumpTo(_currentIndex + 1, feedItems.length + 1);
      }
    });

    // Stage 2: Seamless In-Place Cloud Upgrade
    unawaited(service
        .generateCardForChunk(widget.documentId, chunkMap, _cardsByChunkSeq.length)
        .then((deepMap) async {
      if (deepMap != null && mounted) {
        final deepItem = ReaderItem.fromJson({
          ...deepMap,
          'type': 'context_card',
          'insert_after': currentChunk.id,
          'source_chunk_id': currentChunk.id,
          'sequence': chunkSeq,
          'is_speculative_draft': false,
        });
        await LocalDatabase.instance.insertCards([deepMap]);
        if (mounted) setState(() => _cardsByChunkSeq[chunkSeq] = deepItem);
      }
    }).catchError((e) {
      debugPrint('[Athena Notice] Stage 2 upgrade notice: $e');
    }));
  }
}
