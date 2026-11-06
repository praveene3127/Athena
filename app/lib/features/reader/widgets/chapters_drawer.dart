import 'package:flutter/material.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/core/theme/reader_theme.dart';
import 'package:athena/models/document.dart';

/// L7 Modular Widget: Chapters and Outline Drawer.
///
/// Clean drawer displaying book sections, chapters, and passage milestones.
class ChaptersDrawer extends StatelessWidget {
  final String title;
  final List<ReaderItem> feedItems;
  final ReaderThemeConfig theme;
  final ValueChanged<int> onSelectIndex;

  const ChaptersDrawer({
    super.key,
    required this.title,
    required this.feedItems,
    required this.theme,
    required this.onSelectIndex,
  });

  @override
  Widget build(BuildContext context) {
    // Extract unique chapters / sections
    final sections = <Map<String, dynamic>>[];
    for (int i = 0; i < feedItems.length; i++) {
      final it = feedItems[i];
      if (it.isReadingChunk) {
        final sec = it.sectionTitle?.trim();
        if (sec != null && sec.isNotEmpty) {
          if (sections.isEmpty || sections.last['title'] != sec) {
            sections.add({
              'index': i,
              'title': sec,
              'sequence': it.sequence,
              'page': it.pageReference ?? 'Page ?',
            });
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
                    title,
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
            Expanded(
              child: sections.isEmpty
                  ? Center(
                      child: Text(
                        'Continuous full text without explicit chapters.',
                        style: TextStyle(color: theme.textMutedColor, fontSize: 13),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: sections.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, indent: 20),
                      itemBuilder: (context, idx) {
                        final s = sections[idx];
                        final secTitle = s['title'] as String;
                        final page = s['page'] as String;
                        final targetIndex = s['index'] as int;

                        return ListTile(
                          title: Text(
                            secTitle,
                            style: TextStyle(
                              fontFamily: AppTheme.fontUI,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: theme.textColor,
                            ),
                          ),
                          trailing: Text(
                            page,
                            style: TextStyle(
                              fontFamily: AppTheme.fontMono,
                              fontSize: 11,
                              color: theme.accentColor,
                            ),
                          ),
                          onTap: () {
                            Navigator.of(context).pop();
                            onSelectIndex(targetIndex);
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

