/// A single result from the HowLongToBeat search endpoint.
class GameSearchResult {
  final String name;
  final String? artworkUrl;
  final double? essentialHours;
  final double? extendedHours;
  final double? completionistHours;

  /// HLTB game id, stored when the user picks this result.
  final int? hltbGameId;

  const GameSearchResult({
    required this.name,
    this.artworkUrl,
    this.essentialHours,
    this.extendedHours,
    this.completionistHours,
    this.hltbGameId,
  });
}
