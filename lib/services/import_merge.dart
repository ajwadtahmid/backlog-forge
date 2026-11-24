import 'dart:math' as math;
import 'package:drift/drift.dart';
import 'database/app_database.dart';

/// Builds the update that merges one imported game into the copy already in
/// the library, so an import never throws away what the user has added since.
///
/// Rules, per field:
/// * Notes, rating, play style, completion date and the time-to-beat data:
///   the file wins only when it actually has a value; otherwise the local value
///   stays.
/// * Play time and last-played date keep the larger / later of the two, since
///   the library may have synced more recently than the backup.
/// * Added date keeps the earlier of the two.
/// * Status and the manual-override flag change only when the file marks the
///   game as manually overridden; otherwise statuses are recalculated after the
///   import as usual.
/// * Name, app id and owner are never touched.
GamesCompanion mergeImportedGame(Game local, GamesCompanion file) {
  T? pick<T>(Value<T?> fromFile, T? fromLocal) =>
      fromFile.present && fromFile.value != null ? fromFile.value : fromLocal;

  String? pickText(Value<String?> fromFile, String? fromLocal) {
    final v = fromFile.present ? fromFile.value : null;
    return v != null && v.trim().isNotEmpty ? v : fromLocal;
  }

  DateTime? later(DateTime? a, DateTime? b) =>
      a == null ? b : (b == null ? a : (b.isAfter(a) ? b : a));
  DateTime? earlier(DateTime? a, DateTime? b) =>
      a == null ? b : (b == null ? a : (b.isBefore(a) ? b : a));

  final fileOverrides =
      file.manualOverride.present && file.manualOverride.value;

  return GamesCompanion(
    playtimeMinutes: Value(math.max(
      local.playtimeMinutes,
      file.playtimeMinutes.present ? file.playtimeMinutes.value : 0,
    )),
    lastPlayedAt: Value(later(
      local.lastPlayedAt,
      file.lastPlayedAt.present ? file.lastPlayedAt.value : null,
    )),
    addedAt: Value(earlier(
      local.addedAt,
      file.addedAt.present ? file.addedAt.value : null,
    )!),
    completedAt: Value(pick(file.completedAt, local.completedAt)),
    essentialHours: Value(pick(file.essentialHours, local.essentialHours)),
    extendedHours: Value(pick(file.extendedHours, local.extendedHours)),
    completionistHours:
        Value(pick(file.completionistHours, local.completionistHours)),
    hltbName: Value(pick(file.hltbName, local.hltbName)),
    hltbImageUrl: Value(pick(file.hltbImageUrl, local.hltbImageUrl)),
    hltbGameId: Value(pick(file.hltbGameId, local.hltbGameId)),
    hltbVerified: Value(local.hltbVerified ||
        (file.hltbVerified.present && file.hltbVerified.value)),
    playStyle: Value(pick(file.playStyle, local.playStyle)),
    notes: Value(pickText(file.notes, local.notes)),
    rating: Value(pick(file.rating, local.rating)),
    status: fileOverrides ? file.status : const Value.absent(),
    manualOverride: fileOverrides ? const Value(true) : const Value.absent(),
  );
}
