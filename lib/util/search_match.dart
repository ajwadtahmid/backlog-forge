/// Returns true if [name] matches [query] using a two-pass strategy:
///   1. Direct substring match (case-insensitive).
///   2. Match with punctuation and spaces removed from both sides — handles
///      "Witcher3" → "The Witcher 3" and "garrys" → "Garry's Mod".
///
/// [query] must already be lower case. For filtering a whole list, build one
/// [GameNameMatcher] and reuse it so the query is prepared once, not per game.
bool matchesGameName(String name, String query) =>
    GameNameMatcher(query).matches(name);

/// A search query prepared once and tested against many game names.
///
/// Each name's lower-case and punctuation-free forms are computed once and
/// remembered, because the list is re-filtered after every pause in typing and
/// the names do not change between keystrokes.
class GameNameMatcher {
  GameNameMatcher(this.query) : _stripped = _strip(query);

  /// Lower-case search text.
  final String query;
  final String _stripped;

  static const _maxCachedNames = 20000;
  static final _forms = <String, ({String lower, String stripped})>{};

  /// Keeps only a-z and 0-9 of an already lower-case string. A plain loop:
  /// a regex replace over thousands of names per keystroke was the slow part.
  static String _strip(String lower) {
    final out = StringBuffer();
    for (final c in lower.codeUnits) {
      if ((c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39)) {
        out.writeCharCode(c);
      }
    }
    return out.toString();
  }

  bool matches(String name) {
    var forms = _forms[name];
    if (forms == null) {
      // A library that outgrows the cap just starts over; it refills in one
      // keystroke's worth of work.
      if (_forms.length >= _maxCachedNames) _forms.clear();
      final lower = name.toLowerCase();
      forms = (lower: lower, stripped: _strip(lower));
      _forms[name] = forms;
    }
    if (forms.lower.contains(query)) return true;
    return _stripped.isNotEmpty && forms.stripped.contains(_stripped);
  }
}
