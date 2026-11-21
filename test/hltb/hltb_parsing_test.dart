import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:backlogforge/services/hltb/hltb_names.dart';
import 'package:backlogforge/services/hltb/hltb_parsers.dart';
import 'fake_hltb_server.dart';

/// Parsers are tested against responses captured from howlongtobeat.com on
/// 2026-11-21 (trimmed to the fields we use).
void main() {
  group('HltbParsers — real captured responses', () {
    test('buildId is read from the homepage manifest script', () {
      expect(HltbParsers.buildId(fixture('home.html')), 'RS3MtNrhIzoB1gMv7p1hA');
    });

    test('chunkPaths returns only same-origin Next.js chunks, in order', () {
      final paths = HltbParsers.chunkPaths(fixture('home.html'));
      expect(paths, isNotEmpty);
      expect(paths.every((p) => p.startsWith('/_next/static/chunks/')), isTrue);
      expect(paths, contains(FakeHltbServer.searchChunk));
      expect(paths.any((p) => p.contains('ziffstatic')), isFalse);
    });

    test('searchPath finds the POST endpoint that has an /init sibling', () {
      expect(HltbParsers.searchPath(fixture('search_chunk.js')), '/api/search/site');
    });

    test('searchPath ignores chunks without the search form code', () {
      expect(HltbParsers.searchPath(fixture('other_chunk.js')), isNull);
    });

    test('searchPath handles a renamed single-segment endpoint', () {
      const js = 'searchOptions:{};fetch(`/api/bleed/init?t=1`);'
          'r=await fetch("/api/bleed",{method:"POST",headers:{}})';
      expect(HltbParsers.searchPath(js), '/api/bleed');
    });

    test('searchResults parses the Portal 2 search', () {
      final hits = HltbParsers.searchResults(fixture('search_portal2.json'));
      expect(hits.map((h) => h.gameId), [7231, 27601]);
      final portal = hits.first;
      expect(portal.name, 'Portal 2');
      expect(portal.mainHours, closeTo(8.58, 0.01)); // 30886 s
      expect(portal.imageUrl, startsWith('https://howlongtobeat.com/games/'));
      expect(portal.popularity, greaterThan(0));
    });

    test('gamePage exposes profile_steam for exact matching', () {
      final g = HltbParsers.gamePage(fixture('game_7231.json'));
      expect(g.gameId, 7231);
      expect(g.steamAppId, 620);
      expect(g.mainHours, closeTo(8.58, 0.01));
      expect(g.extraHours, closeTo(13.77, 0.01)); // 49560 s
      expect(g.completionistHours, closeTo(23.0, 0.01)); // 82795 s
    });

    test('zero durations become null (no data), not 0 h', () {
      final body = jsonEncode({
        'data': [
          {'game_id': 1, 'game_name': 'X', 'comp_main': 0, 'comp_plus': 0, 'comp_100': 0},
        ],
      });
      final hit = HltbParsers.searchResults(body).single;
      expect(hit.mainHours, isNull);
      expect(hit.extraHours, isNull);
      expect(hit.completionistHours, isNull);
    });

    test('malformed responses throw FormatException', () {
      expect(() => HltbParsers.searchResults('<html>'), throwsFormatException);
      expect(() => HltbParsers.gamePage('{"pageProps":{}}'), throwsFormatException);
    });

    test('auth reads the token and optional hp key/val fields', () {
      expect(HltbParsers.auth('{"token":"abc"}')!.token, 'abc');
      expect(HltbParsers.auth('{"token":"abc"}')!.hpKey, isNull);
      final withHp = HltbParsers.auth('{"token":"t","hpKey":"k1","hpVal":"v1"}')!;
      expect((withHp.hpKey, withHp.hpVal), ('k1', 'v1'));
      expect(HltbParsers.auth('{}'), isNull);
      expect(HltbParsers.auth('nope'), isNull);
    });

    test('searchBody mirrors the site payload and hides DLC', () {
      final body = jsonDecode(HltbParsers.searchBody('Portal 2', null));
      expect(body['searchTerms'], ['Portal', '2']);
      expect(body['searchOptions']['games']['modifier'], 'hide_dlc');
      final withHp = jsonDecode(HltbParsers.searchBody(
          'x', const HltbAuth(token: 't', hpKey: 'k', hpVal: 'v')));
      expect(withHp['k'], 'v');
    });
  });

  group('HltbNames.searchName', () {
    final cases = {
      'Sekiro™: Shadows Die Twice - GOTY Edition': 'Sekiro: Shadows Die Twice',
      'Divinity: Original Sin 2 - Definitive Edition': 'Divinity: Original Sin 2',
      'Mass Effect™ Legendary Edition': 'Mass Effect Legendary Edition',
      'The Witcher 3: Wild Hunt - Game of the Year Edition': 'The Witcher 3: Wild Hunt',
      'Borderlands 2 (Game of the Year Edition)': 'Borderlands 2',
      'Rain World': 'Rain World',
      // Distinct HLTB entries must survive.
      'Dark Souls™: Remastered': 'Dark Souls: Remastered',
      "Death Stranding Director's Cut": "Death Stranding Director's Cut",
      'Definitive Edition': 'Definitive Edition', // never strip to empty
    };
    cases.forEach((input, expected) {
      test('"$input" → "$expected"', () {
        expect(HltbNames.searchName(input), expected);
      });
    });
  });

  group('HltbNames.similarity', () {
    test('identical after normalisation scores 1', () {
      expect(HltbNames.similarity('SIGNALIS', 'Signalis'), 1.0);
      expect(HltbNames.similarity('Sekiro: Shadows Die Twice', 'Sekiro Shadows Die Twice'), 1.0);
    });

    test('Roman vs Arabic numeral is close but not exact', () {
      final s = HltbNames.similarity('Divinity: Original Sin 2', 'Divinity: Original Sin II');
      expect(s, greaterThan(0.9));
      expect(s, lessThan(1.0));
    });

    test('unrelated names score low', () {
      expect(HltbNames.similarity('Portal 2', 'Stardew Valley'), lessThan(0.3));
    });
  });
}
