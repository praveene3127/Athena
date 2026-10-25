import 'package:flutter/material.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/core/api/api_client.dart';

/// Modal bottom sheet allowing inspection of the exact original PDF page.
/// Uses InteractiveViewer for pan & zoom (CLAUDE.md §11 & §14).
class OriginalPageSheet extends StatelessWidget {
  final String documentId;
  final int pageNumber;
  final String? pageReference;
  final ApiClient apiClient;

  const OriginalPageSheet({
    super.key,
    required this.documentId,
    required this.pageNumber,
    this.pageReference,
    required this.apiClient,
  });

  static Future<void> show(
    BuildContext context, {
    required String documentId,
    required int pageNumber,
    String? pageReference,
    required ApiClient apiClient,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => OriginalPageSheet(
        documentId: documentId,
        pageNumber: pageNumber,
        pageReference: pageReference,
        apiClient: apiClient,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final title = pageReference ?? 'Page $pageNumber';
    final imageUrl = apiClient.pageImageUrl(documentId, pageNumber);

    return SafeArea(
      child: Container(
        height: MediaQuery.of(context).size.height * 0.88,
        decoration: BoxDecoration(
          color: AppTheme.bgOf(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border.all(color: AppTheme.borderOf(context)),
        ),
        child: Column(
          children: [
            // Tactile drag bar
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF333333) : const Color(0xFFE0E0E0),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Header bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: AppTheme.borderOf(context), width: 1),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.picture_as_pdf_rounded,
                    color: isDark ? Colors.white : AppTheme.ink,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'ORIGINAL PDF · $title',
                    style: TextStyle(
                      fontFamily: AppTheme.fontUI,
                      color: isDark ? Colors.white : AppTheme.ink,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(
                      Icons.close_rounded,
                      color: isDark ? AppTheme.darkTextMuted : AppTheme.textMuted,
                      size: 20,
                    ),
                    tooltip: 'Close original page',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            // Helper hint
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: AppTheme.surfaceWarmOf(context),
              width: double.infinity,
              child: Text(
                'Pinch to zoom · Pan to inspect tables, charts, and exact layout.',
                style: TextStyle(
                  fontFamily: AppTheme.fontUI,
                  color: isDark ? AppTheme.darkTextMuted : AppTheme.textMuted,
                  fontSize: 12,
                ),
              ),
            ),
            // Interactive viewer for high-res page image
            Expanded(
              child: InteractiveViewer(
                minScale: 1.0,
                maxScale: 4.0,
                child: Center(
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.contain,
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      final total = loadingProgress.expectedTotalBytes;
                      final loaded = loadingProgress.cumulativeBytesLoaded;
                      final value =
                          total != null && total > 0 ? loaded / total : null;
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(
                              value: value,
                              color: isDark ? Colors.white : AppTheme.ink,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Rendering high-res page...',
                              style: TextStyle(
                                fontFamily: AppTheme.fontUI,
                                color: isDark ? AppTheme.darkTextMuted : AppTheme.textMuted,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                    errorBuilder: (context, error, stackTrace) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.broken_image_rounded,
                                  color: Colors.redAccent, size: 48),
                              const SizedBox(height: 12),
                              Text(
                                'Could not load page image.',
                                style: TextStyle(
                                  fontFamily: AppTheme.fontUI,
                                  color: isDark ? Colors.white : AppTheme.ink,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                error.toString(),
                                style: TextStyle(
                                  fontFamily: AppTheme.fontUI,
                                  color: isDark ? AppTheme.darkTextMuted : AppTheme.textMuted,
                                  fontSize: 12,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
