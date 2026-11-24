import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_l10n.dart';
import '../player/player_providers.dart';
import 'lyric_typography.dart';
import 'lyrics_parser.dart';

typedef _Passage = ({int start, List<VocalCue> voices, VocalCue? next});

List<_Passage> _passages(ParsedLyrics parsed) {
  final cues = parsed.vocalCues.isNotEmpty
      ? parsed.vocalCues
      : [
          for (final line in parsed.lines)
            (
              line: line,
              endMs: null,
              voice: null as String?,
              together: false,
              backing: false,
            ),
        ];
  final starts = <int, List<VocalCue>>{};
  final ends = <int, List<VocalCue>>{};
  for (final cue in cues) {
    starts.putIfAbsent(cue.line.startMs, () => []).add(cue);
    if (cue.endMs case final end? when end > cue.line.startMs) {
      ends.putIfAbsent(end, () => []).add(cue);
    }
  }
  final times = {...starts.keys, ...ends.keys}.toList()..sort();
  final result = <_Passage>[];
  final active = <VocalCue>[];
  VocalCue? next;
  final upcoming = <int, VocalCue?>{};
  for (final time in times.reversed) {
    upcoming[time] = next;
    next =
        starts[time]?.where((c) => !c.line.isInstrumental).firstOrNull ?? next;
  }
  if (times.isNotEmpty && times.first > 0) {
    result.add((start: 0, voices: const [], next: next));
  }
  for (final time in times) {
    final starting = starts[time];
    if (starting != null) {
      final hasLead = starting.any((cue) => !cue.backing);
      active.removeWhere(
        (cue) => cue.endMs == null && (hasLead || cue.backing),
      );
    }
    for (final cue in ends[time] ?? const <VocalCue>[]) {
      active.remove(cue);
    }
    if (starting != null) {
      active.addAll(
        starting.where(
          (cue) =>
              !cue.line.isInstrumental &&
              (cue.endMs == null || cue.endMs! > time),
        ),
      );
    }
    result.add((start: time, voices: List.of(active), next: upcoming[time]));
  }
  return result;
}

class EnsembleLyrics extends ConsumerStatefulWidget {
  const EnsembleLyrics({
    super.key,
    required this.lyrics,
    required this.style,
    required this.translation,
    required this.reduceMotion,
  });
  final ParsedLyrics lyrics;
  final TextStyle style;
  final bool translation;
  final bool reduceMotion;

  @override
  ConsumerState<EnsembleLyrics> createState() => _EnsembleLyricsState();
}

class _EnsembleLyricsState extends ConsumerState<EnsembleLyrics> {
  late var passages = _passages(widget.lyrics);
  late var voices = _voices();

  List<String> _voices() => {
    for (final cue in widget.lyrics.vocalCues)
      if (!cue.together && !cue.backing && cue.voice != null) cue.voice!,
  }.toList();

  @override
  void didUpdateWidget(EnsembleLyrics old) {
    super.didUpdateWidget(old);
    if (old.lyrics != widget.lyrics) {
      passages = _passages(widget.lyrics);
      voices = _voices();
    }
  }

  int _index(int ms) {
    var low = 0, high = passages.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (passages[mid].start <= ms) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low - 1;
  }

  Widget _part(BuildContext context, VocalCue cue) {
    final scheme = Theme.of(context).colorScheme;
    final index = voices.indexOf(cue.voice ?? '');
    final right = index >= 0 && index.isOdd;
    final accent = Color.lerp(
      right || cue.backing ? scheme.tertiary : scheme.primary,
      scheme.onSurface,
      .35,
    )!;
    final centered = cue.together || cue.backing || cue.voice == null;
    final align = centered
        ? TextAlign.center
        : right
        ? TextAlign.end
        : TextAlign.start;
    final label = cue.backing
        ? [context.l10n.pick('和声', 'Backing'), ?cue.voice].join(' · ')
        : cue.together
        ? {context.l10n.pick('合唱', 'Chorus'), ?cue.voice}.join(' · ')
        : cue.voice;
    return Align(
      alignment: centered
          ? Alignment.center
          : right
          ? Alignment.centerRight
          : Alignment.centerLeft,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => ref.read(playerActionsProvider).seek(cue.line.startMs),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: centered
                  ? CrossAxisAlignment.center
                  : right
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                if (label != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!right || centered)
                          Container(
                            width: 24,
                            height: 2,
                            color: accent,
                            margin: const EdgeInsets.only(right: 8),
                          ),
                        Flexible(
                          child: Text(
                            label,
                            textAlign: align,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: accent,
                                ),
                          ),
                        ),
                        if (right || centered)
                          Container(
                            width: 24,
                            height: 2,
                            color: accent,
                            margin: const EdgeInsets.only(left: 8),
                          ),
                      ],
                    ),
                  ),
                Text(
                  cue.line.text,
                  textAlign: align,
                  style: lyricTextStyleFor(cue.line.text, widget.style)
                      .copyWith(
                        color: scheme.onSurface,
                        fontSize: cue.backing
                            ? (widget.style.fontSize ?? 30) * .78
                            : widget.style.fontSize,
                      ),
                ),
                if (widget.translation && cue.line.translation != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      cue.line.translation!,
                      textAlign: align,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(positionProvider.select(_index));
    if (index < 0) return const SizedBox.shrink();
    final passage = passages[index];
    final parts = passage.voices;
    final still =
        widget.reduceMotion || MediaQuery.disableAnimationsOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 60),
      child: LayoutBuilder(
        builder: (context, bounds) {
          final leads = parts.where((c) => !c.backing && !c.together).toList();
          final paired =
              leads.length == 2 &&
              leads.every((cue) => cue.voice != null) &&
              leads.first.voice != leads.last.voice &&
              bounds.maxWidth >= 440;
          if (paired && voices.indexOf(leads.first.voice!).isOdd) {
            leads.setAll(0, leads.reversed.toList());
          }
          final body = Column(
            key: ValueKey(passage.start),
            mainAxisSize: MainAxisSize.min,
            children: [
              if (paired)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _part(context, leads.first)),
                    const SizedBox(width: 12),
                    Expanded(child: _part(context, leads.last)),
                  ],
                ),
              for (final part in parts.where(
                (p) => !paired || !leads.contains(p),
              ))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _part(context, part),
                ),
              if (passage.next case final next?)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: TextButton(
                    onPressed: () =>
                        ref.read(playerActionsProvider).seek(next.line.startMs),
                    child: Text(
                      context.l10n.pick(
                        '下一句 · ${next.line.text}',
                        'Next · ${next.line.text}',
                      ),
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          );
          return Center(
            child: SingleChildScrollView(
              primary: false,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: still
                    ? body
                    : AnimatedSwitcher(
                        duration: const Duration(milliseconds: 160),
                        child: body,
                      ),
              ),
            ),
          );
        },
      ),
    );
  }
}
