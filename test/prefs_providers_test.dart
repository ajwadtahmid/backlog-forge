import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:backlogforge/providers/auth_provider.dart';
import 'package:backlogforge/providers/database_provider.dart';
import 'package:backlogforge/providers/sort_provider.dart';
import 'package:backlogforge/providers/theme_provider.dart';
import 'package:backlogforge/services/database/app_database.dart';
import 'package:backlogforge/services/database/games_dao.dart';

const _me = 'me';

class _SignedIn extends AuthNotifier {
  @override
  Future<AuthState> build() async => const AuthState.signedIn(_me);
}

class _SignedOut extends AuthNotifier {
  @override
  Future<AuthState> build() async => const AuthState.signedOut();
}

Future<ProviderContainer> _container(Map<String, Object> prefs,
    {AppDatabase? db, bool signedIn = true}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final p = await SharedPreferences.getInstance();
  final c = ProviderContainer(overrides: [
    sharedPrefsProvider.overrideWithValue(p),
    if (db != null) databaseProvider.overrideWithValue(db),
    authProvider.overrideWith(() => signedIn ? _SignedIn() : _SignedOut()),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('saved list preferences', () {
    test('defaults', () async {
      final c = await _container({});
      expect(c.read(backlogSortModeProvider), SortMode.alphabetical);
      expect(c.read(completedSortModeProvider), SortMode.alphabetical);
      expect(c.read(backlogFilterProvider), LengthFilter.any);
      expect(c.read(backlogExtraFilterProvider), ExtraFilter.any);
      expect(c.read(completedExtraFilterProvider), ExtraFilter.any);
    });

    test('saved values are restored, unknown ones fall back', () async {
      final c = await _container({
        'backlog_sort': 'longest',
        'completed_sort': 'highestRated',
        'backlog_length_filter': 'medium',
        'backlog_extra_filter': 'rated',
        'completed_extra_filter': 'no such value',
      });
      expect(c.read(backlogSortModeProvider), SortMode.longest);
      expect(c.read(completedSortModeProvider), SortMode.highestRated);
      expect(c.read(backlogFilterProvider), LengthFilter.medium);
      expect(c.read(backlogExtraFilterProvider), ExtraFilter.rated);
      expect(c.read(completedExtraFilterProvider), ExtraFilter.any);
    });

    test('changing a value saves it', () async {
      final c = await _container({});
      c.read(backlogSortModeProvider.notifier).set(SortMode.shortest);
      c.read(backlogFilterProvider.notifier).set(LengthFilter.noData);
      c.read(completedExtraFilterProvider.notifier).set(ExtraFilter.withNotes);
      final prefs = c.read(sharedPrefsProvider);
      expect(prefs.getString('backlog_sort'), 'shortest');
      expect(prefs.getString('backlog_length_filter'), 'noData');
      expect(prefs.getString('completed_extra_filter'), 'withNotes');
      expect(c.read(backlogSortModeProvider), SortMode.shortest);
    });
  });

  group('sorted list providers', () {
    late AppDatabase db;
    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      Future<void> add(String name, double hours, {String status = 'backlog'}) =>
          db.into(db.games).insert(GamesCompanion.insert(
                steamId: _me,
                appId: name.hashCode,
                name: name,
                addedAt: DateTime(2026),
                status: Value(status),
                essentialHours: Value(hours),
                completedAt:
                    status == 'completed' ? Value(DateTime(2026, 2)) : const Value.absent(),
              ));
      await add('Beta', 20);
      await add('Alpha', 5);
      await add('Gamma', 50);
      await add('Done', 9, status: 'completed');
    });
    tearDown(() => db.close());

    Future<List<String>> names(
        ProviderContainer c, StreamProvider<List<Game>> p) async {
      await c.read(authProvider.future); // lists need to know who is signed in
      c.listen(p, (_, _) {}); // keep the stream provider alive between reads
      final games = await c.read(p.future);
      return games.map((g) => g.name).toList();
    }

    test('the backlog follows the saved sort and filter', () async {
      final c = await _container({}, db: db);
      expect(await names(c, backlogSortedProvider), ['Alpha', 'Beta', 'Gamma']);

      c.read(backlogSortModeProvider.notifier).set(SortMode.longest);
      expect(await names(c, backlogSortedProvider), ['Gamma', 'Beta', 'Alpha']);

      c.read(backlogFilterProvider.notifier).set(LengthFilter.short);
      expect(await names(c, backlogSortedProvider), ['Alpha']);
    });

    test('the completed list only holds completed games', () async {
      final c = await _container({}, db: db);
      expect(await names(c, completedSortedProvider), ['Done']);
    });

    test('with nobody signed in both lists are empty', () async {
      final c = await _container({}, db: db, signedIn: false);
      expect(await names(c, backlogSortedProvider), isEmpty);
      expect(await names(c, completedSortedProvider), isEmpty);
    });
  });
}
