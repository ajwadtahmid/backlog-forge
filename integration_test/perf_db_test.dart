// AUDIT harness: DB / import / search / stats timings on-device (in-memory sqlite).
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:backlogforge/models/time_to_beat.dart';
import 'package:backlogforge/services/database/games_dao.dart';
import 'package:backlogforge/services/database/app_database.dart';
import 'package:backlogforge/services/export_import_service.dart';
import 'package:backlogforge/util/search_match.dart';

const _id = 'guest_user';

int _ms(Stopwatch s) => s.elapsedMicroseconds ~/ 1000;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('db perf', (tester) async {
    final out = <String, Object?>{};
    for (final n in [2000, 5000]) {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final json = jsonEncode({
        'version': 1,
        'games': [
          for (var i = 0; i < n; i++)
            {
              'appId': 10 + i * 10,
              'name': 'Synthetic Game $i — The Witcher Style Title',
              'playtimeMinutes': (i * 37) % 4000,
              'status': 'backlog',
              'essentialHours': i % 3 == 0 ? null : 5.0 + i % 40,
              'addedAt': '2026-01-01T00:00:00.000',
            }
        ],
      });
      var sw = Stopwatch()..start();
      final comps = ExportImportService.parseImportJson(json);
      out['parse_ms_$n'] = _ms(sw);
      sw = Stopwatch()..start();
      await db.gamesDao.importGames(_id, comps);
      out['importGames_ms_$n'] = _ms(sw);
      sw = Stopwatch()..start();
      await db.gamesDao.recalculateAllStatuses(_id);
      out['recalc_ms_$n'] = _ms(sw);

      final all = await db.gamesDao.getAllGames(_id);
      // Search per keystroke (filter over all names), median of 20.
      final t = <int>[];
      for (var r = 0; r < 20; r++) {
        sw = Stopwatch()..start();
        all.where((g) => matchesGameName(g.name, 'witcher3')).length;
        t.add(sw.elapsedMicroseconds);
      }
      t.sort();
      out['search_filter_us_median_$n'] = t[10];

      // Stats: one compute, then writes while streams are being watched.
      sw = Stopwatch()..start();
      await db.statsDao.computeStats(_id);
      out['computeStats_ms_$n'] = _ms(sw);

      var statsEmits = 0, listEmits = 0;
      final s1 = db.statsDao.watchComputedStats(_id).listen((_) => statsEmits++);
      final s2 = db.gamesDao
          .watchBacklogSorted(SortMode.alphabetical, _id)
          .listen((_) => listEmits++);
      await Future<void>.delayed(const Duration(seconds: 2));
      statsEmits = 0;
      listEmits = 0;
      final target = all.where((g) => g.essentialHours == null).take(200).toList();
      sw = Stopwatch()..start();
      for (final g in target) {
        await db.gamesDao
            .updateHltbData(g.id, TimeToBeat(essentialHours: 7, hltbName: 'x', hltbGameId: 1));
      }
      out['200_hltb_writes_ms_$n'] = _ms(sw);
      await Future<void>.delayed(const Duration(seconds: 2));
      out['stats_emits_during_200_writes_$n'] = statsEmits;
      out['backlog_list_emits_during_200_writes_$n'] = listEmits;
      await s1.cancel();
      await s2.cancel();

      if (n == 5000) {
        for (final q in [
          "SELECT * FROM games WHERE steam_id='guest_user' AND status='backlog' ORDER BY name",
          "SELECT * FROM games WHERE steam_id='guest_user' AND status='completed' ORDER BY completed_at DESC",
          "SELECT * FROM games WHERE steam_id='guest_user'",
        ]) {
          final r = await db.customSelect('EXPLAIN QUERY PLAN $q').get();
          out['plan: $q'] = r.map((e) => e.data['detail']).toList();
        }
      }
      await db.close();
    }
    binding.reportData = out;
  });
}
