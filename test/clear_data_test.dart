import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:backlogforge/providers/database_provider.dart';
import 'package:backlogforge/providers/settings_provider.dart';
import 'package:backlogforge/providers/theme_provider.dart';
import 'package:backlogforge/services/database/app_database.dart';

const _me = 'guest_user';
const _other = 'someone_else';

Future<void> _addGame(AppDatabase db, String owner, int appId) =>
    db.into(db.games).insert(GamesCompanion.insert(
        steamId: owner, appId: appId, name: 'G$appId', addedAt: DateTime(2026)));

void main() {
  late AppDatabase db;
  late SharedPreferences prefs;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SharedPreferences.setMockInitialValues({
      'theme': 'light',
      'nav_position': 'left',
      'backlog_sort': 'progress',
      'completed_sort': 'highestRated',
      'backlog_length_filter': 'short',
      'quarter_goal': 5,
      'hltb.bootstrap.v1': '{"token":"x"}',
    });
    prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      sharedPrefsProvider.overrideWithValue(prefs),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> seedUser() async {
    await db.settingsDao.seedIfAbsent(_me);
    await db.settingsDao.write(
      const AppSettingsCompanion(
        theme: Value('light'),
        completionThreshold: Value('completionist'),
        showCompletedTab: Value(false),
        dailyBudgetHours: Value(3.5),
      ),
      _me,
    );
    for (var i = 1; i <= 5; i++) {
      await _addGame(db, _me, i);
    }
  }

  test('deletes the games and resets the settings row to its defaults',
      () async {
    await seedUser();

    await container.read(clearAllDataProvider)(_me);

    expect(await db.gamesDao.getAllGames(_me), isEmpty);
    final s = await db.settingsDao.read(_me);
    expect(s.theme, 'dark');
    expect(s.completionThreshold, 'essential');
    expect(s.showCompletedTab, isTrue);
    expect(s.dailyBudgetHours, 0.0);
  });

  test('removes every saved preference but keeps the HLTB cache', () async {
    await seedUser();

    await container.read(clearAllDataProvider)(_me);

    expect(prefs.getString('backlog_sort'), isNull);
    expect(prefs.getString('completed_sort'), isNull);
    expect(prefs.getString('backlog_length_filter'), isNull);
    expect(prefs.getString('nav_position'), isNull);
    expect(prefs.getInt('quarter_goal'), isNull);
    expect(prefs.getString('hltb.bootstrap.v1'), '{"token":"x"}');
  });

  test('providers read the defaults again afterwards', () async {
    await seedUser();
    expect(container.read(navigationPositionProvider), NavigationPosition.left);

    await container.read(clearAllDataProvider)(_me);

    expect(container.read(navigationPositionProvider), NavigationPosition.top);
  });

  test('another user on the same device is left alone', () async {
    await seedUser();
    await db.settingsDao.seedIfAbsent(_other);
    await _addGame(db, _other, 99);

    await container.read(clearAllDataProvider)(_me);

    expect(await db.gamesDao.getAllGames(_other), hasLength(1));
  });

  test('clearing an empty library still works and leaves a settings row',
      () async {
    await container.read(clearAllDataProvider)(_me);
    expect((await db.settingsDao.read(_me)).theme, 'dark');
  });
}
