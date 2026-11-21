// Opt-in end-to-end sync against the REAL backend (BACKEND_URL in .env) and
// the real howlongtobeat.com, on a COPY of an existing app database. The
// original database file is never opened for writing.
//
//   E2E_DB=~/.local/share/com.ajwadtahmid.backlogforge/backlogforge.db \
//   E2E_STEAM_ID=<17-digit id> \
//   flutter test test/live/e2e_sync_live_test.dart
@Tags(['live'])
library;

import 'dart:io';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:backlogforge/providers/library_provider.dart';
import 'package:backlogforge/services/database/app_database.dart';
import 'package:backlogforge/services/hltb/hltb_client.dart';
import 'package:backlogforge/services/hltb/hltb_resolver.dart';
import 'package:backlogforge/services/hltb_sync_service.dart';
import 'package:backlogforge/services/steam_service.dart';

final _db = Platform.environment['E2E_DB'];
final _steamId = Platform.environment['E2E_STEAM_ID'];

void main() {
  test('full sync: Worker → upsert → on-device HLTB → statuses', () async {
    final tmp = await Directory.systemTemp.createTemp('bf_e2e_');
    addTearDown(() => tmp.delete(recursive: true));
    final copy = await File(_db!).copy('${tmp.path}/copy.db');
    final db = AppDatabase.forTesting(NativeDatabase(copy)); // migrates the copy
    addTearDown(db.close);
    final steamId = _steamId!;

    // Clear hours on up to 8 auto-matched Steam games so HLTB must refetch them.
    final before = await db.gamesDao.getAllGames(steamId);
    final targets = before
        .where((g) =>
            g.appId > 0 && !g.manualOverride && g.essentialHours != null)
        .take(8)
        .toList();
    for (final g in targets) {
      await (db.update(db.games)..where((t) => t.id.equals(g.id))).write(
        const GamesCompanion(
          essentialHours: Value(null),
          extendedHours: Value(null),
          completionistHours: Value(null),
          hltbAttemptedAt: Value(null),
        ),
      );
    }

    final sw = Stopwatch()..start();
    final steamGames = await SteamService().getOwnedGames(steamId);
    final steamMs = sw.elapsedMilliseconds;
    await SyncNotifier.upsertSteamGames(db, steamGames, steamId);

    final client = HltbClient();
    addTearDown(client.close);
    final hltbSw = Stopwatch()..start();
    final result = await HltbSyncService(resolve: HltbResolver(client).resolve)
        .fetchAllTimeToBeat(db.gamesDao, await db.gamesDao.getAllGames(steamId));
    final hltbMs = hltbSw.elapsedMilliseconds;
    final autoCompleted = await db.gamesDao.recalculateAllStatuses(steamId);

    // ignore: avoid_print
    print('Steam via Worker: ${steamGames.length} games in $steamMs ms');
    // ignore: avoid_print
    print('HLTB: $result in $hltbMs ms; auto-completed: $autoCompleted');
    final after = await db.gamesDao.getAllGames(steamId);
    for (final old in targets) {
      final now = after.firstWhere((g) => g.id == old.id);
      // ignore: avoid_print
      print('  ${old.name.padRight(42)} old ${old.essentialHours}h '
          '→ new ${now.essentialHours}h  [hltb ${now.hltbGameId}, '
          'verified=${now.hltbVerified}]');
      expect(now.hltbAttemptedAt, isNotNull, reason: old.name);
    }

    expect(steamGames, isNotEmpty);
    expect(result.failed + result.deferred, 0);
  },
      skip: (_db == null || _steamId == null)
          ? 'set E2E_DB and E2E_STEAM_ID to run'
          : false,
      timeout: const Timeout(Duration(minutes: 5)));
}
