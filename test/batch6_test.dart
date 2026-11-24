import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:backlogforge/models/game_status.dart';
import 'package:backlogforge/providers/auth_provider.dart';
import 'package:backlogforge/providers/database_provider.dart';
import 'package:backlogforge/providers/theme_provider.dart';
import 'package:backlogforge/screens/game_detail_screen.dart';
import 'package:backlogforge/services/database/app_database.dart';
import 'package:backlogforge/services/steam_auth_service.dart';
import 'package:backlogforge/services/steam_service.dart';
import 'package:backlogforge/services/sync_exception.dart';
import 'package:backlogforge/util/search_match.dart';
import 'package:backlogforge/widgets/artwork_image.dart';

const _steamId = '76561190000000001';

void main() {
  group('search matching', () {
    test('finds substrings regardless of case', () {
      expect(matchesGameName('The Witcher 3: Wild Hunt', 'witcher'), isTrue);
      expect(matchesGameName('The Witcher 3: Wild Hunt', 'dark'), isFalse);
    });

    test('ignores punctuation when the plain match fails', () {
      expect(matchesGameName('The Witcher 3: Wild Hunt', 'witcher3'), isTrue);
      expect(matchesGameName("Garry's Mod", 'garrys'), isTrue);
    });

    test('a query of only punctuation does not match everything', () {
      expect(matchesGameName('Portal 2', '!!'), isFalse);
    });

    test('one matcher can be reused across many names', () {
      final m = GameNameMatcher('witcher3');
      final hits = ['The Witcher 3', 'Portal', 'Witcher 3 GOTY']
          .where(m.matches)
          .toList();
      expect(hits, ['The Witcher 3', 'Witcher 3 GOTY']);
    });
  });

  test('thumbnails decode at display size, headers at full size', () {
    expect(thumbnailDecodeWidth(96, 2.625), 252);
    expect(thumbnailDecodeWidth(null, 3), isNull);
  });

  group('Steam library parsing', () {
    Future<T> withBody<T>(String body, Future<T> Function() run,
        {int status = 200}) {
      return http.runWithClient(
          run, () => MockClient((_) async => http.Response(body, status)));
    }

    test('reads a normal library', () async {
      final games = await withBody(
          jsonEncode([
            {'appid': 10, 'name': 'A', 'playtime_forever': 5}
          ]),
          () => SteamService().getOwnedGames(_steamId));
      expect(games.single.appId, 10);
    });

    test('a malformed entry is a Steam error, not a crash', () async {
      for (final body in [
        jsonEncode([
          {'appid': 'ten', 'name': 'A'}
        ]),
        jsonEncode([
          {'name': 'no id'}
        ]),
        jsonEncode(['not a map']),
      ]) {
        await expectLater(
            withBody(body, () => SteamService().getOwnedGames(_steamId)),
            throwsA(isA<SteamApiException>()),
            reason: body);
      }
    });

    test('a dropped connection is reported as a network error', () async {
      await expectLater(
          http.runWithClient(() => SteamService().getOwnedGames(_steamId),
              () => MockClient((_) async => throw http.ClientException('x'))),
          throwsA(isA<NetworkException>()));
    });

    test('single-game lookup treats a malformed entry the same way', () async {
      await expectLater(
          withBody(
              jsonEncode([
                {'appid': 1}
              ]),
              () => SteamService().getGamePlaytime(_steamId, 1)),
          throwsA(isA<SteamApiException>()));
    });
  });

  group('Steam sign-in response', () {
    Uri response(String returnTo) => Uri.parse('backlogforge://auth').replace(
          queryParameters: {
            'openid.claimed_id':
                'https://steamcommunity.com/openid/id/$_steamId',
            'openid.return_to': returnTo,
          },
        );

    test('is refused when return_to is not this app\'s own callback',
        () async {
      final svc = SteamAuthService();
      svc.buildBackendLoginUrl('https://api.example.com/');
      expect(
          await svc.extractAndVerifySteamId(
              response('https://evil.example.net/auth/steam/callback')),
          isNull);
    });

    test('is refused when no login was started by this instance', () async {
      expect(
          await SteamAuthService().extractAndVerifySteamId(
              response('https://api.example.com/auth/steam/callback')),
          isNull);
    });

    test('the login URL and the accepted return_to are the same value', () {
      final svc = SteamAuthService();
      final url = svc.buildBackendLoginUrl('https://api.example.com/');
      expect(url.queryParameters['openid.return_to'],
          'https://api.example.com/auth/steam/callback');
    });
  });

  test('backup rules keep the secure-storage files out of Auto Backup', () {
    const files = [
      'FlutterSecureStorage.xml',
      'FlutterSecureKeyStorage.xml',
      'FlutterSecureStorageConfiguration:FlutterSecureStorage.xml',
    ];
    for (final rules in ['backup_rules.xml', 'data_extraction_rules.xml']) {
      final xml =
          File('android/app/src/main/res/xml/$rules').readAsStringSync();
      for (final f in files) {
        expect(xml, contains('path="$f"'), reason: '$rules lacks $f');
      }
    }
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('@xml/backup_rules'));
    expect(manifest, contains('@xml/data_extraction_rules'));
  });

  group('game detail screen', () {
    late AppDatabase db;
    late int id;

    Future<void> open(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final game = await (db.select(db.games)..where((g) => g.id.equals(id)))
          .getSingle();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sharedPrefsProvider.overrideWithValue(prefs),
          authProvider.overrideWith(() => _FakeAuth()),
        ],
        child: MaterialApp(home: GameDetailScreen(game: game)),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> unmount(WidgetTester tester) async {
      // Unmount before the database closes, or its streams error on shutdown.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    }

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      id = await db.into(db.games).insert(GamesCompanion.insert(
            steamId: _steamId,
            appId: -1,
            name: 'Test Game',
            addedAt: DateTime(2026),
            essentialHours: const Value(10),
            extendedHours: const Value(20),
          ));
    });
    tearDown(() => db.close());

    testWidgets('a status change made elsewhere shows up on the open screen',
        (tester) async {
      await open(tester);
      expect(find.text('Backlog'), findsOneWidget);

      // A sync or bulk action marks it completed while the screen is open.
      await (db.update(db.games)..where((g) => g.id.equals(id)))
          .write(GamesCompanion(status: Value(GameStatus.completed.name)));
      await tester.pumpAndSettle();

      Color? fill(String label) => (tester
              .widget<AnimatedContainer>(find
                  .ancestor(
                      of: find.text(label),
                      matching: find.byType(AnimatedContainer))
                  .first)
              .decoration as BoxDecoration)
          .color;
      final primary =
          Theme.of(tester.element(find.text('Completed'))).colorScheme.primary;
      expect(fill('Completed'), primary);
      expect(fill('Backlog'), Colors.transparent);
      await unmount(tester);
    });

    testWidgets('the rating is written once, with the final position',
        (tester) async {
      await open(tester);
      final slider = find.byType(Slider);
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();

      Future<int?> savedRating() async => (await (db.select(db.games)
                ..where((x) => x.id.equals(id)))
              .getSingle())
          .rating;

      final rect = tester.getRect(slider);
      final g = await tester.startGesture(rect.center);
      for (var i = 1; i <= 8; i++) {
        await g.moveBy(const Offset(30, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      // Mid-drag the slider and the "n/10" label follow the finger, but nothing
      // has been written yet: no write per notch passed.
      expect(await savedRating(), isNull);
      expect(find.text('Not set'), findsNothing);

      await g.moveTo(Offset(rect.right + 50, rect.center.dy));
      await tester.pump(const Duration(milliseconds: 16));
      await g.up();
      await tester.pumpAndSettle();

      final row = await (db.select(db.games)..where((x) => x.id.equals(id)))
          .getSingle();
      expect(row.rating, 10);
      expect(find.text('10/10'), findsOneWidget);
      await unmount(tester);
    });
  });
}

class _FakeAuth extends AuthNotifier {
  @override
  Future<AuthState> build() async => const AuthState.signedIn(_steamId);
}
