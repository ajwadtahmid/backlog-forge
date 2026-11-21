/// Time-to-beat estimates sourced from HowLongToBeat.
/// All fields are nullable because not every game has data for every category.
class TimeToBeat {
  final double? essentialHours;
  final double? extendedHours;
  final double? completionistHours;
  final String? hltbName;

  /// HLTB game id; lets later refreshes skip search entirely.
  final int? hltbGameId;

  /// True when HLTB's Steam link (`profile_steam`) matched the game's appId;
  /// false for name-similarity or user-picked matches.
  final bool hltbVerified;

  TimeToBeat({
    this.essentialHours,
    this.extendedHours,
    this.completionistHours,
    this.hltbName,
    this.hltbGameId,
    this.hltbVerified = false,
  });
}
