import 'dart:async';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart';
import '../services/database/app_database.dart';
import '../services/hltb_sync_service.dart';
import '../services/steam_service.dart';
import '../services/sync_exception.dart';
import '../services/app_logger.dart';
import '../models/steam_game.dart';
import 'database_provider.dart';
import 'auth_provider.dart';
import 'hltb_provider.dart';

enum SyncStatus { idle, syncing, error }

class SyncState {
  final SyncStatus status;
  final String? errorMessage;
  final int? hltbCurrent;
  final int? hltbTotal;
  /// Human-readable post-sync notification (auto-completions, HLTB failures).
  final String? notification;
  const SyncState({
    this.status = SyncStatus.idle,
    this.errorMessage,
    this.hltbCurrent,
    this.hltbTotal,
    this.notification,
  });
}

/// Maps typed [SyncException]s (and unknown errors) to user-friendly messages.
String _friendlySyncError(Object e) {
  if (e is ProfilePrivateException) {
    return 'Steam profile is private — make it public to sync.';
  }
  if (e is SteamApiException) {
    return 'Could not reach Steam. Please try again later.';
  }
  if (e is NotSignedInException) return 'You are not signed in.';
  if (e is ServerTimeoutException) {
    return 'The server took too long to respond. Please try again in a moment.';
  }
  if (e is NetworkException) {
    return 'No internet connection. Please check your network.';
  }
  if (e is HltbRateLimitedException) {
    return 'HowLongToBeat is busy. Please wait a minute and try again.';
  }
  if (e is HltbSearchException || e is HltbLookupException) {
    return 'Could not reach HowLongToBeat. Please try again later.';
  }
  return 'Sync failed. Please try again.';
}

final syncStateProvider =
    NotifierProvider<SyncNotifier, SyncState>(SyncNotifier.new);

/// Orchestrates a full sync: fetches Steam library, upserts games, pulls
/// missing HLTB data, then recalculates completion statuses.
class SyncNotifier extends Notifier<SyncState> {
  final _steamService = SteamService();
  Timer? _errorClearTimer;

  @override
  SyncState build() => const SyncState();

  Future<void> sync() async {
    if (state.status == SyncStatus.syncing) return;
    state = const SyncState(status: SyncStatus.syncing);

    try {
      final auth = await ref.read(authProvider.future);
      final steamId = auth.steamId;
      if (steamId == null) throw const NotSignedInException();

      final db = ref.read(databaseProvider);
      final steamGames = await _steamService.getOwnedGames(steamId);

      await upsertSteamGames(db, steamGames, steamId);

      final allGames = await db.gamesDao.getAllGames(steamId);
      final hltbSync = HltbSyncService(
        resolve: ref.read(hltbResolverProvider).resolve,
      );
      final hltbResult = await hltbSync.fetchAllTimeToBeat(
        db.gamesDao,
        allGames,
        onProgress: (current, total) {
          state = SyncState(
            status: SyncStatus.syncing,
            hltbCurrent: current,
            hltbTotal: total,
          );
        },
      );

      // Always recalculate — status correctness matters more than skipping a
      // cheap pass. The recalculator already diffs and skips unchanged rows.
      final autoCompleted = await db.gamesDao.recalculateAllStatuses(steamId);
      state = SyncState(notification: buildSyncNotification(autoCompleted, hltbResult));
    } catch (e, st) {
      AppLogger.instance.error('Sync failed', e, st);
      state = SyncState(
        status: SyncStatus.error,
        errorMessage: _friendlySyncError(e),
      );
      // Auto-clear after 10 s so the error doesn't persist indefinitely in Settings.
      // Cancel any previous timer so rapid re-sync failures don't clear prematurely.
      _errorClearTimer?.cancel();
      _errorClearTimer = Timer(const Duration(seconds: 10), () {
        if (state.status == SyncStatus.error) state = const SyncState();
      });
    }
  }

  @visibleForTesting
  static Future<void> upsertSteamGames(
    AppDatabase db,
    List<SteamGame> steamGames,
    String steamId,
  ) async {
    final now = DateTime.now();
    await db.transaction(() async {
      for (final game in steamGames) {
        await db.into(db.games).insert(
          GamesCompanion.insert(
            steamId: steamId,
            appId: game.appId,
            name: game.name,
            playtimeMinutes: Value(game.playtimeMinutes),
            lastPlayedAt: Value(game.lastPlayedAt),
            addedAt: now,
          ),
          onConflict: DoUpdate(
            (old) => GamesCompanion(
              name: Value(game.name),
              playtimeMinutes: Value(game.playtimeMinutes),
              lastPlayedAt: Value(game.lastPlayedAt),
            ),
            target: [db.games.appId, db.games.steamId],
          ),
        );
      }
    });
  }

  @visibleForTesting
  static String? buildSyncNotification(
    int autoCompleted,
    HltbSyncResult hltbResult,
  ) {
    final parts = <String>[];
    if (autoCompleted > 0) {
      final s = autoCompleted == 1 ? 'game' : 'games';
      parts.add('$autoCompleted $s automatically marked completed based on playtime.');
    }
    // Failed and deferred games were not stamped, so the next sync retries them.
    final pending = hltbResult.failed + hltbResult.deferred;
    if (pending > 0) {
      final s = pending == 1 ? 'game' : 'games';
      final offline = hltbResult.networkFailed > 0 &&
          hltbResult.networkFailed == hltbResult.failed;
      parts.add(offline
          ? 'No internet connection — HLTB data for $pending $s is missing. '
              'They will be retried on the next sync.'
          : 'Couldn\'t get HLTB data for $pending $s right now — '
              'they will be retried on the next sync.');
    }
    return parts.isEmpty ? null : parts.join('\n');
  }
}

/// Fires a background sync every 2 hours while the app is running and the user
/// is signed in. Watch this provider in the root widget so the timer lives for
/// the full app lifetime. The SyncNotifier already guards against concurrent syncs.
final backgroundSyncProvider = Provider<void>((ref) {
  final timer = Timer.periodic(const Duration(hours: 2), (_) {
    final auth = ref.read(authProvider).asData?.value;
    if (auth == null || auth.steamId == AuthNotifier.guestSteamId) return;
    if (ref.read(syncStateProvider).status == SyncStatus.syncing) return;
    ref.read(syncStateProvider.notifier).sync();
  });
  ref.onDispose(timer.cancel);
});

/// Triggers an automatic sync on first launch if the local DB is empty for this user.
final initialSyncProvider = FutureProvider<void>((ref) async {
  final auth = await ref.watch(authProvider.future);
  final steamId = auth.steamId;
  if (steamId == null || steamId == AuthNotifier.guestSteamId) return;
  final db = ref.watch(databaseProvider);
  final games = await db.gamesDao.getAllGames(steamId);
  if (games.isEmpty) {
    await ref.read(syncStateProvider.notifier).sync();
  }
});
