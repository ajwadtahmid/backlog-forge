import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'providers/library_provider.dart';
import 'providers/theme_provider.dart';
import 'router.dart';
import 'services/app_logger.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.instance.init();
  LicenseRegistry.addLicense(_fontLicenses);
  final prefs = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: const BacklogForgeApp(),
    ),
  );
}

/// Shows the licence texts of the bundled fonts on the About / licences page.
Stream<LicenseEntry> _fontLicenses() async* {
  const fonts = {
    'Space Grotesk': 'assets/fonts/OFL-SpaceGrotesk.txt',
    'Inter': 'assets/fonts/OFL-Inter.txt',
    'JetBrains Mono': 'assets/fonts/OFL-JetBrainsMono.txt',
  };
  for (final e in fonts.entries) {
    yield LicenseEntryWithLineBreaks([e.key], await rootBundle.loadString(e.value));
  }
}

class BacklogForgeApp extends ConsumerWidget {
  const BacklogForgeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(backgroundSyncProvider); // arms the 2-hour auto-sync timer
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeProvider);
    final font = ref.watch(appFontProvider);

    return MaterialApp.router(
      title: 'BacklogForge',
      themeMode: themeMode,
      theme: lightThemeFor(font),
      darkTheme: darkThemeFor(font),
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
