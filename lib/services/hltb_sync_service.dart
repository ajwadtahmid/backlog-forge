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
  int deferred, // not attempted because the pass stopped early
});

/// Orchestrates HLTB lookups during a sync: picks games that need data, runs
/// a small worker pool against the on-device resolver, and writes results.
///
/// * Only definitive answers stamp `hltbAttemptedAt`. Errors leave the game
///   untouched so the next sync retries it (previously a 429 blanked a game
///   for the whole retry window).
/// * On 429 every worker pauses for a shared backoff; when backoff is
///   exhausted the pass stops and the remaining games are deferred.
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
    Future<void> Function(Duration)? sleep,
  })  : _sleep = sleep ?? Future.delayed;

  final HltbResolveFn _resolve;
  final int concurrency;
  final List<Duration> rateLimitBackoff;
  final int maxConsecutiveFailures;
  final Future<void> Function(Duration) _sleep;

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
    var consecutiveFailures = 0;
    var stopped = false;
    Future<void>? cooldown; // shared pause after a 429

    Future<void> worker() async {
      while (!stopped && next < queue.length) {
        final game = queue[next++];
        var backoffStep = 0;
        while (true) {
          final pause = cooldown;
          if (pause != null) await pause;
          if (stopped) return; // this game counts as deferred
          try {
            final data = await _resolve(
              name: game.name,
              steamAppId: game.appId > 0 ? game.appId : null,
              hltbGameId: game.hltbGameId,
            );
            if (data != null) {
              await dao.updateHltbData(game.id, data);
              fetched++;
            } else {
              await dao.markHltbNoMatch(game.id);
              noMatch++;
            }
            consecutiveFailures = 0;
            break;
          } on HltbRateLimitedException {
            if (backoffStep >= rateLimitBackoff.length) {
              AppLogger.instance
                  .warning('HLTB rate limit persisted; deferring the rest');
              stopped = true;
              return;
            }
            final delay = rateLimitBackoff[backoffStep++];
            AppLogger.instance
                .warning('HLTB rate limited; pausing ${delay.inSeconds}s');
            cooldown ??= _sleep(delay).whenComplete(() => cooldown = null);
          } catch (e) {
            failed++;
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

    await Future.wait(List.generate(concurrency, (_) => worker()));
    return (
      fetched: fetched,
      noMatch: noMatch,
      failed: failed,
      deferred: total - fetched - noMatch - failed,
    );
  }
}
