import 'dart:math' as math;

/// Name helpers for matching Steam titles against HowLongToBeat entries.
abstract final class HltbNames {
  static final _symbols = RegExp(r'[™®©℠]');
  static final _asciiMarks = RegExp(r'\((?:r|tm)\)', caseSensitive: false);

  /// Purely cosmetic edition suffixes. Deliberately excludes "Remastered",
  /// "Director's Cut" etc., which HLTB usually lists as separate entries.
  static final _editionSuffix = RegExp(
    r"\s*[-–:]?\s*\(?(?:GOTY|Game of the Year|Definitive|Complete|Deluxe|"
    r"Digital Deluxe|Enhanced|Ultimate|Gold|Standard|Anniversary)"
    r"\s+Edition\)?\s*$",
    caseSensitive: false,
  );

  /// Normalises a game name for comparison and de-duplication: strips
  /// trademark symbols, replaces punctuation with spaces, collapses
  /// whitespace and lowercases.
  static String normalise(String name) {
    return name
        .replaceAll(_symbols, '')
        .replaceAll(_asciiMarks, '')
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim()
        .toLowerCase();
  }

  /// Cleans a Steam store name into an HLTB search query: removes trademark
  /// symbols and cosmetic edition suffixes but keeps case and punctuation,
  /// which HLTB's search handles fine.
  ///
  /// `Sekiro™: Shadows Die Twice - GOTY Edition` → `Sekiro: Shadows Die Twice`
  static String searchName(String name) {
    var cleaned = name.replaceAll(_symbols, '').replaceAll(_asciiMarks, '');
    // Strip repeatedly: "X - Definitive Edition (GOTY Edition)" is rare but real.
    while (true) {
      final stripped = cleaned.replaceFirst(_editionSuffix, '');
      if (stripped == cleaned || stripped.trim().isEmpty) break;
      cleaned = stripped;
    }
    return cleaned.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  }

  /// Similarity in [0, 1] between two names after [normalise]:
  /// 1 − (Levenshtein distance / longer length).
  static double similarity(String a, String b) {
    final x = normalise(a);
    final y = normalise(b);
    if (x == y) return 1.0;
    final longest = math.max(x.length, y.length);
    if (longest == 0) return 1.0;
    return 1.0 - _levenshtein(x, y) / longest;
  }

  static int _levenshtein(String a, String b) {
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    var curr = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      curr[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        curr[j] = math.min(
          math.min(curr[j - 1] + 1, prev[j] + 1),
          prev[j - 1] + cost,
        );
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[b.length];
  }
}
