import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/hltb/hltb_client.dart';
import '../services/hltb/hltb_resolver.dart';
import 'theme_provider.dart' show sharedPrefsProvider;

/// Single on-device HLTB client shared by search and sync, so the discovered
/// endpoint, token and build id are reused (and persisted across launches).
final hltbClientProvider = Provider<HltbClient>((ref) {
  final client = HltbClient(
    store: SharedPrefsHltbBootstrapStore(ref.watch(sharedPrefsProvider)),
  );
  ref.onDispose(client.close);
  return client;
});

final hltbResolverProvider =
    Provider<HltbResolver>((ref) => HltbResolver(ref.watch(hltbClientProvider)));
