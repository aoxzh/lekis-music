import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/rust/api/dto.dart';

void main() {
  test('identical consecutive events still notify listeners', () async {
    final source = StreamController<CoreEventDto>.broadcast();
    addTearDown(source.close);
    final container = ProviderContainer(
      overrides: [coreEventSourceProvider.overrideWithValue(source.stream)],
    );
    addTearDown(container.dispose);

    var catalogChanges = 0;
    container.listen<AsyncValue<CoreEventDto>>(coreEventsProvider, (_, next) {
      final event = next.value;
      if (event is CoreEventDto_LibraryChanged &&
          event.scope == LibraryScopeDto.catalog) {
        catalogChanges++;
      }
    });

    // e.g. change a cover, then undo it: two equal events back to back.
    const changed = CoreEventDto.libraryChanged(scope: LibraryScopeDto.catalog);
    source.add(changed);
    await Future<void>.delayed(Duration.zero);
    source.add(changed);
    await Future<void>.delayed(Duration.zero);

    expect(catalogChanges, 2);
  });
}
