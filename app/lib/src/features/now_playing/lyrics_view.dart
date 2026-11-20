import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/now_playing/lyrics_editor_sheet.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/features/now_playing/lyrics_stage.dart';
import 'package:lekis/src/features/now_playing/lyrics_stage_settings.dart';
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Lyrics for [trackId]: a word-by-word stage, plain text, or an empty state.
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
    final trackId = this.trackId;
    if (trackId == null) {
      return const _Message(
        key: ValueKey('idle'),
        icon: Icons.lyrics_outlined,
        title: '暂无歌词',
        detail: '开始播放后会在这里显示歌词',
      );
    }
    final lyrics = ref.watch(lyricsProvider(trackId));
    final stageStyle = ref.watch(lyricsStageStyleProvider);
    final sparks = ref.watch(lyricsSparksProvider);
    final theme = Theme.of(context);
    final Widget body = lyrics.when(
      // An online lookup can take a few seconds; local ones are instant, so
      // the searching state only appears after a short pause.
      loading: () => const _Searching(key: ValueKey('loading')),
      error: (e, _) => _Message(
        key: const ValueKey('error'),
        icon: Icons.lyrics_outlined,
        title: '暂无歌词',
        detail: '查找歌词时出了点问题',
        onRetry: () => ref.invalidate(lyricsProvider(trackId)),
      ),
      data: (parsed) {
        // Lyrics made only of blank / instrumental lines would render as an
        // empty stage.
        if (parsed == null || parsed.lines.every((l) => l.isInstrumental)) {
          return const _Message(
            key: ValueKey('empty'),
            icon: Icons.lyrics_outlined,
            title: '暂无歌词',
            detail: '本地文件和在线都没有找到这首歌的歌词',
          );
        }
        final base = LekisText.lyricsActive.copyWith(
          color: theme.colorScheme.onSurface,
        );
        final style = compact
            ? base.copyWith(fontSize: (base.fontSize ?? 30) * 0.8)
            : base;
        if (!parsed.synced) {
          return _PlainLyrics(
            key: const ValueKey('plain'),
            lyrics: parsed,
            style: style.copyWith(fontWeight: FontWeight.w600),
          );
        }
        return LyricsStage(
          key: ValueKey('stage-$trackId'),
          lyrics: parsed,
          style: stageStyle,
          sparks: sparks,
          baseStyle: style,
          compact: compact,
          lowPower: lowPower,
        );
      },
    );
    // Searching → lyrics / empty cross-fades instead of popping in.
    return Stack(
      children: [
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: LekisMotion.normal,
            layoutBuilder: (current, previous) =>
                Stack(fit: StackFit.expand, children: [...previous, ?current]),
            child: body,
          ),
        ),
        Positioned(
          top: LekisSpacing.xs,
          right: LekisSpacing.xs,
          child: IconButton.filledTonal(
            tooltip: '编辑歌词',
            onPressed: () => showLyricsEditor(context, ref, trackId),
            icon: const Icon(Icons.edit_note, size: 20),
          ),
        ),
      ],
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
        title: '正在查找歌词…',
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
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final VoidCallback? onRetry;

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
      action: onRetry == null
          ? null
          : TextButton(
              style: TextButton.styleFrom(foregroundColor: fg),
              onPressed: onRetry,
              child: const Text('重试'),
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
              '歌词未与播放同步',
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
              style: style.copyWith(
                fontSize: (style.fontSize ?? 30) * 0.75,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
