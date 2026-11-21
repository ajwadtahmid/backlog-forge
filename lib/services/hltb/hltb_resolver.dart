import '../../models/time_to_beat.dart';
import 'hltb_client.dart';
import 'hltb_models.dart';
import 'hltb_names.dart';

/// Finds the HLTB entry for a library game.
///
/// 1. Known [hltbGameId] → one CDN-cached game-page fetch, no search.
/// 2. Otherwise search with a cleaned name, rank hits by similarity, then
///    open up to [maxVerifyCandidates] game pages looking for
///    `profile_steam == steamAppId` → verified match.
/// 3. No verified match → best name match if similar enough → unverified.
///
/// Returns null for a genuine "not on HLTB". Network/HTTP problems throw
/// (including [HltbRateLimitedException]) so callers can retry later.
class HltbResolver {
  HltbResolver(
    this._client, {
    this.maxVerifyCandidates = 5,
    this.minNameSimilarity = 0.6,
  });

  final HltbClient _client;
  final int maxVerifyCandidates;
  final double minNameSimilarity;

  Future<TimeToBeat?> resolve({
    required String name,
    int? steamAppId,
    int? hltbGameId,
  }) async {
    final appId = (steamAppId != null && steamAppId > 0) ? steamAppId : null;

    if (hltbGameId != null) {
      final page = await _client.gamePage(hltbGameId);
      return _fromPage(page,
          verified: appId != null && page.steamAppId == appId);
    }

    final query = HltbNames.searchName(name);
    if (query.isEmpty) return null;
    var hits = await _client.search(query);
    if (hits.isEmpty) {
      // Punctuation occasionally trips HLTB's search; retry once without it.
      final plain = HltbNames.normalise(query);
      if (plain.isNotEmpty && plain != query.toLowerCase()) {
        hits = await _client.search(plain);
      }
    }
    if (hits.isEmpty) return null;

    final ranked = _rank(query, hits);

    if (appId != null) {
      for (final hit in ranked.take(maxVerifyCandidates)) {
        final page = await _client.gamePage(hit.gameId);
        if (page.steamAppId == appId) return _fromPage(page, verified: true);
      }
    }

    final best = ranked.first;
    if (_score(query, best) < minNameSimilarity) return null;
    return TimeToBeat(
      essentialHours: best.mainHours,
      extendedHours: best.extraHours,
      completionistHours: best.completionistHours,
      hltbName: best.name,
      hltbGameId: best.gameId,
      hltbVerified: false,
    );
  }

  static double _score(String query, HltbSearchHit hit) {
    final byName = HltbNames.similarity(query, hit.name);
    if (hit.alias.isEmpty) return byName;
    final byAlias = HltbNames.similarity(query, hit.alias);
    return byAlias > byName ? byAlias : byName;
  }

  /// Most similar first; ties broken by HLTB popularity.
  static List<HltbSearchHit> _rank(String query, List<HltbSearchHit> hits) {
    final scored = [for (final h in hits) (hit: h, score: _score(query, h))];
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0
          ? byScore
          : b.hit.popularity.compareTo(a.hit.popularity);
    });
    return [for (final s in scored) s.hit];
  }

  static TimeToBeat _fromPage(HltbGameData page, {required bool verified}) =>
      TimeToBeat(
        essentialHours: page.mainHours,
        extendedHours: page.extraHours,
        completionistHours: page.completionistHours,
        hltbName: page.name,
        hltbGameId: page.gameId,
        hltbVerified: verified,
      );
}
