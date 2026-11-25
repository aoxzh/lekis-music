// Android 桌面播放小组件的数据同步与点按处理。
//
// 画小组件的是原生 LekisPlayerWidget.kt；这里只做两件事：
// 1. 把正在播放的曲目和播放状态经 home_widget 写进 SharedPreferences 并通知刷新；
// 2. 处理点按小组件打开 App 时带来的 `lekis://widget/...` 链接。
// 播放 / 切歌按钮在 App 运行时直接走 audio_service 的媒体按键通道，不经过这里。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import 'package:lekis/src/rust/api/core.dart' as core;

const _provider = 'dev.lekis.lekis.LekisPlayerWidget';

// 键名与 LekisPlayerWidget.kt 保持一致。
const _kHasTrack = 'lekis.widget.hasTrack';
const _kTitle = 'lekis.widget.title';
const _kArtist = 'lekis.widget.artist';
const _kAlbum = 'lekis.widget.album';
const _kArt = 'lekis.widget.art';
const _kPlaying = 'lekis.widget.playing';
const _kPid = 'lekis.widget.pid';

bool get _supported => !kIsWeb && Platform.isAndroid;

/// 播放器 → 小组件。只在内容真的变了时写入，并合并 200 ms 内的连续变化。
class AndroidPlayerWidget {
  AndroidPlayerWidget._();

  static final instance = AndroidPlayerWidget._();

  _Snapshot _pending = const _Snapshot();
  _Snapshot? _written;
  Timer? _flush;

  void setTrack({
    required String title,
    required String artist,
    required String album,
    required String? artPath,
  }) => _set(
    _pending.copyWith(
      hasTrack: true,
      title: title,
      artist: artist,
      album: album,
      artPath: artPath ?? '',
    ),
  );

  void clearTrack() => _set(
    _pending.copyWith(
      hasTrack: false,
      title: '',
      artist: '',
      album: '',
      artPath: '',
      playing: false,
    ),
  );

  void setPlaying(bool playing) => _set(_pending.copyWith(playing: playing));

  /// 进程即将结束（划掉任务）时立刻写入「已暂停」，不等合并计时器。
  Future<void> flushNow() async {
    _flush?.cancel();
    await _write();
  }

  void _set(_Snapshot next) {
    if (!_supported) return;
    _pending = next;
    if (_pending == _written) return;
    _flush?.cancel();
    _flush = Timer(const Duration(milliseconds: 200), () => unawaited(_write()));
  }

  Future<void> _write() async {
    final s = _pending;
    if (s == _written) return;
    try {
      await Future.wait([
        HomeWidget.saveWidgetData<bool>(_kHasTrack, s.hasTrack),
        HomeWidget.saveWidgetData<String>(_kTitle, s.title),
        HomeWidget.saveWidgetData<String>(_kArtist, s.artist),
        HomeWidget.saveWidgetData<String>(_kAlbum, s.album),
        HomeWidget.saveWidgetData<String>(_kArt, s.artPath),
        HomeWidget.saveWidgetData<bool>(_kPlaying, s.playing),
        // 小组件用它判断写数据的播放器进程是否还活着。
        HomeWidget.saveWidgetData<int>(_kPid, pid),
      ]);
      await HomeWidget.updateWidget(qualifiedAndroidName: _provider);
      _written = s;
    } catch (e) {
      debugPrint('home widget: update failed: $e');
    }
  }
}

@immutable
class _Snapshot {
  const _Snapshot({
    this.hasTrack = false,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.artPath = '',
    this.playing = false,
  });

  final bool hasTrack;
  final String title;
  final String artist;
  final String album;
  final String artPath;
  final bool playing;

  _Snapshot copyWith({
    bool? hasTrack,
    String? title,
    String? artist,
    String? album,
    String? artPath,
    bool? playing,
  }) => _Snapshot(
    hasTrack: hasTrack ?? this.hasTrack,
    title: title ?? this.title,
    artist: artist ?? this.artist,
    album: album ?? this.album,
    artPath: artPath ?? this.artPath,
    playing: playing ?? this.playing,
  );

  @override
  bool operator ==(Object other) =>
      other is _Snapshot &&
      other.hasTrack == hasTrack &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.artPath == artPath &&
      other.playing == playing;

  @override
  int get hashCode =>
      Object.hash(hasTrack, title, artist, album, artPath, playing);
}

// ---- 小组件点按 → App ----

final _openNowPlaying = StreamController<void>.broadcast();

/// 点按小组件主体要求打开正在播放页。界面外壳订阅它（需要 BuildContext）。
Stream<void> get homeWidgetOpenRequests => _openNowPlaying.stream;

bool _launchHandling = false;

/// 处理从小组件打开 App 的链接。要在播放会话恢复之后调用，
/// 这样冷启动时点「播放」能直接接着上次的歌放。
Future<void> startHomeWidgetLaunchHandling() async {
  if (!_supported || _launchHandling) return;
  _launchHandling = true;
  try {
    _handleLaunch(await HomeWidget.initiallyLaunchedFromHomeWidget());
    HomeWidget.widgetClicked.listen(
      _handleLaunch,
      onError: (Object e) => debugPrint('home widget: click stream: $e'),
    );
  } catch (e) {
    debugPrint('home widget: launch handling failed: $e');
  }
}

void _handleLaunch(Uri? uri) {
  if (uri == null || uri.scheme != 'lekis' || uri.host != 'widget') return;
  final hasTrack = core.playbackSnapshot().trackId != null;
  switch (uri.path) {
    case '/play':
      if (!hasTrack) return;
      try {
        core.play();
      } catch (e) {
        debugPrint('home widget: play failed: $e');
      }
    case '/open':
      if (hasTrack) _openNowPlaying.add(null);
  }
}

/// 让桌面启动器弹出「添加小组件」确认框（Android 8+，且启动器支持时）。
Future<bool> requestPinPlayerWidget() async {
  if (!_supported) return false;
  try {
    if (await HomeWidget.isRequestPinWidgetSupported() != true) return false;
    await HomeWidget.requestPinWidget(qualifiedAndroidName: _provider);
    return true;
  } catch (e) {
    debugPrint('home widget: pin request failed: $e');
    return false;
  }
}
