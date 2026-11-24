// AUDIT harness: seeds a guest library of N games, flings the backlog list
// and records frame timings. N via --dart-define=PERF_GAMES (default 2000).
import 'dart:math';
import 'dart:ui' show FrameTiming, Offset;
import 'package:drift/drift.dart' show Value;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' show Scrollable, ListView;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:backlogforge/main.dart';
import 'package:backlogforge/providers/auth_provider.dart';
import 'package:backlogforge/providers/database_provider.dart';
import 'package:backlogforge/providers/theme_provider.dart';
import 'package:backlogforge/services/database/app_database.dart';

const _n = int.fromEnvironment('PERF_GAMES', defaultValue: 2000);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('scroll backlog', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: const BacklogForgeApp(),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 3));
    final c = ProviderScope.containerOf(tester.element(find.byType(BacklogForgeApp)));
    final db = c.read(databaseProvider);
    await c.read(authProvider.notifier).completeSignIn(AuthNotifier.guestSteamId);
    final rnd = Random(42);
    final now = DateTime(2026, 11, 22);
    await db.gamesDao.importGames(AuthNotifier.guestSteamId, [
      for (var i = 0; i < _n; i++)
        GamesCompanion(
          appId: Value(10 + i * 10),
          name: Value('Synthetic Game ${i.toString().padLeft(4, '0')} — A Reasonably Long Title'),
          playtimeMinutes: Value(rnd.nextInt(3000)),
          essentialHours: Value(5 + rnd.nextInt(40).toDouble()),
          extendedHours: Value(10 + rnd.nextInt(60).toDouble()),
          completionistHours: Value(20 + rnd.nextInt(120).toDouble()),
          addedAt: Value(now),
        ),
    ]);
    await tester.pumpAndSettle(const Duration(seconds: 8));
    final frames = <FrameTiming>[];
    void cb(List<FrameTiming> t) => frames.addAll(t);
    SchedulerBinding.instance.addTimingsCallback(cb);
    final list = find.descendant(of: find.byType(ListView).last, matching: find.byType(Scrollable)).first;
    for (var i = 0; i < 12; i++) {
      await tester.fling(list, const Offset(0, -1200), 3000);
      await tester.pump(const Duration(milliseconds: 800));
    }
    for (var i = 0; i < 12; i++) {
      await tester.fling(list, const Offset(0, 1200), 3000);
      await tester.pump(const Duration(milliseconds: 800));
    }
    await Future<void>.delayed(const Duration(seconds: 1));
    SchedulerBinding.instance.removeTimingsCallback(cb);
    binding.reportData = {
      'games': _n,
      'build_us': frames.map((f) => f.buildDuration.inMicroseconds).toList(),
      'raster_us': frames.map((f) => f.rasterDuration.inMicroseconds).toList(),
      'total_us': frames.map((f) => f.totalSpan.inMicroseconds).toList(),
    };
  });
}
