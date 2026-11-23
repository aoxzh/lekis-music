// Desktop mini player mode: the main window shrinks into a small,
// always-on-top, frameless strip that only shows the playing track and the
// transport controls, and grows back into the full window on demand.
//
// It is the same window and the same Flutter tree, so playback state,
// controllers and keyboard shortcuts are shared with the full UI; only the
// window geometry and the root view change (see [MiniModeHost]).
//
// The mini window's position is stored in the core settings table and
// reused next time, as long as it still lands on a connected display.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nativeapi/nativeapi.dart' as na show DisplayManager;
import 'package:window_manager/window_manager.dart';

import '../../platform/ui_profile.dart';
import '../../rust/api/core.dart' as core;

abstract final class MiniModeSettingKeys {
  /// `x,y` of the mini window's top-left corner, in logical screen pixels.
  static const position = 'desktop.mini_player.position';
}

/// Logical size of the mini window (content + invisible resize border).
const Size kMiniWindowSize = Size(380, 116);

/// Gap between the mini window and the work-area edge when there is no
/// remembered position.
const double _kEdgeGap = 24;

/// What the window looked like before it turned into the mini player.
@immutable
class FullWindowSnapshot {
  const FullWindowSnapshot({
    required this.bounds,
    required this.maximized,
    this.fullScreen = false,
    required this.alwaysOnTop,
    required this.resizable,
    required this.maximizable,
    required this.titleBarHidden,
    required this.minimumSize,
  });

  final Rect bounds;
  final bool maximized;
  final bool fullScreen;
  final bool alwaysOnTop;
  final bool resizable;
  final bool maximizable;
  final bool titleBarHidden;
  final Size minimumSize;
}

/// The native side of mini mode. Swapped for a fake in tests, so no real
/// window is touched there.
abstract interface class MiniWindowGateway {
  /// A native window exists and can be reshaped.
  bool get isAvailable;

  Future<FullWindowSnapshot> capture();

  /// Work areas (screen minus task bar) of the connected displays.
  List<Rect> workAreas();

  Future<void> applyMini(Rect bounds);

  Future<void> restore(FullWindowSnapshot snapshot);

  Rect? currentBounds();

  void startDragging();

  /// Calls [onMoved] with the window's new bounds whenever it is moved;
  /// returns a function that stops listening.
  VoidCallback listenMoves(void Function(Rect bounds) onMoved);

  Future<String?> getSetting(String key);

  Future<void> setSetting(String key, String value);
}

/// Picks the mini window's bounds: the remembered position if the window
/// still fits on a display there, otherwise the bottom-right corner of the
/// display the full window is on.
Rect placeMiniWindow({
  required Offset? saved,
  required Rect fullBounds,
  required List<Rect> workAreas,
  Size size = kMiniWindowSize,
}) {
  if (saved != null) {
    final rect = saved & size;
    // At least most of the strip must be on screen, or the user cannot grab
    // it back (a monitor may have been unplugged since).
    for (final area in workAreas) {
      final overlap = area.intersect(rect);
      if (overlap.width >= size.width * 0.6 &&
          overlap.height >= size.height * 0.6) {
        return rect;
      }
    }
  }
  final center = fullBounds.center;
  final area = workAreas.firstWhere(
    (a) => a.contains(center),
    orElse: () => workAreas.isNotEmpty ? workAreas.first : fullBounds,
  );
  return Offset(
        area.right - size.width - _kEdgeGap,
        area.bottom - size.height - _kEdgeGap,
      ) &
      size;
}

/// Parses the stored `x,y` position.
Offset? parseMiniPosition(String? raw) {
  if (raw == null) return null;
  final parts = raw.split(',');
  if (parts.length != 2) return null;
  final x = double.tryParse(parts[0].trim());
  final y = double.tryParse(parts[1].trim());
  if (x == null || y == null || !x.isFinite || !y.isFinite) return null;
  return Offset(x, y);
}

String encodeMiniPosition(Offset position) =>
    '${position.dx.round()},${position.dy.round()}';

class _NativeMiniWindowGateway implements MiniWindowGateway {
  _NativeMiniWindowGateway();

  static const MethodChannel _runner = MethodChannel('lekis/window');

  Window? _cached;

  /// The app's main window, remembered once found.
  ///
  /// Only `getCurrent()` is trusted: it is Win32 `GetActiveWindow()`, which
  /// answers for this thread's own window and nothing else. It is null while
  /// the app is not active, but mini mode is only ever entered from a click
  /// inside the app. `getAll()` must not be used here: on Windows it lists
  /// every visible top-level window on the desktop, other apps' included.
  Window? get _window {
    final cached = _cached;
    if (cached != null) return cached;
    try {
      return _cached = WindowManager.instance.getCurrent();
    } catch (_) {
      return null;
    }
  }

  // Deliberately does not resolve the window: at the first frame the window
  // is not shown (so not active) yet.
  @override
  bool get isAvailable =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  @override
  Future<FullWindowSnapshot> capture() async {
    final w = _window;
    if (w == null) throw StateError('the app window is not active');
    final fullScreen = w.isFullScreen;
    // AppKit leaves fullscreen asynchronously. Wait for its completion before
    // reading the restored normal frame or changing style/size constraints.
    if (fullScreen) await _setFullScreen(w, false);
    return FullWindowSnapshot(
      bounds: w.bounds.toRect(),
      maximized: w.isMaximized,
      fullScreen: fullScreen,
      alwaysOnTop: w.isAlwaysOnTop,
      resizable: w.isResizable,
      maximizable: w.isMaximizable,
      titleBarHidden: w.titleBarStyle == TitleBarStyle.hidden,
      minimumSize: w.minimumSize.toSize(),
    );
  }

  Future<void> _setFullScreen(Window window, bool fullScreen) async {
    if (window.isFullScreen == fullScreen) return;
    if (!Platform.isMacOS) {
      window.isFullScreen = fullScreen;
      return;
    }
    final finished = Completer<void>();
    final listener = window.addListener((event) {
      if ((fullScreen && event is WindowEnteredFullScreenEvent) ||
          (!fullScreen && event is WindowExitedFullScreenEvent)) {
        if (!finished.isCompleted) finished.complete();
      }
    });
    try {
      window.isFullScreen = fullScreen;
      await finished.future.timeout(const Duration(seconds: 5));
    } finally {
      window.removeListener(listener);
    }
  }

  @override
  List<Rect> workAreas() {
    try {
      return [
        for (final d in na.DisplayManager.instance.getAll())
          d.workArea.toRect(),
      ];
    } catch (error) {
      debugPrint('mini mode: reading displays failed: $error');
      return const [];
    }
  }

  /// The Windows runner enforces its own minimum client size for the full
  /// shell layout; lift it while the window is the mini player.
  Future<void> _setRunnerCompact(bool compact) async {
    if (!Platform.isWindows) return;
    try {
      await _runner.invokeMethod<void>('setCompactWindow', compact);
    } catch (_) {
      // Older runner: the native minimum just stays in place.
    }
  }

  @override
  Future<void> applyMini(Rect bounds) async {
    final w = _window;
    if (w == null) throw StateError('the app window is unavailable');
    await _setFullScreen(w, false);
    if (w.isMaximized) w.unmaximize();
    await _setRunnerCompact(true);
    w.minimumSize = const Size(200, 72).toNative();
    w.isMaximizable = false;
    w.titleBarStyle = TitleBarStyle.hidden;
    w.isResizable = false;
    w.bounds = bounds.toNative();
    w.isAlwaysOnTop = true;
    if (w.isMinimized) w.restore();
    if (!w.isVisible) w.show();
  }

  @override
  Future<void> restore(FullWindowSnapshot snapshot) async {
    final w = _window;
    if (w == null) throw StateError('the app window is unavailable');
    w.isAlwaysOnTop = snapshot.alwaysOnTop;
    w.isResizable = snapshot.resizable;
    w.titleBarStyle = snapshot.titleBarHidden
        ? TitleBarStyle.hidden
        : TitleBarStyle.normal;
    w.isMaximizable = snapshot.maximizable;
    await _setRunnerCompact(false);
    w.minimumSize = snapshot.minimumSize.toNative();
    w.bounds = snapshot.bounds.toNative();
    if (snapshot.maximized) w.maximize();
    if (w.isMinimized) w.restore();
    if (!w.isVisible) w.show();
    w.focus();
    if (snapshot.fullScreen) await _setFullScreen(w, true);
  }

  @override
  Rect? currentBounds() => _window?.bounds.toRect();

  @override
  void startDragging() => _window?.startDragging();

  @override
  VoidCallback listenMoves(void Function(Rect bounds) onMoved) {
    final w = _window;
    if (w == null) return () {};
    final id = w.addListener((event) {
      if (event is WindowMovedEvent) onMoved(w.bounds.toRect());
    });
    return () => w.removeListener(id);
  }

  @override
  Future<String?> getSetting(String key) => core.getSetting(key: key);

  @override
  Future<void> setSetting(String key, String value) =>
      core.setSetting(key: key, value: value);
}

final miniWindowGatewayProvider = Provider<MiniWindowGateway>(
  (ref) => _NativeMiniWindowGateway(),
);

/// Mini mode exists on desktop windows only; phones and tablets never see
/// the toggle.
final miniModeSupportedProvider = Provider<bool>((ref) {
  if (!UiProfile.current.isDesktop) return false;
  return ref.watch(miniWindowGatewayProvider).isAvailable;
});

final miniModeProvider = NotifierProvider<MiniModeController, bool>(
  MiniModeController.new,
);

/// `true` while the window is the mini player.
class MiniModeController extends Notifier<bool> {
  FullWindowSnapshot? _full;
  VoidCallback? _stopListening;
  Timer? _saveTimer;
  Offset? _pendingPosition;
  bool _busy = false;

  MiniWindowGateway get _gateway => ref.read(miniWindowGatewayProvider);

  @override
  bool build() {
    ref.onDispose(() {
      _stopListening?.call();
      _stopListening = null;
      _saveTimer?.cancel();
    });
    return false;
  }

  Future<void> toggle() => state ? exit() : enter();

  Future<void> enter() async {
    if (state || _busy || !ref.read(miniModeSupportedProvider)) return;
    _busy = true;
    try {
      final gateway = _gateway;
      final full = await gateway.capture();
      _full = full;
      Offset? saved;
      try {
        saved = parseMiniPosition(
          await gateway.getSetting(MiniModeSettingKeys.position),
        );
      } catch (error) {
        debugPrint('mini mode: reading position failed: $error');
      }
      final bounds = placeMiniWindow(
        saved: saved,
        fullBounds: full.bounds,
        workAreas: gateway.workAreas(),
      );
      // Switch the view first so the first small frame already is the mini
      // player rather than a squashed full layout.
      state = true;
      await gateway.applyMini(bounds);
      _stopListening = gateway.listenMoves(_onMoved);
    } catch (error, stack) {
      debugPrint('mini mode: enter failed: $error\n$stack');
      await _restoreFull();
    } finally {
      _busy = false;
    }
  }

  Future<void> exit() async {
    if (!state || _busy) return;
    _busy = true;
    try {
      final bounds = _gateway.currentBounds();
      if (bounds != null) _pendingPosition = bounds.topLeft;
      await _flushPosition();
      await _restoreFull();
    } finally {
      _busy = false;
    }
  }

  Future<void> _restoreFull() async {
    _stopListening?.call();
    _stopListening = null;
    final full = _full;
    try {
      if (full != null) await _gateway.restore(full);
      _full = null;
      state = false;
    } catch (error, stack) {
      debugPrint('mini mode: restore failed: $error\n$stack');
      // Keep the expand button and snapshot so a temporary native failure can
      // be retried instead of stranding the full UI in a tiny window.
      state = full != null;
      if (state) _stopListening = _gateway.listenMoves(_onMoved);
    }
  }

  void _onMoved(Rect bounds) {
    if (!state) return;
    _pendingPosition = bounds.topLeft;
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 400),
      () => unawaited(_flushPosition()),
    );
  }

  Future<void> _flushPosition() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final position = _pendingPosition;
    _pendingPosition = null;
    if (position == null) return;
    try {
      await _gateway.setSetting(
        MiniModeSettingKeys.position,
        encodeMiniPosition(position),
      );
    } catch (error) {
      debugPrint('mini mode: saving position failed: $error');
    }
  }
}
