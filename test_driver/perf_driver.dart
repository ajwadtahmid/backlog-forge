import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
      responseDataCallback: (data) async {
        if (data == null) return;
        final out = Platform.environment['PERF_OUT'] ?? 'extra/audit/2026-11-23/data/scroll_frames.json';
        await File(out).writeAsString(jsonEncode(data));
      },
    );
