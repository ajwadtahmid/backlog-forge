import 'dart:convert';
import 'hltb_models.dart';

/// Pure parsing helpers for HowLongToBeat responses. Kept free of I/O so they
/// can be tested against captured fixtures.
abstract final class HltbParsers {
  /// Extracts the Next.js build id from the homepage HTML
  /// (`/_next/static/{buildId}/_buildManifest.js`).
  static String? buildId(String html) {
    final m = RegExp(r'''/_next/static/([^/"']+)/_(?:build|ssg)Manifest\.js''')
        .firstMatch(html);
    return m?.group(1);
  }

  /// Same-origin Next.js chunk paths referenced by `<script src>` tags,
  /// in page order. Third-party scripts (ads, consent) are skipped.
  static List<String> chunkPaths(String html) {
    return RegExp(r'''<script\b[^>]*\bsrc=["'](/_next/static/chunks/[^"']+\.js)["']''')
        .allMatches(html)
        .map((m) => m.group(1)!)
        .toList();
  }

  /// Finds the search endpoint in a JS chunk: a `fetch("/api/…", {… method:"POST" …})`
  /// call. Prefers a path that also has a matching `…/init` call, as the live
  /// site does. Returns e.g. `/api/search/site`, or null.
  static String? searchPath(String js) {
    if (!js.contains('searchOptions')) return null;
    final pattern = RegExp(
      r'''fetch\s*\(\s*["'`]/api/([a-zA-Z0-9_/]+)[^"'`]*["'`]\s*,\s*\{[^}]*method\s*:\s*["'`]POST["'`]''',
    );
    String? fallback;
    for (final m in pattern.allMatches(js)) {
      final path = m
          .group(1)!
          .replaceAll(RegExp(r'/+$'), '')
          .replaceAll(RegExp(r'/init$'), '');
      if (path.isEmpty) continue;
      if (js.contains('/api/$path/init')) return '/api/$path';
      fallback ??= '/api/$path';
    }
    return fallback;
  }

  /// Parses the `/init` response into an auth record. Returns null when the
  /// response carries no token.
  static HltbAuth? auth(String body) {
    final decoded = _decodeMap(body);
    final token = decoded?['token'];
    if (token is! String || token.isEmpty) return null;
    String? key, val;
    for (final e in decoded!.entries) {
      if (e.value is! String || e.key == 'token') continue;
      final k = e.key.toLowerCase();
      if (key == null && k.contains('key')) {
        key = e.value as String;
      } else if (val == null && k.contains('val')) {
        val = e.value as String;
      }
    }
    return HltbAuth(token: token, hpKey: key, hpVal: val);
  }

  /// Parses a search response. Throws [FormatException] on unexpected shape.
  static List<HltbSearchHit> searchResults(String body) {
    final data = _decodeMap(body)?['data'];
    if (data is! List) throw const FormatException('search: missing data list');
    return [
      for (final item in data)
        if (item is Map<String, dynamic> &&
            item['game_id'] is int &&
            item['game_name'] is String)
          HltbSearchHit.fromJson(item),
    ];
  }

  /// Parses a `/_next/data/…/game/{id}.json` page. Throws [FormatException]
  /// on unexpected shape.
  static HltbGameData gamePage(String body) {
    final pageProps = _decodeMap(body)?['pageProps'];
    final game = pageProps is Map ? pageProps['game'] : null;
    final data = game is Map ? game['data'] : null;
    final list = data is Map ? data['game'] : null;
    if (list is! List || list.length != 1 || list.first is! Map<String, dynamic>) {
      throw const FormatException('game page: unexpected shape');
    }
    final g = list.first as Map<String, dynamic>;
    if (g['game_id'] is! int || g['game_name'] is! String) {
      throw const FormatException('game page: missing id/name');
    }
    return HltbGameData.fromJson(g);
  }

  /// Builds the search request body, mirroring the live site's payload.
  static String searchBody(String query, HltbAuth? auth) {
    final body = <String, Object?>{
      'searchType': 'games',
      'searchTerms': query.trim().split(RegExp(r'\s+')),
      'searchPage': 1,
      'size': 20,
      'searchOptions': {
        'games': {
          'userId': 0,
          'platform': '',
          'sortCategory': 'popular',
          'rangeCategory': 'main',
          'rangeTime': {'min': 0, 'max': 0},
          'gameplay': {'perspective': '', 'flow': '', 'genre': ''},
          'year': '',
          'modifier': 'hide_dlc',
        },
        'users': {'sortCategory': 'postcount'},
        'lists': {'sortCategory': 'follows'},
        'filter': '',
        'sort': 0,
        'randomizer': 0,
      },
      'useCache': true,
    };
    final key = auth?.hpKey;
    final val = auth?.hpVal;
    if (key != null && val != null) body[key] = val;
    return jsonEncode(body);
  }

  static Map<String, dynamic>? _decodeMap(String body) {
    try {
      final d = jsonDecode(body);
      return d is Map<String, dynamic> ? d : null;
    } on FormatException {
      return null;
    }
  }
}

/// Search auth from `/api/…/init`. `hpKey`/`hpVal` are optional extras HLTB
/// has used in the past; forwarded when present.
class HltbAuth {
  final String token;
  final String? hpKey;
  final String? hpVal;
  const HltbAuth({required this.token, this.hpKey, this.hpVal});

  Map<String, String> toJson() => {
        'token': token,
        'hpKey': ?hpKey,
        'hpVal': ?hpVal,
      };

  static HltbAuth? fromJson(Object? j) {
    if (j is! Map || j['token'] is! String) return null;
    return HltbAuth(
      token: j['token'] as String,
      hpKey: j['hpKey'] as String?,
      hpVal: j['hpVal'] as String?,
    );
  }
}
