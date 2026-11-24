import 'dart:convert';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:backlogforge/services/database/app_database.dart';
import 'package:backlogforge/services/export_import_service.dart';

const _owner = 'guest_user';

late AppDatabase db;

/// A backup file with one entry per map in [games].
List<GamesCompanion> _parse(List<Map<String, Object?>> games) =>
    ExportImportService.parseImportJson(jsonEncode({
      'version': 1,
      'games': [
        for (final g in games)
          {'addedAt': '2026-03-01T00:00:00.000', 'name': 'Game', ...g},
      ],
    }));

Future<int> _addLocal({
  int appId = 10,
  String name = 'Game',
  int playtime = 0,
  String? notes,
  int? rating,
  String status = 'backlog',
  bool manualOverride = false,
  double? essential,
  DateTime? lastPlayed,
}) =>
    db.into(db.games).insert(GamesCompanion.insert(
          steamId: _owner,
          appId: appId,
          name: name,
          addedAt: DateTime(2026, 1, 1),
          playtimeMinutes: Value(playtime),
          notes: Value(notes),
          rating: Value(rating),
          status: Value(status),
          manualOverride: Value(manualOverride),
          essentialHours: Value(essential),
          lastPlayedAt: Value(lastPlayed),
        ));

Future<Game> _game(int appId) async => (await db.gamesDao.getAllGames(_owner))
    .singleWhere((g) => g.appId == appId);

void main() {
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('merging keeps the row id and the notes and rating the file lacks',
      () async {
    final id = await _addLocal(notes: 'my note', rating: 9);

    await db.gamesDao.importGames(_owner, _parse([{'appId': 10}]));

    final g = await _game(10);
    expect(g.id, id);
    expect(g.notes, 'my note');
    expect(g.rating, 9);
  });

  test('a value the file does have replaces the local one', () async {
    await _addLocal(notes: 'old', rating: 3);

    await db.gamesDao.importGames(
        _owner, _parse([{'appId': 10, 'notes': 'new', 'rating': 8}]));

    final g = await _game(10);
    expect(g.notes, 'new');
    expect(g.rating, 8);
  });

  test('blank notes in the file do not erase a local note', () async {
    await _addLocal(notes: 'keep me');
    await db.gamesDao
        .importGames(_owner, _parse([{'appId': 10, 'notes': '  '}]));
    expect((await _game(10)).notes, 'keep me');
  });

  test('play time keeps the larger value and last played the later date',
      () async {
    await _addLocal(playtime: 500, lastPlayed: DateTime.utc(2026, 5, 1));

    await db.gamesDao.importGames(
        _owner,
        _parse([
          {
            'appId': 10,
            'playtimeMinutes': 120,
            'lastPlayedAt': '2026-02-01T00:00:00.000Z',
          }
        ]));
    var g = await _game(10);
    expect(g.playtimeMinutes, 500);
    expect(g.lastPlayedAt!.toUtc(), DateTime.utc(2026, 5, 1));

    await db.gamesDao.importGames(
        _owner, _parse([{'appId': 10, 'playtimeMinutes': 900}]));
    g = await _game(10);
    expect(g.playtimeMinutes, 900);
  });

  test('time to beat from the file fills gaps but never erases local data',
      () async {
    await _addLocal(essential: 12);

    await db.gamesDao
        .importGames(_owner, _parse([{'appId': 10, 'extendedHours': 20}]));

    final g = await _game(10);
    expect(g.essentialHours, 12);
    expect(g.extendedHours, 20);
  });

  test('a local manual status survives a file without an override', () async {
    await _addLocal(status: 'playing', manualOverride: true);

    await db.gamesDao.importGames(
        _owner, _parse([{'appId': 10, 'status': 'backlog'}]));

    final g = await _game(10);
    expect(g.status, 'playing');
    expect(g.manualOverride, isTrue);
  });

  test('a file entry marked as a manual override sets the status', () async {
    await _addLocal();

    await db.gamesDao.importGames(
        _owner,
        _parse([
          {'appId': 10, 'status': 'playing', 'manualOverride': true}
        ]));

    final g = await _game(10);
    expect(g.status, 'playing');
    expect(g.manualOverride, isTrue);
  });

  test('games that are not in the library yet are inserted', () async {
    await _addLocal(appId: 10);

    final n = await db.gamesDao.importGames(
        _owner,
        _parse([
          {'appId': 10},
          {'appId': 20, 'name': 'Brand new', 'rating': 7},
        ]));

    expect(n, 2);
    final all = await db.gamesDao.getAllGames(_owner);
    expect(all, hasLength(2));
    final added = all.singleWhere((g) => g.appId == 20);
    expect(added.name, 'Brand new');
    expect(added.rating, 7);
  });

  test('the same app id twice in one file merges onto one row', () async {
    await db.gamesDao.importGames(
        _owner,
        _parse([
          {'appId': 30, 'notes': 'first', 'playtimeMinutes': 10},
          {'appId': 30, 'rating': 6, 'playtimeMinutes': 50},
        ]));

    final all = await db.gamesDao.getAllGames(_owner);
    expect(all, hasLength(1));
    expect(all.single.notes, 'first');
    expect(all.single.rating, 6);
    expect(all.single.playtimeMinutes, 50);
  });

  test('importing the same file twice changes nothing the second time',
      () async {
    final file = _parse([
      {'appId': 10, 'notes': 'n', 'rating': 4, 'playtimeMinutes': 30},
    ]);
    await db.gamesDao.importGames(_owner, file);
    final first = await _game(10);

    await db.gamesDao.importGames(_owner, file);
    final second = await _game(10);

    expect(second.id, first.id);
    expect(second.notes, first.notes);
    expect(second.rating, first.rating);
    expect(second.playtimeMinutes, first.playtimeMinutes);
  });

  test('other users keep their copy of the same game', () async {
    await db.into(db.games).insert(GamesCompanion.insert(
        steamId: 'someone_else',
        appId: 10,
        name: 'Game',
        addedAt: DateTime(2026, 1, 1),
        notes: const Value('theirs')));

    await db.gamesDao
        .importGames(_owner, _parse([{'appId': 10, 'notes': 'mine'}]));

    final theirs = await db.gamesDao.getAllGames('someone_else');
    expect(theirs.single.notes, 'theirs');
    expect((await _game(10)).notes, 'mine');
  });
}
