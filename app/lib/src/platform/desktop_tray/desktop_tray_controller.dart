// Windows notification-area icon and window close behaviour.
//
// The tray menu mirrors [playbackProvider] instead of keeping its own state:
// every label comes from the same core events that drive the in-app transport
// controls, so "暂停" can only appear while the core reports playing.
//
// Only Windows is wired here. Android keeps using audio_service and never
// creates these native objects.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/player/playback_session.dart';
import '../../features/player/player_providers.dart';
import '../../features/settings/desktop_tray_settings.dart';
import '../../rust/api/core.dart' as core;
import 'desktop_tray_menu_state.dart';

const String _trayIconAsset = 'assets/brand/tray_icon.ico';
const String _trayTooltip = 'Lekis Music';

bool get _desktopTraySupported => !kIsWeb && Platform.isWindows;

/// One controller owns the native tray icon, its menu and the window close
/// hook. It is created from [desktopTrayControllerProvider].
class DesktopTrayController {
  DesktopTrayController(this._ref);

  final Ref _ref;

  TrayIcon? _trayIcon;
  Image? _trayImage;
  MenuItem? _playPauseItem;
  MenuItem? _previousItem;
  MenuItem? _nextItem;

  int? _trackId;
  int _tooltipGeneration = 0;
  String? _nowPlayingLabel;

  Window? _window;
  int? _closeListener;
  bool _retryScheduled = false;
  bool _creating = false;
  bool _quitting = false;
  bool _disposed = false;

  DesktopTrayMenuState _menuState = const DesktopTrayMenuState(
    isPlaying: false,
    hasTrack: false,
  );

  bool get isActive => _trayIcon != null;

  /// Installs the close hook synchronously so the very first Alt+F4 / close
  /// click already respects "close to tray".
  void installCloseHandler() {
    if (!_desktopTraySupported || _disposed || _closeListener != null) return;
    final window = WindowManager.instance.getCurrent();
    if (window == null) {
      if (!_retryScheduled) {
        _retryScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _retryScheduled = false;
          installCloseHandler();
        });
      }
      return;
    }
    _window = window;
    _closeListener = window.addListener(_onWindowEvent);
  }

  Future<void> initialize() async {
    if (!_desktopTraySupported || _disposed) return;
    installCloseHandler();
    updatePlayback(_ref.read(playbackProvider));
    await applySettings(_ref.read(desktopTraySettingsProvider));
  }

  void updatePlayback(PlaybackUiState playback) {
    _menuState = DesktopTrayMenuState.fromPlayback(playback);
    _applyMenuState();
    if (!_desktopTraySupported) return;
    if (playback.trackId != _trackId) {
      _trackId = playback.trackId;
      unawaited(_refreshNowPlaying(playback.trackId));
    }
  }

  Future<void> _refreshNowPlaying(int? trackId) async {
    final generation = ++_tooltipGeneration;
    if (trackId == null) {
      _nowPlayingLabel = null;
      _applyTooltip();
      return;
    }
    try {
      final track = await core.getTrack(trackId: trackId);
      if (_disposed || generation != _tooltipGeneration) return;
      final artists = track.artists.join(' / ');
      _nowPlayingLabel = artists.isEmpty
          ? track.title
          : '${track.title} — $artists';
    } catch (error) {
      if (_disposed || generation != _tooltipGeneration) return;
      debugPrint('desktop tray: track label failed: $error');
      _nowPlayingLabel = null;
    }
    _applyTooltip();
  }

  String get _tooltipText {
    final label = _nowPlayingLabel;
    if (label == null || label.isEmpty) return _trayTooltip;
    final text = '$label · $_trayTooltip';
    return text.length <= 120 ? text : '${text.substring(0, 119)}…';
  }

  void _applyTooltip() {
    _trayIcon?.setTooltip(_tooltipText);
  }

  Future<void> applySettings(DesktopTraySettings settings) async {
    if (!_desktopTraySupported || _disposed) return;
    if (!settings.trayEnabled) {
      _disposeTray();
      return;
    }
    if (_trayIcon != null || _creating) return;
    _creating = true;
    try {
      await _createTray();
    } finally {
      _creating = false;
    }
    // The setting may have been switched off while the native icon was being
    // created.
    if (!_ref.read(desktopTraySettingsProvider).trayEnabled) {
      _disposeTray();
    }
  }

  Future<void> _createTray() async {
    try {
      final icon = TrayIcon.create();
      if (icon == null) throw StateError('TrayIcon.create() returned null');
      final image = ImageAsset.fromAsset(_trayIconAsset);
      if (image == null) {
        icon.dispose();
        throw StateError('tray icon asset missing: $_trayIconAsset');
      }
      final menu = _buildMenu();
      if (menu == null) {
        image.dispose();
        icon.dispose();
        throw StateError('could not build the tray menu');
      }

      _trayIcon = icon;
      _trayImage = image;
      _applyMenuState();

      icon.icon = image;
      _applyTooltip();
      icon.setContextMenu(menu);
      icon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
      icon.setVisible(true);
      icon.addListener((event) {
        if (event is TrayIconDoubleClickedEvent) _showWindow();
      });
    } catch (error, stack) {
      debugPrint('desktop tray: failed to create icon: $error\n$stack');
      _disposeTray();
    }
  }

  Menu? _buildMenu() {
    final menu = Menu.create();
    if (menu == null) return null;

    MenuItem? item(String label, void Function() action) {
      final entry = MenuItem.createWithLabelAndType(label, MenuItemType.normal);
      if (entry == null) return null;
      entry.addListener((event) {
        if (event is MenuItemClickedEvent) action();
      });
      return entry;
    }

    final window = item(_menuState.windowLabel, _toggleWindow);
    final playPause = item(_menuState.playPauseLabel, _playPause);
    final previous = item(_menuState.previousLabel, _previous);
    final next = item(_menuState.nextLabel, _next);
    final quit = item(_menuState.quitLabel, () => unawaited(quitApp()));
    if (window == null ||
        playPause == null ||
        previous == null ||
        next == null ||
        quit == null) {
      return null;
    }

    _playPauseItem = playPause;
    _previousItem = previous;
    _nextItem = next;

    menu.addItem(window);
    menu.addSeparator();
    menu.addItem(playPause);
    menu.addItem(previous);
    menu.addItem(next);
    menu.addSeparator();
    menu.addItem(quit);
    return menu;
  }

  void _applyMenuState() {
    final state = _menuState;
    _playPauseItem
      ?..label = state.playPauseLabel
      ..isEnabled = state.mediaEnabled;
    _previousItem?.isEnabled = state.mediaEnabled;
    _nextItem?.isEnabled = state.mediaEnabled;
  }

  void _onWindowEvent(WindowEvent event) {
    if (event is! WindowCloseRequestedEvent) return;
    if (_quitting || _disposed) return;
    final settings = _ref.read(desktopTraySettingsProvider);
    if (!settings.trayEnabled || !settings.closeToTray || _trayIcon == null) {
      // Closing the window is the only way out when there is no tray icon.
      return;
    }
    event.request.cancel();
    _ref.read(playbackSessionProvider).scheduleSave(delay: Duration.zero);
    _window?.hide();
  }

  void _toggleWindow() {
    final window = _window ?? WindowManager.instance.getCurrent();
    if (window == null) return;
    _window = window;
    if (window.isVisible && !window.isMinimized) {
      window.hide();
    } else {
      _showWindow();
    }
  }

  void _showWindow() {
    final window = _window ?? WindowManager.instance.getCurrent();
    if (window == null) return;
    _window = window;
    if (window.isMinimized) window.restore();
    if (!window.isVisible) window.show();
    window.focus();
  }

  void _playPause() {
    if (!_ref.read(playbackProvider).hasTrack) return;
    _ref.read(playerActionsProvider).playPause();
  }

  void _previous() {
    if (!_ref.read(playbackProvider).hasTrack) return;
    _ref.read(playerActionsProvider).previous();
  }

  void _next() {
    if (!_ref.read(playbackProvider).hasTrack) return;
    _ref.read(playerActionsProvider).next();
  }

  /// Stops audio, saves the session and really closes the process. A short
  /// fallback exit covers a runner that declines the close request.
  Future<void> quitApp() async {
    if (_quitting || _disposed) return;
    _quitting = true;
    try {
      _ref.read(playerActionsProvider).pause();
    } catch (error) {
      debugPrint('desktop tray: pause on quit failed: $error');
    }
    try {
      await _ref
          .read(playbackSessionProvider)
          .saveNow()
          .timeout(const Duration(seconds: 2));
    } catch (error) {
      debugPrint('desktop tray: save on quit failed: $error');
    }
    _disposeTray();
    final window = _window ?? WindowManager.instance.getCurrent();
    try {
      if (window != null) {
        window.close();
      } else {
        exit(0);
      }
    } catch (error) {
      debugPrint('desktop tray: window close failed: $error');
      exit(0);
    }
    Timer(const Duration(seconds: 3), () => exit(0));
  }

  void _disposeTray() {
    final icon = _trayIcon;
    final image = _trayImage;
    _trayIcon = null;
    _trayImage = null;
    _playPauseItem = null;
    _previousItem = null;
    _nextItem = null;
    image?.dispose();
    icon?.setContextMenu(null);
    icon?.dispose();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final listener = _closeListener;
    if (listener != null) {
      _window?.removeListener(listener);
      _closeListener = null;
    }
    _disposeTray();
  }
}

final desktopTrayControllerProvider = Provider<DesktopTrayController>((ref) {
  final controller = DesktopTrayController(ref);
  ref.onDispose(controller.dispose);
  ref.listen<PlaybackUiState>(
    playbackProvider,
    (_, next) => controller.updatePlayback(next),
  );
  ref.listen<DesktopTraySettings>(
    desktopTraySettingsProvider,
    (_, next) => unawaited(controller.applySettings(next)),
  );
  controller.installCloseHandler();
  return controller;
});
