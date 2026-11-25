import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:backlogforge/models/game_status.dart';
import 'package:backlogforge/models/play_style.dart';
import 'package:backlogforge/providers/database_provider.dart';
import 'package:backlogforge/providers/game_actions_provider.dart';
import 'package:backlogforge/services/database/app_database.dart';

const _me = 'me';
late AppDatabase db;
late ProviderContainer container;
var _appId = 0;

GameActions get _actions => container.read(gameActionsProvider);

Future<Game> _add({
  String status = 'backlog',
  int minutes = 0,
  double? essential,
  DateTime? completedAt,
  bool manual = false,
}) async {
  final id = await db.into(db.games).insert(GamesCompanion.insert(
        steamId: _me,
        appId: manual ? -(++_appId) : ++_appId,
        name: 'Game $_appId',
        addedAt: DateTime(2026, 1, 1),
        status: Value(status),
        playtimeMinutes: Value(minutes),
        essentialHours: Value(essential),
        completedAt: Value(completedAt),
      ));
  return _get(id);
}

Future<Game> _get(int id) =>
    (db.select(db.games)..where((g) => g.id.equals(id))).getSingle();

void main() {
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container =
        ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
    _appId = 0;
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  group('status', () {
    test('marking completed stamps the date and sets the manual override',
        () async {
      final g = await _add();
      await _actions.setStatus(g, GameStatus.completed);
      final after = await _get(g.id);
      expect(after.status, 'completed');
      expect(after.completedAt, isNotNull);
      expect(after.manualOverride, isTrue);
    });

    test('marking playing clears the completion date', () async {
      final g = await _add(status: 'completed', completedAt: DateTime(2026, 1, 1));
      await _actions.setStatus(g, GameStatus.playing);
      expect((await _get(g.id)).completedAt, isNull);
    });

    test('replaying keeps the completion date when asked to', () async {
      final done = DateTime(2026, 1, 1);
      final g = await _add(status: 'completed', completedAt: done);
      await _actions.setStatus(g, GameStatus.playing, preserveCompletedAt: true);
      final after = await _get(g.id);
      expect(after.status, 'playing');
      expect(after.completedAt, done);
    });
  });

  group('single-field edits', () {
    test('play style, rating and notes', () async {
      final g = await _add();
      await _actions.setPlayStyle(g, PlayStyle.completionist);
      await _actions.setRating(g, 7);
      await _actions.setNotes(g, 'worth it');
      var a = await _get(g.id);
      expect(a.playStyle, 'completionist');
      expect(a.rating, 7);
      expect(a.notes, 'worth it');

      await _actions.setRating(g, null);
      await _actions.setNotes(g, '');
      a = await _get(g.id);
      expect(a.rating, isNull);
      expect(a.notes, isNull, reason: 'an empty note is stored as no note');
    });

    test('playtime is stored in minutes and can complete the game', () async {
      final g = await _add(essential: 10);
      await _actions.setPlaytime(g, 12.5);
      final a = await _get(g.id);
      expect(a.playtimeMinutes, 750);
      expect(a.status, 'completed', reason: '12.5h is past the 10h target');
    });

    test('time to beat can be edited and cleared, and sets the override',
        () async {
      final g = await _add(essential: 10);
      await _actions.setHltbHours(g,
          essential: 20, extended: 30, completionist: null, hltbName: 'X',
          hltbGameId: 5);
      var a = await _get(g.id);
      expect(a.essentialHours, 20);
      expect(a.extendedHours, 30);
      expect(a.completionistHours, isNull);
      expect(a.hltbName, 'X');
      expect(a.hltbGameId, 5);
      expect(a.hltbVerified, isFalse, reason: 'a hand-picked entry');
      expect(a.manualOverride, isTrue);

      await _actions.setHltbHours(a,
          essential: null, extended: null, completionist: null);
      a = await _get(g.id);
      expect(a.essentialHours, isNull);
      expect(a.hltbGameId, 5, reason: 'not passed, so left alone');
    });

    test('deleting removes only that game', () async {
      final a = await _add(manual: true);
      final b = await _add(manual: true);
      await _actions.deleteGame(a);
      final left = await db.gamesDao.getAllGames(_me);
      expect(left.map((g) => g.id), [b.id]);
    });
  });

  group('bulk actions', () {
    test('an empty list does nothing', () async {
      await _actions.bulkMarkCompleted(const []);
      await _actions.bulkMarkPlaying(const []);
      await _actions.bulkStopReplaying(const []);
      await _actions.bulkMoveToBacklog(const []);
    });

    test('mark completed, playing, stop replaying and back to backlog',
        () async {
      final a = await _add();
      final b = await _add();
      final untouched = await _add();

      await _actions.bulkMarkCompleted([a, b]);
      expect((await _get(a.id)).status, 'completed');
      expect((await _get(a.id)).completedAt, isNotNull);

      await _actions.bulkMarkPlaying([a, b], preserveCompletedAt: true);
      expect((await _get(a.id)).status, 'playing');
      expect((await _get(a.id)).completedAt, isNotNull,
          reason: 'still listed under Completed while replaying');

      await _actions.bulkStopReplaying([a]);
      expect((await _get(a.id)).status, 'completed');

      await _actions.bulkMoveToBacklog([a, b]);
      final back = await _get(a.id);
      expect(back.status, 'backlog');
      expect(back.completedAt, isNull);

      expect((await _get(untouched.id)).manualOverride, isFalse);
    });

    test('mark playing without the flag clears the completion date', () async {
      final g = await _add(status: 'completed', completedAt: DateTime(2026, 1, 1));
      await _actions.bulkMarkPlaying([g]);
      expect((await _get(g.id)).completedAt, isNull);
    });
  });

  test('gameDetailProvider follows changes to one game', () async {
    final g = await _add();
    final values = <int?>[];
    container.listen(gameDetailProvider(g.id), (_, next) {
      values.add(next.asData?.value?.rating);
    }, fireImmediately: true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await _actions.setRating(g, 9);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(values.last, 9);
  });
}
