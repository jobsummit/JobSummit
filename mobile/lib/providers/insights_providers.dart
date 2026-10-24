import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/picks.dart';
import '../domain/relevance.dart';
import '../services/insights_service.dart';
import '../services/picks_repository.dart';
import 'account_providers.dart';
import 'providers.dart';

final picksRepositoryProvider = Provider<PicksRepository>((ref) => PicksRepository());

/// The job-picks model (picks.json), refreshed at most once a day.
final picksProvider = FutureProvider<Picks>((ref) => ref.read(picksRepositoryProvider).load());

/// What people with your degree (or level) lean towards, for ranking.
final crowdAffinityProvider = Provider<Affinity>((ref) {
  final picks = ref.watch(picksProvider).dataOrNull ?? Picks.empty;
  return picks.crowdFor(ref.watch(profileProvider).dataOrNull);
});

final insightsServiceProvider = Provider<InsightsService>((ref) => InsightsService());

/// "Help improve job picks": on unless turned off.
class InsightsConsentNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() => InsightsService.consent();

  Future<void> set(bool yes) async {
    await InsightsService.setConsent(yes);
    state = AsyncData(yes);
  }

  /// Deletes what was shared and stops sharing. Throws when offline.
  Future<void> forget() async {
    await ref.read(insightsServiceProvider).forget();
    state = const AsyncData(false);
  }
}

final insightsConsentProvider =
    AsyncNotifierProvider<InsightsConsentNotifier, bool>(InsightsConsentNotifier.new);
