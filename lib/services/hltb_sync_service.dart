import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../constants.dart';
import '../models/time_to_beat.dart';
import 'app_logger.dart';
import 'database/app_database.dart';
import 'database/games_dao.dart';
import 'sync_exception.dart';

/// Resolves one game to HLTB data; null = genuinely not on HLTB.
/// Matches [HltbResolver.resolve]; a typedef keeps this service testable.
typedef HltbResolveFn = Future<TimeToBeat?> Function({
  required String name,
  int? steamAppId,
  int? hltbGameId,
});

/// Outcome counts for one sync pass.
typedef HltbSyncResult = ({
  int fetched, // matched and saved
  int noMatch, // definitively not on HLTB (retry window applies)
  int failed, // errors; NOT stamped, retried next sync
  int networkFailed, // the part of [failed] caused by no/lost connectivity
  int deferred, // not attempted because the pass stopped early
});

/// Orchestrates HLTB lookups during a sync: picks games that need data, runs
/// a small worker pool against the on-device resolver, and writes results.
///
/// * Only definitive answers stamp `hltbAttemptedAt`. Errors leave the game
///   untouched so the next sync retries it (previously a 429 blanked a game
///   for the whole retry window).
/// * On 429 every worker pauses for a shared backoff. The backoff budget is
///   spent once per pause, not once per worker that hit the limit, and a
///   successful lookup refills it. When it runs out the pass stops and the
///   remaining games are deferred.
/// * Results are written in batches of [batchSize] so list streams re-query
///   once per batch instead of once per game.
/// * After [maxConsecutiveFailures] errors in a row the pass stops too
///   (HLTB down or changed), rather than burning through the whole library.
class HltbSyncService {
  HltbSyncService({
    required this._resolve,
    this.concurrency = 2,
    this.rateLimitBackoff = const [
      Duration(seconds: 10),
      Duration(seconds: 30),
      Duration(seconds: 60),
    ],
    this.maxConsecutiveFailures = 5,
    this.batchSize = 25,
    Future<void> Function(Duration)? sleep,
  })  : _sleep = sleep ?? Future.delayed;

  final HltbResolveFn _resolve;
  final int concurrency;
  final List<Duration> rateLimitBackoff;
  final int maxConsecutiveFailures;
  final int batchSize;
  final Future<void> Function(Duration) _sleep;

  /// True for errors that mean "no usable connection" rather than "HLTB said
  /// no": socket failures, dropped requests and timeouts.
  static bool isNetworkFailure(Object e) =>
      e is SocketException ||
      e is http.ClientException ||
      e is TimeoutException ||
      e is NetworkException;

  /// Games without HLTB data whose last definitive lookup is outside the
  /// retry window. Manually overridden games are never touched.
  static List<Game> gamesNeedingLookup(List<Game> games, {DateTime? now}) {
    final cutoff =
        (now ?? DateTime.now()).subtract(AppConstants.kHltbRetryWindow);
    return games
        .where((g) =>
            !g.manualOverride &&
            g.essentialHours == null &&
            g.extendedHours == null &&
            g.completionistHours == null &&
            (g.hltbAttemptedAt == null || g.hltbAttemptedAt!.isBefore(cutoff)))
        .toList();
  }

  /// [onProgress] is called after each game is processed with (done, total).
  Future<HltbSyncResult> fetchAllTimeToBeat(
    GamesDao dao,
    List<Game> allGames, {
    void Function(int current, int total)? onProgress,
  }) async {
    final queue = gamesNeedingLookup(allGames);
    final total = queue.length;
    var next = 0, fetched = 0, noMatch = 0, failed = 0, processed = 0;
    var networkFailed = 0;
    var consecutiveFailures = 0;
    var stopped = false;
    Future<void>? cooldown; // shared pause after a 429
    var backoffStep = 0; // how many pauses in a row, reset by any success
    var pauses = 0; // pauses started so far, to spot a 429 from before one
    final pending = <({int id, TimeToBeat? data})>[];

    Future<void> flush() async {
      if (pending.isEmpty) return;
      final batch = List.of(pending);
      pending.clear(); // before the await so other workers don't re-send it
      await dao.saveHltbResults(batch);
    }

    Future<void> worker() async {
      while (!stopped && next < queue.length) {
        final game = queue[next++];
        while (true) {
          final pause = cooldown;
          if (pause != null) await pause;
          if (stopped) return; // this game counts as deferred
          final pausesAtStart = pauses;
          try {
            final data = await _resolve(
              name: game.name,
              steamAppId: game.appId > 0 ? game.appId : null,
              hltbGameId: game.hltbGameId,
            );
            pending.add((id: game.id, data: data));
            if (data != null) {
              fetched++;
            } else {
              noMatch++;
            }
            if (pending.length >= batchSize) await flush();
            consecutiveFailures = 0;
            backoffStep = 0;
            break;
          } on HltbRateLimitedException {
            // A pause that started while this request was in flight (or is
            // still running) already covers this 429; just retry after it.
            if (pauses == pausesAtStart && cooldown == null) {
              if (backoffStep >= rateLimitBackoff.length) {
                AppLogger.instance
                    .warning('HLTB rate limit persisted; deferring the rest');
                stopped = true;
                return;
              }
              final delay = rateLimitBackoff[backoffStep++];
              AppLogger.instance
                  .warning('HLTB rate limited; pausing ${delay.inSeconds}s');
              pauses++;
              cooldown = _sleep(delay).whenComplete(() => cooldown = null);
            }
          } catch (e) {
            failed++;
            if (isNetworkFailure(e)) networkFailed++;
            consecutiveFailures++;
            AppLogger.instance
                .warning('HLTB lookup failed for "${game.name}"', e);
            if (consecutiveFailures >= maxConsecutiveFailures) {
              AppLogger.instance.warning(
                  'HLTB: $consecutiveFailures failures in a row; stopping');
              stopped = true;
            }
            break;
          }
        }
        onProgress?.call(++processed, total);
      }
    }

    try {
      await Future.wait(List.generate(concurrency, (_) => worker()));
    } finally {
      await flush(); // also on an unexpected error, so finished work is kept
    }
    return (
      fetched: fetched,
      noMatch: noMatch,
      failed: failed,
      networkFailed: networkFailed,
      deferred: total - fetched - noMatch - failed,
    );
  }
}
