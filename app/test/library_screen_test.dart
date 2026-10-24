import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:athena/features/library/library_screen.dart';
import 'package:athena/models/document.dart';
import 'package:athena/core/app_bottom_nav.dart';

void main() {
  testWidgets('LibraryScreen renders successfully with documents',
      (tester) async {
    final mockDocs = [
      const Document(
        id: 'doc1',
        title: '2001 - Life of Pi',
        filename: 'life_of_pi.pdf',
        status: 'ready',
        pageCount: 178,
        createdAt: '2026-10-23T12:00:00Z',
        updatedAt: '2026-10-23T12:00:00Z',
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          documentsProvider.overrideWith((ref) => Future.value(mockDocs)),
        ],
        child: const MaterialApp(
          home: LibraryScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final navBox = tester.getRect(find.byType(AthenaBottomNav));
    final bodyBox = tester.getRect(find.byType(RefreshIndicator));

    expect(navBox.height, lessThan(120.0));
    expect(bodyBox.height, greaterThan(400.0));

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();

    expect(find.text('2001 Life of Pi'), findsOneWidget);
  });
}
