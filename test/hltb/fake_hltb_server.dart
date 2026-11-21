import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String fixture(String name) =>
    File('test/fixtures/hltb/$name').readAsStringSync();

/// In-memory stand-in for howlongtobeat.com, built from captured real
/// responses (test/fixtures/hltb). Records every request for assertions.
class FakeHltbServer {
  /// Build id embedded in the captured homepage fixture.
  static const fixtureBuildId = 'RS3MtNrhIzoB1gMv7p1hA';
  static const searchChunk = '/_next/static/chunks/0y6nqsvqtx18r.js';

  String buildId = fixtureBuildId;
  String searchPath = '/api/search/site';
  int _tokenCounter = 0;
  String? validToken;

  /// Search results keyed by the query string sent in `searchTerms`.
  final Map<String, List<Map<String, Object?>>> searchResults = {};

  /// Game pages keyed by HLTB id.
  final Map<int, Map<String, Object?>> games = {};

  /// Next N search/page requests answer 429.
  int rateLimitSearches = 0;
  int rateLimitPages = 0;

  final List<String> log = [];
  final List<Map<String, String>> searchHeaders = [];
  final List<Map<String, dynamic>> searchBodies = [];

  int count(String prefix) => log.where((l) => l.startsWith(prefix)).length;

  /// Simulates HLTB expiring every issued token.
  void expireTokens() => validToken = null;

  late final http.Client client = MockClient(_handle);

  void addGame({
    required int id,
    required String name,
    int steamAppId = 0,
    int mainSeconds = 36000,
    String alias = '',
    int popularity = 100,
  }) {
    games[id] = {
      'game_id': id,
      'game_name': name,
      'game_alias': alias,
      'game_image': '$id.jpg',
      'comp_main': mainSeconds,
      'comp_plus': mainSeconds * 2,
      'comp_100': mainSeconds * 3,
      'comp_all': mainSeconds,
      'comp_all_count': popularity,
      'profile_steam': steamAppId,
    };
  }

  /// Registers [ids] (already added via [addGame]) as results for [query].
  void onSearch(String query, List<int> ids) {
    searchResults[query] = [
      for (final id in ids)
        {...games[id]!}..remove('profile_steam'), // search omits Steam id
    ];
  }

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;
    log.add('${req.method} $path');

    if (req.method == 'GET' && path == '/') {
      return http.Response(
        fixture('home.html').replaceAll(fixtureBuildId, buildId),
        200,
      );
    }
    if (path.startsWith('/_next/static/chunks/')) {
      final body = path == searchChunk
          ? fixture('search_chunk.js').replaceAll('/api/search/site', searchPath)
          : fixture('other_chunk.js');
      return http.Response(body, 200);
    }
    if (path == '$searchPath/init') {
      validToken = 'token-${++_tokenCounter}';
      return http.Response(jsonEncode({'token': validToken}), 200);
    }
    if (req.method == 'POST' && path == searchPath) {
      if (rateLimitSearches > 0) {
        rateLimitSearches--;
        return http.Response('{"message":"Too many requests"}', 429);
      }
      searchHeaders.add(req.headers);
      if (validToken == null || req.headers['x-auth-token'] != validToken) {
        return http.Response('{"message":"Forbidden"}', 403);
      }
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      searchBodies.add(body);
      final query = (body['searchTerms'] as List).join(' ');
      return http.Response(
        jsonEncode({'count': 0, 'data': searchResults[query] ?? []}),
        200,
      );
    }
    final page =
        RegExp(r'^/_next/data/([^/]+)/game/(\d+)\.json$').firstMatch(path);
    if (page != null) {
      if (rateLimitPages > 0) {
        rateLimitPages--;
        return http.Response('', 429);
      }
      final game = games[int.parse(page.group(2)!)];
      if (page.group(1) != buildId || game == null) {
        return http.Response('Not Found', 404);
      }
      return http.Response(
        jsonEncode({
          'pageProps': {
            'game': {
              'data': {
                'game': [game],
              },
            },
          },
        }),
        200,
      );
    }
    return http.Response('Not Found', 404);
  }
}
