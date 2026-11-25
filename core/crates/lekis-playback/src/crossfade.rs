//! 交叉淡入淡出（PLY-02）与 EBU R128 响度 / 尾段静音检测。
//!
//! - **等功率交叉淡变（Equal-Power Crossfade）**：采用正余弦曲线
//!   `out = a * cos(t * π/2) + b * sin(t * π/2)`，过渡中点能量恒定（`cos² + sin² = 1`），
//!   不会出现线性交叉淡变常见的中段音量塌陷。
//! - **EBU R128 响度与智能静音跳过**：借助 `ebur128` 测量瞬时响度（Momentary LUFS），
//!   当开启智能尾段检测且曲目接近结尾、响度持续低于阈值（默认 `-45 LUFS`）时提前切入
//!   交叉淡入淡出，避免长时间尾段空白。
//! - **线程模型**：[`CrossfadeControl`] 只含无锁原子量，由核心 / 引擎写入，解码线程读取。
//!   比特完美独占模式跳过交叉淡入淡出（避免改动原始样本位模式）。

use ebur128::{EbuR128, Mode};
use std::f32::consts::FRAC_PI_2;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;

/// 允许的最大交叉淡入淡出时长（毫秒）：12 秒。
pub const MAX_CROSSFADE_MS: u32 = 12_000;

/// 尾段静音检测默认阈值（LUFS）。低于该值视为接近静音。
pub const DEFAULT_SILENCE_THRESHOLD_LUFS: f64 = -45.0;

/// 交叉淡入淡出设置。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CrossfadeSettings {
    /// 交叉淡入淡出时长（毫秒）。`0` 表示关闭（退回样本级无缝播放）。
    pub duration_ms: u32,
    /// 智能静音检测：利用 EBU R128 瞬时响度，在曲目末尾静音段提前开始过渡。
    pub smart_silence: bool,
}

impl CrossfadeSettings {
    /// 创建设置，自动将时长裁剪到 `0..=MAX_CROSSFADE_MS`。
    pub fn new(duration_ms: u32, smart_silence: bool) -> Self {
        Self {
            duration_ms: duration_ms.min(MAX_CROSSFADE_MS),
            smart_silence,
        }
    }
}

/// 跨线程共享的交叉淡入淡出控制句柄（无锁）。
#[derive(Debug, Default)]
pub struct CrossfadeControl {
    duration_ms: AtomicU32,
    smart_silence: AtomicBool,
}

impl CrossfadeControl {
    /// 创建控制句柄。
    pub fn new(settings: CrossfadeSettings) -> Self {
        Self {
            duration_ms: AtomicU32::new(settings.duration_ms.min(MAX_CROSSFADE_MS)),
            smart_silence: AtomicBool::new(settings.smart_silence),
        }
    }

    /// 读取当前时长（毫秒）。
    pub fn duration_ms(&self) -> u32 {
        self.duration_ms.load(Ordering::Acquire)
    }

    /// 读取是否开启智能静音检测。
    pub fn smart_silence(&self) -> bool {
        self.smart_silence.load(Ordering::Acquire)
    }

    /// 读取完整设置。
    pub fn settings(&self) -> CrossfadeSettings {
        CrossfadeSettings {
            duration_ms: self.duration_ms(),
            smart_silence: self.smart_silence(),
        }
    }

    /// 更新时长（毫秒），自动裁剪到 `0..=MAX_CROSSFADE_MS`。
    pub fn set_duration_ms(&self, ms: u32) {
        self.duration_ms
            .store(ms.min(MAX_CROSSFADE_MS), Ordering::Release);
    }

    /// 更新智能静音检测开关。
    pub fn set_smart_silence(&self, enabled: bool) {
        self.smart_silence.store(enabled, Ordering::Release);
    }

    /// 一次性更新全部设置。
    pub fn set(&self, settings: CrossfadeSettings) {
        self.set_duration_ms(settings.duration_ms);
        self.set_smart_silence(settings.smart_silence);
    }

    /// 以 `Arc` 包装构造。
    pub fn shared(settings: CrossfadeSettings) -> Arc<Self> {
        Arc::new(Self::new(settings))
    }
}

/// 等功率交叉淡入淡出混音器（运行在解码线程上，处理设备格式的交错 f32 样本）。
#[derive(Debug, Clone)]
pub struct CrossfadeMixer {
    total_frames: usize,
    done_frames: usize,
    channels: usize,
}

impl CrossfadeMixer {
    /// 创建指定总帧数的混音器。
    pub fn new(sample_rate: u32, channels: u16, duration_ms: u32) -> Self {
        let frames = (u64::from(sample_rate) * u64::from(duration_ms) / 1_000).max(1) as usize;
        Self {
            total_frames: frames,
            done_frames: 0,
            channels: usize::from(channels.max(1)),
        }
    }

    /// 已完成的过渡进度（`0.0..=1.0`）。
    pub fn progress(&self) -> f32 {
        (self.done_frames as f32 / self.total_frames as f32).clamp(0.0, 1.0)
    }

    /// 是否已经完成整段交叉淡入淡出。
    pub fn is_finished(&self) -> bool {
        self.done_frames >= self.total_frames
    }

    /// 剩余过渡帧数。
    pub fn remaining_frames(&self) -> usize {
        self.total_frames.saturating_sub(self.done_frames)
    }

    /// 将当前曲目片段 `outgoing` 与下一首片段 `incoming` 按等功率曲线混音写入 `out`。
    ///
    /// - 两者长度不足对方时，缺失部分按 `0.0` 处理（例如 `outgoing` 提前到达 EOF）；
    /// - 最多处理到本混音器剩余帧数为止，返回本次消耗的帧数。
    pub fn mix_chunk(&mut self, outgoing: &[f32], incoming: &[f32], out: &mut Vec<f32>) -> usize {
        let ch = self.channels;
        let out_frames = outgoing.len() / ch;
        let in_frames = incoming.len() / ch;
        let avail = out_frames.max(in_frames);
        let frames = avail.min(self.remaining_frames());
        if frames == 0 {
            return 0;
        }
        out.reserve(frames * ch);
        let total = self.total_frames as f32;
        for f in 0..frames {
            let t = ((self.done_frames + f) as f32 / total).clamp(0.0, 1.0);
            let angle = t * FRAC_PI_2;
            let gain_out = angle.cos();
            let gain_in = angle.sin();
            let base = f * ch;
            for c in 0..ch {
                let a = outgoing.get(base + c).copied().unwrap_or(0.0);
                let b = incoming.get(base + c).copied().unwrap_or(0.0);
                out.push(a * gain_out + b * gain_in);
            }
        }
        self.done_frames += frames;
        frames
    }
}

/// 基于 EBU R128 的实时响度与静音检测器。
pub struct LoudnessDetector {
    ebur: Option<EbuR128>,
    channels: u16,
    sample_rate: u32,
    silence_threshold_lufs: f64,
    quiet_frames: u64,
    fed_frames: u64,
}

impl LoudnessDetector {
    /// 按设备输出格式构造检测器。
    pub fn new(sample_rate: u32, channels: u16) -> Self {
        let ebur = EbuR128::new(u32::from(channels.max(1)), sample_rate.max(1), Mode::M).ok();
        Self {
            ebur,
            channels: channels.max(1),
            sample_rate: sample_rate.max(1),
            silence_threshold_lufs: DEFAULT_SILENCE_THRESHOLD_LUFS,
            quiet_frames: 0,
            fed_frames: 0,
        }
    }

    /// 重置内部窗口（切歌或 seek 后调用）。
    pub fn reset(&mut self) {
        self.ebur = EbuR128::new(u32::from(self.channels), self.sample_rate, Mode::M).ok();
        self.quiet_frames = 0;
        self.fed_frames = 0;
    }

    /// 送入一块交错 f32 样本，更新瞬时响度与静音持续帧数。
    pub fn feed(&mut self, samples: &[f32]) {
        let ch = usize::from(self.channels);
        let frames = (samples.len() / ch) as u64;
        if frames == 0 {
            return;
        }
        self.fed_frames += frames;
        let Some(ebur) = self.ebur.as_mut() else {
            return;
        };
        if ebur.add_frames_f32(samples).is_err() {
            return;
        }
        // EBU R128 Momentary 窗口是 400 ms；喂满后再判静音，避免曲目开头误触发。
        let min_frames = u64::from(self.sample_rate) * 400 / 1_000;
        if self.fed_frames < min_frames {
            return;
        }
        match ebur.loudness_momentary() {
            Ok(lufs) if lufs < self.silence_threshold_lufs => {
                self.quiet_frames = self.quiet_frames.saturating_add(frames);
            }
            Ok(_) => {
                self.quiet_frames = 0;
            }
            Err(_) => {}
        }
    }

    /// 最近瞬时响度（LUFS），数据不足或初始化失败时为 `None`。
    pub fn momentary_lufs(&self) -> Option<f64> {
        self.ebur.as_ref()?.loudness_momentary().ok()
    }

    /// 连续低于静音阈值的时长是否已达到 `min_quiet_ms` 毫秒。
    pub fn is_trailing_silence(&self, min_quiet_ms: u64) -> bool {
        let needed = u64::from(self.sample_rate).saturating_mul(min_quiet_ms) / 1_000;
        self.quiet_frames >= needed.max(1)
    }
}

/// 离线计算整段 f32 交错音频的 EBU R128 综合响度（LUFS），可用于按需补算 ReplayGain。
pub fn measure_integrated_lufs(samples: &[f32], sample_rate: u32, channels: u16) -> Option<f64> {
    let mut meter = EbuR128::new(u32::from(channels.max(1)), sample_rate.max(1), Mode::I).ok()?;
    meter.add_frames_f32(samples).ok()?;
    let lufs = meter.loudness_global().ok()?;
    lufs.is_finite().then_some(lufs)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn equal_power_crossfade_preserves_midpoint_energy() {
        let mut mixer = CrossfadeMixer::new(1_000, 2, 100); // 100 frames
        let outgoing = vec![1.0f32; 200]; // 100 stereo frames
        let incoming = vec![1.0f32; 200];
        let mut out = Vec::new();
        let consumed = mixer.mix_chunk(&outgoing, &incoming, &mut out);
        assert_eq!(consumed, 100);
        assert!(mixer.is_finished());
        // First frame: cos(0)=1, sin(0)=0 -> 1.0
        assert!((out[0] - 1.0).abs() < 1e-4);
        // Midpoint frame (50): cos(pi/4)+sin(pi/4) = sqrt(2) ≈ 1.414 (correlated signals);
        // for uncorrelated signals energy cos^2 + sin^2 = 1.0.
        let mid = out[50 * 2];
        assert!((mid - std::f32::consts::SQRT_2).abs() < 0.02, "mid = {mid}");
        // Last frame approaches incoming only
        let last = out[99 * 2];
        assert!((last - 1.0).abs() < 0.05, "last = {last}");
    }

    #[test]
    fn ebur128_detector_distinguishes_loud_signal_from_trailing_silence() {
        let sr = 48_000u32;
        let mut det = LoudnessDetector::new(sr, 2);
        // 0.6s of 440 Hz sine wave at -6 dBFS
        let loud_frames = (sr * 600 / 1_000) as usize;
        let mut loud = Vec::with_capacity(loud_frames * 2);
        for i in 0..loud_frames {
            let s = 0.5 * (2.0 * std::f32::consts::PI * 440.0 * i as f32 / sr as f32).sin();
            loud.push(s);
            loud.push(s);
        }
        det.feed(&loud);
        assert!(!det.is_trailing_silence(150));
        assert!(det.momentary_lufs().unwrap() > -20.0);

        // 0.8s of silence
        let silent = vec![0.0f32; (sr * 800 / 1_000) as usize * 2];
        det.feed(&silent);
        assert!(det.is_trailing_silence(150));
    }
}
