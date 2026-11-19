import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';

/// Years that contain at least one play event, newest first (DIS-06).
final listeningYearsProvider = FutureProvider.autoDispose<List<int>>((ref) async {
  ref.cacheFor(const Duration(minutes: 5));
  final years = await core.listeningYears();
  return years.toList();
});

/// Aggregated listening report. `null` means all time.
final listeningSummaryProvider =
    FutureProvider.autoDispose.family<ListeningSummaryDto, int?>((ref, year) async {
      ref.cacheFor(const Duration(minutes: 2));
      return core.listeningSummary(year: year, topLimit: 10);
    });
