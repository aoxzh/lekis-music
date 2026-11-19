//! 系统媒体控件（锁屏 / 系统媒体浮窗 / 媒体键）。

use flutter_rust_bridge::frb;

/// 在桌面端（Windows SMTC / macOS Now Playing / Linux MPRIS）启用系统媒体控件。
///
/// 在 `init_core` 之后调用一次；重复调用无害。返回是否已启用
/// （核心未初始化或在 Android / iOS 上返回 `false`，移动端由 Dart 侧的 audio_service 负责）。
#[frb(sync)]
pub fn enable_system_media_controls() -> bool {
    if crate::internal::CORE.get().is_none() {
        return false;
    }
    crate::media_controls::enable()
}
