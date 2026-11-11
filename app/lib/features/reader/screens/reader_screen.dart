import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'package:athena/core/config/config.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/core/theme/reader_theme.dart';
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

class _ReaderScreenState extends ConsumerState<ReaderScreen>
    with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  late PageController _pageController;
  late ItemScrollController _flowScrollController;
  late ItemPositionsListener _flowPositionsListener;
  late final KinematicScrollGovernor _governor;

  String _readingMode =
      'feed'; // 'feed' (1-swipe=1-card) or 'flow' (continuous)
  String _themeId = 'paper';
  double _fontSize = 18.0;
  String _fontFamily = AppTheme.fontReading;
  double _lineHeight = 1.62;
  bool _bionic = false;
  int _currentIndex = 0;

  final Map<int, ReaderItem> _cardsByChunkSeq = {};
  final Set<String> _dismissedCardIds = {};
  final Map<String, String> _chunkEdits = {};
  final Map<String, String> _chunkNotes = {};
  final Map<String, ReaderItem> _chunksById = {};
  Timer? _flowSaveDebounceTimer;
  List<ReaderItem> _currentFeed = const [];
  List<ReaderItem> _cachedFeedItems = const [];
  ReaderData? _lastReaderData;
  bool _initialPositionResolved = false;
  bool _preferencesLoaded = false;
  String? _savedChunkId;
  int? _savedChunkSeq;
  bool _isGeneratingCard = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageController = PageController(initialPage: 0);
    _flowScrollController = ItemScrollController();
    _flowPositionsListener = ItemPositionsListener.create();
    _flowPositionsListener.itemPositions.addListener(_onFlowPositionsChanged);

    _governor = KinematicScrollGovernor(
      localDwellDuration: const Duration(milliseconds: 450),
      aiDwellDuration: const Duration(milliseconds: 1500),
      onLocalDwell: (index) {
        if (index < 0 || index >= _cachedFeedItems.length) return;
        final chunk = _readingChunkAt(index, _cachedFeedItems);
        final chunkSeq = chunk?.sequence;
        final chunkId = chunk?.id;

        SharedPreferences.getInstance().then((prefs) {
          prefs.setInt('reader_pos_${widget.documentId}', index);
          if (chunkId != null) {
            prefs.setString('reader_chunk_id_${widget.documentId}', chunkId);
          }
          if (chunkSeq != null) {
            prefs.setInt('reader_chunk_seq_${widget.documentId}', chunkSeq);
          }
        });

        if (chunkSeq != null) {
          _syncProgressAndMergeCards(chunkSeq,
              chunkId: chunkId, feedIndex: index);
        }
        _prefetchUpcomingCards(index);
      },
      onAiDwell: (index) async {
        if (index < 0 || index >= _cachedFeedItems.length) return;
        final currentItem = _cachedFeedItems[index];
        if (!currentItem.isReadingChunk) return;
        final chunkSeq = currentItem.sequence;
        if (chunkSeq == null || _cardsByChunkSeq.containsKey(chunkSeq)) return;

        final chunkId = currentItem.id;

        try {
          final chunkDb = await LocalDatabase.instance.getChunkById(chunkId);
          final chunkMap = chunkDb ?? {
            'id': currentItem.id,
            'raw_text': currentItem.rawText,
            'sequence': chunkSeq,
          };

          Map<String, Object?>? cardMap;
          if (!AppConfig.isStandaloneMobile &&
              AppConfig.apiBaseUrl.isNotEmpty) {
            try {
              final serverCard = await ref
                  .read(apiClientProvider)
                  .generateCardForChunk(
                    widget.documentId,
                    chunkSeq,
                    chunkId: currentItem.id,
                    feedIndex: index,
                  );
              if (serverCard != null) {
                cardMap = Map<String, Object?>.from(serverCard);
              }
            } catch (e) {
              debugPrint(
                  '[Athena Card Sync] Remote generateCardForChunk notice: $e');
            }
          }

          if (cardMap == null) {
            final service = LocalContextService();
            cardMap = await service.generateCardForChunk(
              widget.documentId,
              chunkMap,
              _cardsByChunkSeq.length,
            );
          }

          if (cardMap != null) {
            // ALWAYS persist valid generated cards to SQLite so the work is never lost (RC-07)
            await LocalDatabase.instance.insertCards([cardMap]);

            final cardItem = ReaderItem.fromJson({
              ...cardMap,
              'type': 'context_card',
              'insert_after': currentItem.id,
              'source_chunk_id': currentItem.id,
              'sequence': chunkSeq,
              'is_speculative_draft': false,
            });

            _cardsByChunkSeq[chunkSeq] = cardItem;

            // UI-04: Only insert background-prefetched cards at chunkSeq >= currentChunkSeq
            // and reconcile _currentIndex atomically in the same frame
            final currentChunk = _readingChunkAt(_currentIndex, _cachedFeedItems);
            final currentSeq = currentChunk?.sequence ?? 0;
            if (chunkSeq >= currentSeq) {
              if (mounted) {
                setState(() {
                  _recomputeCachedFeed();
                });
              }
            }
          }
        } catch (e) {
          debugPrint('[Athena Dwell Notice] Background card generation: $e');
        }
      },
    );

    _loadPreferences();
    _loadChunkEdits();
  }

  final Set<int> _prefetchInFlight = {};

  void _prefetchUpcomingCards(int currentFeedIndex) {
    if (_cachedFeedItems.isEmpty) return;

    // Prefetch window: [cursor + 1 .. cursor + 12]
    final start = (currentFeedIndex + 1).clamp(0, _cachedFeedItems.length);
    final end = (currentFeedIndex + 13).clamp(0, _cachedFeedItems.length);

    for (int i = start; i < end; i++) {
      final item = _cachedFeedItems[i];
      if (!item.isReadingChunk) continue;
      final seq = item.sequence;
      if (seq == null ||
          _cardsByChunkSeq.containsKey(seq) ||
          _prefetchInFlight.contains(seq)) {
        continue;
      }

      if (_prefetchInFlight.length >= 2) break;

      _prefetchInFlight.add(seq);
      _executePrefetchForChunk(item);
    }
  }

  Future<void> _executePrefetchForChunk(ReaderItem item) async {
    final seq = item.sequence;
    if (seq == null) return;
    try {
      final chunkDb = await LocalDatabase.instance.getChunkById(item.id);
      final chunkMap = chunkDb ?? {
        'id': item.id,
        'raw_text': item.rawText,
        'sequence': seq,
        'section_title': item.sectionTitle,
        'section_role': item.sectionRole,
      };

      Map<String, Object?>? cardMap;
      if (!AppConfig.isStandaloneMobile && AppConfig.apiBaseUrl.isNotEmpty) {
        try {
          final serverCard = await ref
              .read(apiClientProvider)
              .generateCardForChunk(
                widget.documentId,
                seq,
                chunkId: item.id,
              );
          if (serverCard != null) {
            cardMap = Map<String, Object?>.from(serverCard);
          }
        } catch (e) {
          debugPrint('[Athena Prefetch] Remote generateCardForChunk notice: $e');
        }
      }

      if (cardMap == null) {
        final service = LocalContextService();
        cardMap = await service.generateCardForChunk(
          widget.documentId,
          chunkMap,
          _cardsByChunkSeq.length,
        );
      }

      if (cardMap != null) {
        await LocalDatabase.instance.insertCards([cardMap]);

        final cardItem = ReaderItem.fromJson({
          ...cardMap,
          'type': 'context_card',
          'insert_after': item.id,
          'source_chunk_id': item.id,
          'sequence': seq,
          'is_speculative_draft': false,
        });

        _cardsByChunkSeq[seq] = cardItem;

        // UI-04: Only insert background-prefetched cards at chunkSeq >= currentChunkSeq
        final currentChunk = _readingChunkAt(_currentIndex, _cachedFeedItems);
        final currentSeq = currentChunk?.sequence ?? 0;
        if (seq >= currentSeq) {
          if (mounted) {
            setState(() {
              _recomputeCachedFeed();
            });
          }
        }
      }
    } catch (e) {
      debugPrint('[Athena Prefetch Notice] Card generation: $e');
    } finally {
      _prefetchInFlight.remove(seq);
    }
  }

  void _syncData(ReaderData data) {
    _lastReaderData = data;

    if (data.chunkEditsMap.isNotEmpty) {
      for (final entry in data.chunkEditsMap.entries) {
        final text = entry.value['edited_text'] as String?;
        final note = entry.value['user_note'] as String?;
        if (text != null && text.isNotEmpty) _chunkEdits[entry.key] = text;
        if (note != null && note.isNotEmpty) _chunkNotes[entry.key] = note;
      }
    }

    for (final it in data.cards) {
      final seq = it.sequence;
      if (seq != null && seq > 0) {
        _cardsByChunkSeq[seq] = it;
      }
    }

    _recomputeCachedFeed(data);
    _prefetchUpcomingCards(_currentIndex);
  }

  void _recomputeCachedFeed([ReaderData? data]) {
    final d = data ?? _lastReaderData;
    if (d == null) return;

    final String? anchorItemId = (_cachedFeedItems.isNotEmpty &&
            _currentIndex >= 0 &&
            _currentIndex < _cachedFeedItems.length)
        ? _cachedFeedItems[_currentIndex].id
        : null;

    _cachedFeedItems = buildInterleavedFeed(
      rawItems: d.items,
      dynamicCardsBySeq: _cardsByChunkSeq,
      dismissedCardIds: _dismissedCardIds,
      showContextCards: true,
    );
    _currentFeed = _cachedFeedItems;
    _chunksById.clear();
    for (final it in _cachedFeedItems) {
      if (it.isReadingChunk) {
        _chunksById[it.id] = it;
      }
    }

    if (anchorItemId != null && _cachedFeedItems.isNotEmpty) {
      final newIdx = _cachedFeedItems.indexWhere((it) => it.id == anchorItemId);
      if (newIdx != -1 && newIdx != _currentIndex) {
        _currentIndex = newIdx;
        if (_readingMode == 'feed' && _pageController.hasClients) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_pageController.hasClients && mounted) {
              _pageController.jumpToPage(newIdx);
            }
          });
        }
      }
    }
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
      final savedChunkId = prefs.getString('reader_chunk_id_${widget.documentId}');
      final savedChunkSeq = prefs.getInt('reader_chunk_seq_${widget.documentId}');

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
          if (savedChunkId != null) _savedChunkId = savedChunkId;
          if (savedChunkSeq != null) _savedChunkSeq = savedChunkSeq;
          if (savedPos != null) {
            _currentIndex = savedPos;
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
    WidgetsBinding.instance.removeObserver(this);
    _flowSaveDebounceTimer?.cancel();
    _flowPositionsListener.itemPositions
        .removeListener(_onFlowPositionsChanged);
    _governor.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _flushReadingProgress();
    }
  }

  void _flushReadingProgress() {
    if (_currentIndex < 0 || _currentIndex >= _cachedFeedItems.length) return;
    final chunk = _readingChunkAt(_currentIndex, _cachedFeedItems);
    final chunkSeq = chunk?.sequence;
    final chunkId = chunk?.id;
    if (chunkSeq != null) {
      ref.read(apiClientProvider).syncReadingProgress(
            widget.documentId,
            chunkSeq,
            chunkId: chunkId,
            feedIndex: _currentIndex,
            readingMode: _readingMode,
          );
    }
  }

  Future<void> _syncProgressAndMergeCards(
    int chunkSeq, {
    String? chunkId,
    int? feedIndex,
  }) async {
    try {
      final res = await ref.read(apiClientProvider).syncReadingProgress(
            widget.documentId,
            chunkSeq,
            chunkId: chunkId,
            feedIndex: feedIndex ?? _currentIndex,
            readingMode: _readingMode,
          );
      if (res['cards'] is List) {
        final cardsList = res['cards'] as List;
        bool changed = false;
        for (final c in cardsList) {
          if (c is Map) {
            final map = Map<String, dynamic>.from(c);
            final seq = map['sequence'] is int
                ? map['sequence'] as int
                : int.tryParse(map['sequence']?.toString() ?? '');
            if (seq != null && !_cardsByChunkSeq.containsKey(seq)) {
              _cardsByChunkSeq[seq] = ReaderItem.fromJson({
                ...map,
                'type': 'context_card',
              });
              changed = true;
            }
          }
        }
        if (changed && mounted) {
          setState(() => _recomputeCachedFeed());
        }
      }
    } catch (e) {
      debugPrint('[Athena Progress] Sync notice: $e');
    }
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
      _governor.onPageTurn(index);

      // Debounce flow scroll position saves (600ms)
      _flowSaveDebounceTimer?.cancel();
      _flowSaveDebounceTimer = Timer(const Duration(milliseconds: 600), () {
        if (!mounted) return;
        final chunk = _readingChunkAt(index, _currentFeed);
        final chunkSeq = chunk?.sequence;
        final chunkId = chunk?.id;
        unawaited(SharedPreferences.getInstance().then((prefs) {
          prefs.setInt('reader_pos_${widget.documentId}', index);
          if (chunkId != null) {
            prefs.setString('reader_chunk_id_${widget.documentId}', chunkId);
          }
          if (chunkSeq != null) {
            prefs.setInt('reader_chunk_seq_${widget.documentId}', chunkSeq);
          }
        }));
        if (chunkSeq != null) {
          _syncProgressAndMergeCards(chunkSeq,
              chunkId: chunkId, feedIndex: index);
        }
      });
    }
  }

  ReaderItem? _readingChunkAt(int index, List<ReaderItem> items) {
    if (index < 0 || index >= items.length) return null;
    final item = items[index];
    if (item.isReadingChunk) return item;
    final sourceId = item.sourceChunkId ?? item.insertAfter;
    if (sourceId != null) {
      final cached = _chunksById[sourceId];
      if (cached != null) return cached;
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
    ref.listen<AsyncValue<ReaderData>>(
      readerDataProvider(widget.documentId),
      (previous, next) {
        next.whenData((d) {
          if (!identical(_lastReaderData, d)) {
            _syncData(d);
          }
        });
      },
    );

    final readerAsync = ref.watch(readerDataProvider(widget.documentId));
    final theme = ReaderThemeConfig.getById(_themeId);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: theme.scaffoldBackground,
      drawer: readerAsync.maybeWhen(
        data: (d) {
          if (_lastReaderData == null) {
            _syncData(d);
          }
          return ChaptersDrawer(
            title: d.title,
            documentId: widget.documentId,
            apiClient: ref.read(apiClientProvider),
            feedItems: _cachedFeedItems,
            theme: theme,
            onSelectIndex: (idx) {
              Navigator.of(context).pop();
              _jumpTo(idx, _cachedFeedItems.length);
            },
          );
        },
        orElse: () => null,
      ),
      appBar: ReaderTopBar(
        title: readerAsync.value?.title ?? '',
        readingMode: _readingMode,
        theme: theme,
        isDark: isDark,
        progress: _cachedFeedItems.isNotEmpty
            ? ((_currentIndex + 1) / _cachedFeedItems.length).clamp(0.0, 1.0)
            : 0.0,
        onBack: () => context.go('/'),
        onReadingModeChanged: (mode) {
          setState(() => _readingMode = mode);
          SharedPreferences.getInstance().then(
              (p) => p.setString('reader_mode_${widget.documentId}', mode));
        },
        onSearch: () {
          ReaderSearchSheet.show(
            context,
            documentId: widget.documentId,
            themeId: _themeId,
            feedItems: _cachedFeedItems,
            apiClient: ref.read(apiClientProvider),
            onJumpToItemIndex: (idx) => _jumpTo(idx, _cachedFeedItems.length),
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
            if (_lastReaderData == null) {
              _syncData(data);
            }
            final feedItems = _cachedFeedItems;
            final chunks = feedItems.where((it) => it.isReadingChunk).toList();
            if (!_initialPositionResolved &&
                _preferencesLoaded &&
                feedItems.isNotEmpty) {
              _initialPositionResolved = true;
              var target = -1;

              // 1. Deep link takes highest priority
              final deepLink = widget.initialChunkId;
              if (deepLink != null && deepLink.isNotEmpty) {
                final match = feedItems.indexWhere((item) =>
                    item.id == deepLink || item.sourceChunkId == deepLink);
                if (match >= 0) target = match;
              }

              // 2. Saved chunk_id
              if (target < 0 && _savedChunkId != null && _savedChunkId!.isNotEmpty) {
                final match = feedItems.indexWhere((item) =>
                    item.isReadingChunk && item.id == _savedChunkId);
                if (match >= 0) target = match;
              }

              // 3. Saved sequence
              if (target < 0 && _savedChunkSeq != null && _savedChunkSeq! > 0) {
                final match = feedItems.indexWhere((item) =>
                    item.isReadingChunk && item.sequence == _savedChunkSeq);
                if (match >= 0) target = match;
              }

              // 4. Server progress sequence
              final serverSequence = data.currentChunkIndex;
              if (target < 0 && serverSequence != null && serverSequence > 0) {
                final match = feedItems.indexWhere((item) =>
                    item.isReadingChunk && item.sequence == serverSequence);
                if (match >= 0) target = match;
              }

              // 5. Fallback
              if (target < 0) {
                target = _currentIndex.clamp(0, feedItems.length - 1);
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
                    child: Column(
                      children: [
                        Expanded(
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
                        if (data.status == 'partially_readable')
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                            decoration: BoxDecoration(
                              color: theme.innerCardColor,
                              border: Border(
                                top: BorderSide(color: theme.borderColor, width: 0.8),
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.5,
                                    color: theme.accentColor,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Still preparing pages ${data.processedPages ?? 0}/${data.pageCount}...',
                                  style: TextStyle(
                                    fontFamily: AppTheme.fontMono,
                                    fontSize: 11,
                                    color: theme.textMutedColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
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
    setState(() {
      _dismissedCardIds.add(card.id);
      _recomputeCachedFeed();
    });
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
    final newSaved = !wasSaved;

    // Optimistically toggle saved on the card in _cardsByChunkSeq (P2-05)
    final seq = card.sequence;
    if (seq != null && _cardsByChunkSeq.containsKey(seq)) {
      final existing = _cardsByChunkSeq[seq]!;
      _cardsByChunkSeq[seq] = existing.copyWith(saved: newSaved);
    }
    setState(() => _recomputeCachedFeed());

    try {
      if (!kIsWeb) {
        await LocalDatabase.instance.setCardSaved(card.id, newSaved);
      }
      if (wasSaved) {
        await client.unsaveCard(card.id);
      } else {
        await client.saveCard(card.id);
      }
      ref.invalidate(savedCardsProvider);
    } catch (e) {
      debugPrint('[Athena] Toggle save card notice: $e');
    }
  }

  Future<void> _handleGenerateCard(
      List<ReaderItem> feedItems, List<ReaderItem> chunks) async {
    if (chunks.isEmpty || _isGeneratingCard) return;
    final currentItem = (_currentIndex >= 0 && _currentIndex < feedItems.length)
        ? feedItems[_currentIndex]
        : null;
    final currentChunk = (currentItem != null && currentItem.isReadingChunk)
        ? currentItem
        : chunks.first;
    final chunkSeq = currentChunk.sequence ?? 1;

    if (_cardsByChunkSeq.containsKey(chunkSeq)) return;

    setState(() => _isGeneratingCard = true);
    HapticFeedback.lightImpact();

    final chunkDb = await LocalDatabase.instance.getChunkById(currentChunk.id);
    final chunkMap = chunkDb ?? {
      'id': currentChunk.id,
      'raw_text': currentChunk.rawText,
      'sequence': chunkSeq,
    };

    try {
      Map<String, Object?>? cardMap;
      if (!AppConfig.isStandaloneMobile &&
          AppConfig.apiBaseUrl.isNotEmpty) {
        try {
          final serverCard = await ref
              .read(apiClientProvider)
              .generateCardForChunk(
                widget.documentId,
                chunkSeq,
                chunkId: currentChunk.id,
                feedIndex: _currentIndex,
              );
          if (serverCard != null) {
            cardMap = Map<String, Object?>.from(serverCard);
          }
        } catch (e) {
          debugPrint(
              '[Athena Card Action] Remote generateCardForChunk notice: $e');
        }
      }

      if (cardMap == null) {
        final service = LocalContextService();
        cardMap = await service.generateCardForChunk(
          widget.documentId,
          chunkMap,
          _cardsByChunkSeq.length,
        );
      }
      if (cardMap != null && mounted) {
        final cardItem = ReaderItem.fromJson({
          ...cardMap,
          'type': 'context_card',
          'insert_after': currentChunk.id,
          'source_chunk_id': currentChunk.id,
          'sequence': chunkSeq,
          'is_speculative_draft': false,
        });
        await LocalDatabase.instance.insertCards([cardMap]);
        if (mounted) {
          setState(() {
            _cardsByChunkSeq[chunkSeq] = cardItem;
            _recomputeCachedFeed();
            _isGeneratingCard = false;
          });
          HapticFeedback.mediumImpact();
          final newCardIndex = _cachedFeedItems.indexWhere(
              (i) => i.isContextCard && i.sourceChunkId == currentChunk.id);
          if (newCardIndex >= 0) {
            _jumpTo(newCardIndex, _cachedFeedItems.length);
          }
        }
      } else {
        if (mounted) {
          setState(() => _isGeneratingCard = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'No verified academic evidence found for this passage.'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isGeneratingCard = false);
        debugPrint('[Athena Notice] Card generation notice: $e');
      }
    }
  }
}
