import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:backlogforge/models/time_to_beat.dart';
import 'package:backlogforge/providers/library_provider.dart';
import 'package:backlogforge/services/database/app_database.dart';
import 'package:backlogforge/services/export_import_service.dart';
import 'package:backlogforge/services/hltb_sync_service.dart';
import 'package:backlogforge/services/sync_exception.dart';

const _steamId = 's1';

Future<int> _insert(
  AppDatabase db, {
  required int appId,
  required String name,
  double? essential,
  bool manualOverride = false,
  DateTime? attemptedAt,
  int? hltbGameId,
}) =>
    db.into(db.games).insert(GamesCompanion.insert(
          steamId: _steamId,
          appId: appId,
          name: name,
          addedAt: DateTime(2024),
          essentialHours: Value(essential),
          manualOverride: Value(manualOverride),
          hltbAttemptedAt: Value(attemptedAt),
          hltbGameId: Value(hltbGameId),
        ));

Future<Game> _game(AppDatabase db, int id) =>
    (db.select(db.games)..where((g) => g.id.equals(id))).getSingle();

/// Scripted resolver: outcome per game name. A value may be a [TimeToBeat],
/// null (no match), an [Exception] to throw, or a list consumed per call.
class _ScriptedResolver {
  final Map<String, Object?> script;
  final calls = <({String name, int? steamAppId, int? hltbGameId})>[];
  int inFlight = 0, maxInFlight = 0;
  _ScriptedResolver(this.script);

  Future<TimeToBeat?> call({
    required String name,
    int? steamAppId,
    int? hltbGameId,
  }) async {
    calls.add((name: name, steamAppId: steamAppId, hltbGameId: hltbGameId));
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    await Future<void>.delayed(Duration.zero); // let other workers interleave
    inFlight--;
    var outcome = script[name];
    if (outcome is List) outcome = outcome.isEmpty ? null : outcome.removeAt(0);
    if (outcome is Exception) throw outcome;
    return outcome as TimeToBeat?;
  }
}

TimeToBeat _ttb(int id, {bool verified = true}) => TimeToBeat(
      essentialHours: 10,
      extendedHours: 20,
      completionistHours: 30,
      hltbName: 'HLTB $id',
      hltbGameId: id,
      hltbVerified: verified,
    );

void main() {
  late AppDatabase db;
  late List<Duration> sleeps;

  HltbSyncService service(_ScriptedResolver r) => HltbSyncService(
        resolve: r.call,
        sleep: (d) async => sleeps.add(d),
      );

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    sleeps = [];
  });
  tearDown(() => db.close());

  Future<HltbSyncResult> runSync(_ScriptedResolver r) async => service(r)
      .fetchAllTimeToBeat(db.gamesDao, await db.gamesDao.getAllGames(_steamId));

  test('match → saves hours, HLTB id, verified flag and stamps attempt', () async {
    final id = await _insert(db, appId: 620, name: 'Portal 2');
    final result = await runSync(_ScriptedResolver({'Portal 2': _ttb(7231)}));

    expect(result, (fetched: 1, noMatch: 0, failed: 0, deferred: 0));
    final g = await _game(db, id);
    expect(g.essentialHours, 10);
    expect(g.completionistHours, 30);
    expect(g.hltbGameId, 7231);
    expect(g.hltbVerified, isTrue);
    expect(g.hltbName, 'HLTB 7231');
    expect(g.hltbAttemptedAt, isNotNull);
  });

  test('genuine no-match → stamps attempt so the retry window applies', () async {
    final id = await _insert(db, appId: 1, name: 'Not On HLTB');
    final result = await runSync(_ScriptedResolver({'Not On HLTB': null}));
    expect(result.noMatch, 1);
    final g = await _game(db, id);
    expect(g.hltbAttemptedAt, isNotNull);
    expect(g.essentialHours, isNull);
  });

  test('REGRESSION: a failed lookup is NOT stamped and is retried next sync', () async {
    final id = await _insert(db, appId: 2, name: 'Flaky');
    final resolver = _ScriptedResolver({
      'Flaky': [const HltbSearchException('status 502'), _ttb(99)],
    });

    final first = await runSync(resolver);
    expect(first.failed, 1);
    expect((await _game(db, id)).hltbAttemptedAt, isNull,
        reason: 'old code stamped here and skipped the game for 7 days');

    final second = await runSync(resolver);
    expect(second.fetched, 1);
    expect((await _game(db, id)).hltbGameId, 99);
  });

  test('429 → shared backoff, then continues without counting a failure', () async {
    final id = await _insert(db, appId: 3, name: 'Busy');
    final result = await runSync(_ScriptedResolver({
      'Busy': [const HltbRateLimitedException(), _ttb(5)],
    }));
    expect(result, (fetched: 1, noMatch: 0, failed: 0, deferred: 0));
    expect(sleeps, [const Duration(seconds: 10)]);
    expect((await _game(db, id)).hltbGameId, 5);
  });

  test('persistent 429 → stops after backoff; rest deferred and untouched', () async {
    for (var i = 1; i <= 6; i++) {
      await _insert(db, appId: i, name: 'G$i');
    }
    final result = await runSync(_ScriptedResolver({
      for (var i = 1; i <= 6; i++) 'G$i': const HltbRateLimitedException(),
    }));
    expect(result.fetched + result.noMatch + result.failed, 0);
    expect(result.deferred, 6);
    expect(sleeps.length, lessThanOrEqualTo(3 * 2)); // bounded backoff
    final games = await db.gamesDao.getAllGames(_steamId);
    expect(games.every((g) => g.hltbAttemptedAt == null), isTrue);
  });

  test('stops after 5 consecutive failures (HLTB down) instead of hammering', () async {
    for (var i = 1; i <= 20; i++) {
      await _insert(db, appId: i, name: 'G$i');
    }
    final resolver = _ScriptedResolver({
      for (var i = 1; i <= 20; i++) 'G$i': const HltbSearchException('down'),
    });
    final result = await runSync(resolver);
    expect(result.failed, inInclusiveRange(5, 6)); // 2 workers may overlap by one
    expect(result.deferred, 20 - result.failed);
    expect(resolver.calls.length, result.failed);
  });

  test('a success resets the consecutive-failure counter', () async {
    final names = ['F1', 'F2', 'F3', 'F4', 'OK', 'F5', 'F6', 'F7', 'F8'];
    for (var i = 0; i < names.length; i++) {
      await _insert(db, appId: i + 1, name: names[i]);
    }
    final result = await HltbSyncService(
      resolve: _ScriptedResolver({
        for (final n in names)
          n: n == 'OK' ? _ttb(1) : const HltbSearchException('x'),
      }).call,
      concurrency: 1,
      sleep: (d) async {},
    ).fetchAllTimeToBeat(db.gamesDao, await db.gamesDao.getAllGames(_steamId));
    // getAllGames has no ORDER BY guarantee beyond rowid; insertion order holds.
    expect(result, (fetched: 1, noMatch: 0, failed: 8, deferred: 0));
  });

  test('selects only games that need data', () async {
    final now = DateTime.now();
    await _insert(db, appId: 1, name: 'Needs data');
    await _insert(db, appId: 2, name: 'Has hours', essential: 5);
    await _insert(db, appId: 3, name: 'Manual', manualOverride: true);
    await _insert(db, appId: 4, name: 'Tried yesterday',
        attemptedAt: now.subtract(const Duration(days: 1)));
    await _insert(db, appId: 5, name: 'Tried last month',
        attemptedAt: now.subtract(const Duration(days: 30)));

    final resolver = _ScriptedResolver({});
    await runSync(resolver);
    expect(resolver.calls.map((c) => c.name).toSet(),
        {'Needs data', 'Tried last month'});
  });

  test('passes Steam appId (not for manual games) and known HLTB id', () async {
    await _insert(db, appId: 620, name: 'Steam game', hltbGameId: 7231);
    await _insert(db, appId: -1, name: 'Manual game');
    final resolver = _ScriptedResolver({});
    await runSync(resolver);
    final byName = {for (final c in resolver.calls) c.name: c};
    expect(byName['Steam game']!.steamAppId, 620);
    expect(byName['Steam game']!.hltbGameId, 7231);
    expect(byName['Manual game']!.steamAppId, isNull);
  });

  test('runs at most 2 lookups at once and reports progress', () async {
    for (var i = 1; i <= 7; i++) {
      await _insert(db, appId: i, name: 'G$i');
    }
    final resolver = _ScriptedResolver({});
    final progress = <int>[];
    await service(resolver).fetchAllTimeToBeat(
      db.gamesDao,
      await db.gamesDao.getAllGames(_steamId),
      onProgress: (done, total) {
        expect(total, 7);
        progress.add(done);
      },
    );
    expect(resolver.maxInFlight, 2);
    expect(progress, [1, 2, 3, 4, 5, 6, 7]);
  });

  test('sync notification mentions failed + deferred games as retried later', () {
    expect(
        SyncNotifier.buildSyncNotification(
            0, (fetched: 3, noMatch: 1, failed: 0, deferred: 0)),
        isNull);
    final msg = SyncNotifier.buildSyncNotification(
        2, (fetched: 0, noMatch: 0, failed: 1, deferred: 4))!;
    expect(msg, contains('2 games automatically marked completed'));
    expect(msg, contains('5 games'));
    expect(msg, contains('retried on the next sync'));
  });

  group('schema 13', () {
    test('migrates a v12 database: adds hltb_game_id / hltb_verified, keeps data',
        () async {
      final v12 = AppDatabase.forTesting(NativeDatabase.memory(setup: (raw) {
        raw.execute('''
          CREATE TABLE games (
            id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
            steam_id TEXT NOT NULL, app_id INTEGER NOT NULL, name TEXT NOT NULL,
            playtime_minutes INTEGER NOT NULL DEFAULT 0,
            essential_hours REAL, extended_hours REAL, completionist_hours REAL,
            status TEXT NOT NULL DEFAULT 'backlog', added_at INTEGER NOT NULL,
            completed_at INTEGER, last_played_at INTEGER,
            hltb_image_url TEXT, hltb_name TEXT, play_style TEXT,
            manual_override INTEGER NOT NULL DEFAULT 0
              CHECK (manual_override IN (0, 1)),
            hltb_attempted_at INTEGER, notes TEXT, rating INTEGER,
            UNIQUE (steam_id, app_id));
        ''');
        raw.execute('''
          CREATE TABLE app_settings (
            steam_id TEXT NOT NULL PRIMARY KEY,
            completion_threshold TEXT NOT NULL DEFAULT 'essential',
            sort_order TEXT NOT NULL DEFAULT 'alpha',
            show_completed_tab INTEGER NOT NULL DEFAULT 1
              CHECK (show_completed_tab IN (0, 1)),
            theme TEXT NOT NULL DEFAULT 'dark',
            daily_budget_hours REAL NOT NULL DEFAULT 0.0);
        ''');
        raw.execute(
            "INSERT INTO games (steam_id, app_id, name, essential_hours, added_at) "
            "VALUES ('s1', 620, 'Portal 2', 8.5, 1700000000)");
        raw.execute('PRAGMA user_version = 12');
      }));
      addTearDown(v12.close);

      final g = (await v12.gamesDao.getAllGames('s1')).single;
      expect(g.name, 'Portal 2');
      expect(g.essentialHours, 8.5);
      expect(g.hltbGameId, isNull);
      expect(g.hltbVerified, isFalse);

      await v12.gamesDao.updateHltbData(g.id, _ttb(7231));
      expect((await v12.gamesDao.getAllGames('s1')).single.hltbGameId, 7231);
    });

    test('export/import round-trips HLTB id + verified; old exports default',
        () async {
      final id = await _insert(db, appId: 620, name: 'Portal 2');
      await db.gamesDao.updateHltbData(id, _ttb(7231));
      final json = ExportImportService.buildExportJson(
          _steamId, await db.gamesDao.getAllGames(_steamId));
      final row = ExportImportService.parseImportJson(json).single;
      expect(row.hltbGameId.value, 7231);
      expect(row.hltbVerified.value, isTrue);

      final legacy = json
          .replaceAll(RegExp(r'\s*"hltbGameId": \d+,'), '')
          .replaceAll(RegExp(r'\s*"hltbVerified": true,'), '');
      expect(legacy.contains('hltbGameId'), isFalse);
      final old = ExportImportService.parseImportJson(legacy).single;
      expect(old.hltbGameId.value, isNull);
      expect(old.hltbVerified.value, isFalse);
    });
  });
}
