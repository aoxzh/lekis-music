//! Android USB DAC 直出（PLY-05）：格式匹配、回退决策和全局状态。
//!
//! Android 14（API 34）起，`AudioManager.getSupportedMixerAttributes(device)` 能列出 USB 设备支持的
//! 混音器属性；其中 `MIXER_BEHAVIOR_BIT_PERFECT` 的条目表示「混音器按这个格式原样透传」。
//! 播放每一首前：
//!
//! 1. 通过 [`UsbAudioPlatform`]（桥接层用 JNI 实现）列出 USB 输出设备和它们的比特完美格式；
//! 2. 按当前曲目的采样率 / 声道 / 位深挑一个格式（[`match_mixer`]，只接受无损容器）；
//! 3. `setPreferredMixerAttributes(USAGE_MEDIA, device, attrs)`，再按**完全相同**的格式打开 AAudio 流
//!    （`aaudio_direct`，只在 Android 上编译）。
//!
//! 任何一步不满足（没 USB 设备、系统 < 14、HAL 不支持比特完美、格式不匹配）都返回原因，
//! 会话层退回普通共享输出，状态里写清楚原因给 UI 显示。
//!
//! 这一层不依赖 Android：平台能力抽象成 trait，单元测试用假的设备。

use std::sync::{Arc, Mutex, OnceLock};

use super::bitperfect::{NativePacking, NativePlan};
use crate::decode::{NativeSampleFormat, PcmFormat};
use lekis_types::{ErrorCode, LekisError, Result};

/// `android.media.AudioFormat` 的编码常量（只列出比特完美会用到的 PCM 编码）。
pub mod encoding {
    /// `ENCODING_PCM_16BIT`
    pub const PCM_16BIT: i32 = 2;
    /// `ENCODING_PCM_8BIT`
    pub const PCM_8BIT: i32 = 3;
    /// `ENCODING_PCM_FLOAT`
    pub const PCM_FLOAT: i32 = 4;
    /// `ENCODING_PCM_24BIT_PACKED`
    pub const PCM_24BIT_PACKED: i32 = 21;
    /// `ENCODING_PCM_32BIT`
    pub const PCM_32BIT: i32 = 22;
}

/// `AudioFormat.CHANNEL_OUT_MONO`
pub const CHANNEL_OUT_MONO: i32 = 0x4;
/// `AudioFormat.CHANNEL_OUT_STEREO`
pub const CHANNEL_OUT_STEREO: i32 = 0xC;
/// `AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT`
pub const MIXER_BEHAVIOR_BIT_PERFECT: i32 = 1;
/// `getSupportedMixerAttributes` 从 Android 14 开始才有。
pub const MIN_SDK_BIT_PERFECT: i32 = 34;

/// 一条 `AudioMixerAttributes`（设备支持的混音器格式）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MixerFormat {
    /// `AudioFormat.ENCODING_*`
    pub encoding: i32,
    /// 采样率（Hz）。
    pub sample_rate: u32,
    /// `AudioFormat.CHANNEL_OUT_*` 声道掩码。
    pub channel_mask: i32,
    /// `AudioMixerAttributes.MIXER_BEHAVIOR_*`
    pub behavior: i32,
}

impl MixerFormat {
    /// 是否是比特完美混音器行为。
    pub fn is_bit_perfect(&self) -> bool {
        self.behavior == MIXER_BEHAVIOR_BIT_PERFECT
    }
}

/// 一个 USB 音频输出设备（`AudioDeviceInfo` 的 TYPE_USB_DEVICE / TYPE_USB_HEADSET）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsbAudioDevice {
    /// `AudioDeviceInfo.getId()`，也是 AAudio 的 device id。
    pub id: i32,
    /// 产品名。
    pub name: String,
    /// `getSupportedMixerAttributes` 的结果（API < 34 时为空）。
    pub mixer_formats: Vec<MixerFormat>,
}

impl UsbAudioDevice {
    /// 是否至少有一种比特完美格式。
    pub fn supports_bit_perfect(&self) -> bool {
        self.mixer_formats.iter().any(MixerFormat::is_bit_perfect)
    }
}

/// 一次设备探测的结果。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct UsbProbe {
    /// `Build.VERSION.SDK_INT`
    pub sdk_int: i32,
    /// 当前连接的 USB 音频输出设备。
    pub devices: Vec<UsbAudioDevice>,
}

/// 平台能力（Android 上由桥接层通过 JNI 调 `AudioManager` 实现；测试里用假的）。
pub trait UsbAudioPlatform: Send + Sync {
    /// 列出 USB 输出设备及其支持的混音器属性。
    fn probe(&self) -> Result<UsbProbe>;
    /// `setPreferredMixerAttributes(USAGE_MEDIA, device, format)`。
    fn set_preferred(&self, device_id: i32, format: &MixerFormat) -> Result<()>;
    /// `clearPreferredMixerAttributes(USAGE_MEDIA, device)`。
    fn clear_preferred(&self, device_id: i32) -> Result<()>;
}

/// USB 直出当前状态（给 UI 的状态行）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UsbDirectState {
    /// 用户没开。
    Disabled,
    /// 平台没有登记（非 Android / 还没初始化）。
    Unavailable,
    /// 开了，但没有连接 USB 音频设备。
    NoDevice,
    /// 系统版本低于 Android 14，或设备 HAL 不支持比特完美混音器。
    Unsupported,
    /// 设备支持比特完美，但不支持当前曲目的格式，本曲已回退普通输出。
    FormatFallback,
    /// 设备支持比特完美，等待下一次播放。
    Ready,
    /// 正在比特完美输出。
    Active,
    /// 设置混音器属性或打开流失败，本曲已回退普通输出。
    Failed,
}

/// 比特完美输出正在使用的格式。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ActiveFormat {
    /// 采样率。
    pub sample_rate: u32,
    /// 声道数。
    pub channels: u16,
    /// 源位深（浮点为 32）。
    pub source_bits: u8,
    /// 源是否是浮点。
    pub source_float: bool,
    /// 设备容器。
    pub packing: NativePacking,
}

/// 完整状态快照。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsbDirectStatus {
    /// 用户是否打开了 USB 直出。
    pub enabled: bool,
    /// 状态。
    pub state: UsbDirectState,
    /// 当前 USB 设备名。
    pub device_name: Option<String>,
    /// 设备是否支持比特完美（有任何 BIT_PERFECT 条目）。
    pub device_supports_bit_perfect: bool,
    /// 系统 SDK 版本（0 = 未知）。
    pub sdk_int: i32,
    /// 正在使用 / 最近一次尝试的格式。
    pub format: Option<ActiveFormat>,
    /// 回退或失败原因（给日志和 UI）。
    pub message: Option<String>,
}

impl Default for UsbDirectStatus {
    fn default() -> Self {
        Self {
            enabled: false,
            state: UsbDirectState::Disabled,
            device_name: None,
            device_supports_bit_perfect: false,
            sdk_int: 0,
            format: None,
            message: None,
        }
    }
}

/// 一次匹配成功的直出计划。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UsbPlan {
    /// USB 设备 id（AAudio device id）。
    pub device_id: i32,
    /// 要设成首选的混音器格式。
    pub mixer: MixerFormat,
    /// 设备容器。
    pub packing: NativePacking,
    /// 流的采样率 / 声道（与源完全一致）。
    pub format: PcmFormat,
}

impl UsbPlan {
    /// 转成会话层用的 [`NativePlan`]。
    pub fn native_plan(&self) -> NativePlan {
        NativePlan {
            format: self.format,
            packing: self.packing,
        }
    }
}

/// 声道数 → `CHANNEL_OUT_*` 掩码（只支持单声道 / 立体声；多声道不做比特完美）。
pub fn channel_mask_for(channels: u16) -> Option<i32> {
    match channels {
        1 => Some(CHANNEL_OUT_MONO),
        2 => Some(CHANNEL_OUT_STEREO),
        _ => None,
    }
}

/// 设备容器 → Android 编码。
pub fn encoding_for(packing: NativePacking) -> i32 {
    match packing {
        NativePacking::Int16 => encoding::PCM_16BIT,
        NativePacking::Int24Packed => encoding::PCM_24BIT_PACKED,
        // 24-in-32 在 Android 上没有单独的公开编码：左对齐 i32 就是 PCM_32BIT 的高 24 位。
        NativePacking::Int24In32 | NativePacking::Int32 => encoding::PCM_32BIT,
        NativePacking::Float32 => encoding::PCM_FLOAT,
    }
}

/// Android 上某个源格式可用的容器，按优先级排列。
///
/// 和 WASAPI 一样只接受无损容器；另外允许「整数源放进更宽的整数容器」：
/// 左对齐 i32 的低位本来就是零，按高位取字节只是补零，样本值不经过任何运算
/// （很多 USB DAC 只报 24 / 32 bit 格式，这样 16 bit 源也能比特完美）。
pub fn android_packing_candidates(native: NativeSampleFormat) -> &'static [NativePacking] {
    match native {
        NativeSampleFormat::Int { bits: 16 } => &[
            NativePacking::Int16,
            NativePacking::Int24Packed,
            NativePacking::Int32,
        ],
        NativeSampleFormat::Int { bits: 24 } => {
            &[NativePacking::Int24Packed, NativePacking::Int24In32]
        }
        NativeSampleFormat::Int { bits: 32 } => &[NativePacking::Int32],
        NativeSampleFormat::Float32 => &[NativePacking::Float32],
        NativeSampleFormat::Int { .. } => &[],
    }
}

/// 在设备支持的混音器格式里找一个与源完全一致的比特完美格式。
///
/// 要求：`MIXER_BEHAVIOR_BIT_PERFECT`、采样率相同、声道掩码相同、编码是无损容器之一。
/// 多个候选时按 [`android_packing_candidates`] 的顺序取第一个（最窄的无损容器优先）。
pub fn match_mixer(
    requested: PcmFormat,
    native: NativeSampleFormat,
    formats: &[MixerFormat],
) -> Option<(MixerFormat, NativePacking)> {
    let mask = channel_mask_for(requested.channels)?;
    android_packing_candidates(native)
        .iter()
        .find_map(|&packing| {
            let enc = encoding_for(packing);
            formats
                .iter()
                .find(|f| {
                    f.is_bit_perfect()
                        && f.sample_rate == requested.sample_rate
                        && f.channel_mask == mask
                        && f.encoding == enc
                })
                .map(|f| (*f, packing))
        })
}

fn source_bits(native: NativeSampleFormat) -> (u8, bool) {
    match native {
        NativeSampleFormat::Int { bits } => (bits, false),
        NativeSampleFormat::Float32 => (32, true),
    }
}

/// USB 直出控制器：记住开关、已经设置的首选混音器属性和 UI 状态。
///
/// 所有平台调用都经过 [`UsbAudioPlatform`]，所以回退逻辑可以用假设备测试。
pub struct UsbDirectController {
    platform: Option<Arc<dyn UsbAudioPlatform>>,
    enabled: bool,
    /// 已经调过 `setPreferredMixerAttributes` 的 (设备, 格式)。
    applied: Option<(i32, MixerFormat)>,
    /// 设备探测缓存（热插拔时失效）。
    probe: Option<UsbProbe>,
    status: UsbDirectStatus,
}

impl Default for UsbDirectController {
    fn default() -> Self {
        Self::new(None)
    }
}

impl UsbDirectController {
    /// 用给定平台创建（`None` = 没有平台能力）。
    pub fn new(platform: Option<Arc<dyn UsbAudioPlatform>>) -> Self {
        Self {
            platform,
            enabled: false,
            applied: None,
            probe: None,
            status: UsbDirectStatus::default(),
        }
    }

    /// 登记平台能力（桥接层在 Android 启动时调用）。
    pub fn set_platform(&mut self, platform: Arc<dyn UsbAudioPlatform>) {
        self.platform = Some(platform);
        self.probe = None;
        self.refresh_idle_status();
    }

    /// 是否打开了 USB 直出。
    pub fn enabled(&self) -> bool {
        self.enabled
    }

    /// 当前状态。
    pub fn status(&self) -> UsbDirectStatus {
        self.status.clone()
    }

    /// 打开 / 关闭。关闭时立刻清掉首选混音器属性，让系统恢复普通混音。
    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
        if !enabled {
            self.release();
        }
        self.refresh_idle_status();
    }

    /// 设备列表变了（USB 插拔）：丢掉缓存；已经设置的设备不在了就清掉记录。
    pub fn devices_changed(&mut self) {
        self.probe = None;
        if let Some((device_id, _)) = self.applied {
            let still_there = self
                .probe_cached()
                .map(|p| p.devices.iter().any(|d| d.id == device_id))
                .unwrap_or(false);
            if !still_there {
                // 设备拔掉后系统会自己丢掉首选属性；这里再清一次，失败也无所谓。
                self.release();
            }
        }
        if self.status.state != UsbDirectState::Active || self.applied.is_none() {
            self.refresh_idle_status();
        }
    }

    /// 为当前曲目协商直出计划。
    ///
    /// - `Ok(None)`：没开 / 没平台 / 没 USB 设备 —— 静默走普通输出；
    /// - `Err`：有 USB 设备但不能比特完美（系统太旧、HAL 不支持、格式不匹配）—— 回退并写原因；
    /// - `Ok(Some(plan))`：可以直出。
    pub fn plan(
        &mut self,
        requested: PcmFormat,
        native: NativeSampleFormat,
    ) -> Result<Option<UsbPlan>> {
        if !self.enabled {
            self.status = UsbDirectStatus::default();
            return Ok(None);
        }
        let (bits, float) = source_bits(native);
        let wanted = ActiveFormat {
            sample_rate: requested.sample_rate,
            channels: requested.channels,
            source_bits: bits,
            source_float: float,
            packing: NativePacking::Int16,
        };
        let probe = match self.probe_cached() {
            Some(p) => p,
            None => {
                self.set_status(UsbDirectState::Unavailable, None, None, None);
                return Ok(None);
            }
        };
        let sdk = probe.sdk_int;
        let Some(device) = probe.devices.first().cloned() else {
            self.status = UsbDirectStatus {
                enabled: true,
                state: UsbDirectState::NoDevice,
                sdk_int: sdk,
                ..UsbDirectStatus::default()
            };
            return Ok(None);
        };
        let name = Some(device.name.clone());
        if sdk != 0 && sdk < MIN_SDK_BIT_PERFECT {
            let msg = format!("Android SDK {sdk} < 34: no bit-perfect mixer API");
            self.set_device_status(UsbDirectState::Unsupported, &device, sdk, None, &msg);
            return Err(LekisError::new(ErrorCode::Unsupported, msg));
        }
        if !device.supports_bit_perfect() {
            let msg = format!(
                "USB device {} reports no bit-perfect mixer attributes",
                device.name
            );
            self.set_device_status(UsbDirectState::Unsupported, &device, sdk, None, &msg);
            return Err(LekisError::new(ErrorCode::Unsupported, msg));
        }
        match match_mixer(requested, native, &device.mixer_formats) {
            Some((mixer, packing)) => {
                self.status = UsbDirectStatus {
                    enabled: true,
                    state: UsbDirectState::Ready,
                    device_name: name,
                    device_supports_bit_perfect: true,
                    sdk_int: sdk,
                    format: Some(ActiveFormat { packing, ..wanted }),
                    message: None,
                };
                Ok(Some(UsbPlan {
                    device_id: device.id,
                    mixer,
                    packing,
                    format: requested,
                }))
            }
            None => {
                // 这首歌的格式不能直出：清掉上一首设的首选属性，让普通输出不被锁在旧格式上。
                self.release();
                let msg = format!(
                    "{} has no bit-perfect mixer for {} Hz / {} ch / {}{}",
                    device.name,
                    requested.sample_rate,
                    requested.channels,
                    bits,
                    if float { "-bit float" } else { "-bit" }
                );
                self.set_device_status(
                    UsbDirectState::FormatFallback,
                    &device,
                    sdk,
                    Some(wanted),
                    &msg,
                );
                Err(LekisError::new(ErrorCode::Unsupported, msg))
            }
        }
    }

    /// 把计划的格式设成首选混音器属性（同一设备同一格式不重复设置，避免路由抖动）。
    pub fn activate(&mut self, plan: &UsbPlan) -> Result<()> {
        let Some(platform) = self.platform.clone() else {
            return Err(LekisError::new(
                ErrorCode::Unsupported,
                "USB direct output platform is not registered",
            ));
        };
        if self.applied != Some((plan.device_id, plan.mixer)) {
            if let Some((old, _)) = self.applied.take() {
                if old != plan.device_id {
                    let _ = platform.clear_preferred(old);
                }
            }
            if let Err(e) = platform.set_preferred(plan.device_id, &plan.mixer) {
                self.mark_failed(&e.message);
                return Err(e);
            }
            self.applied = Some((plan.device_id, plan.mixer));
        }
        Ok(())
    }

    /// AAudio 流已经按计划打开：状态切到「比特完美」。
    pub fn mark_active(&mut self) {
        self.status.state = UsbDirectState::Active;
        self.status.message = None;
    }

    /// 设置属性或开流失败：清掉首选属性，状态写失败原因（会话随后退回普通输出）。
    pub fn mark_failed(&mut self, reason: &str) {
        self.release();
        self.status.state = UsbDirectState::Failed;
        self.status.message = Some(reason.to_string());
    }

    /// 普通输出要开流了：不能让系统停在比特完美混音器上（否则其他声音会被静音）。
    pub fn on_shared_output(&mut self) {
        if self.applied.is_some() {
            self.release();
        }
        if self.status.state == UsbDirectState::Active {
            self.refresh_idle_status();
        }
    }

    /// 清掉已设置的首选混音器属性（关闭开关、拔出设备、退出时）。
    pub fn release(&mut self) {
        if let Some((device_id, _)) = self.applied.take() {
            if let Some(platform) = &self.platform {
                if let Err(e) = platform.clear_preferred(device_id) {
                    tracing::debug!(
                        target: "playback::usb",
                        error = %e,
                        "clearPreferredMixerAttributes failed"
                    );
                }
            }
        }
    }

    /// 当前已经设置为首选的 (设备, 格式)。
    pub fn applied(&self) -> Option<(i32, MixerFormat)> {
        self.applied
    }

    fn probe_cached(&mut self) -> Option<UsbProbe> {
        if self.probe.is_none() {
            let platform = self.platform.as_ref()?;
            match platform.probe() {
                Ok(p) => self.probe = Some(p),
                Err(e) => {
                    tracing::warn!(target: "playback::usb", error = %e, "USB audio probe failed");
                    return None;
                }
            }
        }
        self.probe.clone()
    }

    /// 不在播放时的状态：根据开关和设备情况给出「就绪 / 无设备 / 不支持」。
    fn refresh_idle_status(&mut self) {
        if !self.enabled {
            self.status = UsbDirectStatus::default();
            return;
        }
        let Some(probe) = self.probe_cached() else {
            self.set_status(UsbDirectState::Unavailable, None, None, None);
            return;
        };
        let sdk = probe.sdk_int;
        match probe.devices.first() {
            None => {
                self.status = UsbDirectStatus {
                    enabled: true,
                    state: UsbDirectState::NoDevice,
                    sdk_int: sdk,
                    ..UsbDirectStatus::default()
                };
            }
            Some(device) => {
                let device = device.clone();
                let ok = (sdk == 0 || sdk >= MIN_SDK_BIT_PERFECT) && device.supports_bit_perfect();
                let state = if ok {
                    UsbDirectState::Ready
                } else {
                    UsbDirectState::Unsupported
                };
                self.status = UsbDirectStatus {
                    enabled: true,
                    state,
                    device_name: Some(device.name.clone()),
                    device_supports_bit_perfect: device.supports_bit_perfect(),
                    sdk_int: sdk,
                    format: None,
                    message: None,
                };
            }
        }
    }

    fn set_status(
        &mut self,
        state: UsbDirectState,
        device_name: Option<String>,
        format: Option<ActiveFormat>,
        message: Option<String>,
    ) {
        self.status = UsbDirectStatus {
            enabled: self.enabled,
            state,
            device_name,
            device_supports_bit_perfect: false,
            sdk_int: self.probe.as_ref().map(|p| p.sdk_int).unwrap_or(0),
            format,
            message,
        };
    }

    fn set_device_status(
        &mut self,
        state: UsbDirectState,
        device: &UsbAudioDevice,
        sdk: i32,
        format: Option<ActiveFormat>,
        message: &str,
    ) {
        tracing::warn!(target: "playback::usb", state = ?state, "{message}");
        self.status = UsbDirectStatus {
            enabled: true,
            state,
            device_name: Some(device.name.clone()),
            device_supports_bit_perfect: device.supports_bit_perfect(),
            sdk_int: sdk,
            format,
            message: Some(message.to_string()),
        };
    }
}

// ---------------------------------------------------------------------------
// 进程级单例（输出后端和桥接层共用）
// ---------------------------------------------------------------------------

fn global() -> &'static Mutex<UsbDirectController> {
    static CONTROLLER: OnceLock<Mutex<UsbDirectController>> = OnceLock::new();
    CONTROLLER.get_or_init(|| Mutex::new(UsbDirectController::default()))
}

fn with_global<T>(f: impl FnOnce(&mut UsbDirectController) -> T) -> T {
    let mut guard = match global().lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    };
    f(&mut guard)
}

/// 登记平台能力（Android 桥接层启动时调用一次）。
pub fn register_usb_platform(platform: Arc<dyn UsbAudioPlatform>) {
    with_global(|c| c.set_platform(platform));
}

/// 打开 / 关闭 USB 直出。真正生效要配合引擎切到 [`super::OutputMode::Exclusive`]。
pub fn set_usb_direct_enabled(enabled: bool) {
    with_global(|c| c.set_enabled(enabled));
}

/// 是否打开了 USB 直出。
pub fn usb_direct_enabled() -> bool {
    with_global(|c| c.enabled())
}

/// 当前状态快照。
pub fn usb_direct_status() -> UsbDirectStatus {
    with_global(|c| c.status())
}

/// USB 设备插拔通知。
pub fn usb_devices_changed() {
    with_global(UsbDirectController::devices_changed);
}

/// 清掉首选混音器属性（退出时）。
pub fn usb_direct_release() {
    with_global(UsbDirectController::release);
}

/// 当前设备探测结果（诊断用；会刷新缓存）。
pub fn usb_direct_probe() -> Option<UsbProbe> {
    with_global(|c| {
        c.probe = None;
        c.probe_cached()
    })
}

/// 输出后端用：协商计划。
#[cfg_attr(not(target_os = "android"), allow(dead_code))]
pub(crate) fn plan_global(
    requested: PcmFormat,
    native: NativeSampleFormat,
) -> Result<Option<UsbPlan>> {
    with_global(|c| c.plan(requested, native))
}

/// 输出后端用：协商并设置首选混音器属性。
#[cfg_attr(not(target_os = "android"), allow(dead_code))]
pub(crate) fn prepare_global(requested: PcmFormat, native: NativeSampleFormat) -> Result<UsbPlan> {
    with_global(|c| {
        let plan = c.plan(requested, native)?.ok_or_else(|| {
            LekisError::new(
                ErrorCode::Unsupported,
                "no USB audio device for direct output",
            )
        })?;
        c.activate(&plan)?;
        Ok(plan)
    })
}

/// 输出后端用：流已打开 / 打开失败 / 改走普通输出。
#[cfg_attr(not(target_os = "android"), allow(dead_code))]
pub(crate) fn mark_active_global() {
    with_global(UsbDirectController::mark_active);
}

/// 见 [`UsbDirectController::mark_failed`]。
#[cfg_attr(not(target_os = "android"), allow(dead_code))]
pub(crate) fn mark_failed_global(reason: &str) {
    with_global(|c| c.mark_failed(reason));
}

/// 见 [`UsbDirectController::on_shared_output`]。
#[cfg_attr(not(target_os = "android"), allow(dead_code))]
pub(crate) fn on_shared_output_global() {
    with_global(UsbDirectController::on_shared_output);
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    const STEREO: i32 = CHANNEL_OUT_STEREO;

    fn bp(encoding: i32, rate: u32) -> MixerFormat {
        MixerFormat {
            encoding,
            sample_rate: rate,
            channel_mask: STEREO,
            behavior: MIXER_BEHAVIOR_BIT_PERFECT,
        }
    }

    fn fmt(rate: u32, channels: u16) -> PcmFormat {
        PcmFormat {
            sample_rate: rate,
            channels,
        }
    }

    /// 假平台：记录 set / clear 调用。
    #[derive(Default)]
    struct FakePlatform {
        probe: Mutex<UsbProbe>,
        fail_set: bool,
        calls: Mutex<Vec<String>>,
    }

    impl FakePlatform {
        fn with(sdk: i32, devices: Vec<UsbAudioDevice>) -> Arc<Self> {
            Arc::new(Self {
                probe: Mutex::new(UsbProbe {
                    sdk_int: sdk,
                    devices,
                }),
                ..Self::default()
            })
        }
        fn calls(&self) -> Vec<String> {
            self.calls.lock().unwrap().clone()
        }
    }

    impl UsbAudioPlatform for FakePlatform {
        fn probe(&self) -> Result<UsbProbe> {
            Ok(self.probe.lock().unwrap().clone())
        }
        fn set_preferred(&self, device_id: i32, format: &MixerFormat) -> Result<()> {
            self.calls.lock().unwrap().push(format!(
                "set {device_id} {} {}",
                format.encoding, format.sample_rate
            ));
            if self.fail_set {
                Err(LekisError::new(ErrorCode::Io, "HAL refused"))
            } else {
                Ok(())
            }
        }
        fn clear_preferred(&self, device_id: i32) -> Result<()> {
            self.calls
                .lock()
                .unwrap()
                .push(format!("clear {device_id}"));
            Ok(())
        }
    }

    fn dac(formats: Vec<MixerFormat>) -> UsbAudioDevice {
        UsbAudioDevice {
            id: 42,
            name: "Test DAC".into(),
            mixer_formats: formats,
        }
    }

    fn controller(platform: Arc<FakePlatform>) -> UsbDirectController {
        let mut c = UsbDirectController::new(Some(platform));
        c.set_enabled(true);
        c
    }

    #[test]
    fn matches_exact_rate_channels_and_encoding() {
        let formats = [
            bp(encoding::PCM_16BIT, 44_100),
            bp(encoding::PCM_24BIT_PACKED, 96_000),
            bp(encoding::PCM_32BIT, 96_000),
        ];
        let (m, p) = match_mixer(
            fmt(96_000, 2),
            NativeSampleFormat::Int { bits: 24 },
            &formats,
        )
        .unwrap();
        assert_eq!(m.encoding, encoding::PCM_24BIT_PACKED);
        assert_eq!(p, NativePacking::Int24Packed);

        // 采样率不同就不匹配（不允许系统重采样）。
        assert!(match_mixer(
            fmt(48_000, 2),
            NativeSampleFormat::Int { bits: 24 },
            &formats
        )
        .is_none());
    }

    #[test]
    fn prefers_narrowest_lossless_container() {
        // 24 bit 源：只有 32 bit 容器时用 24-in-32。
        let formats = [bp(encoding::PCM_32BIT, 48_000)];
        let (_, p) = match_mixer(
            fmt(48_000, 2),
            NativeSampleFormat::Int { bits: 24 },
            &formats,
        )
        .unwrap();
        assert_eq!(p, NativePacking::Int24In32);

        // 16 bit 源：16 > 24 packed > 32。
        let formats = [
            bp(encoding::PCM_32BIT, 44_100),
            bp(encoding::PCM_24BIT_PACKED, 44_100),
        ];
        let (_, p) = match_mixer(
            fmt(44_100, 2),
            NativeSampleFormat::Int { bits: 16 },
            &formats,
        )
        .unwrap();
        assert_eq!(p, NativePacking::Int24Packed);
    }

    #[test]
    fn rejects_lossy_or_non_bit_perfect_entries() {
        // 24 bit 源不能放进 16 bit 容器。
        let formats = [bp(encoding::PCM_16BIT, 48_000)];
        assert!(match_mixer(
            fmt(48_000, 2),
            NativeSampleFormat::Int { bits: 24 },
            &formats
        )
        .is_none());
        // MIXER_BEHAVIOR_DEFAULT 的条目不算。
        let mut default_behavior = bp(encoding::PCM_16BIT, 48_000);
        default_behavior.behavior = 0;
        assert!(match_mixer(
            fmt(48_000, 2),
            NativeSampleFormat::Int { bits: 16 },
            &[default_behavior]
        )
        .is_none());
        // 浮点源只接受 float 容器。
        assert!(match_mixer(
            fmt(48_000, 2),
            NativeSampleFormat::Float32,
            &[bp(encoding::PCM_32BIT, 48_000)]
        )
        .is_none());
        // 多声道不做比特完美。
        assert!(match_mixer(
            fmt(48_000, 6),
            NativeSampleFormat::Int { bits: 16 },
            &[bp(encoding::PCM_16BIT, 48_000)]
        )
        .is_none());
    }

    #[test]
    fn mono_needs_mono_mask() {
        let mut mono = bp(encoding::PCM_16BIT, 48_000);
        mono.channel_mask = CHANNEL_OUT_MONO;
        assert!(match_mixer(
            fmt(48_000, 1),
            NativeSampleFormat::Int { bits: 16 },
            &[mono]
        )
        .is_some());
        assert!(match_mixer(
            fmt(48_000, 1),
            NativeSampleFormat::Int { bits: 16 },
            &[bp(encoding::PCM_16BIT, 48_000)]
        )
        .is_none());
    }

    #[test]
    fn disabled_or_no_device_is_silent_fallback() {
        let platform = FakePlatform::with(36, vec![]);
        let mut c = UsbDirectController::new(Some(platform.clone()));
        let native = NativeSampleFormat::Int { bits: 16 };
        assert_eq!(c.plan(fmt(44_100, 2), native).unwrap(), None);
        assert_eq!(c.status().state, UsbDirectState::Disabled);

        c.set_enabled(true);
        assert_eq!(c.status().state, UsbDirectState::NoDevice);
        assert_eq!(c.plan(fmt(44_100, 2), native).unwrap(), None);
        assert_eq!(c.status().state, UsbDirectState::NoDevice);
        assert!(platform.calls().is_empty());
    }

    #[test]
    fn no_platform_is_unavailable() {
        let mut c = UsbDirectController::new(None);
        c.set_enabled(true);
        assert_eq!(c.status().state, UsbDirectState::Unavailable);
        let r = c.plan(fmt(44_100, 2), NativeSampleFormat::Int { bits: 16 });
        assert_eq!(r.unwrap(), None);
    }

    #[test]
    fn old_android_or_unsupported_hal_falls_back_with_reason() {
        let native = NativeSampleFormat::Int { bits: 16 };
        let old = FakePlatform::with(33, vec![dac(vec![bp(encoding::PCM_16BIT, 44_100)])]);
        let mut c = controller(old);
        assert_eq!(c.status().state, UsbDirectState::Unsupported);
        assert!(c.plan(fmt(44_100, 2), native).is_err());
        assert_eq!(c.status().state, UsbDirectState::Unsupported);
        assert_eq!(c.status().device_name.as_deref(), Some("Test DAC"));

        let no_hal = FakePlatform::with(36, vec![dac(vec![])]);
        let mut c = controller(no_hal);
        assert!(c.plan(fmt(44_100, 2), native).is_err());
        let s = c.status();
        assert_eq!(s.state, UsbDirectState::Unsupported);
        assert!(!s.device_supports_bit_perfect);
        assert!(s.message.is_some());
    }

    #[test]
    fn activate_sets_once_and_switches_per_format() {
        let platform = FakePlatform::with(
            36,
            vec![dac(vec![
                bp(encoding::PCM_16BIT, 44_100),
                bp(encoding::PCM_24BIT_PACKED, 96_000),
            ])],
        );
        let mut c = controller(platform.clone());
        let cd = NativeSampleFormat::Int { bits: 16 };
        let hires = NativeSampleFormat::Int { bits: 24 };

        let plan = c.plan(fmt(44_100, 2), cd).unwrap().unwrap();
        assert_eq!(plan.device_id, 42);
        c.activate(&plan).unwrap();
        c.mark_active();
        assert_eq!(c.status().state, UsbDirectState::Active);
        // 同一格式的下一首：不重复设置（避免路由切换的爆音）。
        let plan2 = c.plan(fmt(44_100, 2), cd).unwrap().unwrap();
        c.activate(&plan2).unwrap();
        assert_eq!(platform.calls(), vec!["set 42 2 44100"]);

        // 格式变了：重新设置。
        let plan3 = c.plan(fmt(96_000, 2), hires).unwrap().unwrap();
        c.activate(&plan3).unwrap();
        assert_eq!(platform.calls().last().unwrap(), "set 42 21 96000");
        let f = c.status().format.unwrap();
        assert_eq!((f.sample_rate, f.source_bits), (96_000, 24));

        // 不支持的格式：清掉首选属性，状态是格式回退。
        assert!(c.plan(fmt(192_000, 2), hires).is_err());
        assert_eq!(platform.calls().last().unwrap(), "clear 42");
        assert_eq!(c.status().state, UsbDirectState::FormatFallback);
        assert_eq!(c.applied(), None);
    }

    #[test]
    fn set_failure_clears_and_reports() {
        let platform = Arc::new(FakePlatform {
            probe: Mutex::new(UsbProbe {
                sdk_int: 36,
                devices: vec![dac(vec![bp(encoding::PCM_16BIT, 44_100)])],
            }),
            fail_set: true,
            calls: Mutex::new(vec![]),
        });
        let mut c = controller(platform);
        let plan = c
            .plan(fmt(44_100, 2), NativeSampleFormat::Int { bits: 16 })
            .unwrap()
            .unwrap();
        assert!(c.activate(&plan).is_err());
        assert_eq!(c.status().state, UsbDirectState::Failed);
        assert_eq!(c.applied(), None);
    }

    #[test]
    fn disable_unplug_and_shared_output_release_preferred() {
        let platform = FakePlatform::with(36, vec![dac(vec![bp(encoding::PCM_16BIT, 44_100)])]);
        let native = NativeSampleFormat::Int { bits: 16 };
        let mut c = controller(platform.clone());
        let plan = c.plan(fmt(44_100, 2), native).unwrap().unwrap();
        c.activate(&plan).unwrap();

        // 普通输出开流时清掉。
        c.on_shared_output();
        assert_eq!(platform.calls().last().unwrap(), "clear 42");

        // 拔掉设备时清掉，状态变为无设备。
        c.activate(&plan).unwrap();
        platform.probe.lock().unwrap().devices.clear();
        c.devices_changed();
        assert_eq!(platform.calls().last().unwrap(), "clear 42");
        assert_eq!(c.status().state, UsbDirectState::NoDevice);

        // 重新插上 + 关闭开关时清掉。
        platform.probe.lock().unwrap().devices = vec![dac(vec![bp(encoding::PCM_16BIT, 44_100)])];
        c.devices_changed();
        assert_eq!(c.status().state, UsbDirectState::Ready);
        let plan = c.plan(fmt(44_100, 2), native).unwrap().unwrap();
        c.activate(&plan).unwrap();
        c.set_enabled(false);
        assert_eq!(platform.calls().last().unwrap(), "clear 42");
        assert_eq!(c.status().state, UsbDirectState::Disabled);
    }
}
