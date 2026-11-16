import 'package:flutter/material.dart';
import 'package:athena/core/api/api_client.dart';
import 'package:athena/core/config/config.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/core/theme/reader_theme.dart';
import 'package:athena/models/document.dart';
import 'package:athena/models/section_role.dart';
import 'package:athena/services/local_database.dart';

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
    if (widget.documentId == null) return;
    setState(() => _loading = true);

    try {
      final localChapters =
          await LocalDatabase.instance.getDocumentChapters(widget.documentId!);
      if (mounted && localChapters.isNotEmpty) {
        setState(() {
          _chapters = localChapters;
          _loading = false;
        });
        return;
      }
    } catch (e) {
      debugPrint('[Athena ChaptersDrawer] Error loading local chapters: $e');
    }

    if (widget.apiClient != null &&
        !AppConfig.isStandaloneMobile &&
        AppConfig.apiBaseUrl.isNotEmpty) {
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
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final List<Map<String, dynamic>> displayedSections = [];

    String computeZone(String roleStr, bool isRoman) {
      if (isRoman) return 'front';
      const frontRoles = {
        'cover', 'titlepage', 'halftitle', 'copyright', 'dedication',
        'epigraph', 'toc', 'preface', 'foreword', 'introduction', 'prologue'
      };
      const backRoles = {
        'epilogue', 'afterword', 'appendix', 'acknowledgments', 'acknowledgements',
        'notes', 'endnotes', 'glossary', 'bibliography', 'references',
        'bookindex', 'index', 'aboutauthor'
      };
      final rNorm = roleStr.replaceAll('_', '').toLowerCase().trim();
      if (frontRoles.contains(rNorm)) return 'front';
      if (backRoles.contains(rNorm)) return 'back';
      return 'body';
    }

    if (_chapters.isNotEmpty) {
      for (final ch in _chapters) {
        final title = ch['title']?.toString() ?? 'Chapter';
        if (title.toLowerCase() == 'chapter passage') continue;
        final seq = (ch['chunk_sequence'] ?? ch['start_chunk_index']) as num?;
        final level = (ch['level'] as num?)?.toInt() ?? 1;
        final rawPage = ch['raw_page_label']?.toString() ??
            ch['page']?.toString() ??
            ch['page_reference']?.toString() ??
            '';
        final isRoman = ch['is_roman'] == 1 || ch['is_roman'] == true;
        final rawRole = ch['section_role']?.toString() ?? '';
        final rawZone = ch['zone']?.toString() ?? '';
        final roleStr = rawRole.isNotEmpty ? rawRole : SectionRole.fromString(title).name;
        final zone = rawZone.isNotEmpty ? rawZone : computeZone(roleStr, isRoman);

        int targetIdx = -1;
        if (seq != null) {
          final targetSeq = seq.toInt();
          targetIdx = widget.feedItems.indexWhere(
              (it) => it.isReadingChunk && (it.sequence ?? 0) >= targetSeq);
        }
        if (targetIdx < 0) targetIdx = 0;

        String pageLabel = '';
        if (rawPage.isNotEmpty) {
          pageLabel = isRoman ? rawPage.toLowerCase() : 'p. $rawPage';
        }

        displayedSections.add({
          'index': targetIdx,
          'title': title,
          'level': level,
          'page': pageLabel,
          'is_roman': isRoman,
          'role': roleStr,
          'zone': zone,
        });
      }
    } else {
      for (int i = 0; i < widget.feedItems.length; i++) {
        final it = widget.feedItems[i];
        if (it.isReadingChunk) {
          final sec = it.sectionTitle?.trim();
          final roleStr = it.sectionRole ?? (sec != null ? SectionRole.fromString(sec).name : 'chapter');
          final zone = computeZone(roleStr, false);
          if (sec != null && sec.isNotEmpty && sec.toLowerCase() != 'chapter passage') {
            if (displayedSections.isEmpty ||
                displayedSections.last['title'] != sec) {
              displayedSections.add({
                'index': i,
                'title': sec,
                'level': 1,
                'page': it.pageReference ?? '',
                'role': roleStr,
                'zone': zone,
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
                        final zone = (s['zone'] as String? ?? 'body').toLowerCase();
                        final prevZone = idx > 0 ? (displayedSections[idx - 1]['zone'] as String? ?? 'body').toLowerCase() : null;
                        final isZoneHeader = idx == 0 || zone != prevZone;

                        final roleStr = (s['role'] as String? ?? '').toLowerCase().replaceAll('_', ' ').trim();
                        final showBadge = roleStr.isNotEmpty && roleStr != 'chapter' && roleStr != 'unknown';
                        final badgeLabel = roleStr == 'bookindex' ? 'INDEX' : roleStr.toUpperCase();

                        final tile = Padding(
                          padding: EdgeInsets.only(left: indent),
                          child: ListTile(
                            title: Row(
                              children: [
                                if (showBadge) ...[
                                  Container(
                                    margin: const EdgeInsets.only(right: 8),
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: theme.accentColor.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      badgeLabel,
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.5,
                                        color: theme.accentColor,
                                      ),
                                    ),
                                  ),
                                ],
                                Expanded(
                                  child: Text(
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
                                ),
                              ],
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

                        if (isZoneHeader) {
                          String label = 'CHAPTERS';
                          if (zone == 'front') {
                            label = 'FRONT MATTER';
                          } else if (zone == 'back') {
                            label = 'BACK MATTER & NOTES';
                          }
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                                child: Text(
                                  label,
                                  style: TextStyle(
                                    fontFamily: AppTheme.fontMono,
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.8,
                                    color: theme.accentColor,
                                  ),
                                ),
                              ),
                              tile,
                            ],
                          );
                        }

                        return tile;
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
