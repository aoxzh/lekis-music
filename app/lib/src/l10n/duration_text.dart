// Shared human-readable total running time for albums, artists and playlists.
//
// Kept separate from any one feature so the same wording is used everywhere.

import 'package:lekis/src/l10n/app_l10n.dart';

/// Formats a total duration such as "1 小时 12 分" / "1h 12m".
String formatTotalDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  if (h > 0) return L10n.tr('$h 小时 $m 分', '${h}h ${m}m');
  final s = d.inSeconds.remainder(60);
  return s == 0
      ? L10n.tr('$m 分钟', '${m}m')
      : L10n.tr('$m 分 $s 秒', '${m}m ${s}s');
}
