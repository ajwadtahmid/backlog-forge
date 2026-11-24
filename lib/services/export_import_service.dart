import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import '../constants.dart';
import 'database/app_database.dart';
import '../models/game_status.dart';
import '../models/play_style.dart';
import 'app_logger.dart';

class ExportImportService {
  static String _dateStamp() {
    final now = DateTime.now();
    return '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
  }

  static String buildFilename() => 'backlogforge_export_${_dateStamp()}.json';

  /// Builds the export JSON string without touching the filesystem.
  static String buildExportJson(String steamId, List<Game> games) {
    final now = DateTime.now();
    final payload = {
      'version': 1,
      'exportedAt': now.toIso8601String(),
      'steamId': steamId,
      'games': games
          .map((g) => {
                'appId': g.appId,
                'name': g.name,
                'playtimeMinutes': g.playtimeMinutes,
                'status': g.status,
                'essentialHours': g.essentialHours,
                'extendedHours': g.extendedHours,
                'completionistHours': g.completionistHours,
                'hltbName': g.hltbName,
                'hltbImageUrl': g.hltbImageUrl,
                'hltbGameId': g.hltbGameId,
                'hltbVerified': g.hltbVerified,
                'playStyle': g.playStyle,
                'manualOverride': g.manualOverride,
                'addedAt': g.addedAt.toIso8601String(),
                'completedAt': g.completedAt?.toIso8601String(),
                'lastPlayedAt': g.lastPlayedAt?.toIso8601String(),
                'notes': g.notes,
                'rating': g.rating,
              })
          .toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// Writes [json] to [path]. Used on macOS/Windows/Linux after the
  /// save-dialog returns a path.
  static Future<void> writeToPath(String path, String json) =>
      File(path).writeAsString(json);

  static Future<List<GamesCompanion>> parseImportFile(String path) =>
      File(path).readAsString().then(parseImportJson);

  static List<GamesCompanion> parseImportBytes(Uint8List bytes) =>
      parseImportJson(utf8.decode(bytes));

  /// Returns the steamId stored in the export file, or null if absent/invalid.
  static String? readBackupSteamId(String content) {
    try {
      final data = jsonDecode(content) as Map<String, dynamic>;
      return data['steamId'] as String?;
    } catch (_) {
      return null;
    }
  }

  static String buildCsvFilename() => 'backlogforge_export_${_dateStamp()}.csv';

  /// Builds a CSV export string with one row per game.
  static String buildExportCsv(String steamId, List<Game> games) {
    final buffer = StringBuffer();
    buffer.writeln('Name,Status,Playtime (h),Rating,HLTB Name,Essential (h),Extended (h),Completionist (h),Completed At,Notes');
    for (final g in games) {
      buffer.writeln([
        _csvField(g.name),
        g.status,
        (g.playtimeMinutes / 60.0).toStringAsFixed(2),
        g.rating?.toString() ?? '',
        _csvField(g.hltbName ?? ''),
        g.essentialHours?.toStringAsFixed(1) ?? '',
        g.extendedHours?.toStringAsFixed(1) ?? '',
        g.completionistHours?.toStringAsFixed(1) ?? '',
        g.completedAt?.toIso8601String() ?? '',
        _csvField(g.notes ?? ''),
      ].join(','));
    }
    return buffer.toString();
  }

  static String _csvField(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  /// Time-to-beat hours from a file; null unless a plausible positive number.
  static double? _validHours(Object? raw) {
    final v = (raw as num?)?.toDouble();
    if (v == null || !v.isFinite || v <= 0 || v > AppConstants.kMaxHltbHours) {
      return null;
    }
    return v;
  }

  /// Rating from a file; null unless inside the 1–10 range the UI offers.
  static int? _validRating(Object? raw) {
    final v = (raw as num?)?.toInt();
    if (v == null || v < AppConstants.kMinRating || v > AppConstants.kMaxRating) {
      return null;
    }
    return v;
  }

  /// Parses a JSON export string produced by [buildExportJson].
  ///
  /// Values that cannot be right (a rating of 47, negative play time, zero or
  /// negative hours) are dropped or clamped here, the one place untrusted data
  /// enters the app. Entries that cannot be read at all are skipped.
  static List<GamesCompanion> parseImportJson(String content) {
    final data = jsonDecode(content) as Map<String, dynamic>;

    final version = data['version'] as int?;
    if (version != 1) throw const FormatException('Unsupported export version');

    final gamesJson = data['games'] as List<dynamic>;
    final validStatuses = GameStatus.values.asNameMap().keys.toSet();
    final validPlayStyles = PlayStyle.values.asNameMap().keys.toSet();

    return gamesJson.map<GamesCompanion?>((raw) {
      try {
        final g = raw as Map<String, dynamic>;

        final name = (g['name'] as String).trim();
        if (name.isEmpty) throw const FormatException('empty name');

        final rawStatus = g['status'] as String?;
        final status = rawStatus != null && validStatuses.contains(rawStatus)
            ? rawStatus
            : GameStatus.backlog.name;

        final rawPlayStyle = g['playStyle'] as String?;
        final playStyle =
            rawPlayStyle != null && validPlayStyles.contains(rawPlayStyle)
                ? rawPlayStyle
                : null;

        return GamesCompanion(
          appId: Value(g['appId'] as int),
          name: Value(name),
          playtimeMinutes: Value(
              ((g['playtimeMinutes'] as num?)?.toInt() ?? 0)
                  .clamp(0, AppConstants.kMaxPlaytimeMinutes)),
          status: Value(status),
          essentialHours: Value(_validHours(g['essentialHours'])),
          extendedHours: Value(_validHours(g['extendedHours'])),
          completionistHours: Value(_validHours(g['completionistHours'])),
          hltbName: Value(g['hltbName'] as String?),
          hltbImageUrl: Value(g['hltbImageUrl'] as String?),
          // Absent in exports made before schema 13 — defaults keep them valid.
          hltbGameId: Value((g['hltbGameId'] as num?)?.toInt()),
          hltbVerified: Value(g['hltbVerified'] as bool? ?? false),
          playStyle: Value(playStyle),
          manualOverride: Value(g['manualOverride'] as bool? ?? false),
          addedAt: Value(DateTime.parse(g['addedAt'] as String)),
          completedAt: Value(g['completedAt'] != null
              ? DateTime.parse(g['completedAt'] as String)
              : null),
          lastPlayedAt: Value(g['lastPlayedAt'] != null
              ? DateTime.parse(g['lastPlayedAt'] as String)
              : null),
          notes: Value(g['notes'] as String?),
          rating: Value(_validRating(g['rating'])),
        );
      } catch (e) {
        AppLogger.instance.warning('Skipped malformed game entry during import: $e');
        return null;
      }
    }).whereType<GamesCompanion>().toList();
  }
}
