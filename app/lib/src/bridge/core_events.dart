// Core event stream exposed to the widget tree via Riverpod.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:lekis/src/rust/api/core.dart';
import 'package:lekis/src/rust/api/dto.dart';

/// The one subscription to the core's event stream for this process.
/// Created lazily on first access and never cancelled, so late listeners
/// share it instead of opening a second Rust sink.
final Stream<CoreEventDto> coreEventStream = coreEvents().asBroadcastStream();

/// Latest core event (playback, progress, scans, library changes, ...).
///
/// Widgets usually `ref.listen` to this and react to the variants they care
/// about, e.g. `CoreEventDto_LibraryChanged`.
final coreEventsProvider = StreamProvider<CoreEventDto>(
  (ref) => coreEventStream,
);
