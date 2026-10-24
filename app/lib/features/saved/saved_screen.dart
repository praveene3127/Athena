import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/theme.dart';
import '../../core/errors.dart';
import '../../core/app_bottom_nav.dart';
import '../../services/api_client.dart';
import '../library/library_screen.dart';

class SavedItem {
  final String id;
  final String documentId;
  final String documentTitle;
  final String chunkId;
  final int sequence;
  final String pageReference;
  final String cardType;
  final String title;
  final String body;
  final String? whyHere;
  final List<Map<String, dynamic>> citations;

  SavedItem({
    required this.id,
    required this.documentId,
    required this.documentTitle,
    required this.chunkId,
    required this.sequence,
    required this.pageReference,
    required this.cardType,
    required this.title,
    required this.body,
    this.whyHere,
    required this.citations,
  });

  factory SavedItem.fromJson(Map<String, dynamic> json) {
    return SavedItem(
      id: json['id'] as String? ?? '',
      documentId: json['document_id'] as String? ?? '',
      documentTitle: json['document_title'] as String? ?? 'Document',
      chunkId: json['chunk_id'] as String? ?? '',
      sequence: json['sequence'] as int? ?? 1,
      pageReference: json['page_reference'] as String? ?? 'Page 1',
      cardType: json['card_type'] as String? ?? 'explain',
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      whyHere: json['why_here'] as String?,
      citations:
          (json['citations'] as List?)?.cast<Map<String, dynamic>>() ?? [],
    );
  }
}

final savedCardsProvider =
    FutureProvider.autoDispose<List<SavedItem>>((ref) async {
  final client = ref.watch(apiClientProvider);
  final List<SavedItem> result = [];

  // Query valid document IDs so we can prune orphaned cards from deleted books
  Set<String> validDocIds = {};
  bool checkedDocs = false;
  try {
    final docs = await client.listDocuments();
    validDocIds = docs
        .map((d) => d['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    checkedDocs = true;
  } catch (_) {}

  try {
    final list = await client.getSavedCards();
    for (final item in list) {
      final docId = item['document_id']?.toString() ?? '';
      // If we checked documents and the document was deleted, prune it
      if (checkedDocs && !validDocIds.contains(docId)) {
        continue;
      }
      result.add(SavedItem.fromJson(item));
    }
  } catch (_) {}

  // Also merge any cards stored locally to guarantee zero loss
  try {
    final prefs = await SharedPreferences.getInstance();
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
    if (brainDeckJson != null && brainDeckJson.isNotEmpty) {
      final decoded = json.decode(brainDeckJson);
      if (decoded is List) {
        final existingIds = result.map((c) => c.id).toSet();
        final List<dynamic> retainedLocals = [];
        for (final item in decoded) {
          if (item is Map) {
            final docId = item['docId']?.toString() ?? '';
            // If books checked and doc was deleted, prune it
            if (checkedDocs && !validDocIds.contains(docId)) {
              continue;
            }
            retainedLocals.add(item);
            if (!existingIds.contains(item['id'])) {
              result.add(SavedItem(
                id: item['id']?.toString() ?? '',
                documentId: docId,
                documentTitle: item['docTitle']?.toString() ?? 'Document',
                chunkId: '',
                sequence: (item['chunkSeq'] as num?)?.toInt() ?? 1,
                pageReference: 'Saved Note',
                cardType: 'explain',
                title: item['title']?.toString() ?? '',
                body: item['body']?.toString() ?? '',
                citations: ((item['citations'] as List?) ?? [])
                    .whereType<Map>()
                    .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
                    .toList(),
              ));
            }
          }
        }
        if (retainedLocals.length != decoded.length) {
          await prefs.setString(
              'athena_saved_notes_v1', json.encode(retainedLocals));
        }
      }
    }
  } catch (_) {}

  return result;
});

class SavedScreen extends ConsumerStatefulWidget {
  const SavedScreen({super.key});

  @override
  ConsumerState<SavedScreen> createState() => _SavedScreenState();
}

class _SavedScreenState extends ConsumerState<SavedScreen> {
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _openSourceUrl(String? url) async {
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _confirmClearAll(ApiClient client) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF181818) : const Color(0xFFF7F6F2),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: isDark ? const Color(0xFF282828) : const Color(0xFFE5E7DC),
              width: 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark ? Colors.black54 : const Color(0x18141714),
                blurRadius: 28,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF202020) : Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isDark ? const Color(0xFF2E2E2E) : const Color(0xFFECEEE4),
                width: 1.0,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withValues(alpha: isDark ? 0.2 : 0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.redAccent.withValues(alpha: 0.3),
                          width: 1,
                        ),
                      ),
                      child: const Icon(
                        Icons.delete_sweep_rounded,
                        color: Colors.redAccent,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Clear Saved Notes',
                        style: TextStyle(
                          fontFamily: AppTheme.fontDisplay,
                          color: isDark ? Colors.white : AppTheme.ink,
                          fontSize: 20,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'This will permanently remove all saved context cards and notes from your deck.',
                  style: TextStyle(
                    fontFamily: AppTheme.fontUI,
                    color: isDark ? AppTheme.darkTextMuted : AppTheme.textMuted,
                    fontSize: 13.5,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: isDark ? Colors.white : AppTheme.ink,
                          side: BorderSide(
                            color: isDark ? const Color(0xFF333333) : const Color(0xFFE0E0E0),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                        child: const Text(
                          'Cancel',
                          style: TextStyle(
                            fontFamily: AppTheme.fontUI,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                        child: const Text(
                          'Clear All',
                          style: TextStyle(
                            fontFamily: AppTheme.fontUI,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (confirmed == true) {
      await client.clearAllSavedCards();
      if (!mounted) return;
      ref.invalidate(savedCardsProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All saved notes cleared')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final savedAsync = ref.watch(savedCardsProvider);
    final client = ref.read(apiClientProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: AppTheme.bgOf(context),
      bottomNavigationBar: AthenaBottomNav(
        selectedIndex: 1,
        onDestinationSelected: (index) {
          if (index == 0) context.go('/');
        },
      ),
      appBar: AppBar(
        backgroundColor: AppTheme.bgOf(context),
        elevation: 0,
        leading: Container(
          margin: const EdgeInsets.only(left: 14),
          child: IconButton(
            icon: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF202020) : Colors.white,
                shape: BoxShape.circle,
                border: Border.all(
                    color: isDark ? const Color(0xFF2E2E2E) : const Color(0xFFE5E7DC)),
              ),
              child: Icon(Icons.arrow_back_rounded,
                  color: isDark ? const Color(0xFFF3F3F3) : AppTheme.ink, size: 18),
            ),
            tooltip: 'Back to Library',
            onPressed: () => context.go('/'),
          ),
        ),
        title: Text(
          'Saved Ideas',
          style: TextStyle(
            fontFamily: AppTheme.fontDisplay,
            fontSize: 21,
            color: isDark ? const Color(0xFFF3F3F3) : AppTheme.ink,
            fontWeight: FontWeight.w400,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              Icons.delete_sweep_outlined,
              color: isDark ? const Color(0xFFCCCCCC) : AppTheme.ink,
              size: 21,
            ),
            tooltip: 'Clear all saved notes',
            onPressed: () => _confirmClearAll(client),
          ),
          Consumer(
            builder: (context, ref, _) {
              return InkWell(
                onTap: () {
                  HapticFeedback.selectionClick();
                  ref.read(themeModeProvider.notifier).toggleTheme();
                },
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.all(7),
                  margin: const EdgeInsets.only(right: 16),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF202020) : AppTheme.surfaceWarm,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isDark ? const Color(0xFF2E2E2E) : AppTheme.border,
                    ),
                  ),
                  child: Icon(
                    isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                    size: 16,
                    color: isDark ? Colors.amberAccent : AppTheme.ink,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: savedAsync.when(
        data: (cards) {
          if (cards.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF005E54).withValues(alpha: 0.25)
                            : const Color(0xFFF2F4EB),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: isDark
                                ? const Color(0xFF005E54).withValues(alpha: 0.45)
                                : const Color(0xFFDCE2D0)),
                      ),
                      child: Center(
                        child: Icon(Icons.bookmarks_outlined,
                            size: 28,
                            color: isDark
                                ? const Color(0xFF2DD4BF)
                                : const Color(0xFF005E54)),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'No Saved Notes',
                      style: TextStyle(
                        fontFamily: AppTheme.fontDisplay,
                        fontSize: 22,
                        fontWeight: FontWeight.w400,
                        color: isDark ? const Color(0xFFF3F3F3) : AppTheme.ink,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Bookmark cards while reading to save them here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: AppTheme.fontReading,
                        color: isDark ? const Color(0xFF9E9E9E) : AppTheme.textMuted,
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          final filteredCards = _searchQuery.isEmpty
              ? cards
              : cards.where((c) {
                  final t = c.title.toLowerCase();
                  final b = c.body.toLowerCase();
                  final dt = c.documentTitle.toLowerCase();
                  return t.contains(_searchQuery) ||
                      b.contains(_searchQuery) ||
                      dt.contains(_searchQuery);
                }).toList();

          // Group cards by documentTitle
          final Map<String, List<SavedItem>> grouped = {};
          for (final card in filteredCards) {
            grouped.putIfAbsent(card.documentTitle, () => []).add(card);
          }

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                children: [
                  // --- Editorial Hero Masthead (Double-Bezel Architecture) ---
                  Container(
                    width: double.infinity,
                    // Outer Shell
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF181818) : const Color(0xFFF7F6F2),
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(
                        color: isDark ? const Color(0xFF282828) : const Color(0xFFE8EAE0),
                        width: 1.0,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: isDark ? Colors.black26 : const Color(0x06141714),
                          blurRadius: 18,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Container(
                      // Inner Core
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF202020) : Colors.white,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF005E54).withValues(alpha: 0.25)
                                  : const Color(0xFFF2F4EB),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                  color: isDark
                                      ? const Color(0xFF005E54).withValues(alpha: 0.45)
                                      : const Color(0xFFDCE2D0)),
                            ),
                            child: Center(
                              child: Icon(
                                Icons.bookmarks_rounded,
                                color: isDark
                                    ? const Color(0xFF2DD4BF)
                                    : const Color(0xFF005E54),
                                size: 22,
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Ideas Worth Keeping',
                                  style: TextStyle(
                                    fontFamily: AppTheme.fontDisplay,
                                    color: isDark ? const Color(0xFFF3F3F3) : AppTheme.ink,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w400,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${cards.length} saved ${cards.length == 1 ? 'note & citation' : 'notes & citations'}',
                                  style: TextStyle(
                                    fontFamily: AppTheme.fontUI,
                                    color: isDark ? const Color(0xFF9E9E9E) : AppTheme.textMuted,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),

                  // Search Filter
                  Container(
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF202020) : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: isDark ? const Color(0xFF2E2E2E) : const Color(0xFFE5E7DC),
                          width: 1.0),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        Icon(Icons.search_rounded,
                            size: 18,
                            color: isDark ? const Color(0xFF757575) : AppTheme.textMuted),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            style: TextStyle(
                              fontFamily: AppTheme.fontUI,
                              fontSize: 13,
                              color: isDark ? const Color(0xFFF3F3F3) : AppTheme.ink,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Search saved notes & citations...',
                              hintStyle: TextStyle(
                                fontFamily: AppTheme.fontUI,
                                fontSize: 13,
                                color: isDark ? const Color(0xFF757575) : const Color(0xFF9E9E9E),
                              ),
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding:
                                  const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onChanged: (val) {
                              setState(() =>
                                  _searchQuery = val.trim().toLowerCase());
                            },
                          ),
                        ),
                        if (_searchQuery.isNotEmpty)
                          IconButton(
                            icon: Icon(Icons.close_rounded,
                                size: 16,
                                color: isDark ? const Color(0xFF9E9E9E) : AppTheme.textMuted),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  if (grouped.isEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 36),
                      alignment: Alignment.center,
                      child: Text(
                        'No saved notes match "$_searchQuery"',
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          color: isDark ? const Color(0xFF9E9E9E) : AppTheme.textMuted,
                          fontSize: 13,
                        ),
                      ),
                    ),

                  ...grouped.entries.map((entry) {
                    final docTitle = entry.key;
                    final docCards = entry.value;

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Document Group Title
                        Padding(
                          padding: const EdgeInsets.only(
                              top: 10, bottom: 10, left: 4),
                          child: Row(
                            children: [
                              Icon(Icons.description_outlined,
                                  color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF005E54),
                                  size: 16),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  docTitle,
                                  style: TextStyle(
                                    fontFamily: AppTheme.fontDisplay,
                                    color: isDark ? const Color(0xFFF3F3F3) : AppTheme.textPrimary,
                                    fontWeight: FontWeight.w400,
                                    fontSize: 18,
                                    letterSpacing: 0.1,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                        // Cards under this document (Double-Bezel Architecture)
                        ...docCards.map((card) {
                          final citations = card.citations;
                          final sourceUrl = citations.isNotEmpty
                              ? citations.first['url'] as String?
                              : null;

                          return Container(
                            margin: const EdgeInsets.only(bottom: 14),
                            // Outer Shell
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF181818) : const Color(0xFFF7F6F2),
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                color: isDark ? const Color(0xFF282828) : const Color(0xFFE5E7DC),
                                width: 1.0,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: isDark ? Colors.black26 : const Color(0x06141714),
                                  blurRadius: 12,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Container(
                              // Inner Core
                              padding: const EdgeInsets.all(18),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF202020) : Colors.white,
                                borderRadius: BorderRadius.circular(19),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Page reference & remove button
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: isDark
                                              ? const Color(0xFF005E54).withValues(alpha: 0.25)
                                              : const Color(0xFFF2F4EB),
                                          borderRadius:
                                              BorderRadius.circular(16),
                                        ),
                                        child: Text(
                                          card.pageReference.toUpperCase(),
                                          style: TextStyle(
                                            fontFamily: AppTheme.fontUI,
                                            color: isDark
                                                ? const Color(0xFF2DD4BF)
                                                : const Color(0xFF005E54),
                                            fontSize: 10,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.6,
                                          ),
                                        ),
                                      ),
                                      const Spacer(),
                                      IconButton(
                                        icon: Icon(
                                            Icons.bookmark_remove_outlined,
                                            color: isDark ? const Color(0xFF9E9E9E) : AppTheme.textMuted,
                                            size: 18),
                                        tooltip: 'Remove from saved',
                                        constraints: const BoxConstraints(
                                            minWidth: 32, minHeight: 32),
                                        padding: EdgeInsets.zero,
                                        onPressed: () async {
                                          HapticFeedback.lightImpact();
                                          await client.unsaveCard(card.id);
                                          ref.invalidate(savedCardsProvider);
                                        },
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),

                                  // Title
                                  Text(
                                    card.title,
                                    style: TextStyle(
                                      fontFamily: AppTheme.fontDisplay,
                                      color: isDark ? const Color(0xFFF3F3F3) : AppTheme.textPrimary,
                                      fontWeight: FontWeight.w400,
                                      fontSize: 17,
                                      height: 1.25,
                                    ),
                                  ),
                                  const SizedBox(height: 8),

                                  // Body preview
                                  Text(
                                    card.body,
                                    maxLines: 4,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: AppTheme.fontReading,
                                      color: isDark ? const Color(0xFFB0B0B0) : const Color(0xFF4A4F48),
                                      fontSize: 13.5,
                                      height: 1.5,
                                    ),
                                  ),
                                  const SizedBox(height: 16),

                                  // Actions: Button-in-Button "Open in reader" & "Open source"
                                  Row(
                                    children: [
                                      GestureDetector(
                                        onTap: () {
                                          context.go(
                                              '/reader/${card.documentId}?chunk=${card.chunkId}');
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.fromLTRB(
                                              14, 6, 6, 6),
                                          decoration: BoxDecoration(
                                            color: isDark ? Colors.white : const Color(0xFF141714),
                                            borderRadius:
                                                BorderRadius.circular(22),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                'Open in reader',
                                                style: TextStyle(
                                                  fontFamily: AppTheme.fontUI,
                                                  color: isDark ? const Color(0xFF141714) : Colors.white,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              Container(
                                                width: 22,
                                                height: 22,
                                                decoration: BoxDecoration(
                                                  color: isDark
                                                      ? const Color(0xFF141714).withValues(alpha: 0.12)
                                                      : Colors.white.withValues(alpha: 0.18),
                                                  shape: BoxShape.circle,
                                                ),
                                                child: Center(
                                                  child: Icon(
                                                    Icons.arrow_forward_rounded,
                                                    size: 13,
                                                    color: isDark ? const Color(0xFF141714) : Colors.white,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      if (sourceUrl != null)
                                        InkWell(
                                          onTap: () =>
                                              _openSourceUrl(sourceUrl),
                                          borderRadius:
                                              BorderRadius.circular(20),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 10, vertical: 6),
                                            decoration: BoxDecoration(
                                              color: isDark ? const Color(0xFF181818) : const Color(0xFFF7F6F2),
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                              border: Border.all(
                                                  color: isDark ? const Color(0xFF282828) : const Color(0xFFE5E7DC)),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  'Source',
                                                  style: TextStyle(
                                                    fontFamily: AppTheme.fontUI,
                                                    color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF005E54),
                                                    fontSize: 11.5,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                const SizedBox(width: 4),
                                                Icon(Icons.open_in_new_rounded,
                                                    size: 12,
                                                    color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF005E54)),
                                              ],
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                        const SizedBox(height: 8),
                      ],
                    );
                  }),
                ],
              ),
            ),
          );
        },
        loading: () => Center(
          child: CircularProgressIndicator(color: isDark ? Colors.white : AppTheme.ink),
        ),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.redAccent.withValues(alpha: 0.20)
                        : const Color(0xFFFEE2E2),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: isDark
                            ? Colors.redAccent.withValues(alpha: 0.45)
                            : const Color(0xFFFCA5A5)),
                  ),
                  child: const Center(
                    child: Icon(Icons.error_outline_rounded,
                        size: 28, color: Colors.redAccent),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Failed to Load Saved Cards',
                  style: TextStyle(
                    fontFamily: AppTheme.fontDisplay,
                    fontSize: 22,
                    fontWeight: FontWeight.w400,
                    color: isDark ? const Color(0xFFF3F3F3) : AppTheme.ink,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  err is AppError
                      ? err.message
                      : 'Please check your connection to the Athena backend.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: AppTheme.fontReading,
                    color: isDark ? const Color(0xFF9E9E9E) : AppTheme.textMuted,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: () => ref.invalidate(savedCardsProvider),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Try Again'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isDark ? Colors.white : AppTheme.ink,
                    foregroundColor: isDark ? const Color(0xFF141714) : Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
