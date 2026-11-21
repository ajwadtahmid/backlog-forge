import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../constants.dart';
import '../models/game_search_result.dart';
import '../services/hltb/hltb_names.dart';
import '../services/sync_exception.dart';
import 'hltb_provider.dart';

class SearchState {
  final List<GameSearchResult> results;
  final bool isLoading;
  final String? errorMessage;

  SearchState({
    this.results = const [],
    this.isLoading = false,
    this.errorMessage,
  });

  SearchState copyWith({
    List<GameSearchResult>? results,
    bool? isLoading,
    String? errorMessage,
  }) {
    return SearchState(
      results: results ?? this.results,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

/// Manages game search against HowLongToBeat (directly from the device).
class SearchNotifier extends Notifier<SearchState> {
  static const _kMaxResults = 10;

  /// Incremented per search so a slow, stale response can't overwrite a
  /// newer one while the user is typing.
  int _generation = 0;

  @override
  SearchState build() => SearchState();

  Future<void> search(String query) async {
    final trimmed = query.trim();
    final generation = ++_generation;
    if (trimmed.isEmpty) {
      state = SearchState();
      return;
    }
    if (trimmed.length > AppConstants.kMaxQueryLength) return;

    // Fresh state (not copyWith) so a previous error message is cleared.
    state = SearchState(results: state.results, isLoading: true);
    try {
      final hits = await ref.read(hltbClientProvider).search(trimmed);
      if (generation != _generation) return;
      final results = [
        for (final h in hits)
          GameSearchResult(
            name: h.name,
            artworkUrl: h.imageUrl,
            essentialHours: h.mainHours,
            extendedHours: h.extraHours,
            completionistHours: h.completionistHours,
            hltbGameId: h.gameId,
          ),
      ];
      // Re-rank by client-side normalised similarity so the best match floats up.
      results.sort((a, b) =>
          _similarity(trimmed, b.name).compareTo(_similarity(trimmed, a.name)));
      state = SearchState(results: results.take(_kMaxResults).toList());
    } catch (e) {
      if (generation != _generation) return;
      state = SearchState(
        errorMessage: e is HltbRateLimitedException
            ? 'HowLongToBeat is busy. Please wait a minute and try again.'
            : 'Search failed. Check your connection and try again.',
      );
    }
  }

  static double _similarity(String query, String candidate) {
    final q = HltbNames.normalise(query);
    final c = HltbNames.normalise(candidate);
    if (q == c) return 1.0;
    if (c.startsWith(q)) return 0.9;
    if (c.contains(q)) return 0.75;
    final qWords = q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toSet();
    final cWords = c.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toSet();
    if (qWords.isEmpty || cWords.isEmpty) return 0.0;
    final intersection = qWords.intersection(cWords).length;
    final union = qWords.union(cWords).length;
    return intersection / union;
  }

  /// Resets search results and any error state.
  void clear() {
    _generation++;
    state = SearchState();
  }
}

final searchProvider =
    NotifierProvider<SearchNotifier, SearchState>(SearchNotifier.new);
