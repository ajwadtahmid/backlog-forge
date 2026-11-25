import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:backlogforge/providers/auth_provider.dart';
import 'package:backlogforge/providers/database_provider.dart';
import 'package:backlogforge/providers/play_next_provider.dart';
import 'package:backlogforge/services/database/app_database.dart';

class _SignedIn extends AuthNotifier {
  @override
  Future<AuthState> build() async => const AuthState.signedIn('me');
}

void main() {
  test('a failed database read ends the spin instead of loading forever',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customStatement('DROP TABLE games'); // reading games now throws
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      authProvider.overrideWith(() => _SignedIn()),
    ]);
    addTearDown(c.dispose);
    await c.read(authProvider.future);

    final notifier = c.read(playNextProvider.notifier);
    await notifier.spin(); // must not throw

    final state = c.read(playNextProvider);
    expect(state.loading, isFalse);
    expect(state.spun, isFalse, reason: 'nothing was loaded');
  });

  test('a normal spin still fills the picks', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      authProvider.overrideWith(() => _SignedIn()),
    ]);
    addTearDown(c.dispose);
    await c.read(authProvider.future);

    await c.read(playNextProvider.notifier).spin();
    final state = c.read(playNextProvider);
    expect(state.loading, isFalse);
    expect(state.spun, isTrue);
    expect(state.picks, isEmpty); // empty library: nothing to pick, but done
  });
}
