import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/core/theme/reader_theme.dart';

void main() {
  group('PASS 3 — Four Distinct AthenaTokens Presets', () {
    test('Paper preset matches specified palette', () {
      final t = AthenaTokens.paper;
      expect(t.canvas, const Color(0xFFFBF9F5));
      expect(t.surface, const Color(0xFFFFFFFF));
      expect(t.surfaceSubtle, const Color(0xFFF2EFE9));
      expect(t.ink, const Color(0xFF161615));
      expect(t.inkMuted, const Color(0xFF6E6E6B));
      expect(t.hairline, const Color(0xFFE6E1D6));
      expect(t.accent, const Color(0xFF2D6A4F));
    });

    test('Sepia preset matches parchment palette', () {
      final t = AthenaTokens.sepia;
      expect(t.canvas, const Color(0xFFF4ECD8));
      expect(t.surface, const Color(0xFFFAF4E4));
      expect(t.surfaceSubtle, const Color(0xFFEAE0C8));
      expect(t.ink, const Color(0xFF2C221E));
      expect(t.inkMuted, const Color(0xFF6E5D53));
      expect(t.hairline, const Color(0xFFDCD0B8));
      expect(t.accent, const Color(0xFF8C4A27));
    });

    test('Charcoal preset matches dark palette', () {
      final t = AthenaTokens.charcoal;
      expect(t.canvas, const Color(0xFF121316));
      expect(t.surface, const Color(0xFF1A1C20));
      expect(t.surfaceSubtle, const Color(0xFF22252A));
      expect(t.ink, const Color(0xFFECEAE4));
      expect(t.inkMuted, const Color(0xFF9CA0A8));
      expect(t.hairline, const Color(0xFF2A2E35));
      expect(t.accent, const Color(0xFF34D399));
    });

    test('OLED preset matches true-black #000000 canvas', () {
      final t = AthenaTokens.oled;
      expect(t.canvas, const Color(0xFF000000));
      expect(t.surface, const Color(0xFF0A0A0C));
      expect(t.surfaceSubtle, const Color(0xFF121215));
      expect(t.ink, const Color(0xFFF5F5F0));
      expect(t.inkMuted, const Color(0xFF8E8E93));
      expect(t.hairline, const Color(0xFF1F1F24));
      expect(t.accent, const Color(0xFF34D399));
    });

    test('All four presets have distinct canvas colors', () {
      final canvases = {
        AthenaTokens.paper.canvas.toARGB32(),
        AthenaTokens.sepia.canvas.toARGB32(),
        AthenaTokens.charcoal.canvas.toARGB32(),
        AthenaTokens.oled.canvas.toARGB32(),
      };
      expect(canvases.length, 4);
    });

    test('AppTheme.themeForAppearance binds corresponding AthenaTokens extension', () {
      for (final app in AthenaAppearance.values) {
        final theme = AppTheme.themeForAppearance(app);
        final tokens = theme.extension<AthenaTokens>();
        expect(tokens, isNotNull);
        expect(theme.scaffoldBackgroundColor, tokens!.canvas);
      }
    });
  });

  group('PASS 3 — ReaderThemeConfig Unified IDs', () {
    test('Default configs use paper, sepia, charcoal, oled IDs', () {
      final ids = ReaderThemeConfig.defaults.map((c) => c.id).toList();
      expect(ids, containsAll(['paper', 'sepia', 'charcoal', 'oled']));
    });

    test('Legacy theme IDs map cleanly to modern token presets', () {
      expect(ReaderThemeConfig.fromId('night').id, 'charcoal');
      expect(ReaderThemeConfig.fromId('obsidian').id, 'oled');
      expect(ReaderThemeConfig.fromId('paper').id, 'paper');
      expect(ReaderThemeConfig.fromId('sepia').id, 'sepia');
    });

    test('ReaderThemeConfig toAppearance maps correctly', () {
      expect(ReaderThemeConfig.fromId('paper').toAppearance(), AthenaAppearance.paper);
      expect(ReaderThemeConfig.fromId('sepia').toAppearance(), AthenaAppearance.sepia);
      expect(ReaderThemeConfig.fromId('charcoal').toAppearance(), AthenaAppearance.charcoal);
      expect(ReaderThemeConfig.fromId('oled').toAppearance(), AthenaAppearance.oled);
    });
  });

  group('PASS 3 — showAthenaError Widget Integration', () {
    testWidgets('Displays error message in SnackBar with token styling', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.themeForAppearance(AthenaAppearance.charcoal),
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => showAthenaError(ctx, 'Failed to connect to gateway'),
                child: const Text('Trigger'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Trigger'));
      await tester.pump(); // Start animation
      await tester.pump(const Duration(milliseconds: 100)); // Advance animation

      expect(find.text('Failed to connect to gateway'), findsOneWidget);
    });
  });
}
