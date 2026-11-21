/// Plain data types returned by the on-device HowLongToBeat client.
library;

const _kImageBase = 'https://howlongtobeat.com/games/';

/// Converts an HLTB duration in seconds to hours (2 dp); 0/absent → null.
double? _hours(Object? seconds) {
  if (seconds is! num || seconds <= 0) return null;
  return (seconds / 3600 * 100).round() / 100;
}

/// One entry from the search endpoint. Search results do NOT include the
/// Steam app id — use the game page for that.
class HltbSearchHit {
  final int gameId;
  final String name;
  final String alias;
  final String? imageUrl;
  final double? mainHours;
  final double? extraHours;
  final double? completionistHours;
  final int popularity; // comp_all_count — used as a tie-breaker

  const HltbSearchHit({
    required this.gameId,
    required this.name,
    this.alias = '',
    this.imageUrl,
    this.mainHours,
    this.extraHours,
    this.completionistHours,
    this.popularity = 0,
  });

  factory HltbSearchHit.fromJson(Map<String, dynamic> j) => HltbSearchHit(
        gameId: j['game_id'] as int,
        name: j['game_name'] as String,
        alias: (j['game_alias'] as String?) ?? '',
        imageUrl: _image(j['game_image']),
        mainHours: _hours(j['comp_main']),
        extraHours: _hours(j['comp_plus']),
        completionistHours: _hours(j['comp_100']),
        popularity: (j['comp_all_count'] as num?)?.toInt() ?? 0,
      );
}

/// Full record from `/_next/data/{buildId}/game/{id}.json`.
class HltbGameData {
  final int gameId;
  final String name;
  final String? imageUrl;
  final double? mainHours;
  final double? extraHours;
  final double? completionistHours;

  /// Steam app id linked on HLTB; 0 when the entry has no Steam link.
  final int steamAppId;

  const HltbGameData({
    required this.gameId,
    required this.name,
    this.imageUrl,
    this.mainHours,
    this.extraHours,
    this.completionistHours,
    this.steamAppId = 0,
  });

  factory HltbGameData.fromJson(Map<String, dynamic> j) => HltbGameData(
        gameId: j['game_id'] as int,
        name: j['game_name'] as String,
        imageUrl: _image(j['game_image']),
        mainHours: _hours(j['comp_main']),
        extraHours: _hours(j['comp_plus']),
        completionistHours: _hours(j['comp_100']),
        steamAppId: (j['profile_steam'] as num?)?.toInt() ?? 0,
      );
}

String? _image(Object? file) =>
    file is String && file.isNotEmpty ? '$_kImageBase$file' : null;
