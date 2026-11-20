// Core event stream exposed to the widget tree via Riverpod.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:lekis/src/rust/api/core.dart';
import 'package:lekis/src/rust/api/dto.dart';

/// The one subscription to the core's event stream for this process.
/// Created lazily on first access and never cancelled, so late listeners
/// share it instead of opening a second Rust sink.
final Stream<CoreEventDto> coreEventStream = coreEvents().asBroadcastStream();

/// Where [coreEventsProvider] reads events from. Tests override this with
/// `const Stream.empty()` (or a controller) so they never touch the core.
final coreEventSourceProvider = Provider<Stream<CoreEventDto>>(
  (ref) => coreEventStream,
);

/// Latest core event (playback, progress, scans, library changes, ...).
///
/// Widgets usually `ref.listen` to this and react to the variants they care
/// about, e.g. `CoreEventDto_LibraryChanged`.
///
/// Every event notifies listeners, even one equal to the previous event:
/// events are things that happened, not state. (Riverpod would otherwise drop
/// the second of two identical `LibraryChanged(catalog)` events, e.g. changing
/// a cover and then undoing it, and the UI would show stale data.)
final coreEventsProvider =
    StreamNotifierProvider<CoreEventsNotifier, CoreEventDto>(
      CoreEventsNotifier.new,
    );

class CoreEventsNotifier extends StreamNotifier<CoreEventDto> {
  @override
  Stream<CoreEventDto> build() => ref.watch(coreEventSourceProvider);

  @override
  bool updateShouldNotify(
    AsyncValue<CoreEventDto> previous,
    AsyncValue<CoreEventDto> next,
  ) => true;
}
