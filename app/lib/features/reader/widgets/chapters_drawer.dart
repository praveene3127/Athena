import 'package:flutter/material.dart';
import 'package:athena/core/api/api_client.dart';
import 'package:athena/core/config/config.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/core/theme/reader_theme.dart';
import 'package:athena/models/document.dart';

/// L7 Modular Widget: Chapters and Outline Drawer.
///
/// Clean drawer displaying book sections, chapters, and passage milestones with
/// support for hierarchical chapter levels and API integration.
class ChaptersDrawer extends StatefulWidget {
  final String title;
  final String? documentId;
  final ApiClient? apiClient;
  final List<ReaderItem> feedItems;
  final ReaderThemeConfig theme;
  final ValueChanged<int> onSelectIndex;

  const ChaptersDrawer({
    super.key,
    required this.title,
    this.documentId,
    this.apiClient,
    required this.feedItems,
    required this.theme,
    required this.onSelectIndex,
  });

  @override
  State<ChaptersDrawer> createState() => _ChaptersDrawerState();
}

class _ChaptersDrawerState extends State<ChaptersDrawer> {
  List<Map<String, dynamic>> _chapters = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadChapters();
  }

  Future<void> _loadChapters() async {
    if (widget.apiClient != null &&
        widget.documentId != null &&
        !AppConfig.isStandaloneMobile &&
        AppConfig.apiBaseUrl.isNotEmpty) {
      setState(() => _loading = true);
      try {
        final serverChapters =
            await widget.apiClient!.getChapters(widget.documentId!);
        if (mounted && serverChapters.isNotEmpty) {
          setState(() {
            _chapters = serverChapters;
            _loading = false;
          });
          return;
        }
      } catch (e) {
        debugPrint('[Athena ChaptersDrawer] Error loading server chapters: $e');
      }
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final List<Map<String, dynamic>> displayedSections = [];

    if (_chapters.isNotEmpty) {
      for (final ch in _chapters) {
        final title = ch['title']?.toString() ?? 'Chapter';
        if (title.toLowerCase() == 'chapter passage') continue;
        final seq = (ch['chunk_sequence'] as num?)?.toInt() ?? 1;
        final level = (ch['level'] as num?)?.toInt() ?? 1;
        final page = ch['page']?.toString() ??
            (ch['page_reference']?.toString() ?? '');

        int targetIdx = widget.feedItems.indexWhere(
            (it) => it.isReadingChunk && (it.sequence ?? 0) >= seq);
        if (targetIdx < 0) targetIdx = 0;

        displayedSections.add({
          'index': targetIdx,
          'title': title,
          'level': level,
          'page': page.isNotEmpty
              ? (page.startsWith('Page') ? page : 'Page $page')
              : '',
        });
      }
    } else {
      for (int i = 0; i < widget.feedItems.length; i++) {
        final it = widget.feedItems[i];
        if (it.isReadingChunk) {
          final sec = it.sectionTitle?.trim();
          if (sec != null && sec.isNotEmpty && sec.toLowerCase() != 'chapter passage') {
            if (displayedSections.isEmpty ||
                displayedSections.last['title'] != sec) {
              displayedSections.add({
                'index': i,
                'title': sec,
                'level': 1,
                'page': it.pageReference ?? '',
              });
            }
          }
        }
      }
    }

    return Drawer(
      backgroundColor: theme.scaffoldBackground,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'TABLE OF CONTENTS',
                    style: TextStyle(
                      fontFamily: AppTheme.fontMono,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: theme.textMutedColor,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: AppTheme.fontDisplay,
                      fontSize: 18,
                      fontWeight: FontWeight.w400,
                      color: theme.textColor,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (_loading)
              const LinearProgressIndicator(minHeight: 2)
            else
              const SizedBox.shrink(),
            Expanded(
              child: displayedSections.isEmpty
                  ? Center(
                      child: Text(
                        'Continuous full text without explicit chapters.',
                        style: TextStyle(
                            color: theme.textMutedColor, fontSize: 13),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: displayedSections.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, indent: 20),
                      itemBuilder: (context, idx) {
                        final s = displayedSections[idx];
                        final secTitle = s['title'] as String;
                        final page = s['page'] as String;
                        final targetIndex = s['index'] as int;
                        final level = (s['level'] as int?) ?? 1;
                        final indent = (level - 1) * 14.0;

                        return Padding(
                          padding: EdgeInsets.only(left: indent),
                          child: ListTile(
                            title: Text(
                              secTitle,
                              style: TextStyle(
                                fontFamily: AppTheme.fontUI,
                                fontSize: level > 1 ? 12.5 : 13.5,
                                fontWeight: level == 1
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: theme.textColor,
                              ),
                            ),
                            trailing: page.isNotEmpty
                                ? Text(
                                    page,
                                    style: TextStyle(
                                      fontFamily: AppTheme.fontMono,
                                      fontSize: 11,
                                      color: theme.accentColor,
                                    ),
                                  )
                                : null,
                            onTap: () {
                              Navigator.of(context).pop();
                              widget.onSelectIndex(targetIndex);
                            },
                          ),
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
