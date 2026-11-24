import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/now_playing/lyric_typography.dart';
import 'package:lekis/src/features/now_playing/lyrics_classic.dart';
import 'package:lekis/src/features/now_playing/lyrics_editor_sheet.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/features/now_playing/lyrics_stage.dart';
import 'package:lekis/src/features/now_playing/lyrics_ensemble.dart';
import 'package:lekis/src/features/now_playing/lyrics_stage_settings.dart';
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/features/settings/settings_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart' show LyricsFormatDto;
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Lyrics for [trackId]: the Apple Music-style classic view (default), the
/// opt-in word-by-word stage, plain text, or an empty state.
///
/// The searching / empty / error states are centred in the pane (a lyrics
/// pane never shows up as a big blank area).
class LyricsView extends ConsumerWidget {
  const LyricsView({
    super.key,
    required this.trackId,
    this.compact = false,
    this.lowPower = false,
  });

  /// `null` when nothing is playing yet.
  final int? trackId;

  /// Smaller type for narrow windows.
  final bool compact;

  /// Reduce-motion / low-power: no springs, sparks or blur.
  final bool lowPower;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final trackId = this.trackId;
    if (trackId == null) {
      return _Message(
        key: const ValueKey('idle'),
        icon: Icons.lyrics_outlined,
        title: l10n.noLyrics,
        detail: l10n.pick(
          '开始播放后会在这里显示歌词',
          'Lyrics will appear once playback starts',
        ),
      );
    }
    // Keep the next track's lyrics warm while this pane is visible.
    ref.watch(lyricsPrefetchProvider);
    final lyrics = ref.watch(lyricsProvider(trackId));
    final lyricsStyle = ref.watch(lyricsStyleProvider);
    final theme = Theme.of(context);
    var synced = false;
    var offsetMs = 0;
    var lyricsSource = '';
    LyricsFormatDto? lyricsFormat;
    final Widget body = lyrics.when(
      // An online lookup can take a few seconds; local ones are instant, so
      // the searching state only appears after a short pause.
      loading: () => const _Searching(key: ValueKey('loading')),
      error: (e, _) => _Message(
        key: const ValueKey('error'),
        icon: Icons.lyrics_outlined,
        title: l10n.noLyrics,
        detail: l10n.pick(
          '查找歌词时出了点问题',
          'Something went wrong while fetching lyrics',
        ),
        onSearch: () => showLyricsEditor(context, ref, trackId),
      ),
      data: (parsed) {
        // Lyrics made only of blank / instrumental lines would render as an
        // empty stage.
        if (parsed == null || parsed.lines.every((l) => l.isInstrumental)) {
          return _Message(
            key: const ValueKey('empty'),
            icon: Icons.lyrics_outlined,
            title: l10n.noLyrics,
            detail: l10n.pick(
              '还没有选用歌词。可以查看候选版本，或重新搜索。',
              'No lyrics selected. Check available versions or search again.',
            ),
            onSearch: () => showLyricsEditor(context, ref, trackId),
          );
        }
        synced = parsed.synced;
        offsetMs = parsed.offsetMs;
        lyricsSource = parsed.source;
        lyricsFormat = parsed.format;
        final showTranslation =
            ref.watch(settingProvider(SettingKeys.lyricsTranslation)).value !=
            'false';
        final display =
            showTranslation ||
                lyricsStyle == LyricsStyle.ensemble && parsed.synced
            ? parsed
            : ParsedLyrics(
                lines: [
                  for (final line in parsed.lines)
                    LyricLine(line.startMs, line.text, words: line.words),
                ],
                synced: parsed.synced,
                offsetMs: parsed.offsetMs,
                source: parsed.source,
                format: parsed.format,
              );
        final base = LekisText.lyricsActive.copyWith(
          color: theme.colorScheme.onSurface,
        );
        final scaleValue = double.tryParse(
          ref.watch(settingProvider(SettingKeys.lyricsFontScale)).value ?? '',
        );
        final scale = (scaleValue ?? 1.0).clamp(0.7, 1.6);
        final style = base.copyWith(
          fontSize: (base.fontSize ?? 30) * (compact ? 0.8 : 1.0) * scale,
        );
        if (!display.synced) {
          return _PlainLyrics(
            key: const ValueKey('plain'),
            lyrics: display,
            style: style.copyWith(fontWeight: FontWeight.w600),
          );
        }
        if (lyricsStyle == LyricsStyle.ensemble) {
          return EnsembleLyrics(
            key: ValueKey('ensemble-$trackId'),
            lyrics: parsed,
            style: style,
            translation: showTranslation,
            reduceMotion: lowPower,
          );
        }
        // 经典视图是默认；只有用户显式选了舞台样式才走逐字舞台。
        final stageStyle = lyricsStyle.stage;
        if (stageStyle == null) {
          return ClassicLyrics(
            key: ValueKey('classic-$trackId'),
            lyrics: display,
            style: style,
            compact: compact,
            lowPower: lowPower,
          );
        }
        return LyricsStage(
          key: ValueKey('stage-$trackId'),
          lyrics: display,
          style: stageStyle,
          sparks: ref.watch(lyricsSparksProvider),
          baseStyle: style,
          compact: compact,
          lowPower: lowPower,
        );
      },
    );
    // Searching → lyrics / empty cross-fades instead of popping in.
    //
    // No floating edit button over the first lyric line any more: 编辑歌词
    // lives in the title row's “更多” menu (now_playing_library_actions).
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedSwitcher(
          duration: lowPower || MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : LekisMotion.normal,
          layoutBuilder: (current, previous) =>
              Stack(fit: StackFit.expand, children: [...previous, ?current]),
          child: body,
        ),
        if (lyricsSource.isNotEmpty)
          Positioned(
            left: LekisSpacing.md,
            bottom: LekisSpacing.md,
            child: _LyricsSourceBadge(
              source: lyricsSource,
              format: lyricsFormat,
            ),
          ),
        if (synced)
          Positioned(
            right: LekisSpacing.md,
            bottom: LekisSpacing.md,
            child: _LyricsOffsetBar(trackId: trackId, offsetMs: offsetMs),
          ),
      ],
    );
  }
}

/// Small provenance badge over the lyrics: embedded, sidecar, online, manual.
class _LyricsSourceBadge extends StatelessWidget {
  const _LyricsSourceBadge({required this.source, this.format});

  final String source;
  final LyricsFormatDto? format;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final sourceLabel = switch (source) {
      'embedded' => l10n.pick('内嵌歌词', 'Embedded'),
      'sidecar' => l10n.pick('同名文件', 'Sidecar'),
      'lrclib' => l10n.pick('在线歌词', 'Online'),
      'manual' => l10n.pick('手动编辑', 'Manual'),
      _ => l10n.lyricsSourceName(source),
    };
    final formatLabel = switch (format) {
      LyricsFormatDto.lrc => 'LRC',
      LyricsFormatDto.enhancedLrc => 'Enhanced LRC',
      LyricsFormatDto.ttml => 'TTML',
      LyricsFormatDto.plain => 'Text',
      null => null,
    };
    final label = formatLabel == null
        ? sourceLabel
        : '$sourceLabel · $formatLabel';
    return Material(
      color: colors.surfaceElevated.withValues(alpha: 0.92),
      elevation: 2,
      borderRadius: BorderRadius.circular(LekisRadius.pill),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: LekisSpacing.sm,
            vertical: LekisSpacing.xxs,
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// Small always-available offset control over synced lyrics: nudge the
/// timestamps without opening the lyrics editor.
class _LyricsOffsetBar extends ConsumerWidget {
  const _LyricsOffsetBar({required this.trackId, required this.offsetMs});

  final int trackId;
  final int offsetMs;

  Future<void> _set(BuildContext context, WidgetRef ref, int next) async {
    final value = next.clamp(-60000, 60000);
    try {
      await core.setLyricsOffset(trackId: trackId, offsetMs: value);
      ref.invalidate(lyricsProvider(trackId));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.pick(
                '调整歌词偏移失败：$e',
                'Failed to adjust lyrics offset: $e',
              ),
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    final seconds = (offsetMs / 1000).toStringAsFixed(1);
    final label = '${offsetMs >= 0 ? '+' : ''}${seconds}s';
    final l10n = context.l10n;
    return Material(
      color: colors.surfaceElevated.withValues(alpha: 0.92),
      elevation: 2,
      borderRadius: BorderRadius.circular(LekisRadius.pill),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.xxs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: l10n.pick('歌词提前 0.5 秒', 'Lyrics 0.5s earlier'),
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              iconSize: 18,
              onPressed: offsetMs >= 60000
                  ? null
                  : () => _set(context, ref, offsetMs + 500),
              icon: const Icon(Icons.fast_rewind_rounded),
            ),
            SizedBox(
              width: 48,
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontFeatures: LekisText.tabularFigures,
                ),
              ),
            ),
            IconButton(
              tooltip: l10n.pick('歌词延后 0.5 秒', 'Lyrics 0.5s later'),
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              iconSize: 18,
              onPressed: offsetMs <= -60000
                  ? null
                  : () => _set(context, ref, offsetMs - 500),
              icon: const Icon(Icons.fast_forward_rounded),
            ),
            IconButton(
              tooltip: l10n.pick('重置歌词偏移', 'Reset lyrics offset'),
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              iconSize: 18,
              onPressed: offsetMs == 0 ? null : () => _set(context, ref, 0),
              icon: const Icon(Icons.restart_alt_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

/// Soft top / bottom fade so lines dissolve into the edges.
Widget _edgeFade({required Widget child}) => ShaderMask(
  shaderCallback: (rect) => const LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    // Alpha-only mask; the hue is irrelevant.
    colors: [
      Color(0x00000000),
      Color(0xFF000000),
      Color(0xFF000000),
      Color(0x00000000),
    ],
    stops: [0, 0.12, 0.85, 1],
  ).createShader(rect),
  blendMode: BlendMode.dstIn,
  child: child,
);

/// Shown while the core looks for lyrics (sidecar, tags, then online).
class _Searching extends StatefulWidget {
  const _Searching({super.key});

  @override
  State<_Searching> createState() => _SearchingState();
}

class _SearchingState extends State<_Searching> {
  /// Below this, a spinner would only flicker.
  static const _delay = Duration(milliseconds: 350);

  Timer? _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_delay, () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).colorScheme.onSurface;
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: LekisMotion.normal,
      child: _LyricsState(
        leading: SizedBox.square(
          dimension: LekisSpacing.xl,
          child: CircularProgressIndicator(
            strokeWidth: LekisSpacing.xxs,
            color: fg.withValues(alpha: LekisType.lyricsInactiveOpacity * 2),
          ),
        ),
        title: context.l10n.pick('正在查找歌词…', 'Searching for lyrics…'),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.onSearch,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final VoidCallback? onSearch;

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).colorScheme.onSurface;
    return _LyricsState(
      leading: Icon(
        icon,
        size: LekisSpacing.xxxl,
        color: fg.withValues(alpha: LekisType.lyricsInactiveOpacity),
      ),
      title: title,
      detail: detail,
      action: onSearch == null
          ? null
          : TextButton(
              style: TextButton.styleFrom(foregroundColor: fg),
              onPressed: onSearch,
              child: Text(context.l10n.pick('查找歌词版本', 'Find lyrics versions')),
            ),
    );
  }
}

/// Shared layout of the searching / empty / error states: a 48 dp leading
/// slot, a title and optional detail and action, centred in the pane.
class _LyricsState extends StatelessWidget {
  const _LyricsState({
    required this.leading,
    required this.title,
    this.detail,
    this.action,
  });

  final Widget leading;
  final String title;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSurface;
    final muted = fg.withValues(alpha: LekisType.lyricsInactiveOpacity * 2);
    return Center(
      child: SingleChildScrollView(
        primary: false,
        padding: const EdgeInsets.all(LekisSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: LekisSpacing.xxxl,
              child: Center(child: leading),
            ),
            const SizedBox(height: LekisSpacing.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(color: muted),
            ),
            if (detail != null) ...[
              const SizedBox(height: LekisSpacing.xs),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: fg.withValues(alpha: LekisType.lyricsInactiveOpacity),
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: LekisSpacing.md),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Unsynced lyrics: static, selectable, a little smaller than synced ones.
class _PlainLyrics extends StatelessWidget {
  const _PlainLyrics({super.key, required this.lyrics, required this.style});
  final ParsedLyrics lyrics;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _edgeFade(
      child: SingleChildScrollView(
        primary: false,
        padding: const EdgeInsets.symmetric(
          horizontal: LekisSpacing.xl,
          vertical: LekisSpacing.xxxl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.l10n.pick(
                '歌词未与播放同步',
                'Lyrics are not synced with playback',
              ),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(
                  alpha: LekisType.lyricsInactiveOpacity,
                ),
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: LekisSpacing.md),
            SelectableText(
              lyrics.lines.map((l) => l.text).join('\n'),
              style: lyricTextStyleFor(
                lyrics.lines.map((l) => l.text).join('\n'),
                style.copyWith(
                  fontSize: (style.fontSize ?? 30) * 0.75,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
