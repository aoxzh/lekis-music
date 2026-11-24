import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';

/// Keystrokes within this window collapse into one core query.
const Duration searchDebounce = Duration(milliseconds: 250);

/// Max results per section before "Show more".
const int searchDefaultLimit = 25;
const int searchMaxLimit = 100;
const int searchLimitStep = 25;

class SearchLimitController extends Notifier<int> {
  @override
  int build() => searchDefaultLimit;

  void more() {
    if (state >= searchMaxLimit) return;
    state = (state + searchLimitStep).clamp(searchDefaultLimit, searchMaxLimit);
  }

  void reset() => state = searchDefaultLimit;
}

final searchLimitProvider = NotifierProvider<SearchLimitController, int>(
  SearchLimitController.new,
);

/// null selects the library; otherwise use an installed source plugin ID.
final searchSourceProvider = NotifierProvider<SimpleValue<String?>, String?>(
  () => SimpleValue<String?>(null),
);

final searchQueryProvider = NotifierProvider<SimpleValue<String>, String>(
  () => SimpleValue<String>(''),
);

/// Debounced results: each new query disposes the previous computation
/// before its delay elapses, so only the last keystroke hits the core.
final searchResultsProvider = FutureProvider.autoDispose<SearchResultsDto?>((
  ref,
) async {
  final query = ref.watch(searchQueryProvider).trim();
  final source = ref.watch(searchSourceProvider);
  final limit = ref.watch(searchLimitProvider);
  // A plugin search imports its rows into the library, which emits a catalog
  // change. Reacting to that here would invalidate this very request and run
  // the search again, forever. Only library searches need catalog refreshes.
  if (source == null) ref.invalidateOnCatalogChange();
  ref.cacheFor(const Duration(seconds: 30));
  if (query.isEmpty) return null;

  var cancelled = false;
  ref.onDispose(() => cancelled = true);
  await Future<void>.delayed(searchDebounce);
  if (cancelled) throw const _Superseded();

  return source == null
      ? core.search(text: query, limit: limit)
      : core.searchPlugin(pluginId: source, query: query, limit: limit);
}, retry: (_, _) => null);

class _Superseded implements Exception {
  const _Superseded();
}

/// Library source search has its own query identity; switching sources disposes
/// the old request and never changes the standalone Search tab's selection.
final librarySourceSearchProvider = FutureProvider.autoDispose
    .family<SearchResultsDto?, (String, String)>((ref, request) async {
      final (pluginId, text) = request;
      final query = text.trim();
      ref.cacheFor(const Duration(seconds: 30));
      if (query.isEmpty) return null;
      var cancelled = false;
      ref.onDispose(() => cancelled = true);
      await Future<void>.delayed(searchDebounce);
      if (cancelled) throw const _Superseded();
      return core.searchPlugin(pluginId: pluginId, query: query, limit: 50);
    }, retry: (_, _) => null);
