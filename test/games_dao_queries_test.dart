import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:backlogforge/models/time_to_beat.dart';
import 'package:backlogforge/services/database/app_database.dart';
import 'package:backlogforge/services/database/games_dao.dart';

const _me = 'me';
late AppDatabase db;
var _appId = 0;

Future<void> _add(
  String name, {
  String status = 'backlog',
  int minutes = 0,
  double? essential,
  double? extended,
  int? rating,
  String? notes,
  DateTime? added,
  DateTime? completedAt,
  String? playStyle,
}) async {
  await db.into(db.games).insert(GamesCompanion.insert(
        steamId: _me,
        appId: ++_appId,
        name: name,
        addedAt: added ?? DateTime(2026, 1, 1),
        status: Value(status),
        playtimeMinutes: Value(minutes),
        essentialHours: Value(essential),
        extendedHours: Value(extended),
        rating: Value(rating),
        notes: Value(notes),
        completedAt: Value(completedAt),
        playStyle: Value(playStyle),
      ));
}

Future<List<String>> _names(Stream<List<Game>> s) async =>
    (await s.first).map((g) => g.name).toList();

Stream<List<Game>> _backlog(SortMode m,
        {LengthFilter f = LengthFilter.any,
        ExtraFilter e = ExtraFilter.any}) =>
    db.gamesDao.watchBacklogSorted(m, _me, filter: f, extraFilter: e);

void main() {
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    _appId = 0;
  });
  tearDown(() => db.close());

  group('backlog sort modes', () {
    setUp(() async {
      await _add('Charlie', essential: 30, minutes: 60 * 10, rating: 4);
      await _add('Alpha', essential: 5, minutes: 60 * 4, rating: 9);
      await _add('Bravo', essential: 12, rating: 7);
      await _add('NoData', minutes: 60);
    });

    test('shortest puts the least time remaining first, no-data last',
        () async {
      // remaining: Alpha 1h, Bravo 12h, Charlie 20h
      expect(await _names(_backlog(SortMode.shortest)),
          ['Alpha', 'Bravo', 'Charlie', 'NoData']);
    });

    test('longest puts the most time remaining first, no-data last', () async {
      expect(await _names(_backlog(SortMode.longest)),
          ['Charlie', 'Bravo', 'Alpha', 'NoData']);
    });

    test('progress puts the furthest along first', () async {
      // Alpha 80%, Charlie 33%, NoData a sliver (1h against an unknown
      // target), Bravo 0% (never played).
      expect(await _names(_backlog(SortMode.progress)),
          ['Alpha', 'Charlie', 'NoData', 'Bravo']);
    });

    test('highest rated puts rated games first, best first', () async {
      final names = await _names(_backlog(SortMode.highestRated));
      expect(names.take(3), ['Alpha', 'Bravo', 'Charlie']);
      expect(names.last, 'NoData');
    });

    test('neglected shows only unplayed games, oldest added first', () async {
      await _add('Old unplayed', added: DateTime(2020, 1, 1));
      final names = await _names(_backlog(SortMode.neglected));
      expect(names.first, 'Old unplayed');
      expect(names, containsAll(['Bravo']));
      expect(names, isNot(contains('Alpha')));
    });
  });

  group('backlog filters', () {
    setUp(() async {
      await _add('Short', essential: 5);
      await _add('Medium', essential: 20);
      await _add('Long', essential: 60);
      await _add('Fallback', extended: 8); // uses extended when no essential
      await _add('None');
    });

    test('short is under 10 hours', () async {
      expect(await _names(_backlog(SortMode.alphabetical, f: LengthFilter.short)),
          ['Fallback', 'Short']);
    });
    test('medium is 10 to 30 hours', () async {
      expect(
          await _names(_backlog(SortMode.alphabetical, f: LengthFilter.medium)),
          ['Medium']);
    });
    test('long is 30 hours and up', () async {
      expect(await _names(_backlog(SortMode.alphabetical, f: LengthFilter.long)),
          ['Long']);
    });
    test('no data finds games without any estimate', () async {
      expect(
          await _names(_backlog(SortMode.alphabetical, f: LengthFilter.noData)),
          ['None']);
    });
    test('any returns everything', () async {
      expect(
          (await _names(_backlog(SortMode.alphabetical))).length, 5);
    });
  });

  group('extra filters', () {
    setUp(() async {
      await _add('Rated', rating: 6);
      await _add('Noted', notes: 'hello');
      await _add('Blank note', notes: '');
      await _add('Plain');
    });

    test('rated keeps only rated games', () async {
      expect(
          await _names(
              _backlog(SortMode.alphabetical, e: ExtraFilter.rated)),
          ['Rated']);
    });

    test('has notes ignores empty notes', () async {
      expect(
          await _names(
              _backlog(SortMode.alphabetical, e: ExtraFilter.withNotes)),
          ['Noted']);
    });
  });

  group('completed list', () {
    test('sorts and filters like the backlog, by absolute hours', () async {
      await _add('Big', status: 'completed', essential: 40, rating: 8,
          completedAt: DateTime(2026, 2, 1));
      await _add('Small', status: 'completed', essential: 3,
          completedAt: DateTime(2026, 2, 2));
      await _add('Open'); // backlog, must not appear
      expect(
          await _names(
              db.gamesDao.watchCompletedSorted(SortMode.shortest, _me)),
          ['Small', 'Big']);
      expect(
          await _names(db.gamesDao.watchCompletedSorted(
              SortMode.alphabetical, _me,
              extraFilter: ExtraFilter.rated)),
          ['Big']);
    });
  });

  group('lookups and edits', () {
    test('findByName matches exactly and only for that user', () async {
      await _add('Portal 2');
      expect((await db.gamesDao.findByName('Portal 2', _me))?.name, 'Portal 2');
      expect(await db.gamesDao.findByName('Portal', _me), isNull);
      expect(await db.gamesDao.findByName('Portal 2', 'someone'), isNull);
    });

    test('getBacklog excludes completed games and pins playing ones first',
        () async {
      await _add('B backlog');
      await _add('A playing', status: 'playing');
      await _add('C done', status: 'completed', completedAt: DateTime(2026, 1, 1));
      final names = (await db.gamesDao.getBacklog(_me)).map((g) => g.name);
      expect(names.toList(), ['A playing', 'B backlog']);
    });

    test('addManualGame stores the data, marks it manual and gives a negative id',
        () async {
      final id = await db.gamesDao.addManualGame(
        'Hand added',
        TimeToBeat(
            essentialHours: 7, hltbName: 'Hand Added', hltbGameId: 99),
        _me,
        artworkUrl: 'https://example.invalid/a.jpg',
      );
      final g = await (db.select(db.games)..where((x) => x.id.equals(id)))
          .getSingle();
      expect(g.appId, lessThan(0));
      expect(g.manualOverride, isTrue);
      expect(g.essentialHours, 7);
      expect(g.hltbGameId, 99);
      expect(g.hltbImageUrl, 'https://example.invalid/a.jpg');
    });

    test('saveHltbResults writes a batch and stamps the attempt', () async {
      await _add('One');
      await _add('Two');
      final all = await db.gamesDao.getAllGames(_me);
      await db.gamesDao.saveHltbResults([
        (
          id: all[0].id,
          data: TimeToBeat(
              essentialHours: 4, hltbName: 'One', hltbGameId: 1)
        ),
        (id: all[1].id, data: null),
      ]);
      final after = await db.gamesDao.getAllGames(_me);
      expect(after[0].essentialHours, 4);
      expect(after[0].hltbAttemptedAt, isNotNull);
      expect(after[1].essentialHours, isNull);
      expect(after[1].hltbAttemptedAt, isNotNull);
      await db.gamesDao.saveHltbResults(const []); // nothing to do, no error
    });
  });
}
