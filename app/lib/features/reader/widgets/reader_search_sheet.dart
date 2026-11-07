import 'package:flutter/material.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/core/theme/reader_theme.dart';
import 'package:athena/models/document.dart';
import 'package:athena/services/local_database.dart';

/// L7 Modular Sheet: Reader Search Sheet (FTS5 + Substring Fast Search).
///
/// Provides instant in-book search with BM25 ranked FTS5 matching,
/// highlighting results and jumping directly to the target chunk sequence.
class ReaderSearchSheet extends StatefulWidget {
  final String documentId;
  final String themeId;
  final List<ReaderItem> feedItems;
  final ValueChanged<int> onJumpToItemIndex;

  const ReaderSearchSheet({
    super.key,
    required this.documentId,
    required this.themeId,
    required this.feedItems,
    required this.onJumpToItemIndex,
  });

  static Future<void> show(
    BuildContext context, {
    required String documentId,
    required String themeId,
    required List<ReaderItem> feedItems,
    required ValueChanged<int> onJumpToItemIndex,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ReaderSearchSheet(
        documentId: documentId,
        themeId: themeId,
        feedItems: feedItems,
        onJumpToItemIndex: onJumpToItemIndex,
      ),
    );
  }

  @override
  State<ReaderSearchSheet> createState() => _ReaderSearchSheetState();
}

class _ReaderSearchSheetState extends State<ReaderSearchSheet> {
  final TextEditingController _queryController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  bool _isSearching = false;

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _performSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }

    setState(() => _isSearching = true);
    try {
      final results =
          await LocalDatabase.instance.searchChunks(widget.documentId, q);
      if (mounted) {
        final resolved = results.isNotEmpty ? results : _searchInMemory(q);
        setState(() {
          _searchResults = resolved;
          _isSearching = false;
        });
      }
    } catch (e) {
      debugPrint('[Athena] Search error: $e');
      if (mounted) {
        // Fallback to in-memory search over feedItems
        final memoryMatches = _searchInMemory(q);

        setState(() {
          _searchResults = memoryMatches;
          _isSearching = false;
        });
      }
    }
  }

  List<Map<String, dynamic>> _searchInMemory(String query) {
    final lower = query.toLowerCase();
    return widget.feedItems
        .where((item) =>
            item.isReadingChunk && item.rawText.toLowerCase().contains(lower))
        .map((item) => {
              'id': item.id,
              'sequence': item.sequence,
              'raw_text': item.rawText,
              'section_title': item.sectionTitle,
            })
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ReaderThemeConfig.getById(widget.themeId);

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      decoration: BoxDecoration(
        color: theme.scaffoldBackground,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        border: Border.all(color: theme.borderColor),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: theme.borderColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _queryController,
                autofocus: true,
                onChanged: _performSearch,
                style: TextStyle(
                    fontFamily: AppTheme.fontUI,
                    color: theme.textColor,
                    fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Search text, concepts, or keywords...',
                  hintStyle:
                      TextStyle(color: theme.textMutedColor, fontSize: 14),
                  prefixIcon: Icon(Icons.search_rounded,
                      color: theme.accentColor, size: 20),
                  suffixIcon: _queryController.text.isNotEmpty
                      ? IconButton(
                          icon: Icon(Icons.clear_rounded,
                              size: 18, color: theme.textMutedColor),
                          onPressed: () {
                            _queryController.clear();
                            _performSearch('');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: theme.innerCardColor,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: theme.borderColor),
                  ),
                ),
              ),
            ),
            if (_isSearching)
              const LinearProgressIndicator(minHeight: 2)
            else
              const Divider(height: 1),
            Expanded(
              child: _searchResults.isEmpty
                  ? Center(
                      child: Text(
                        _queryController.text.isEmpty
                            ? 'Type to search across the entire book'
                            : 'No matches found',
                        style: TextStyle(
                            fontFamily: AppTheme.fontUI,
                            color: theme.textMutedColor,
                            fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _searchResults.length,
                      itemBuilder: (context, idx) {
                        final r = _searchResults[idx];
                        final rawText = (r['raw_text'] ?? '') as String;
                        final seq = r['sequence'] as int?;
                        final chunkId = (r['id'] ?? r['chunk_id']) as String?;

                        return ListTile(
                          title: Text(
                            rawText,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: AppTheme.fontSerif,
                              fontSize: 13.5,
                              color: theme.textColor,
                            ),
                          ),
                          subtitle: Text(
                            seq != null ? 'Passage #$seq' : (chunkId ?? ''),
                            style: TextStyle(
                              fontFamily: AppTheme.fontMono,
                              fontSize: 10,
                              color: theme.textMutedColor,
                            ),
                          ),
                          onTap: () {
                            Navigator.of(context).pop();
                            // Locate index in feedItems
                            final targetIndex = widget.feedItems.indexWhere(
                              (it) =>
                                  it.id == chunkId ||
                                  (seq != null && it.sequence == seq),
                            );
                            if (targetIndex >= 0) {
                              widget.onJumpToItemIndex(targetIndex);
                            }
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
}
