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
import 'package:athena/features/saved/screens/saved_screen.dart';

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

  String _readingMode =
      'feed'; // 'feed' (1-swipe=1-card) or 'flow' (continuous)
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
  List<ReaderItem> _currentFeed = const [];
  bool _initialPositionResolved = false;
  bool _preferencesLoaded = false;
  bool _hasLocalSavedPosition = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: 0);
    _flowScrollController = ItemScrollController();
    _flowPositionsListener = ItemPositionsListener.create();
    _flowPositionsListener.itemPositions.addListener(_onFlowPositionsChanged);

    _governor = KinematicScrollGovernor(
      localDwellDuration: const Duration(milliseconds: 450),
      aiDwellDuration: const Duration(milliseconds: 1500),
      onLocalDwell: (index) {
        SharedPreferences.getInstance().then((prefs) {
          prefs.setInt('reader_pos_${widget.documentId}', index);
        });
        if (AppConfig.apiBaseUrl.isNotEmpty) {
          final chunk = _readingChunkAt(index, _currentFeed);
          if (chunk?.sequence != null) {
            ref.read(apiClientProvider).syncReadingProgress(
                  widget.documentId,
                  chunk!.sequence!,
                  chunkId: chunk.id,
                  feedIndex: index,
                );
          }
        }
      },
      onAiDwell: (index) {
        debugPrint(
            '[Athena Governor] User dwelled on index $index (>= 1500ms). Background AI synthesis permitted.');
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
      final savedLineHeight = prefs.getDouble('reader_line_height');
      final savedBionic = prefs.getBool('reader_bionic_reading');
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
          if (savedLineHeight != null) _lineHeight = savedLineHeight;
          if (savedBionic != null) _bionic = savedBionic;
          if (savedPos != null) {
            _currentIndex = savedPos;
            _hasLocalSavedPosition = true;
          }
          _preferencesLoaded = true;
        });
        if (savedPos != null && _pageController.hasClients) {
          _pageController.jumpToPage(savedPos);
        }
      }
    } catch (e) {
      debugPrint('[Athena] Reader preferences load notice: $e');
    }
  }

  Future<void> _loadChunkEdits() async {
    try {
      final edits =
          await LocalDatabase.instance.getChunkEdits(widget.documentId);
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
    _flowPositionsListener.itemPositions
        .removeListener(_onFlowPositionsChanged);
    _governor.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _onFlowPositionsChanged() {
    if (!mounted || _readingMode != 'flow' || _currentFeed.isEmpty) return;
    final visible = _flowPositionsListener.itemPositions.value
        .where((position) =>
            position.itemTrailingEdge > 0 && position.itemLeadingEdge < 1)
        .toList()
      ..sort((a, b) => a.itemLeadingEdge.compareTo(b.itemLeadingEdge));
    if (visible.isEmpty) return;
    final index = visible.first.index.clamp(0, _currentFeed.length - 1);
    if (index != _currentIndex) {
      setState(() => _currentIndex = index);
      unawaited(SharedPreferences.getInstance().then(
          (prefs) => prefs.setInt('reader_pos_${widget.documentId}', index)));
      final chunk = _readingChunkAt(index, _currentFeed);
      if (chunk?.sequence != null) {
        ref.read(apiClientProvider).syncReadingProgress(
              widget.documentId,
              chunk!.sequence!,
              chunkId: chunk.id,
              feedIndex: index,
            );
      }
      _governor.onPageTurn(index);
    }
  }

  ReaderItem? _readingChunkAt(int index, List<ReaderItem> items) {
    if (index < 0 || index >= items.length) return null;
    final item = items[index];
    if (item.isReadingChunk) return item;
    final sourceId = item.sourceChunkId ?? item.insertAfter;
    if (sourceId == null) return null;
    for (final candidate in items) {
      if (candidate.isReadingChunk && candidate.id == sourceId) return candidate;
    }
    return null;
  }

  Future<void> _persistTypography(String key, Object value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is double) await prefs.setDouble(key, value);
    if (value is String) await prefs.setString(key, value);
    if (value is bool) await prefs.setBool(key, value);
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
        progress:
            readerAsync.value != null && readerAsync.value!.items.isNotEmpty
                ? (_currentIndex + 1) / readerAsync.value!.items.length
                : 0.0,
        onBack: () => context.go('/'),
        onReadingModeChanged: (mode) {
          setState(() => _readingMode = mode);
          SharedPreferences.getInstance().then(
              (p) => p.setString('reader_mode_${widget.documentId}', mode));
        },
        onSearch: () {
          final items = readerAsync.value != null
              ? _buildFeed(readerAsync.value!)
              : <ReaderItem>[];
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
          onThemeChanged: (t) {
            setState(() => _themeId = t);
            unawaited(_persistTypography('reader_theme', t));
          },
          onFontSizeChanged: (s) {
            setState(() => _fontSize = s);
            unawaited(_persistTypography('reader_font_size', s));
          },
          onFontFamilyChanged: (f) {
            setState(() => _fontFamily = f);
            unawaited(_persistTypography('reader_font_family', f));
          },
          onLineHeightChanged: (lh) {
            setState(() => _lineHeight = lh);
            unawaited(_persistTypography('reader_line_height', lh));
          },
          onBionicChanged: (b) {
            setState(() => _bionic = b);
            unawaited(_persistTypography('reader_bionic_reading', b));
          },
        ),
        onToggleTheme: () => ref.read(themeModeProvider.notifier).toggleTheme(),
      ),
      body: SafeArea(
        top: false,
        child: readerAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
              child: Text('Error loading reader: $e',
                  style: TextStyle(color: theme.textColor))),
          data: (data) {
            final feedItems = _buildFeed(data);
            final chunks = feedItems.where((it) => it.isReadingChunk).toList();
            if (!_initialPositionResolved &&
                _preferencesLoaded &&
                feedItems.isNotEmpty) {
              _initialPositionResolved = true;
              var target = _currentIndex.clamp(0, feedItems.length - 1);
              final serverSequence = data.currentChunkIndex;
              final serverTarget = serverSequence == null
                  ? -1
                  : feedItems.indexWhere((item) =>
                      item.isReadingChunk && item.sequence == serverSequence);
              final localChunk = _hasLocalSavedPosition
                  ? _readingChunkAt(target, feedItems)
                  : null;
              if (serverTarget >= 0 &&
                  (!_hasLocalSavedPosition ||
                      (localChunk?.sequence ?? 0) < serverSequence!)) {
                target = serverTarget;
              }
              final deepLink = widget.initialChunkId;
              if (deepLink != null && deepLink.isNotEmpty) {
                final match = feedItems.indexWhere((item) =>
                    item.id == deepLink || item.sourceChunkId == deepLink);
                if (match >= 0) target = match;
              }
              _currentIndex = target;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                if (_readingMode == 'feed' && _pageController.hasClients) {
                  _pageController.jumpToPage(target);
                } else if (_readingMode == 'flow' &&
                    _flowScrollController.isAttached) {
                  _flowScrollController.jumpTo(index: target);
                }
              });
            }

            return Column(
              children: [
                // 1) Viewport (Expanded, zero stack overlap)
                Expanded(
                  child: Focus(
                    autofocus: true,
                    onKeyEvent: (_, event) =>
                        _handleKeyEvent(event, feedItems.length),
                    child: _readingMode == 'feed'
                        ? ReaderFeedView(
                            documentId: widget.documentId,
                            onJumpToPassage: (id) =>
                                _jumpToChunkId(id, feedItems),
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
                            onDismissCard: _dismissCard,
                            onAskAthenaForCard: (card) => _openAsk(card),
                          )
                        : ReaderFlowView(
                            documentId: widget.documentId,
                            onJumpToPassage: (id) =>
                                _jumpToChunkId(id, feedItems),
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
                            onDismissCard: _dismissCard,
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
                  onPrevious: _currentIndex > 0
                      ? () => _jumpTo(_currentIndex - 1, feedItems.length)
                      : null,
                  onNext: _currentIndex < feedItems.length - 1
                      ? () => _jumpTo(_currentIndex + 1, feedItems.length)
                      : null,
                  onJumpToChapter: () =>
                      _scaffoldKey.currentState?.openDrawer(),
                  onAsk: chunks.isNotEmpty
                      ? () => _openAsk(_activeChunk(feedItems, chunks))
                      : null,
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

    final items = buildInterleavedFeed(
      rawItems: data.items,
      dynamicCardsBySeq: _cardsByChunkSeq,
      dismissedCardIds: _dismissedCardIds,
      showContextCards: true,
    );
    _currentFeed = items;
    return items;
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

  Future<void> _saveQuote(ReaderItem chunk, [String? quote]) async {
    final text = quote ?? chunk.rawText;
    try {
      final title =
          ref.read(readerDataProvider(widget.documentId)).value?.title;
      await ref.read(apiClientProvider).saveUserQuote(
            id: 'quote_${DateTime.now().microsecondsSinceEpoch}',
            documentId: widget.documentId,
            chunkId: chunk.id,
            title: 'Saved passage',
            quoteText: text,
            exactQuote: text,
            documentTitle: title,
          );
      ref.invalidate(savedCardsProvider);
      if (!mounted) return;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save passage: $e')));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              'Quote saved: "${text.length > 40 ? '${text.substring(0, 40)}...' : text}"')),
    );
  }

  Future<void> _dismissCard(ReaderItem card) async {
    setState(() => _dismissedCardIds.add(card.id));
    try {
      await LocalDatabase.instance.setCardDismissed(card.id, true);
      await ref.read(apiClientProvider).dismissCard(card.id);
      ref.invalidate(readerDataProvider(widget.documentId));
    } catch (e) {
      debugPrint('[Athena] Card dismissal persistence notice: $e');
    }
  }

  ReaderItem _activeChunk(List<ReaderItem> feedItems, List<ReaderItem> chunks) {
    if (_currentIndex >= 0 && _currentIndex < feedItems.length) {
      final item = feedItems[_currentIndex];
      if (item.isReadingChunk) return item;
      final parentId = item.sourceChunkId ?? item.insertAfter;
      for (final chunk in chunks) {
        if (chunk.id == parentId) return chunk;
      }
    }
    return chunks.first;
  }

  void _jumpToChunkId(String chunkId, List<ReaderItem> feedItems) {
    final index = feedItems
        .indexWhere((item) => item.isReadingChunk && item.id == chunkId);
    if (index >= 0) _jumpTo(index, feedItems.length);
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

  Future<void> _handleGenerateCard(
      List<ReaderItem> feedItems, List<ReaderItem> chunks) async {
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
        .generateCardForChunk(
            widget.documentId, chunkMap, _cardsByChunkSeq.length)
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
