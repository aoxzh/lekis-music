//! 10 段图形均衡器（PLY-04）。
//!
//! 只在**共享输出链路**启用：解码线程把样本转换成设备格式之后、写进环形缓冲之前
//! 依次经过 10 个 peaking biquad。比特完美独占链路（WASAPI exclusive）完全绕过
//! 本模块，样本位模式保持不变。
//!
//! - 频段固定为 31 / 62 / 125 / 250 / 500 / 1k / 2k / 4k / 8k / 16k Hz；
//! - 每段和 preamp 都限制在 -12..=+12 dB；
//! - 系数按**输出设备采样率**计算，新建会话 / 切换采样率时重建；
//! - 参数更新通过 [`EqControl`] 的无锁原子量传到解码线程，正在播放的音频在下一个
//!   解码块（通常几十毫秒内）就会用上新参数；
//! - 参数变化按块做一阶平滑，滤波器历史在旁路 / seek 时清空，避免爆音；
//! - 输出非有限值会替换成 0，并限制在安全幅度内，防止 NaN / Inf 扩散。
//!
//! 预设数据是 **AutoEQ 风格的近似补偿曲线**，用于让不同耳机听起来更接近中性，
//! 不是官方测量数据，也不代表厂商的推荐设置。

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;

/// 均衡器频段数。
pub const BAND_COUNT: usize = 10;

/// 10 段中心频率（Hz）。
pub const BAND_FREQUENCIES_HZ: [f32; BAND_COUNT] = [
    31.0, 62.0, 125.0, 250.0, 500.0, 1_000.0, 2_000.0, 4_000.0, 8_000.0, 16_000.0,
];

/// 每段允许的最小增益（dB）。
pub const MIN_GAIN_DB: f32 = -12.0;

/// 每段允许的最大增益（dB）。
pub const MAX_GAIN_DB: f32 = 12.0;

/// 默认 peaking 滤波器的 Q 值。10 段按倍频程排列，Q=1 时相邻频段有适量重叠。
pub const DEFAULT_Q: f32 = 1.0;

/// 输出安全上限。正常音频在 ±1 以内，这里只用于兜底拦住滤波后的异常值。
const SAFETY_LIMIT: f32 = 16.0;

/// 每个解码块的参数平滑比例。0.35 大约 10~20 个块收敛，听感上不会有台阶。
const SMOOTHING: f32 = 0.35;

/// 把一段增益限制到合法范围；NaN / Inf 归零。
pub fn clamp_gain_db(db: f32) -> f32 {
    if db.is_finite() {
        db.clamp(MIN_GAIN_DB, MAX_GAIN_DB)
    } else {
        0.0
    }
}

/// 一份完整的均衡器设置。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EqSettings {
    /// 是否启用。关闭时 DSP 只做一次原子读取，不遍历样本。
    pub enabled: bool,
    /// 全局前级增益（dB）。
    pub preamp_db: f32,
    /// 10 段增益（dB）。
    pub bands_db: [f32; BAND_COUNT],
}

impl Default for EqSettings {
    fn default() -> Self {
        Self::flat()
    }
}

impl EqSettings {
    /// 平直曲线：全部 0 dB，默认关闭。
    pub fn flat() -> Self {
        Self {
            enabled: false,
            preamp_db: 0.0,
            bands_db: [0.0; BAND_COUNT],
        }
    }

    /// 从任意长度的增益切片构造；缺的段补 0，多的忽略，并做范围钳制。
    pub fn new(enabled: bool, preamp_db: f32, bands_db: &[f32]) -> Self {
        let mut bands = [0.0f32; BAND_COUNT];
        for (slot, value) in bands.iter_mut().zip(bands_db.iter().copied()) {
            *slot = clamp_gain_db(value);
        }
        Self {
            enabled,
            preamp_db: clamp_gain_db(preamp_db),
            bands_db: bands,
        }
    }

    /// 再钳制一次，保证从设置文件 / FFI 进来的值都安全。
    pub fn sanitized(self) -> Self {
        let mut bands = [0.0f32; BAND_COUNT];
        for (slot, value) in bands.iter_mut().zip(self.bands_db.iter().copied()) {
            *slot = clamp_gain_db(value);
        }
        Self {
            enabled: self.enabled,
            preamp_db: clamp_gain_db(self.preamp_db),
            bands_db: bands,
        }
    }

    /// 曲线是否完全平直（preamp 也是 0 dB）。
    pub fn is_flat(&self) -> bool {
        self.preamp_db.abs() < f32::EPSILON
            && self.bands_db.iter().all(|gain| gain.abs() < f32::EPSILON)
    }
}

/// 跨线程共享的均衡器参数。
///
/// 引擎 / 设置线程写，解码线程每个块读一次。内部只有原子量，不加锁、不分配。
#[derive(Debug)]
pub struct EqControl {
    enabled: AtomicBool,
    preamp_bits: AtomicU32,
    bands_bits: [AtomicU32; BAND_COUNT],
    generation: AtomicU64,
}

impl Default for EqControl {
    fn default() -> Self {
        Self::new(EqSettings::flat())
    }
}

impl EqControl {
    /// 用初始设置创建。
    pub fn new(settings: EqSettings) -> Self {
        let settings = settings.sanitized();
        let bands_bits = std::array::from_fn(|i| AtomicU32::new(settings.bands_db[i].to_bits()));
        Self {
            enabled: AtomicBool::new(settings.enabled),
            preamp_bits: AtomicU32::new(settings.preamp_db.to_bits()),
            bands_bits,
            generation: AtomicU64::new(0),
        }
    }

    /// 写入新设置；正在播放的会话会在下一个解码块看到新参数。
    pub fn set(&self, settings: EqSettings) {
        let settings = settings.sanitized();
        for (atom, value) in self.bands_bits.iter().zip(settings.bands_db.iter()) {
            atom.store(value.to_bits(), Ordering::Relaxed);
        }
        self.preamp_bits
            .store(settings.preamp_db.to_bits(), Ordering::Relaxed);
        self.enabled.store(settings.enabled, Ordering::Relaxed);
        // Release 保证解码线程读到新 generation 时，上面的参数已经可见。
        self.generation.fetch_add(1, Ordering::Release);
    }

    /// 当前设置（诊断 / 设置页回读用）。
    pub fn settings(&self) -> EqSettings {
        // 写入是多次原子 store；用 generation 校验读到的是一份稳定快照。
        loop {
            let before = self.generation.load(Ordering::Acquire);
            let bands_db =
                std::array::from_fn(|i| f32::from_bits(self.bands_bits[i].load(Ordering::Relaxed)));
            let preamp_db = f32::from_bits(self.preamp_bits.load(Ordering::Relaxed));
            let enabled = self.enabled.load(Ordering::Relaxed);
            let after = self.generation.load(Ordering::Acquire);
            if before == after {
                return EqSettings {
                    enabled,
                    preamp_db: clamp_gain_db(preamp_db),
                    bands_db,
                }
                .sanitized();
            }
        }
    }

    /// 是否启用（解码线程热路径只读这个）。
    pub fn enabled(&self) -> bool {
        self.enabled.load(Ordering::Relaxed)
    }

    /// 参数版本号；变化后 DSP 需要重建系数。
    pub fn generation(&self) -> u64 {
        self.generation.load(Ordering::Acquire)
    }
}

/// 单个双二阶滤波器（Direct Form II Transposed）。
#[derive(Debug, Clone, Copy)]
struct Biquad {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    z1: f32,
    z2: f32,
}

impl Biquad {
    const IDENTITY: Self = Self {
        b0: 1.0,
        b1: 0.0,
        b2: 0.0,
        a1: 0.0,
        a2: 0.0,
        z1: 0.0,
        z2: 0.0,
    };

    /// RBJ cookbook peaking EQ。频率非法 / 非有限参数时返回直通。
    fn peaking(sample_rate: u32, frequency: f32, q: f32, gain_db: f32) -> Self {
        let rate = sample_rate.max(8_000) as f32;
        // 超过 Nyquist 的频段在低采样率下没有意义，直通而不是硬折叠。
        if !frequency.is_finite()
            || frequency <= 0.0
            || frequency >= rate * 0.49
            || !gain_db.is_finite()
            || gain_db.abs() < 1e-6
            || !q.is_finite()
            || q <= 0.0
        {
            return Self::IDENTITY;
        }
        let a = 10f32.powf(gain_db / 40.0);
        let w0 = 2.0 * std::f32::consts::PI * frequency / rate;
        let cos_w0 = w0.cos();
        let sin_w0 = w0.sin();
        let alpha = sin_w0 / (2.0 * q);
        let a0 = 1.0 + alpha / a;
        if !a0.is_finite() || a0.abs() < f32::MIN_POSITIVE {
            return Self::IDENTITY;
        }
        let b0 = (1.0 + alpha * a) / a0;
        let b1 = (-2.0 * cos_w0) / a0;
        let b2 = (1.0 - alpha * a) / a0;
        let a1 = (-2.0 * cos_w0) / a0;
        let a2 = (1.0 - alpha / a) / a0;
        if [b0, b1, b2, a1, a2].iter().all(|value| value.is_finite()) {
            Self {
                b0,
                b1,
                b2,
                a1,
                a2,
                z1: 0.0,
                z2: 0.0,
            }
        } else {
            Self::IDENTITY
        }
    }

    #[inline]
    fn process(&mut self, x: f32) -> f32 {
        let y = self.b0.mul_add(x, self.z1);
        self.z1 = self.b1.mul_add(x, self.z2 - self.a1 * y);
        self.z2 = self.b2 * x - self.a2 * y;
        y
    }

    fn reset(&mut self) {
        self.z1 = 0.0;
        self.z2 = 0.0;
    }
}

/// 解码线程里的 10 段均衡器节点。
///
/// `process` 不分配、不加锁，只做浮点运算。关闭时只读一次原子量并立即返回。
pub struct ParametricEq {
    control: Arc<EqControl>,
    sample_rate: u32,
    channels: usize,
    /// 每个声道一组 10 个 biquad；系数相同，状态独立。
    filters: Vec<Biquad>,
    generation: u64,
    target_preamp: f32,
    current_preamp: f32,
    target_gains: [f32; BAND_COUNT],
    current_gains: [f32; BAND_COUNT],
    smoothing: bool,
    active: bool,
    /// 是否已经处理过块。首次启用可以直接用目标参数；播放中途再打开则平滑淡入。
    ran_once: bool,
}

impl ParametricEq {
    /// 按输出采样率和声道数创建。`channels` 为 0 时按 1 处理。
    pub fn new(control: Arc<EqControl>, sample_rate: u32, channels: u16) -> Self {
        let channels = usize::from(channels.max(1));
        let settings = control.settings();
        let mut eq = Self {
            control,
            sample_rate: sample_rate.max(8_000),
            channels,
            filters: vec![Biquad::IDENTITY; channels * BAND_COUNT],
            generation: 0,
            target_preamp: settings.preamp_db,
            current_preamp: settings.preamp_db,
            target_gains: settings.bands_db,
            current_gains: settings.bands_db,
            smoothing: false,
            active: false,
            ran_once: false,
        };
        eq.rebuild();
        eq
    }

    /// 当前使用的采样率（测试 / 诊断用）。
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// 切换采样率并立即重建系数，同时清空滤波器历史。
    ///
    /// 会话换设备 / 换输出格式时会新建节点；这个入口也方便测试和将来的动态重采样。
    pub fn set_sample_rate(&mut self, sample_rate: u32) {
        let sample_rate = sample_rate.max(8_000);
        if sample_rate == self.sample_rate {
            return;
        }
        self.sample_rate = sample_rate;
        self.rebuild();
        self.reset_filters();
    }

    /// 清空滤波器历史（seek / flush / 旁路时调用），系数不变。
    pub fn reset(&mut self) {
        self.reset_filters();
    }

    /// 原地处理一块交错样本。`channels` 与会话建立时的声道数不一致时按实际声道数尽力处理。
    pub fn process(&mut self, samples: &mut [f32], channels: u16) {
        let first_block = !self.ran_once;
        self.ran_once = true;
        if !self.control.enabled() {
            if self.active {
                // 关掉时清历史，下次打开不会把旁路期间的旧状态接上。
                self.reset_filters();
                self.active = false;
            }
            return;
        }

        if !self.active {
            // 从旁路切到启用：抓当前参数并清历史，避免第一块出现旧数据。
            // 会话的第一块直接用目标参数；播放中途打开则从平直曲线平滑过渡，避免突变。
            self.active = true;
            let settings = self.control.settings();
            self.generation = self.control.generation();
            self.target_preamp = settings.preamp_db;
            self.target_gains = settings.bands_db;
            if !first_block {
                self.current_preamp = 0.0;
                self.current_gains = [0.0; BAND_COUNT];
                self.smoothing = true;
            } else {
                self.current_preamp = settings.preamp_db;
                self.current_gains = settings.bands_db;
                self.smoothing = false;
            }
            self.rebuild();
            self.reset_filters();
        } else {
            let generation = self.control.generation();
            if generation != self.generation {
                self.generation = generation;
                let settings = self.control.settings();
                self.target_preamp = settings.preamp_db;
                self.target_gains = settings.bands_db;
                self.smoothing = true;
            }
        }

        if self.smoothing && !self.smooth_towards_targets() {
            self.smoothing = false;
        }

        let flat = self.current_preamp.abs() < 1e-5
            && self.current_gains.iter().all(|gain| gain.abs() < 1e-5);
        if flat {
            // 平直曲线时保持零状态，之后重新加增益不会接上旧历史。
            self.reset_filters();
            return;
        }

        let channels = usize::from(channels.max(1)).min(self.channels);
        if channels == 0 || samples.is_empty() {
            return;
        }
        let frames = samples.len() / channels;
        let preamp = db_to_linear(self.current_preamp);
        let mut non_finite = false;
        for frame in 0..frames {
            let start = frame * channels;
            for channel in 0..channels {
                let mut value = samples[start + channel] * preamp;
                let base = channel * BAND_COUNT;
                for band in 0..BAND_COUNT {
                    value = self.filters[base + band].process(value);
                }
                if value.is_finite() {
                    samples[start + channel] = value.clamp(-SAFETY_LIMIT, SAFETY_LIMIT);
                } else {
                    samples[start + channel] = 0.0;
                    non_finite = true;
                }
            }
        }
        if non_finite {
            // NaN / Inf 会污染 biquad 的状态；清掉后下一块从干净状态继续。
            self.reset_filters();
        }
    }

    fn reset_filters(&mut self) {
        for filter in &mut self.filters {
            filter.reset();
        }
    }

    /// 返回是否还有未收敛的参数。
    fn smooth_towards_targets(&mut self) -> bool {
        let mut moving = false;
        if smooth_value(&mut self.current_preamp, self.target_preamp) {
            moving = true;
        }
        for band in 0..BAND_COUNT {
            if smooth_value(&mut self.current_gains[band], self.target_gains[band]) {
                moving = true;
            }
        }
        self.rebuild();
        moving
    }

    fn rebuild(&mut self) {
        for channel in 0..self.channels {
            for (band, frequency) in BAND_FREQUENCIES_HZ.iter().enumerate() {
                let index = channel * BAND_COUNT + band;
                let coefficients = Biquad::peaking(
                    self.sample_rate,
                    *frequency,
                    DEFAULT_Q,
                    self.current_gains[band],
                );
                // 只换系数，保留 z1/z2：参数平滑期间滤波器状态是连续的。
                let state = &mut self.filters[index];
                state.b0 = coefficients.b0;
                state.b1 = coefficients.b1;
                state.b2 = coefficients.b2;
                state.a1 = coefficients.a1;
                state.a2 = coefficients.a2;
            }
        }
    }
}

/// 把 `current` 向 `target` 推进一步；返回是否还在移动。
fn smooth_value(current: &mut f32, target: f32) -> bool {
    let delta = target - *current;
    if delta.abs() < 1e-4 {
        *current = target;
        return false;
    }
    *current += delta * SMOOTHING;
    if (target - *current).abs() < 1e-4 {
        *current = target;
        false
    } else {
        true
    }
}

/// dB 转线性增益（与 [`crate::dsp::db_to_linear`] 相同的公式，避免 eq 模块依赖 dsp 的测试）。
fn db_to_linear(db: f32) -> f32 {
    10f32.powf(db / 20.0)
}

/// 一个内置预设。
#[derive(Debug, Clone, Copy)]
pub struct EqPreset {
    /// 稳定 ID，写进 `playback.eq.preset`。
    pub id: &'static str,
    /// 显示名称。
    pub name: &'static str,
    /// 说明（来源 / 适用场景）。
    pub description: &'static str,
    /// 建议 preamp（dB）。
    pub preamp_db: f32,
    /// 10 段增益（dB），顺序同 [`BAND_FREQUENCIES_HZ`]。
    pub bands_db: [f32; BAND_COUNT],
}

impl EqPreset {
    /// 转成可应用的设置（默认不改变启用状态）。
    pub fn settings(&self, enabled: bool) -> EqSettings {
        EqSettings::new(enabled, self.preamp_db, &self.bands_db)
    }
}

/// 内置的 AutoEQ 风格预设。
///
/// 这些曲线是**近似补偿**（按常见耳机的趋势手工整理），不是官方测量数据。
/// 不同耳罩 / 佩戴方式 / 固件都会改变实际响应，请以听感为准并自行微调。
pub const PRESETS: &[EqPreset] = &[
    EqPreset {
        id: "sony-wh-1000xm5",
        name: "Sony WH-1000XM5",
        description: "降低低频轰鸣、轻微提升高频细节（近似）",
        preamp_db: -5.5,
        bands_db: [4.5, 4.0, 2.0, 0.0, -1.5, -2.0, -1.0, 0.5, 2.0, 2.5],
    },
    EqPreset {
        id: "apple-airpods-pro-2",
        name: "Apple AirPods Pro 2",
        description: "收敛低频、平衡中高频（近似）",
        preamp_db: -3.0,
        bands_db: [2.5, 2.0, 0.5, -0.5, -1.0, -0.5, 0.0, 0.5, 1.5, 1.0],
    },
    EqPreset {
        id: "sennheiser-hd-600",
        name: "Sennheiser HD 600",
        description: "接近中性的微调，保留自然中频（近似）",
        preamp_db: -2.0,
        bands_db: [0.5, 0.5, 0.0, -0.5, -0.5, 0.0, 0.5, 0.5, 0.0, -0.5],
    },
    EqPreset {
        id: "sennheiser-hd-650",
        name: "Sennheiser HD 650",
        description: "减少一点中低频厚度，补足空气感（近似）",
        preamp_db: -1.5,
        bands_db: [1.0, 0.5, 0.0, -0.5, -0.5, 0.0, 0.5, 0.5, 0.0, -1.0],
    },
    EqPreset {
        id: "beyerdynamic-dt-770-pro",
        name: "Beyerdynamic DT 770 Pro",
        description: "压低低频与刺耳高频，适合封闭式监听（近似）",
        preamp_db: -4.5,
        bands_db: [-3.0, -2.0, -0.5, 0.5, 0.0, -0.5, 0.0, 1.5, 2.0, 1.0],
    },
    EqPreset {
        id: "moondrop-aria",
        name: "Moondrop Aria",
        description: "柔化高频、增加一点低频下潜（近似）",
        preamp_db: -2.5,
        bands_db: [1.5, 1.0, 0.0, -0.5, 0.0, 0.5, 0.5, 0.5, 0.0, -0.5],
    },
    EqPreset {
        id: "7hz-salnotes-zero",
        name: "7Hz Salnotes Zero",
        description: "补足低频、保留清晰的极高频（近似）",
        preamp_db: -2.0,
        bands_db: [2.5, 1.5, 0.0, -0.5, 0.5, 0.5, 0.0, 0.5, 0.0, -0.5],
    },
    EqPreset {
        id: "apple-airpods-max",
        name: "Apple AirPods Max",
        description: "收敛低频、提升高频通透度（近似）",
        preamp_db: -4.0,
        bands_db: [3.0, 2.0, 0.5, -0.5, -1.0, -0.5, 0.0, 0.5, 1.5, 1.0],
    },
    EqPreset {
        id: "sony-wf-1000xm5",
        name: "Sony WF-1000XM5",
        description: "减少低频堆积、平衡人声（近似）",
        preamp_db: -4.0,
        bands_db: [3.5, 2.5, 0.5, -0.5, -1.0, -0.5, 0.0, 0.5, 1.5, 1.0],
    },
    EqPreset {
        id: "sennheiser-ie-600",
        name: "Sennheiser IE 600",
        description: "轻微低频增益与高频顺滑（近似）",
        preamp_db: -2.0,
        bands_db: [1.0, 0.5, 0.0, -0.5, 0.0, 0.5, 0.5, 0.5, 0.0, -0.5],
    },
];

/// 按 ID 找预设。
pub fn preset(id: &str) -> Option<&'static EqPreset> {
    PRESETS.iter().find(|preset| preset.id == id)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    fn rms(samples: &[f32]) -> f32 {
        if samples.is_empty() {
            return 0.0;
        }
        (samples.iter().map(|s| s * s).sum::<f32>() / samples.len() as f32).sqrt()
    }

    fn sine(rate: u32, frequency: f32, frames: usize) -> Vec<f32> {
        (0..frames)
            .map(|i| (2.0 * std::f32::consts::PI * frequency * i as f32 / rate as f32).sin() * 0.25)
            .collect()
    }

    #[test]
    fn bypass_is_bit_exact_and_does_not_touch_buffers() {
        let control = Arc::new(EqControl::new(EqSettings::new(
            false,
            6.0,
            &[12.0, 12.0, 12.0, 12.0, 12.0, 12.0, 12.0, 12.0, 12.0, 12.0],
        )));
        let mut eq = ParametricEq::new(control, 48_000, 2);
        let original = vec![0.1, -0.2, 0.3, -0.4, 0.5, -0.6];
        let mut samples = original.clone();
        eq.process(&mut samples, 2);
        assert_eq!(samples, original);
    }

    #[test]
    fn single_band_boost_at_center_frequency() {
        let control = Arc::new(EqControl::new(EqSettings::new(
            true,
            0.0,
            &[0.0, 0.0, 0.0, 0.0, 0.0, 6.0, 0.0, 0.0, 0.0, 0.0],
        )));
        let rate = 48_000;
        let mut eq = ParametricEq::new(control, rate, 1);
        let mut samples = sine(rate, 1_000.0, 24_000);
        // 让滤波器先进入稳态，再比较后半段。
        eq.process(&mut samples, 1);
        let before = rms(&sine(rate, 1_000.0, 12_000));
        let after = rms(&samples[12_000..]);
        let gain_db = 20.0 * (after / before).log10();
        assert!(
            (gain_db - 6.0).abs() < 0.6,
            "1 kHz 中心频率应接近 +6 dB，实际 {gain_db:.2} dB"
        );
    }

    #[test]
    fn preamp_scales_the_whole_signal() {
        let control = Arc::new(EqControl::new(EqSettings::new(
            true,
            -6.020_6,
            &[0.0; BAND_COUNT],
        )));
        let mut eq = ParametricEq::new(control, 48_000, 2);
        let mut samples = vec![0.2, -0.2, 0.4, -0.4];
        eq.process(&mut samples, 2);
        let expected = 10f32.powf(-6.020_6 / 20.0);
        let input = [0.2f32, -0.2, 0.4, -0.4];
        for (sample, original) in samples.iter().zip(input) {
            assert!(
                (sample - original * expected).abs() < 1e-5,
                "preamp 应为线性缩放，实际 {samples:?}"
            );
        }
    }

    #[test]
    fn coefficients_stay_finite_at_all_supported_rates() {
        let bands = [
            12.0f32, -12.0, 12.0, -12.0, 12.0, -12.0, 12.0, -12.0, 12.0, -12.0,
        ];
        let control = Arc::new(EqControl::new(EqSettings::new(true, 12.0, &bands)));
        for rate in [8_000u32, 44_100, 48_000, 96_000, 192_000] {
            let mut eq = ParametricEq::new(control.clone(), rate, 2);
            assert_eq!(eq.sample_rate(), rate);
            for filter in &eq.filters {
                assert!(filter.b0.is_finite());
                assert!(filter.b1.is_finite());
                assert!(filter.b2.is_finite());
                assert!(filter.a1.is_finite());
                assert!(filter.a2.is_finite());
            }
            let mut samples = vec![0.5f32; 4_096];
            eq.process(&mut samples, 2);
            assert!(
                samples.iter().all(|s| s.is_finite()),
                "{rate} Hz 处理后的样本必须有限"
            );
        }
    }

    #[test]
    fn sample_rate_change_rebuilds_coefficients() {
        let control = Arc::new(EqControl::new(EqSettings::new(
            true,
            0.0,
            &[0.0, 0.0, 0.0, 0.0, 0.0, 6.0, 0.0, 0.0, 0.0, 0.0],
        )));
        let mut eq = ParametricEq::new(control, 44_100, 1);
        let before = eq.filters[5].b0;
        eq.set_sample_rate(96_000);
        let after = eq.filters[5].b0;
        assert_eq!(eq.sample_rate(), 96_000);
        assert!(
            (before - after).abs() > 1e-6,
            "不同采样率必须重算系数：{before} vs {after}"
        );
    }

    #[test]
    fn settings_are_clamped_and_non_finite_is_rejected() {
        let settings = EqSettings::new(
            true,
            99.0,
            &[
                -99.0,
                99.0,
                f32::NAN,
                f32::INFINITY,
                f32::NEG_INFINITY,
                1.0,
                -1.0,
                0.0,
                12.0,
                -12.0,
            ],
        )
        .sanitized();
        assert_eq!(settings.preamp_db, MAX_GAIN_DB);
        assert_eq!(settings.bands_db[0], MIN_GAIN_DB);
        assert_eq!(settings.bands_db[1], MAX_GAIN_DB);
        assert_eq!(settings.bands_db[2], 0.0);
        assert_eq!(settings.bands_db[3], 0.0);
        assert_eq!(settings.bands_db[4], 0.0);
        assert_eq!(settings.bands_db[8], MAX_GAIN_DB);
        assert_eq!(settings.bands_db[9], MIN_GAIN_DB);
    }

    #[test]
    fn presets_are_complete_and_in_range() {
        assert!(PRESETS.len() >= 8, "至少要有 8 个内置预设");
        for preset in PRESETS {
            assert!(!preset.id.is_empty());
            assert!(!preset.name.is_empty());
            assert!(preset.preamp_db >= MIN_GAIN_DB && preset.preamp_db <= MAX_GAIN_DB);
            assert!(
                preset
                    .bands_db
                    .iter()
                    .all(|gain| gain.is_finite() && *gain >= MIN_GAIN_DB && *gain <= MAX_GAIN_DB),
                "{} 的频段越界",
                preset.id
            );
        }
        assert!(preset("sennheiser-hd-600").is_some());
        assert!(preset("not-a-real-headphone").is_none());
    }

    #[test]
    fn non_finite_input_does_not_escape() {
        let control = Arc::new(EqControl::new(EqSettings::new(
            true,
            0.0,
            &[6.0; BAND_COUNT],
        )));
        let mut eq = ParametricEq::new(control, 48_000, 2);
        let mut samples = vec![f32::NAN, f32::INFINITY, f32::NEG_INFINITY, 0.5];
        eq.process(&mut samples, 2);
        assert!(
            samples.iter().all(|s| s.is_finite()),
            "NaN / Inf 不能扩散到输出：{samples:?}"
        );
        // 坏样本会污染滤波器状态；随后输入的正常样本必须还能正常出声。
        let mut recovered = vec![0.5f32; 512];
        eq.process(&mut recovered, 2);
        assert!(
            recovered.iter().all(|s| s.is_finite()) && recovered.iter().any(|s| *s != 0.0),
            "清理状态后必须恢复处理：{recovered:?}"
        );
    }

    #[test]
    fn stereo_channels_have_independent_state() {
        let control = Arc::new(EqControl::new(EqSettings::new(
            true,
            0.0,
            &[0.0, 0.0, 0.0, 0.0, 0.0, 6.0, 0.0, 0.0, 0.0, 0.0],
        )));
        let mut eq = ParametricEq::new(control, 48_000, 2);
        let mut left = sine(48_000, 1_000.0, 4_096);
        let mut interleaved = Vec::with_capacity(left.len() * 2);
        for sample in &left {
            interleaved.push(*sample);
            interleaved.push(0.0);
        }
        eq.process(&mut interleaved, 2);
        for (i, frame) in interleaved.chunks_exact(2).enumerate() {
            left[i] = frame[0];
            assert_eq!(frame[1], 0.0, "右声道输入为 0 时输出也必须为 0");
        }
        assert!(left.iter().any(|sample| sample.abs() > 0.25));
    }
}
