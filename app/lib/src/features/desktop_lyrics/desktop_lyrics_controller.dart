// 桌面悬浮歌词控制器与宿主（UIX-07）。
//
// Windows 由 Rust 窗口线程渲染，macOS 使用 AppKit 面板与菜单栏；这里只负责：
// 1. 持久化开关 / 锁定 / 样式 / 各显示器位置（通过核心设置表）；
// 2. 换曲或歌词变化时推一次整首歌词；播放状态 / 进度采样变化时推时钟；
// 3. 接收悬浮窗发回的关闭、锁定、播放控制、位置变化事件。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../rust/api/core.dart' as core;
import '../../rust/api/desktop_lyrics.dart' as bridge;
import '../../rust/api/dto.dart';
import '../now_playing/lyrics_parser.dart';
import '../now_playing/now_playing_providers.dart';
import '../player/player_providers.dart';
import '../sync/sync_providers.dart';

abstract final class DesktopLyricsSettingKeys {
  static const visible = 'desktop_lyrics.visible';
  static const menuBarVisible = 'desktop_lyrics.menu_bar_visible';
  static const locked = 'desktop_lyrics.locked';
  static const twoLine = 'desktop_lyrics.two_line';
  static const fontSize = 'desktop_lyrics.font_size';
  static const opacity = 'desktop_lyrics.opacity';
  static const placements = 'desktop_lyrics.placements';
}

/// 可注入的原生窗口通道（单测替换，不创建真实 Win32 窗口）。
abstract interface class DesktopLyricsGateway {
  bool isSupported();
  bool isMenuBarSupported();
  bool setMenuBarVisible(bool visible);
  bool show();
  void hide();
  void setLocked(bool locked);
  void setStyle(bridge.DesktopLyricsStyleDto style);
  void setLyrics(bridge.DesktopLyricsDocDto doc);
  void setClock(bridge.DesktopLyricsClockDto clock);
  void setPlacements(String json);
  Stream<bridge.DesktopLyricsEventDto> events();
  Future<String?> getSetting(String key);
  Future<void> setSetting(String key, String value);
}

class _BridgeDesktopLyricsGateway implements DesktopLyricsGateway {
  const _BridgeDesktopLyricsGateway();

  @override
  bool isSupported() {
    try {
      return bridge.desktopLyricsIsSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  bool isMenuBarSupported() {
    try {
      return bridge.desktopLyricsIsMenuBarSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  bool setMenuBarVisible(bool visible) =>
      bridge.desktopLyricsSetMenuBarVisible(visible: visible);

  @override
  bool show() => bridge.desktopLyricsShow();

  @override
  void hide() => bridge.desktopLyricsHide();

  @override
  void setLocked(bool locked) => bridge.desktopLyricsSetLocked(locked: locked);

  @override
  void setStyle(bridge.DesktopLyricsStyleDto style) =>
      bridge.desktopLyricsSetStyle(style: style);

  @override
  void setLyrics(bridge.DesktopLyricsDocDto doc) =>
      bridge.desktopLyricsSetLyrics(doc: doc);

  @override
  void setClock(bridge.DesktopLyricsClockDto clock) =>
      bridge.desktopLyricsSetClock(clock: clock);

  @override
  void setPlacements(String json) =>
      bridge.desktopLyricsSetPlacements(json: json);

  @override
  Stream<bridge.DesktopLyricsEventDto> events() => bridge.desktopLyricsEvents();

  @override
  Future<String?> getSetting(String key) => core.getSetting(key: key);

  @override
  Future<void> setSetting(String key, String value) =>
      core.setSetting(key: key, value: value);
}

final desktopLyricsGatewayProvider = Provider<DesktopLyricsGateway>(
  (_) => const _BridgeDesktopLyricsGateway(),
);

/// 当前平台是否支持桌面悬浮歌词。
final desktopLyricsSupportedProvider = Provider<bool>(
  (ref) => ref.watch(desktopLyricsGatewayProvider).isSupported(),
);

final menuBarLyricsSupportedProvider = Provider<bool>(
  (ref) => ref.watch(desktopLyricsGatewayProvider).isMenuBarSupported(),
);

@immutable
class DesktopLyricsState {
  const DesktopLyricsState({
    this.visible = false,
    this.menuBarVisible = false,
    this.locked = false,
    this.twoLine = true,
    this.fontSize = 34,
    this.opacity = 1.0,
    this.initialized = false,
  });

  final bool visible;
  final bool menuBarVisible;
  final bool locked;
  final bool twoLine;
  final double fontSize;
  final double opacity;
  final bool initialized;

  bridge.DesktopLyricsStyleDto toStyleDto({bool nativeMacStyle = false}) =>
      bridge.DesktopLyricsStyleDto(
        fontSize: fontSize,
        fontFamily: '',
        bold: !nativeMacStyle,
        // 月夜高亮紫蓝 + 纯白未唱 + 柔黑描边，与主界面色板呼应。
        sungColor: nativeMacStyle ? 0xFFFFFFFF : 0xFF8B7BFF,
        unsungColor: nativeMacStyle ? 0xA6FFFFFF : 0xFFFFFFFF,
        outlineColor: nativeMacStyle ? 0x90000000 : 0xC8000000,
        opacity: opacity,
        twoLine: twoLine,
      );

  DesktopLyricsState copyWith({
    bool? visible,
    bool? menuBarVisible,
    bool? locked,
    bool? twoLine,
    double? fontSize,
    double? opacity,
    bool? initialized,
  }) => DesktopLyricsState(
    visible: visible ?? this.visible,
    menuBarVisible: menuBarVisible ?? this.menuBarVisible,
    locked: locked ?? this.locked,
    twoLine: twoLine ?? this.twoLine,
    fontSize: fontSize ?? this.fontSize,
    opacity: opacity ?? this.opacity,
    initialized: initialized ?? this.initialized,
  );
}

/// 把 Dart 侧解析好的歌词转成 Rust 悬浮窗文档。
bridge.DesktopLyricsDocDto buildDesktopLyricsDoc({
  required int? trackId,
  required TrackDto? track,
  required ParsedLyrics? lyrics,
}) {
  // AsyncLoading may retain the previous provider value while the next track loads.
  final current = track?.id == trackId ? track : null;
  final title = current?.title ?? '';
  final artist = current?.artists.join(' / ') ?? '';
  if (lyrics == null || !lyrics.synced || lyrics.lines.isEmpty) {
    return bridge.DesktopLyricsDocDto(
      trackId: trackId,
      title: title,
      artist: artist,
      synced: false,
      lines: const [],
    );
  }
  return bridge.DesktopLyricsDocDto(
    trackId: trackId,
    title: title,
    artist: artist,
    synced: true,
    lines: [
      for (final line in lyrics.lines)
        bridge.DesktopLyricsLineDto(
          startMs: line.startMs < 0 ? 0 : line.startMs,
          text: line.text,
          translation: line.translation,
          words: [
            if (line.words != null)
              for (final w in line.words!)
                bridge.DesktopLyricsWordDto(
                  startMs: w.startMs < 0 ? 0 : w.startMs,
                  endMs: w.endMs < 0 ? 0 : w.endMs,
                  text: w.text,
                ),
          ],
        ),
    ],
  );
}

final desktopLyricsProvider =
    NotifierProvider<DesktopLyricsController, DesktopLyricsState>(
      DesktopLyricsController.new,
    );

class DesktopLyricsController extends Notifier<DesktopLyricsState> {
  StreamSubscription<bridge.DesktopLyricsEventDto>? _events;
  Future<void>? _bootstrapFuture;
  int _visibilityRevision = 0;
  int _menuBarRevision = 0;
  int _lockRevision = 0;
  int _placementRevision = 0;

  @override
  DesktopLyricsState build() {
    ref.onDispose(() {
      _events?.cancel();
      _events = null;
    });
    return const DesktopLyricsState();
  }

  Future<void> bootstrap() => _bootstrapFuture ??= _restore();

  Future<void> _restore() async {
    final gw = ref.read(desktopLyricsGatewayProvider);
    if (!gw.isSupported()) return;
    final visibilityRevision = _visibilityRevision;
    final menuBarRevision = _menuBarRevision;
    final lockRevision = _lockRevision;
    final placementRevision = _placementRevision;
    _events?.cancel();
    _events = gw.events().listen(_onNativeEvent);

    final results = await Future.wait([
      gw.getSetting(DesktopLyricsSettingKeys.visible),
      gw.getSetting(DesktopLyricsSettingKeys.locked),
      gw.getSetting(DesktopLyricsSettingKeys.twoLine),
      gw.getSetting(DesktopLyricsSettingKeys.fontSize),
      gw.getSetting(DesktopLyricsSettingKeys.opacity),
      gw.getSetting(DesktopLyricsSettingKeys.placements),
      gw.getSetting(DesktopLyricsSettingKeys.menuBarVisible),
    ]);
    if (!ref.mounted) return;
    final wantVisible = visibilityRevision == _visibilityRevision
        ? results[0] == 'true'
        : state.visible;
    final wantMenuBar = menuBarRevision == _menuBarRevision
        ? results[6] == 'true'
        : state.menuBarVisible;
    final locked = lockRevision == _lockRevision
        ? results[1] == 'true'
        : state.locked;
    final twoLine = results[2] != 'false';
    final fontSize =
        (double.tryParse(results[3] ?? '') ??
                (gw.isMenuBarSupported() ? 26 : 34))
            .clamp(18.0, 60.0);
    final opacity = (double.tryParse(results[4] ?? '') ?? 1.0).clamp(0.4, 1.0);
    final placements = results[5];

    if (placements != null &&
        placements.isNotEmpty &&
        placementRevision == _placementRevision) {
      gw.setPlacements(placements);
    }

    final next = DesktopLyricsState(
      visible: false,
      locked: locked,
      twoLine: twoLine,
      fontSize: fontSize,
      opacity: opacity,
      initialized: true,
    );
    state = next;
    gw.setStyle(next.toStyleDto(nativeMacStyle: gw.isMenuBarSupported()));
    gw.setLocked(locked);

    if (gw.isMenuBarSupported()) {
      state = state.copyWith(menuBarVisible: gw.setMenuBarVisible(wantMenuBar));
    }

    if (wantVisible) {
      final shown = gw.show();
      state = state.copyWith(visible: shown);
    } else {
      gw.hide();
    }
  }

  void _onNativeEvent(bridge.DesktopLyricsEventDto event) {
    if (!ref.mounted) return;
    final gw = ref.read(desktopLyricsGatewayProvider);
    switch (event) {
      case bridge.DesktopLyricsEventDto_VisibilityChanged(:final visible):
        _visibilityRevision++;
        state = state.copyWith(visible: visible);
        unawaited(
          gw.setSetting(
            DesktopLyricsSettingKeys.visible,
            visible ? 'true' : 'false',
          ),
        );
      case bridge.DesktopLyricsEventDto_MenuBarClosed():
        _menuBarRevision++;
        state = state.copyWith(menuBarVisible: false);
        unawaited(
          gw.setSetting(DesktopLyricsSettingKeys.menuBarVisible, 'false'),
        );
      case bridge.DesktopLyricsEventDto_Closed():
        _visibilityRevision++;
        state = state.copyWith(visible: false);
        unawaited(gw.setSetting(DesktopLyricsSettingKeys.visible, 'false'));
      case bridge.DesktopLyricsEventDto_LockChanged(:final locked):
        _lockRevision++;
        state = state.copyWith(locked: locked);
        unawaited(
          gw.setSetting(
            DesktopLyricsSettingKeys.locked,
            locked ? 'true' : 'false',
          ),
        );
      case bridge.DesktopLyricsEventDto_Control(:final action):
        final actions = ref.read(playerActionsProvider);
        switch (action) {
          case bridge.DesktopLyricsControlDto.previous:
            actions.previous();
          case bridge.DesktopLyricsControlDto.playPause:
            actions.playPause();
          case bridge.DesktopLyricsControlDto.next:
            actions.next();
        }
      case bridge.DesktopLyricsEventDto_PlacementChanged(:final json):
        _placementRevision++;
        unawaited(gw.setSetting(DesktopLyricsSettingKeys.placements, json));
    }
  }

  Future<void> setVisible(bool visible) async {
    await bootstrap();
    if (!ref.mounted) return;
    final gw = ref.read(desktopLyricsGatewayProvider);
    if (!gw.isSupported()) return;
    if (visible) {
      gw.setStyle(state.toStyleDto(nativeMacStyle: gw.isMenuBarSupported()));
      gw.setLocked(state.locked);
      final shown = gw.show();
      state = state.copyWith(visible: shown);
      await gw.setSetting(
        DesktopLyricsSettingKeys.visible,
        shown ? 'true' : 'false',
      );
    } else {
      gw.hide();
      state = state.copyWith(visible: false);
      await gw.setSetting(DesktopLyricsSettingKeys.visible, 'false');
    }
  }

  Future<void> toggleVisible() => setVisible(!state.visible);

  Future<void> setMenuBarVisible(bool visible) async {
    await bootstrap();
    if (!ref.mounted) return;
    final gw = ref.read(desktopLyricsGatewayProvider);
    if (!gw.isMenuBarSupported()) return;
    final shown = gw.setMenuBarVisible(visible);
    state = state.copyWith(menuBarVisible: shown);
    await gw.setSetting(
      DesktopLyricsSettingKeys.menuBarVisible,
      shown ? 'true' : 'false',
    );
  }

  Future<void> setLocked(bool locked) async {
    await bootstrap();
    if (!ref.mounted) return;
    final gw = ref.read(desktopLyricsGatewayProvider);
    if (!gw.isSupported()) return;
    gw.setLocked(locked);
    state = state.copyWith(locked: locked);
    await gw.setSetting(
      DesktopLyricsSettingKeys.locked,
      locked ? 'true' : 'false',
    );
  }

  Future<void> setTwoLine(bool twoLine) async {
    await bootstrap();
    if (!ref.mounted) return;
    final gw = ref.read(desktopLyricsGatewayProvider);
    state = state.copyWith(twoLine: twoLine);
    if (gw.isSupported()) {
      gw.setStyle(state.toStyleDto(nativeMacStyle: gw.isMenuBarSupported()));
    }
    await gw.setSetting(
      DesktopLyricsSettingKeys.twoLine,
      twoLine ? 'true' : 'false',
    );
  }

  Future<void> setFontSize(double fontSize, {bool persist = true}) async {
    await bootstrap();
    if (!ref.mounted) return;
    final clamped = fontSize.clamp(18.0, 60.0);
    final gw = ref.read(desktopLyricsGatewayProvider);
    state = state.copyWith(fontSize: clamped);
    if (gw.isSupported()) {
      gw.setStyle(state.toStyleDto(nativeMacStyle: gw.isMenuBarSupported()));
    }
    if (persist) {
      await gw.setSetting(
        DesktopLyricsSettingKeys.fontSize,
        clamped.toStringAsFixed(0),
      );
    }
  }

  Future<void> setOpacity(double opacity, {bool persist = true}) async {
    await bootstrap();
    if (!ref.mounted) return;
    final clamped = opacity.clamp(0.4, 1.0);
    final gw = ref.read(desktopLyricsGatewayProvider);
    state = state.copyWith(opacity: clamped);
    if (gw.isSupported()) {
      gw.setStyle(state.toStyleDto(nativeMacStyle: gw.isMenuBarSupported()));
    }
    if (persist) {
      await gw.setSetting(
        DesktopLyricsSettingKeys.opacity,
        clamped.toStringAsFixed(2),
      );
    }
  }
}

/// 挂在 [AppShell] 里：启动桌面悬浮歌词同步，并在配置了自动同步时触发启动同步。
class DesktopLyricsRuntimeHost extends ConsumerStatefulWidget {
  const DesktopLyricsRuntimeHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<DesktopLyricsRuntimeHost> createState() =>
      _DesktopLyricsRuntimeHostState();
}

class _DesktopLyricsRuntimeHostState
    extends ConsumerState<DesktopLyricsRuntimeHost> {
  bool _autoSynced = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await ref.read(desktopLyricsProvider.notifier).bootstrap();
      if (!mounted || _autoSynced) return;
      _autoSynced = true;
      final sync = await ref.read(syncControllerProvider.future);
      if (mounted && sync.autoOnLaunch && sync.sourceId != null) {
        unawaited(ref.read(syncControllerProvider.notifier).syncNow());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final supported = ref.watch(desktopLyricsSupportedProvider);
    if (!supported) return widget.child;

    final gw = ref.watch(desktopLyricsGatewayProvider);
    final playback = ref.watch(
      playbackProvider.select(
        (s) => (trackId: s.trackId, playing: s.isPlaying),
      ),
    );
    final positionMs = ref.watch(throttledPositionProvider);
    final track = ref.watch(currentTrackProvider).value;
    final lyrics = playback.trackId == null
        ? null
        : ref.watch(lyricsProvider(playback.trackId!)).value;

    gw.setLyrics(
      buildDesktopLyricsDoc(
        trackId: playback.trackId,
        track: track,
        lyrics: lyrics,
      ),
    );
    gw.setClock(
      bridge.DesktopLyricsClockDto(
        trackId: playback.trackId,
        playing: playback.playing,
        positionMs: BigInt.from(positionMs < 0 ? 0 : positionMs),
      ),
    );

    return widget.child;
  }
}
