import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../services/api_client.dart';

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
      backgroundColor: AppTheme.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
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
    final title = pageReference ?? 'Page $pageNumber';
    final imageUrl = apiClient.pageImageUrl(documentId, pageNumber);

    return SafeArea(
      child: Container(
        height: MediaQuery.of(context).size.height * 0.88,
        decoration: const BoxDecoration(
          color: AppTheme.background,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          children: [
            // Header bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                border: Border(
                    bottom: BorderSide(color: AppTheme.border, width: 1)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.picture_as_pdf,
                      color: AppTheme.lime, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'ORIGINAL PDF · $title',
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: AppTheme.textMuted),
                    tooltip: 'Close original page',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            // Helper hint
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: AppTheme.surface,
              width: double.infinity,
              child: const Text(
                'Pinch to zoom · Pan to inspect tables, charts, and exact layout.',
                style: TextStyle(
                  color: AppTheme.textMuted,
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
                              color: AppTheme.lime,
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Rendering high-res page...',
                              style: TextStyle(
                                  color: AppTheme.textMuted, fontSize: 13),
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
                              const Icon(Icons.broken_image,
                                  color: Colors.redAccent, size: 48),
                              const SizedBox(height: 12),
                              const Text(
                                'Could not load page image.',
                                style: TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                error.toString(),
                                style: const TextStyle(
                                    color: AppTheme.textMuted, fontSize: 12),
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
