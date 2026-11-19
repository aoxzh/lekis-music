import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';

/// Keystrokes within this window collapse into one core query.
const Duration searchDebounce = Duration(milliseconds: 250);

/// Max results per section.
const int searchLimit = 25;

final searchQueryProvider = NotifierProvider<SimpleValue<String>, String>(
  () => SimpleValue<String>(''),
);

/// Debounced results: each new query disposes the previous computation
/// before its delay elapses, so only the last keystroke hits the core.
final searchResultsProvider = FutureProvider.autoDispose<SearchResultsDto?>((
  ref,
) async {
  final query = ref.watch(searchQueryProvider).trim();
  if (query.isEmpty) return null;

  var cancelled = false;
  ref.onDispose(() => cancelled = true);
  await Future<void>.delayed(searchDebounce);
  if (cancelled) throw const _Superseded();

  return core.search(text: query, limit: searchLimit);
});

class _Superseded implements Exception {
  const _Superseded();
}
