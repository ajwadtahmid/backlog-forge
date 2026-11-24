import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:backlogforge/widgets/dialogs/game_detail_dialogs.dart';
import 'package:backlogforge/widgets/game_detail_widgets.dart';

Widget _host(Widget child,
        {double scale = 1.0, Size size = const Size(360, 780), EdgeInsets? insets}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(scale),
          viewInsets: insets ?? EdgeInsets.zero,
        ),
        child: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

const _options = [
  ToggleOption(value: 1, label: 'Backlog', icon: Icons.inbox_outlined),
  ToggleOption(value: 2, label: 'Playing', icon: Icons.play_circle_outline),
  ToggleOption(value: 3, label: 'Completed', icon: Icons.check_circle_outline),
];

void main() {
  testWidgets('toggle options sit side by side at normal text size',
      (tester) async {
    await tester.pumpWidget(_host(ToggleRow<int>(
        options: _options, selected: 1, onChanged: (_) {})));
    final a = tester.getTopLeft(find.text('Backlog'));
    final b = tester.getTopLeft(find.text('Playing'));
    expect(a.dy, b.dy);
    expect(b.dx, greaterThan(a.dx));
  });

  testWidgets('toggle options stack at 2x text so no label is clipped',
      (tester) async {
    await tester.pumpWidget(_host(
        ToggleRow<int>(options: _options, selected: 1, onChanged: (_) {}),
        scale: 2.0));
    final a = tester.getTopLeft(find.text('Backlog'));
    final c = tester.getTopLeft(find.text('Completed'));
    expect(c.dy, greaterThan(a.dy));
    // Full width tiles: the whole word fits on a single line.
    final box = tester.getSize(find.text('Completed'));
    expect(box.height, lessThan(60));
    expect(tester.takeException(), isNull);
  });

  testWidgets('time-to-beat chips stack at 2x text', (tester) async {
    Widget chips() => HltbChipRow(chips: const [
          HltbChip(label: 'Essential', hours: 10, color: Colors.red),
          HltbChip(label: 'Extended', hours: 20, color: Colors.green),
          HltbChip(label: 'Completionist', hours: 30, color: Colors.blue),
        ]);
    await tester.pumpWidget(_host(chips()));
    expect(tester.getTopLeft(find.text('Essential')).dy,
        tester.getTopLeft(find.text('Extended')).dy);

    await tester.pumpWidget(_host(chips(), scale: 2.0));
    expect(tester.getTopLeft(find.text('Extended')).dy,
        greaterThan(tester.getTopLeft(find.text('Essential')).dy));
    expect(tester.takeException(), isNull);
  });

  group('Edit Playtime dialog', () {
    Future<TextEditingController> open(WidgetTester tester,
        {Size size = const Size(360, 780), EdgeInsets? insets}) async {
      await tester.pumpWidget(_host(
          const PlaytimeDialog(initialHours: 0, isSteamGame: false),
          size: size,
          insets: insets));
      await tester.pump();
      return tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
    }

    testWidgets('opens with the whole value selected', (tester) async {
      final c = await open(tester);
      expect(c.text, '0.0');
      expect(c.selection.start, 0);
      expect(c.selection.end, 3);
    });

    testWidgets('typing over the selection gives 12.5, not 0.012.5',
        (tester) async {
      final c = await open(tester);
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '12.5',
        selection: TextSelection.collapsed(offset: 4),
      ));
      await tester.pump();
      expect(c.text, '12.5');
    });

    testWidgets('rejects non numbers, infinity and absurd values',
        (tester) async {
      final c = await open(tester);
      for (final bad in ['abc', 'Infinity', '-3', '999999']) {
        c.text = bad;
        await tester.tap(find.text('Save'));
        await tester.pump();
        expect(find.byType(TextField), findsOneWidget, reason: bad);
        expect(
            tester.widget<TextField>(find.byType(TextField)).decoration!.errorText,
            isNotNull,
            reason: bad);
      }
    });

    testWidgets('stays usable in landscape with the keyboard open',
        (tester) async {
      await open(tester,
          size: const Size(780, 360),
          insets: const EdgeInsets.only(bottom: 200));
      expect(tester.takeException(), isNull);
      // The field and both buttons are still in the tree and can be scrolled to.
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
    });
  });
}
