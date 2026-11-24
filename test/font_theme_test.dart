import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:backlogforge/providers/theme_provider.dart';
import 'package:backlogforge/theme.dart';

Future<ProviderContainer> _container(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  final p = await SharedPreferences.getInstance();
  final c = ProviderContainer(
      overrides: [sharedPrefsProvider.overrideWithValue(p)]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('font choice', () {
    test('a new install uses Space Grotesk', () async {
      final c = await _container({});
      expect(c.read(appFontProvider), AppFont.spaceGrotesk);
    });

    test('the saved choice is restored, and unknown values fall back',
        () async {
      expect(
          (await _container({'font': 'inter'})).read(appFontProvider),
          AppFont.inter);
      expect(
          (await _container({'font': 'comic'})).read(appFontProvider),
          AppFont.spaceGrotesk);
    });

    test('setFont persists the choice', () async {
      final c = await _container({});
      await c.read(appFontProvider.notifier).setFont(AppFont.jetBrainsMono);
      expect(c.read(appFontProvider), AppFont.jetBrainsMono);
      expect(c.read(sharedPrefsProvider).getString('font'), 'jetBrainsMono');
    });
  });

  group('theme default', () {
    test('a new install starts dark', () async {
      final c = await _container({});
      expect(c.read(themeProvider), ThemeMode.dark);
    });

    test('a saved choice is kept', () async {
      expect((await _container({'theme': 'light'})).read(themeProvider),
          ThemeMode.light);
      expect((await _container({'theme': 'system'})).read(themeProvider),
          ThemeMode.system);
    });
  });

  group('themes', () {
    test('each bundled font is applied to the whole text theme', () {
      for (final f in AppFont.values.where((f) => f.family != null)) {
        for (final t in [lightThemeFor(f), darkThemeFor(f)]) {
          expect(t.textTheme.bodyMedium!.fontFamily, f.family);
          expect(t.textTheme.titleLarge!.fontFamily, f.family);
        }
      }
    });

    test('System leaves the platform font alone', () {
      expect(darkThemeFor(AppFont.system).textTheme.bodyMedium!.fontFamily,
          isNot(anyOf('SpaceGrotesk', 'Inter', 'JetBrainsMono')));
    });
  });

  test('every bundled font file is declared in pubspec and exists', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final f in AppFont.values.where((f) => f.family != null)) {
      expect(pubspec, contains('family: ${f.family}'));
      for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        final path = 'assets/fonts/${f.family}-$w.ttf';
        expect(File(path).existsSync(), isTrue, reason: path);
        expect(pubspec, contains(path));
      }
      expect(File('assets/fonts/OFL-${f.family}.txt').existsSync(), isTrue);
    }
    expect(pubspec, isNot(contains('google_fonts')));
  });
}
