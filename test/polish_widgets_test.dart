import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:backlogforge/screens/tabs/game_list_tab_shared.dart';
import 'package:backlogforge/theme.dart';
import 'package:backlogforge/widgets/artwork_image.dart';

double _lum(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double _contrast(Color a, Color b) {
  final l1 = _lum(a), l2 = _lum(b);
  return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
}

Color _over(Color top, Color bottom) => Color.alphaBlend(top, bottom);

void main() {
  group('Playing badge text', () {
    testWidgets('meets 4.5:1 on the light theme, including on a playing row',
        (tester) async {
      late Color text;
      await tester.pumpWidget(MaterialApp(
        theme: lightThemeFor(AppFont.system),
        home: Builder(builder: (c) {
          text = playingTextColor(c);
          return const SizedBox();
        }),
      ));
      final surface = lightThemeFor(AppFont.system).colorScheme.surface;
      // The row is tinted with the same green, and the badge sits on top of it.
      final row = _over(kColorPlayingBg, surface);
      final badge = _over(kColorPlayingBg, row);
      expect(_contrast(text, badge), greaterThanOrEqualTo(4.5));
    });

    testWidgets('keeps the bright green on the dark theme', (tester) async {
      late Color text;
      await tester.pumpWidget(MaterialApp(
        theme: darkThemeFor(AppFont.system),
        home: Builder(builder: (c) {
          text = playingTextColor(c);
          return const SizedBox();
        }),
      ));
      expect(text, kColorPlaying);
      final surface = darkThemeFor(AppFont.system).colorScheme.surface;
      final badge = _over(kColorPlayingBg, _over(kColorPlayingBg, surface));
      expect(_contrast(text, badge), greaterThanOrEqualTo(4.5));
    });
  });

  testWidgets('bulk action bar shows a caption under every icon',
      (tester) async {
    var tapped = '';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BulkActionBar(
          selectedCount: 2,
          onCancel: () {},
          actions: [
            BulkAction(
                icon: Icons.check,
                label: 'Mark complete',
                shortLabel: 'Complete',
                onPressed: () => tapped = 'complete'),
            BulkAction(
                icon: Icons.undo,
                label: 'Remove from playing',
                onPressed: () => tapped = 'undo'),
          ],
        ),
      ),
    ));
    expect(find.text('Complete'), findsOneWidget);
    expect(find.text('Remove from playing'), findsOneWidget); // falls back
    await tester.tap(find.text('Complete'));
    expect(tapped, 'complete');
  });

  group('missing artwork placeholder', () {
    for (final entry in {
      'light': lightThemeFor(AppFont.system),
      'dark': darkThemeFor(AppFont.system),
    }.entries) {
      testWidgets('follows the ${entry.key} theme', (tester) async {
        await tester.pumpWidget(MaterialApp(
          theme: entry.value,
          home: const Scaffold(
              body: ArtworkImage(url: null, width: 96, height: 54)),
        ));
        expect(find.text('No Artwork'), findsOneWidget);
        final box = tester.widget<Container>(find.descendant(
            of: find.byType(ArtworkImage), matching: find.byType(Container)));
        expect(box.color, entry.value.colorScheme.surfaceContainerHighest);
      });
    }
  });

  testWidgets('list thumbnails are decoded at display size, not full size',
      (tester) async {
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(children: [
          ArtworkImage(url: 'https://example.invalid/a.jpg', width: 96, height: 54),
          ArtworkImage(url: 'https://example.invalid/b.jpg'),
        ]),
      ),
    ));
    final images = tester
        .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .toList();
    expect(images[0].memCacheWidth, 192); // 96 dp * 2.0
    expect(images[1].memCacheWidth, isNull); // no width given: full size
  });
}
