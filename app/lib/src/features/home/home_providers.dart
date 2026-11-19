import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';

/// Items per home shelf.
const int homeShelfLimit = 30;

final recentlyAddedProvider = FutureProvider.autoDispose<List<TrackRowDto>>((
  ref,
) async {
  ref.invalidateOnCatalogChange();
  ref.cacheFor(const Duration(minutes: 5));
  return core.recentlyAdded(limit: homeShelfLimit);
});

final mostPlayedProvider = FutureProvider.autoDispose<List<TrackRowDto>>((
  ref,
) async {
  ref.invalidateOnCatalogChange();
  ref.cacheFor(const Duration(minutes: 5));
  return core.mostPlayed(limit: homeShelfLimit);
});

// TODO(core): "Continue listening" needs a recently-played history call
// (e.g. `recentlyPlayed(limit)`). Until then Home shows only the current
// track in that shelf.
