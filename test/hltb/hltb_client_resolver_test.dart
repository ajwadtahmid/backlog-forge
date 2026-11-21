import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:backlogforge/services/hltb/hltb_client.dart';
import 'package:backlogforge/services/hltb/hltb_resolver.dart';
import 'package:backlogforge/services/sync_exception.dart';
import 'fake_hltb_server.dart';

void main() {
  late FakeHltbServer server;
  late MemoryHltbBootstrapStore store;
  late HltbClient client;

  setUp(() {
    server = FakeHltbServer();
    store = MemoryHltbBootstrapStore();
    client = HltbClient(httpClient: server.client, store: store);
    server.addGame(id: 7231, name: 'Portal 2', steamAppId: 620, mainSeconds: 30886);
    server.addGame(id: 27601, name: 'Portal 2: Sixense Perceptual Pack', steamAppId: 0);
    server.onSearch('Portal 2', [7231, 27601]);
  });

  group('HltbClient bootstrap', () {
    test('first search discovers endpoint + token, then reuses them', () async {
      final first = await client.search('Portal 2');
      expect(first.map((h) => h.gameId), [7231, 27601]);
      expect(server.count('GET /api/search/site/init'), 1);
      expect(server.count('POST /api/search/site'), 1);

      server.log.clear();
      await client.search('Portal 2');
      await client.search('Portal 2');
      // Bootstrap is cached: exactly 1 request per search afterwards.
      expect(server.log, ['POST /api/search/site', 'POST /api/search/site']);
    });

    test('stops scanning chunks once the search endpoint is found', () async {
      await client.search('Portal 2');
      final chunks = server.log.where((l) => l.contains('/_next/static/chunks/'));
      expect(chunks.last, 'GET ${FakeHltbServer.searchChunk}');
    });

    test('bootstrap persists, so a new client (app restart) skips discovery', () async {
      await client.search('Portal 2');
      expect(store.current.searchPath, '/api/search/site');
      expect(store.current.auth?.token, server.validToken);
      expect(store.current.buildId, FakeHltbServer.fixtureBuildId);

      server.log.clear();
      final restarted = HltbClient(httpClient: server.client, store: store);
      await restarted.search('Portal 2');
      expect(server.log, ['POST /api/search/site']);
    });

    test('sends the token header and same-site origin headers', () async {
      await client.search('Portal 2');
      final headers = server.searchHeaders.last;
      expect(headers['x-auth-token'], server.validToken);
      expect(headers['Origin'], 'https://howlongtobeat.com');
      expect(headers['Referer'], 'https://howlongtobeat.com/');
    });

    test('403 (expired token) → refreshes the token once and retries', () async {
      await client.search('Portal 2');
      server.expireTokens();
      server.log.clear();

      final hits = await client.search('Portal 2');
      expect(hits, isNotEmpty);
      expect(server.log, [
        'POST /api/search/site', // 403
        'GET /api/search/site/init',
        'POST /api/search/site', // 200
      ]);
    });

    test('endpoint moved → re-discovers the search path from the JS', () async {
      await client.search('Portal 2'); // learns /api/search/site
      server.searchPath = '/api/find/v3'; // HLTB redeploys
      server.onSearch('Portal 2', [7231]);
      server.log.clear();

      final hits = await client.search('Portal 2');
      expect(hits.single.gameId, 7231);
      expect(store.current.searchPath, '/api/find/v3');
      expect(server.log.first, 'POST /api/search/site');
      expect(server.log.last, 'POST /api/find/v3');
    });

    test('concurrent searches share one token refresh', () async {
      await client.search('Portal 2');
      server.expireTokens();
      server.log.clear();
      await Future.wait([for (var i = 0; i < 4; i++) client.search('Portal 2')]);
      expect(server.count('GET /api/search/site/init'), 1);
    });

    test('429 surfaces as HltbRateLimitedException without refreshing', () async {
      await client.search('Portal 2');
      server.rateLimitSearches = 1;
      server.log.clear();
      await expectLater(
          client.search('Portal 2'), throwsA(isA<HltbRateLimitedException>()));
      expect(server.log, ['POST /api/search/site']);
    });
  });

  group('HltbClient.gamePage', () {
    test('reads the CDN game route with the discovered build id', () async {
      final page = await client.gamePage(7231);
      expect(page.steamAppId, 620);
      expect(server.log.last,
          'GET /_next/data/${FakeHltbServer.fixtureBuildId}/game/7231.json');
    });

    test('stale build id (404) → refreshes from homepage and retries', () async {
      await client.gamePage(7231);
      server.buildId = 'NEWBUILD'; // site redeployed
      server.log.clear();

      final page = await client.gamePage(7231);
      expect(page.gameId, 7231);
      expect(server.log, [
        'GET /_next/data/${FakeHltbServer.fixtureBuildId}/game/7231.json',
        'GET /',
        'GET /_next/data/NEWBUILD/game/7231.json',
      ]);
      expect(store.current.buildId, 'NEWBUILD');
    });

    test('unknown game id throws HltbLookupException (no infinite retry)', () async {
      await expectLater(client.gamePage(999), throwsA(isA<HltbLookupException>()));
      expect(server.count('GET /_next/data'), 2);
    });
  });

  group('HltbResolver', () {
    late HltbResolver resolver;
    setUp(() => resolver = HltbResolver(client));

    test('verifies by Steam appId via the game page', () async {
      final r = await resolver.resolve(name: 'Portal 2', steamAppId: 620);
      expect(r!.hltbGameId, 7231);
      expect(r.hltbVerified, isTrue);
      expect(r.essentialHours, closeTo(8.58, 0.01));
      expect(r.hltbName, 'Portal 2');
    });

    test('Steam name with ™ + edition suffix still matches (cleaned query)', () async {
      server.addGame(id: 57415, name: 'Sekiro: Shadows Die Twice', steamAppId: 814380);
      server.onSearch('Sekiro: Shadows Die Twice', [57415]);
      final r = await resolver.resolve(
          name: 'Sekiro™: Shadows Die Twice - GOTY Edition', steamAppId: 814380);
      expect(r!.hltbGameId, 57415);
      expect(r.hltbVerified, isTrue);
      expect(server.searchBodies.last['searchTerms'],
          ['Sekiro:', 'Shadows', 'Die', 'Twice']);
    });

    test('verification picks the right entry even when names differ', () async {
      server.addGame(id: 39525, name: 'Divinity: Original Sin II', steamAppId: 435150);
      server.addGame(
          id: 2611, name: 'Divinity: Original Sin', steamAppId: 230230, popularity: 9999);
      server.onSearch('Divinity: Original Sin 2', [2611, 39525]);
      final r = await resolver.resolve(
          name: 'Divinity: Original Sin 2 - Definitive Edition', steamAppId: 435150);
      expect(r!.hltbGameId, 39525);
      expect(r.hltbVerified, isTrue);
    });

    test('no Steam link on HLTB → best name match, marked unverified', () async {
      server.addGame(id: 500, name: 'Tiny Indie Game', steamAppId: 0);
      server.onSearch('Tiny Indie Game', [500]);
      final r = await resolver.resolve(name: 'Tiny Indie Game', steamAppId: 123);
      expect(r!.hltbGameId, 500);
      expect(r.hltbVerified, isFalse);
    });

    test('only weak name matches → null (genuine no-match)', () async {
      server.addGame(id: 600, name: 'Completely Different Title', steamAppId: 1);
      server.onSearch('Obscure Thing', [600]);
      expect(await resolver.resolve(name: 'Obscure Thing', steamAppId: 999), isNull);
    });

    test('no results at all → retries once without punctuation, then null', () async {
      expect(await resolver.resolve(name: 'Nope: Not Real', steamAppId: 5), isNull);
      final queries =
          server.searchBodies.map((b) => (b['searchTerms'] as List).join(' '));
      expect(queries, ['Nope: Not Real', 'nope not real']);
    });

    test('known hltbGameId skips search entirely (1 request)', () async {
      await client.gamePage(7231); // warm build id
      server.log.clear();
      final r = await resolver.resolve(
          name: 'Portal 2', steamAppId: 620, hltbGameId: 7231);
      expect(r!.hltbVerified, isTrue);
      expect(server.log,
          ['GET /_next/data/${FakeHltbServer.fixtureBuildId}/game/7231.json']);
    });

    test('caps verification page fetches at maxVerifyCandidates', () async {
      for (var i = 1; i <= 8; i++) {
        server.addGame(id: 1000 + i, name: 'Same Name', steamAppId: 0);
      }
      server.onSearch('Same Name', [for (var i = 1; i <= 8; i++) 1000 + i]);
      await resolver.resolve(name: 'Same Name', steamAppId: 42);
      expect(server.count('GET /_next/data'), 5);
    });

    test('rate limit during verification propagates (so sync can back off)', () async {
      server.rateLimitPages = 1;
      await expectLater(resolver.resolve(name: 'Portal 2', steamAppId: 620),
          throwsA(isA<HltbRateLimitedException>()));
    });
  });

  test('SharedPrefsHltbBootstrapStore round-trips and tolerates junk', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final prefsStore = SharedPrefsHltbBootstrapStore(prefs);
    expect((await prefsStore.load()).searchPath, isNull);

    final c = HltbClient(httpClient: server.client, store: prefsStore);
    await c.search('Portal 2');
    final loaded = await prefsStore.load();
    expect(loaded.searchPath, '/api/search/site');
    expect(loaded.auth?.token, server.validToken);

    await prefs.setString(SharedPrefsHltbBootstrapStore.key, '{not json');
    expect((await prefsStore.load()).auth, isNull);
  });
}
