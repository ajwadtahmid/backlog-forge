import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../../constants.dart';
import '../app_logger.dart';
import '../sync_exception.dart';
import 'hltb_models.dart';
import 'hltb_parsers.dart';

/// Values discovered from howlongtobeat.com and reused across requests and
/// app launches. Each is refreshed only when a request using it fails.
class HltbBootstrap {
  String? searchPath; // e.g. /api/search/site
  HltbAuth? auth;
  String? buildId; // Next.js build id for /_next/data routes

  HltbBootstrap({this.searchPath, this.auth, this.buildId});

  Map<String, Object?> toJson() => {
        'searchPath': searchPath,
        'auth': auth?.toJson(),
        'buildId': buildId,
      };

  factory HltbBootstrap.fromJson(Map<String, dynamic> j) => HltbBootstrap(
        searchPath: j['searchPath'] as String?,
        auth: HltbAuth.fromJson(j['auth']),
        buildId: j['buildId'] as String?,
      );
}

/// Persists [HltbBootstrap] between launches.
abstract interface class HltbBootstrapStore {
  Future<HltbBootstrap> load();
  Future<void> save(HltbBootstrap value);
}

class MemoryHltbBootstrapStore implements HltbBootstrapStore {
  HltbBootstrap _value;
  MemoryHltbBootstrapStore([HltbBootstrap? initial])
      : _value = initial ?? HltbBootstrap();
  int saves = 0;

  HltbBootstrap get current => _value;

  @override
  Future<HltbBootstrap> load() async => HltbBootstrap.fromJson(
        jsonDecode(jsonEncode(_value.toJson())) as Map<String, dynamic>,
      );

  @override
  Future<void> save(HltbBootstrap value) async {
    saves++;
    _value = HltbBootstrap.fromJson(
      jsonDecode(jsonEncode(value.toJson())) as Map<String, dynamic>,
    );
  }
}

class SharedPrefsHltbBootstrapStore implements HltbBootstrapStore {
  static const key = 'hltb.bootstrap.v1';
  final SharedPreferences _prefs;
  SharedPrefsHltbBootstrapStore(this._prefs);

  @override
  Future<HltbBootstrap> load() async {
    final raw = _prefs.getString(key);
    if (raw == null) return HltbBootstrap();
    try {
      return HltbBootstrap.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return HltbBootstrap();
    }
  }

  @override
  Future<void> save(HltbBootstrap value) =>
      _prefs.setString(key, jsonEncode(value.toJson()));
}

/// Talks to howlongtobeat.com directly from the device, using the same
/// requests the website makes. Port of the approach in
/// https://github.com/morwy/hltb-for-deck (`src/hooks/HltbApi.ts`).
///
/// * Search: `POST {searchPath}` with an `x-auth-token` from `{searchPath}/init`.
/// * Game data: `GET /_next/data/{buildId}/game/{id}.json` — CDN-cached and
///   includes `profile_steam`, which lets callers verify a match exactly.
///
/// Bootstrap values are discovered lazily and refreshed only on failure:
/// 403 → new token; still failing → re-discover the search path;
/// 404 on a game page → new build id. 429 is surfaced as
/// [HltbRateLimitedException] without retrying.
class HltbClient {
  static const baseUrl = 'https://howlongtobeat.com';
  static const defaultSearchPath = '/api/search/site';
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';
  static const _baseHeaders = {
    'User-Agent': _userAgent,
    'Origin': baseUrl,
    'Referer': '$baseUrl/',
  };

  final http.Client _http;
  final HltbBootstrapStore _store;
  final Duration _timeout;

  HltbBootstrap? _state;
  Future<HltbBootstrap>? _loading;
  Future<void>? _authRefresh;
  Future<void>? _siteRefresh;

  HltbClient({
    http.Client? httpClient,
    HltbBootstrapStore? store,
    this._timeout = AppConstants.kHltbTimeout,
  })  : _http = httpClient ?? http.Client(),
        _store = store ?? MemoryHltbBootstrapStore();

  // ── Public API ────────────────────────────────────────────────────────────

  /// Searches HLTB for [query] (DLC hidden). Returns up to 20 hits.
  Future<List<HltbSearchHit>> search(String query) async {
    final s = await _bootstrap();
    if (s.searchPath == null) await _refreshSite(s, needSearchPath: true);
    if (s.auth == null) await _refreshAuth(s, staleToken: null);

    // Attempt 1 → (403/other) fresh token → (still failing) re-discover path.
    for (var attempt = 0; attempt < 3; attempt++) {
      final used = s.auth;
      if (used != null) {
        final res = await _postSearch(s.searchPath!, used, query);
        if (res.statusCode == 200) {
          try {
            return HltbParsers.searchResults(res.body);
          } on FormatException catch (e) {
            throw HltbSearchException('bad search response: ${e.message}');
          }
        }
        if (res.statusCode == 429) throw const HltbRateLimitedException();
        AppLogger.instance.warning(
            'HLTB search returned ${res.statusCode} (attempt ${attempt + 1})');
      }
      if (attempt == 0) {
        await _refreshAuth(s, staleToken: used?.token);
      } else if (attempt == 1) {
        await _refreshSite(s, needSearchPath: true, force: true);
        await _refreshAuth(s, staleToken: s.auth?.token);
      }
    }
    throw const HltbSearchException(
        'search failed after refreshing auth and endpoint');
  }

  /// Fetches the full record for an HLTB game id (includes `profile_steam`).
  Future<HltbGameData> gamePage(int gameId) async {
    final s = await _bootstrap();
    if (s.buildId == null) await _refreshSite(s, needSearchPath: false);

    for (var attempt = 0; attempt < 2; attempt++) {
      final usedBuild = s.buildId;
      if (usedBuild != null) {
        final res =
            await _get('$baseUrl/_next/data/$usedBuild/game/$gameId.json');
        if (res.statusCode == 200) {
          try {
            return HltbParsers.gamePage(res.body);
          } on FormatException catch (e) {
            throw HltbLookupException('bad game page: ${e.message}');
          }
        }
        if (res.statusCode == 429) throw const HltbRateLimitedException();
        if (res.statusCode != 404) {
          throw HltbLookupException('game page status ${res.statusCode}');
        }
      }
      // 404 → the site was redeployed and the build id rotated.
      if (attempt == 0) {
        await _refreshSite(s,
            needSearchPath: false, force: true, staleBuildId: usedBuild);
      }
    }
    throw HltbLookupException('game $gameId not found');
  }

  void close() => _http.close();

  // ── Bootstrap management ──────────────────────────────────────────────────

  Future<HltbBootstrap> _bootstrap() async {
    final loaded = _state;
    if (loaded != null) return loaded;
    return _loading ??= _store.load().then((v) => _state = v);
  }

  /// Fetches a fresh token unless another request already replaced
  /// [staleToken] (avoids duplicate refreshes from concurrent lookups).
  Future<void> _refreshAuth(HltbBootstrap s, {required String? staleToken}) {
    final current = s.auth;
    if (current != null && current.token != staleToken) return Future.value();
    return _authRefresh ??= () async {
      try {
        s.searchPath ??= defaultSearchPath;
        final res = await _get(
          '$baseUrl${s.searchPath}/init?t=${DateTime.now().millisecondsSinceEpoch}',
        );
        if (res.statusCode == 429) throw const HltbRateLimitedException();
        s.auth = res.statusCode == 200 ? HltbParsers.auth(res.body) : null;
        if (s.auth == null) {
          AppLogger.instance
              .warning('HLTB init returned ${res.statusCode} without a token');
        }
        await _store.save(s);
      } finally {
        _authRefresh = null;
      }
    }();
  }

  /// Reads the homepage once to refresh the build id and, when
  /// [needSearchPath] is set, scans its JS chunks for the search endpoint.
  Future<void> _refreshSite(
    HltbBootstrap s, {
    required bool needSearchPath,
    bool force = false,
    String? staleBuildId,
  }) {
    final missing = needSearchPath ? s.searchPath == null : s.buildId == null;
    if (!force && !missing) return Future.value();
    if (staleBuildId != null && s.buildId != staleBuildId) {
      return Future.value(); // another request already refreshed it
    }
    return _siteRefresh ??= () async {
      try {
        final home = await _get('$baseUrl/');
        if (home.statusCode == 429) throw const HltbRateLimitedException();
        if (home.statusCode != 200) {
          throw HltbSearchException('homepage status ${home.statusCode}');
        }
        s.buildId = HltbParsers.buildId(home.body) ?? s.buildId;
        if (needSearchPath) {
          String? found;
          for (final path in HltbParsers.chunkPaths(home.body)) {
            final js = await _get('$baseUrl$path');
            if (js.statusCode != 200) continue;
            found = HltbParsers.searchPath(js.body);
            if (found != null) break;
          }
          if (found == null) {
            AppLogger.instance.warning(
                'HLTB search path not found; using $defaultSearchPath');
          }
          final newPath = found ?? defaultSearchPath;
          if (newPath != s.searchPath) s.auth = null; // token is per endpoint
          s.searchPath = newPath;
        }
        await _store.save(s);
      } finally {
        _siteRefresh = null;
      }
    }();
  }

  // ── HTTP ──────────────────────────────────────────────────────────────────

  Future<http.Response> _get(String url) =>
      _http.get(Uri.parse(url), headers: _baseHeaders).timeout(_timeout);

  Future<http.Response> _postSearch(
      String path, HltbAuth auth, String query) {
    final hpKey = auth.hpKey;
    final hpVal = auth.hpVal;
    final headers = {
      ..._baseHeaders,
      'Content-Type': 'application/json',
      'x-auth-token': auth.token,
      if (hpKey != null && hpVal != null) ...{
        'x-hp-key': hpKey,
        'x-hp-val': hpVal,
      },
    };
    return _http
        .post(Uri.parse('$baseUrl$path'),
            headers: headers, body: HltbParsers.searchBody(query, auth))
        .timeout(_timeout);
  }
}
