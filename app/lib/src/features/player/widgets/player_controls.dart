import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart'
    show formatDuration;
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/lekis_slider.dart';
import 'package:material_ui/material_ui.dart';

/// Whether the platform has its own hardware/system volume UI.
bool get platformHasSystemVolume => UiProfile.current.hasSystemVolume;

const BoxConstraints _touchTarget = BoxConstraints(
  minWidth: LekisSizes.touchTargetMin,
  minHeight: LekisSizes.touchTargetMin,
);

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

/// Media keys for a subtree: Space = play/pause, Ctrl/⌘+←/→ = previous/next,
/// Shift+←/→ = seek ∓10 s, Ctrl/⌘+↑/↓ = volume.
///
/// Text fields swallow Space themselves, so this is safe around search boxes.
/// The shell can wrap its whole body with this for app-wide shortcuts.
class PlayerShortcuts extends ConsumerWidget {
  const PlayerShortcuts({
    super.key,
    required this.child,
    this.autofocus = false,
  });

  final Widget child;
  final bool autofocus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.read(playerActionsProvider);
    void volume(double delta) =>
        actions.setVolume(ref.read(playbackProvider).volume + delta);
    final mod = defaultTargetPlatform == TargetPlatform.macOS
        ? (LogicalKeyboardKey k) => SingleActivator(k, meta: true)
        : (LogicalKeyboardKey k) => SingleActivator(k, control: true);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): actions.playPause,
        const SingleActivator(LogicalKeyboardKey.mediaPlayPause):
            actions.playPause,
        const SingleActivator(LogicalKeyboardKey.mediaTrackNext): actions.next,
        const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious):
            actions.previous,
        mod(LogicalKeyboardKey.arrowRight): actions.next,
        mod(LogicalKeyboardKey.arrowLeft): actions.previous,
        mod(LogicalKeyboardKey.arrowUp): () => volume(0.05),
        mod(LogicalKeyboardKey.arrowDown): () => volume(-0.05),
        const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): () =>
            actions.seekRelative(const Duration(seconds: 10)),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): () =>
            actions.seekRelative(const Duration(seconds: -10)),
      },
      child: Focus(autofocus: autofocus, child: child),
    );
  }
}

// ---------------------------------------------------------------------------
// Buttons
// ---------------------------------------------------------------------------

/// Play / pause with a morphing icon. [filled] draws the big round button.
class PlayPauseButton extends ConsumerWidget {
  const PlayPauseButton({super.key, this.size, this.filled = false});

  final double? size;
  final bool filled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (isPlaying, hasTrack, buffering) = ref.watch(
      playbackProvider.select((s) => (s.isPlaying, s.hasTrack, s.isBuffering)),
    );
    final actions = ref.read(playerActionsProvider);
    final icon = AnimatedSwitcher(
      duration: LekisMotion.fast,
      transitionBuilder: (child, anim) =>
          ScaleTransition(scale: anim, child: child),
      child: Icon(
        isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
        key: ValueKey(isPlaying),
        size: size,
      ),
    );
    final tooltip = isPlaying ? '暂停' : '播放';
    final onPressed = hasTrack ? actions.playPause : null;
    final button = filled
        ? IconButton.filled(
            tooltip: tooltip,
            onPressed: onPressed,
            // Filled play button: the accent disc comes from the variant, but
            // the icon must be onPrimary (the theme's plain icon colour would
            // sit on the filled disc and disappear in the light theme).
            style: IconButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
            ),
            constraints: _touchTarget,
            iconSize: size,
            icon: icon,
          )
        : IconButton(
            tooltip: tooltip,
            onPressed: onPressed,
            constraints: _touchTarget,
            iconSize: size,
            icon: icon,
          );
    if (!buffering) return button;
    return Stack(
      alignment: Alignment.center,
      children: [
        button,
        IgnorePointer(
          child: SizedBox.square(
            dimension: (size ?? LekisSpacing.xl) + LekisSpacing.xl,
            child: const CircularProgressIndicator(
              strokeWidth: LekisSpacing.xxs,
            ),
          ),
        ),
      ],
    );
  }
}

class NextButton extends ConsumerWidget {
  const NextButton({super.key, this.size});
  final double? size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(playbackProvider.select((s) => s.hasTrack));
    return IconButton(
      tooltip: '下一首',
      constraints: _touchTarget,
      iconSize: size,
      onPressed: enabled ? ref.read(playerActionsProvider).next : null,
      icon: const Icon(Icons.skip_next_rounded),
    );
  }
}

class PreviousButton extends ConsumerWidget {
  const PreviousButton({super.key, this.size});
  final double? size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(playbackProvider.select((s) => s.canGoPrevious));
    return IconButton(
      tooltip: '上一首',
      constraints: _touchTarget,
      iconSize: size,
      onPressed: enabled ? ref.read(playerActionsProvider).previous : null,
      icon: const Icon(Icons.skip_previous_rounded),
    );
  }
}

class ShuffleButton extends ConsumerWidget {
  const ShuffleButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(
      playbackProvider.select((s) => s.shuffle != ShuffleModeDto.off),
    );
    // Same on/off rule as [RepeatButton]: the theme paints the disc and the
    // selected colour, the widget only swaps the glyph.
    return IconButton(
      tooltip: on ? '关闭随机播放' : '随机播放',
      isSelected: on,
      constraints: _touchTarget,
      onPressed: ref.read(playerActionsProvider).toggleShuffle,
      icon: const Icon(Icons.shuffle_rounded),
      selectedIcon: const Icon(Icons.shuffle_on_rounded),
    );
  }
}

class RepeatButton extends ConsumerWidget {
  const RepeatButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(playbackProvider.select((s) => s.repeat));
    final on = mode != RepeatModeDto.off;
    final (icon, selectedIcon, tip) = switch (mode) {
      RepeatModeDto.off => (
        Icons.repeat_rounded,
        Icons.repeat_on_rounded,
        '列表循环',
      ),
      RepeatModeDto.all => (
        Icons.repeat_on_rounded,
        Icons.repeat_one_on_rounded,
        '单曲循环',
      ),
      RepeatModeDto.one => (
        Icons.repeat_one_on_rounded,
        Icons.repeat_rounded,
        '关闭循环',
      ),
    };
    return IconButton(
      tooltip: tip,
      isSelected: on,
      constraints: _touchTarget,
      onPressed: ref.read(playerActionsProvider).cycleRepeat,
      icon: Icon(icon),
      selectedIcon: Icon(selectedIcon),
    );
  }
}

/// Shuffle · previous · play/pause · next · repeat.
class TransportControls extends StatelessWidget {
  const TransportControls({
    super.key,
    this.large = false,
    this.showModes = true,
  });

  final bool large;
  final bool showModes;

  @override
  Widget build(BuildContext context) {
    final skip = large ? LekisSpacing.xxl + LekisSpacing.xs : null;
    final play = large ? LekisSpacing.xxxl : LekisSpacing.xl + LekisSpacing.xs;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (showModes) const ShuffleButton(),
        if (showModes)
          SizedBox(width: large ? LekisSpacing.lg : LekisSpacing.xs),
        PreviousButton(size: skip),
        SizedBox(width: large ? LekisSpacing.lg : LekisSpacing.xs),
        PlayPauseButton(size: play, filled: true),
        SizedBox(width: large ? LekisSpacing.lg : LekisSpacing.xs),
        NextButton(size: skip),
        if (showModes)
          SizedBox(width: large ? LekisSpacing.lg : LekisSpacing.xs),
        if (showModes) const RepeatButton(),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Seek bar
// ---------------------------------------------------------------------------

/// Seek slider with elapsed / remaining times.
///
/// Watches only [throttledPositionProvider], so it rebuilds a few times per
/// second at most; while dragging it shows the local drag value.
class SeekBar extends ConsumerStatefulWidget {
  const SeekBar({super.key, this.inlineTimes = false});

  /// `true`: `0:12 ───●─── 3:45` on one row (desktop bar).
  /// `false`: times below the slider (Now Playing).
  final bool inlineTimes;

  @override
  ConsumerState<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<SeekBar> {
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    final duration = ref.watch(playbackProvider.select((s) => s.durationMs));
    final position = ref.watch(throttledPositionProvider);
    final shown = (_dragMs ?? position.toDouble()).clamp(
      0.0,
      duration > 0 ? duration.toDouble() : 0.0,
    );
    final theme = Theme.of(context);
    final timeStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: LekisText.tabularFigures,
    );

    final slider = LekisSlider(
      value: shown,
      max: duration > 0 ? duration.toDouble() : 1,
      semanticFormatterCallback: (v) =>
          '${formatDuration(v.round())} / ${formatDuration(duration)}',
      onChangeStart: duration > 0 ? (v) => setState(() => _dragMs = v) : null,
      onChanged: duration > 0 ? (v) => setState(() => _dragMs = v) : null,
      onChangeEnd: duration > 0
          ? (v) {
              ref.read(playerActionsProvider).seek(v.round());
              setState(() => _dragMs = null);
            }
          : null,
      trackHeight: LekisSliderGeometry.track,
      thumbRadius: _dragMs != null
          ? LekisSliderGeometry.thumbDragging
          : LekisSliderGeometry.thumb,
      overlayRadius: widget.inlineTimes
          ? LekisSliderGeometry.overlayDense
          : LekisSliderGeometry.overlay,
      dense: widget.inlineTimes,
    );

    final elapsed = Text(formatDuration(shown.round()), style: timeStyle);
    final remaining = Text(
      duration > 0 ? '-${formatDuration(duration - shown.round())}' : '--:--',
      style: timeStyle,
    );

    if (widget.inlineTimes) {
      // Fixed-width time labels with a gap, so the thumb never runs into the
      // text and the track doesn't jitter as the digits change.
      const timeWidth = LekisSpacing.xxxl;
      return Row(
        children: [
          SizedBox(
            width: timeWidth,
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: elapsed,
            ),
          ),
          const SizedBox(width: LekisSpacing.md),
          Expanded(child: slider),
          const SizedBox(width: LekisSpacing.md),
          SizedBox(
            width: timeWidth,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: remaining,
            ),
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        slider,
        Padding(
          // Same inset as the slider's overlay radius, so the times line up
          // with the track ends (and with the Now Playing title above).
          padding: const EdgeInsets.symmetric(
            horizontal: LekisSizes.touchTargetMin / 2,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [elapsed, remaining],
          ),
        ),
      ],
    );
  }
}

/// Thin, non-interactive progress line (mini player).
class ThinProgressBar extends ConsumerWidget {
  const ThinProgressBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(progressProvider);
    final colors = context.lekisColors;
    return LinearProgressIndicator(
      value: progress,
      minHeight: LekisSpacing.xxs,
      color: colors.accent,
      backgroundColor: colors.outline,
    );
  }
}

// ---------------------------------------------------------------------------
// Volume
// ---------------------------------------------------------------------------

class VolumeControl extends ConsumerStatefulWidget {
  const VolumeControl({super.key, this.width, this.showSlider = true});

  final double? width;

  /// `false` keeps only the mute button (narrow desktop windows).
  final bool showSlider;

  @override
  ConsumerState<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends ConsumerState<VolumeControl> {
  double _beforeMute = 1;

  @override
  Widget build(BuildContext context) {
    final volume = ref.watch(playbackProvider.select((s) => s.volume));
    final actions = ref.read(playerActionsProvider);
    final icon = volume == 0
        ? Icons.volume_off_rounded
        : volume < 0.5
        ? Icons.volume_down_rounded
        : Icons.volume_up_rounded;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: volume == 0 ? '取消静音' : '静音',
          constraints: _touchTarget,
          onPressed: () {
            if (volume == 0) {
              actions.setVolume(_beforeMute > 0 ? _beforeMute : 1);
            } else {
              _beforeMute = volume;
              actions.setVolume(0);
            }
          },
          icon: Icon(icon),
        ),
        if (widget.showSlider)
          SizedBox(
            width: widget.width ?? LekisSizes.gridArtworkMin * 0.75,
            child: LekisSlider(
              value: volume.clamp(0.0, 1.0),
              semanticFormatterCallback: (v) => '音量 ${(v * 100).round()}%',
              onChanged: actions.setVolume,
              trackHeight: LekisSliderGeometry.track,
            ),
          ),
      ],
    );
  }
}
