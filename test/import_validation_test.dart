import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:backlogforge/services/export_import_service.dart';

String _file(Map<String, Object?> game) => jsonEncode({
      'version': 1,
      'games': [
        {
          'appId': 10,
          'name': 'Game',
          'addedAt': '2026-01-01T00:00:00.000',
          ...game,
        },
      ],
    });

void main() {
  group('rating', () {
    test('keeps values the UI can produce', () {
      for (final r in [1, 5, 10]) {
        final c =
            ExportImportService.parseImportJson(_file({'rating': r})).single;
        expect(c.rating.value, r);
      }
    });

    test('drops values outside 1 to 10', () {
      for (final r in [47, 11, 0, -3]) {
        final c =
            ExportImportService.parseImportJson(_file({'rating': r})).single;
        expect(c.rating.value, isNull, reason: 'rating $r');
      }
    });
  });

  group('playtime', () {
    test('negative play time becomes zero', () {
      final c = ExportImportService.parseImportJson(
          _file({'playtimeMinutes': -190})).single;
      expect(c.playtimeMinutes.value, 0);
    });

    test('absurdly large play time is capped', () {
      final c = ExportImportService.parseImportJson(
          _file({'playtimeMinutes': 999999999})).single;
      expect(c.playtimeMinutes.value, 6000000);
    });

    test('normal play time is kept', () {
      final c = ExportImportService.parseImportJson(
          _file({'playtimeMinutes': 1830})).single;
      expect(c.playtimeMinutes.value, 1830);
    });
  });

  group('time to beat hours', () {
    test('zero, negative and huge values are dropped', () {
      final c = ExportImportService.parseImportJson(_file({
        'essentialHours': -5,
        'extendedHours': 1e9,
        'completionistHours': 0,
      })).single;
      expect(c.essentialHours.value, isNull);
      expect(c.extendedHours.value, isNull);
      expect(c.completionistHours.value, isNull);
    });

    test('plausible values are kept', () {
      final c = ExportImportService.parseImportJson(_file({
        'essentialHours': 12.5,
        'extendedHours': 20,
        'completionistHours': 80.25,
      })).single;
      expect(c.essentialHours.value, 12.5);
      expect(c.extendedHours.value, 20.0);
      expect(c.completionistHours.value, 80.25);
    });
  });

  group('entries', () {
    test('an entry with a blank name is skipped, the rest still import', () {
      final text = jsonEncode({
        'version': 1,
        'games': [
          {'appId': 1, 'name': '   ', 'addedAt': '2026-01-01T00:00:00.000'},
          {'appId': 2, 'name': 'Kept', 'addedAt': '2026-01-01T00:00:00.000'},
        ],
      });
      final parsed = ExportImportService.parseImportJson(text);
      expect(parsed, hasLength(1));
      expect(parsed.single.name.value, 'Kept');
    });

    test('the name is trimmed', () {
      final c = ExportImportService.parseImportJson(
          _file({'name': '  Padded  '})).single;
      expect(c.name.value, 'Padded');
    });
  });
}
