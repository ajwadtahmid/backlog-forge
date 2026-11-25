import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:backlogforge/services/database/app_database.dart';

const _me = 'me';
const _other = 'other';

late AppDatabase db;
var _appId = 0;

Future<void> _add({
  String owner = _me,
  String status = 'backlog',
  int minutes = 0,
  double? essential,
  double? extended,
  String? playStyle,
  DateTime? completedAt,
}) async {
  await db.into(db.games).insert(GamesCompanion.insert(
        steamId: owner,
        appId: ++_appId,
        name: 'Game $_appId',
        addedAt: DateTime(2026, 1, 1),
        status: Value(status),
        playtimeMinutes: Value(minutes),
        essentialHours: Value(essential),
        extendedHours: Value(extended),
        playStyle: Value(playStyle),
        completedAt: Value(completedAt),
      ));
}

void main() {
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    _appId = 0;
  });
  tearDown(() => db.close());

  group('computeStats', () {
    test('an empty library is all zeros with no average', () async {
      final s = await db.statsDao.computeStats(_me);
      expect(s.backlog, 0);
      expect(s.completed, 0);
      expect(s.playing, 0);
      expect(s.totalHours, 0);
      expect(s.avgCompletionHours, isNull);
      expect(s.completedQuarterly, 0);
      expect(s.analysis.hltbTotal, 0);
    });

    test('counts each status, total hours and the average completion time',
        () async {
      await _add(status: 'backlog', minutes: 0);
      await _add(status: 'backlog', minutes: 120);
      await _add(status: 'playing', minutes: 60);
      await _add(
          status: 'completed', minutes: 600, completedAt: DateTime(2026, 2, 1));
      await _add(
          status: 'completed', minutes: 1200, completedAt: DateTime(2026, 3, 1));

      final s = await db.statsDao.computeStats(_me);
      expect(s.backlog, 3); // two backlog + one playing, none completed
      expect(s.playing, 1);
      expect(s.completed, 2);
      expect(s.totalHours, (0 + 120 + 60 + 600 + 1200) / 60);
      expect(s.avgCompletionHours, (10 + 20) / 2);
    });

    test('a completed game being replayed still counts as completed',
        () async {
      await _add(
          status: 'playing', minutes: 300, completedAt: DateTime(2026, 1, 5));
      final s = await db.statsDao.computeStats(_me);
      expect(s.completed, 1);
      expect(s.backlog, 0, reason: 'it must not also count as unfinished');
      expect(s.playing, 1);
    });

    test('other users\' games are ignored', () async {
      await _add(owner: _other, status: 'completed', minutes: 6000);
      await _add(owner: _other, status: 'backlog');
      final s = await db.statsDao.computeStats(_me);
      expect(s.backlog + s.completed, 0);
      expect(s.totalHours, 0);
    });
  });

  group('backlogStats', () {
    test('hours remaining follow the chosen play style', () async {
      await _add(minutes: 60, essential: 10, extended: 20); // 9h left
      await _add(
          minutes: 60, essential: 10, extended: 20, playStyle: 'extended'); // 19h
      final a = await db.statsDao.backlogStats(_me);
      expect(a.hoursRemaining, 9 + 19);
      expect(a.hltbCovered, 2);
      expect(a.hltbTotal, 2);
    });

    test('a game over its target has no hours remaining, not negative',
        () async {
      await _add(minutes: 60 * 15, essential: 10);
      expect((await db.statsDao.backlogStats(_me)).hoursRemaining, 0);
    });

    test('buckets never started, barely played and halfway done', () async {
      await _add(minutes: 0, essential: 10); // never started
      await _add(minutes: 30, essential: 10); // 5%  -> barely played
      await _add(minutes: 300, essential: 10); // 50% -> halfway
      await _add(minutes: 480, essential: 10); // 80% -> halfway
      await _add(minutes: 120, essential: 10); // 20% -> neither
      final a = await db.statsDao.backlogStats(_me);
      expect(a.neverStarted, 1);
      expect(a.barelyPlayed, 1);
      expect(a.halfwayDone, 2);
    });

    test('games without time-to-beat data count toward the total only',
        () async {
      await _add(minutes: 100);
      await _add(minutes: 0);
      final a = await db.statsDao.backlogStats(_me);
      expect(a.hltbCovered, 0);
      expect(a.hltbTotal, 2);
      expect(a.neverStarted, 1);
      expect(a.halfwayDone, 0);
    });

    test('completed and replaying games are left out', () async {
      await _add(status: 'completed', minutes: 600, essential: 10);
      await _add(
          status: 'playing',
          minutes: 600,
          essential: 10,
          completedAt: DateTime(2026, 1, 1));
      expect((await db.statsDao.backlogStats(_me)).hltbTotal, 0);
    });
  });

  group('completions over time', () {
    test('completedByMonth groups by month, oldest first', () async {
      await _add(status: 'completed', completedAt: DateTime(2026, 3, 10));
      await _add(status: 'completed', completedAt: DateTime(2025, 12, 31));
      await _add(status: 'completed', completedAt: DateTime(2026, 3, 1));
      await _add(
          status: 'playing', completedAt: DateTime(2026, 1, 2)); // replaying
      await _add(status: 'backlog');
      final months = await db.statsDao.completedByMonth(_me);
      expect(months, [
        (year: 2025, month: 12, count: 1),
        (year: 2026, month: 1, count: 1),
        (year: 2026, month: 3, count: 2),
      ]);
    });

    test('completedLastFourMonths counts this month and the previous three',
        () async {
      final now = DateTime.now();
      await _add(status: 'completed', completedAt: now);
      await _add(
          status: 'completed', completedAt: DateTime(now.year, now.month - 3, 1));
      await _add(
          status: 'completed',
          completedAt: DateTime(now.year, now.month - 4, 28)); // too old
      expect(await db.statsDao.completedLastFourMonths(_me), 2);
    });
  });

  test('watchComputedStats emits again after a change', () async {
    await _add(status: 'backlog');
    final stream = db.statsDao.watchComputedStats(_me);
    final emitted = <int>[];
    final sub = stream.listen((s) => emitted.add(s.backlog));
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await _add(status: 'backlog');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await sub.cancel();
    expect(emitted.first, 1);
    expect(emitted.last, 2);
  });
}
