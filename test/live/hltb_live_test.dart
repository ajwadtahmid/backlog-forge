// Opt-in check against the real howlongtobeat.com. Skipped by default so
// normal test runs never touch the network. Run with:
//
//   HLTB_LIVE=1 flutter test test/live/hltb_live_test.dart
//
// If this fails while the unit tests pass, HLTB has changed its site.
@Tags(['live'])
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:backlogforge/services/hltb/hltb_client.dart';
import 'package:backlogforge/services/hltb/hltb_resolver.dart';

final _enabled = Platform.environment['HLTB_LIVE'] == '1';

void main() {
  // Steam appId, Steam store name, expected HLTB id (all must be verified).
  const games = [
    (620, 'Portal 2', 7231),
    (312520, 'Rain World', 32976),
    (844590, 'Hypnospace Outlaw', 65593),
    (1262350, 'SIGNALIS', 57149),
    (2475490, 'Mouthwashing', 145368),
    (814380, 'Sekiro™: Shadows Die Twice - GOTY Edition', 57415),
    (435150, 'Divinity: Original Sin 2 - Definitive Edition', 39525),
    (1205520, 'Pentiment', 109237),
  ];

  test('resolves real Steam titles to appId-verified HLTB entries', () async {
    final store = MemoryHltbBootstrapStore();
    final client = HltbClient(store: store);
    final resolver = HltbResolver(client);
    addTearDown(client.close);

    for (final (appId, name, expectedId) in games) {
      final sw = Stopwatch()..start();
      final r = await resolver.resolve(name: name, steamAppId: appId);
      // ignore: avoid_print
      print('${name.padRight(48)} -> ${r?.hltbName} [${r?.hltbGameId}] '
          'verified=${r?.hltbVerified} main=${r?.essentialHours}h '
          '(${sw.elapsedMilliseconds} ms)');
      expect(r, isNotNull, reason: name);
      expect(r!.hltbGameId, expectedId, reason: name);
      expect(r.hltbVerified, isTrue, reason: name);
      expect(r.essentialHours, greaterThan(0), reason: name);
      await Future<void>.delayed(const Duration(milliseconds: 500)); // be polite
    }

    // Refresh path: a known HLTB id costs one CDN request, no search.
    final sw = Stopwatch()..start();
    final refreshed = await resolver.resolve(
        name: 'Portal 2', steamAppId: 620, hltbGameId: 7231);
    // ignore: avoid_print
    print('refresh by known id: ${sw.elapsedMilliseconds} ms');
    expect(refreshed!.hltbVerified, isTrue);

    expect(store.current.searchPath, isNotNull);
    expect(store.current.buildId, isNotNull);
  },
      skip: _enabled ? false : 'set HLTB_LIVE=1 to run against howlongtobeat.com',
      timeout: const Timeout(Duration(minutes: 2)));
}
