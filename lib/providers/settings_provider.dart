import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/database/app_database.dart';
import 'auth_provider.dart';
import 'database_provider.dart';
import 'goals_provider.dart';
import 'sort_provider.dart';
import 'theme_provider.dart';

/// Reactively emits the current user's settings row whenever it changes.
/// Emits null when no user is signed in.
final settingsStreamProvider = StreamProvider<AppSetting?>((ref) {
  final auth = ref.watch(authProvider).asData?.value;
  final steamId = auth?.steamId;
  if (steamId == null) return Stream.value(null);
  final db = ref.watch(databaseProvider);
  return db.settingsDao.watch(steamId);
});

/// "Clear All Data": deletes the user's games, puts their settings row back to
/// the defaults, and removes every saved preference (theme, sort order,
/// filters, quarter goal, navigation position) so the app looks like a fresh
/// install. Technical caches under `hltb.` are kept; they hold no user choices.
final clearAllDataProvider =
    Provider<Future<void> Function(String steamId)>((ref) {
  return (String steamId) async {
    await ref.read(databaseProvider).clearAllUserData(steamId);

    final prefs = ref.read(sharedPrefsProvider);
    for (final key in prefs.getKeys().toList()) {
      if (!key.startsWith('hltb.')) await prefs.remove(key);
    }
    ref
      ..invalidate(themeProvider)
      ..invalidate(appFontProvider)
      ..invalidate(navigationPositionProvider)
      ..invalidate(quarterGoalProvider)
      ..invalidate(backlogSortModeProvider)
      ..invalidate(completedSortModeProvider)
      ..invalidate(backlogFilterProvider)
      ..invalidate(backlogExtraFilterProvider)
      ..invalidate(completedExtraFilterProvider);
  };
});

/// Updates the completion threshold and immediately recalculates all statuses.
final setCompletionThresholdProvider =
    Provider<Future<void> Function(String threshold)>((ref) {
  return (String threshold) async {
    final steamId =
        ref.read(authProvider).asData?.value.steamId;
    if (steamId == null) return;
    final db = ref.read(databaseProvider);
    await db.settingsDao.write(
      AppSettingsCompanion(completionThreshold: Value(threshold)),
      steamId,
    );
    await db.gamesDao.recalculateAllStatuses(steamId);
  };
});

