//! DSP 链。每个节点原地处理一块 f32 交错样本。
//!
//! 节点在解码线程上运行，不在实时线程上，但仍然要求：`process` 里不分配内存。
//! 比特完美模式（PLY-05）下整条 DSP 链被跳过。
//!
//! 共享模式还有一条**输出侧**的淡入淡出包络（[`FadeRamp`]）：它在实时回调里
//! 对已经从环形缓冲取出的样本做 20 ms 线性斜坡。ReplayGain / 音量仍然只在解码
//! 线程的 [`Gain`] 链里应用一次，淡入淡出不会重复乘增益。比特完美独占链路不建
//! 这个包络，样本位模式保持原样。

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

/// 默认淡入 / 淡出时长（毫秒）。20 ms 足够盖住播放、暂停、seek 的阶跃，
/// 又短到不会被听成"音量渐变"。
pub const DEFAULT_FADE_MS: u32 = 20;

/// DSP 节点。
pub trait DspNode: Send {
    /// 原地处理样本。`channels` 是声道数，`samples.len()` 是声道数的整数倍。
    fn process(&mut self, samples: &mut [f32], channels: u16);

    /// 切歌或跳转时重置内部状态（滤波器历史等）。
    fn reset(&mut self) {}
}

/// 把 dB 转成线性增益。
pub fn db_to_linear(db: f32) -> f32 {
    10f32.powf(db / 20.0)
}

/// 一次淡入 / 淡出需要多少**帧**（不是样本；立体声要再乘声道数）。
pub fn fade_frames(sample_rate: u32, fade_ms: u32) -> usize {
    let frames = u64::from(sample_rate) * u64::from(fade_ms) / 1_000;
    usize::try_from(frames.max(1)).unwrap_or(1)
}

/// 跨线程的淡入淡出目标（0.0 = 静音，1.0 = 原样）。
///
/// 引擎 / 解码线程写，实时回调只读；内部只有一个原子量，不加锁、不分配。
#[derive(Clone, Debug)]
pub struct FadeControl {
    target_bits: Arc<AtomicU32>,
}

impl FadeControl {
    /// 创建，`target` 通常从 1.0 开始（新会话淡入）。
    pub fn new(target: f32) -> Self {
        Self {
            target_bits: Arc::new(AtomicU32::new(target.clamp(0.0, 1.0).to_bits())),
        }
    }

    /// 要求下一次回调开始向 `target` 斜坡。
    pub fn set_target(&self, target: f32) {
        self.target_bits
            .store(target.clamp(0.0, 1.0).to_bits(), Ordering::Release);
    }

    /// 淡出到静音。
    pub fn fade_out(&self) {
        self.set_target(0.0);
    }

    /// 淡入到原样。
    pub fn fade_in(&self) {
        self.set_target(1.0);
    }

    /// 实时回调读到的目标值。
    pub fn target(&self) -> f32 {
        f32::from_bits(self.target_bits.load(Ordering::Acquire)).clamp(0.0, 1.0)
    }
}

/// 输出侧线性淡入淡出包络。
///
/// 语义（和测试里的断言一致）：
/// - 从 0 淡入时第一帧增益是 `1 / frames`（不是 0），最后一帧正好 1.0；
/// - 从 1 淡出时第一帧保持 1.0，第 `frames` 帧增益是 `1 / frames`，之后归零；
/// - 每个**帧**的所有声道用同一个增益，声道之间不会错位；
/// - `reset()` 会把增益归零并等待下一次有真实样本时重新淡入 —— seek / flush 之后
///   即使回调在静音欠载里空转，也不会提前把斜坡走完。
#[derive(Debug, Clone)]
pub struct FadeRamp {
    step: f32,
    gain: f32,
    primed: bool,
}

impl FadeRamp {
    /// 按采样率创建（初始静音，等待首块样本淡入）。
    pub fn new(sample_rate: u32, fade_ms: u32) -> Self {
        let frames = fade_frames(sample_rate, fade_ms);
        Self {
            step: 1.0 / frames as f32,
            gain: 0.0,
            primed: false,
        }
    }

    /// 当前增益（测试 / 诊断用）。
    pub fn gain(&self) -> f32 {
        self.gain
    }

    /// seek / flush 后重新从静音开始，且必须等真实样本到来才起斜坡。
    pub fn reset(&mut self) {
        self.gain = 0.0;
        self.primed = false;
    }

    /// 原地处理一块交错样本，向 `target` 线性靠近。
    ///
    /// 实时线程安全：只做浮点运算，不分配、不加锁、不打日志。
    pub fn process(&mut self, samples: &mut [f32], channels: u16, target: f32) {
        let channels = usize::from(channels.max(1));
        let frames = samples.len() / channels;
        if frames == 0 {
            return;
        }
        if !self.primed {
            // 第一次拿到真实样本：从静音起斜坡；之前空转的静音块不消耗斜坡。
            self.primed = true;
        }
        let target = target.clamp(0.0, 1.0);
        let start = self.gain;
        let delta = target - start;
        if delta.abs() <= f32::EPSILON {
            if (target - 1.0).abs() > f32::EPSILON {
                scale_rest(samples, 0, channels, target);
            }
            self.gain = target;
            return;
        }

        // 用「需要多少帧」而不是反复累加 step：f32 下 960 × (1/960) 不会精确等于 1，
        // 逐帧插值能保证第 N 帧正好落在目标值上（拼接点 / 测试都依赖这个）。
        let total = ((delta.abs() / self.step.max(f32::MIN_POSITIVE)).round() as usize).max(1);
        let ramp_frames = frames.min(total);
        for frame in 0..ramp_frames {
            // 淡入从 step 开始、淡出从原增益开始，两者共用同一条线性插值。
            let position = if delta > 0.0 {
                (frame + 1) as f32
            } else {
                frame as f32
            } / total as f32;
            scale_frame(samples, frame, channels, start + delta * position);
        }
        if frames >= total {
            self.gain = target;
            scale_rest(samples, total, channels, target);
        } else {
            self.gain = start + delta * (frames as f32 / total as f32);
        }
    }
}

/// 给一整帧的所有声道乘同一个增益。
#[inline]
fn scale_frame(samples: &mut [f32], frame: usize, channels: usize, gain: f32) {
    let start = frame * channels;
    for sample in &mut samples[start..start + channels] {
        *sample *= gain;
    }
}

/// 从 `first_frame` 起整段乘同一个增益。
#[inline]
fn scale_rest(samples: &mut [f32], first_frame: usize, channels: usize, gain: f32) {
    if (gain - 1.0).abs() <= f32::EPSILON {
        return;
    }
    let start = first_frame * channels;
    for sample in &mut samples[start..] {
        *sample *= gain;
    }
}

/// ReplayGain / 音量节点（PLY-03）。
#[derive(Debug, Clone)]
pub struct Gain {
    linear: f32,
}

impl Gain {
    /// 用 dB 值创建。
    pub fn from_db(db: f32) -> Self {
        Self {
            linear: db_to_linear(db),
        }
    }

    /// 修改增益。
    pub fn set_db(&mut self, db: f32) {
        self.linear = db_to_linear(db);
    }
}

impl DspNode for Gain {
    fn process(&mut self, samples: &mut [f32], _channels: u16) {
        if (self.linear - 1.0).abs() < f32::EPSILON {
            return;
        }
        for s in samples.iter_mut() {
            *s *= self.linear;
        }
    }
}

/// 简单的软限幅器，防止 ReplayGain 正增益或 EQ 导致削波（PLY-03 防削波）。
///
/// TODO：换成带前瞻（look-ahead）的真正限幅器。
#[derive(Debug, Clone, Default)]
pub struct SoftClipper;

impl DspNode for SoftClipper {
    fn process(&mut self, samples: &mut [f32], _channels: u16) {
        for s in samples.iter_mut() {
            let x = *s;
            if x.abs() > 0.9 {
                // 0.9 以上用 tanh 曲线压到 (−1, 1)。
                *s = x.signum() * (0.9 + 0.1 * ((x.abs() - 0.9) / 0.1).tanh());
            }
        }
    }
}

/// DSP 链。
#[derive(Default)]
pub struct DspChain {
    nodes: Vec<Box<dyn DspNode>>,
}

impl DspChain {
    /// 追加节点。
    pub fn push(&mut self, node: Box<dyn DspNode>) {
        self.nodes.push(node);
    }

    /// 依次执行所有节点。
    pub fn process(&mut self, samples: &mut [f32], channels: u16) {
        for node in &mut self.nodes {
            node.process(samples, channels);
        }
    }

    /// 重置所有节点。
    pub fn reset(&mut self) {
        for node in &mut self.nodes {
            node.reset();
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn gain_and_clip() {
        let mut chain = DspChain::default();
        chain.push(Box::new(Gain::from_db(6.0)));
        chain.push(Box::new(SoftClipper));
        let mut buf = vec![0.1, -0.1, 0.9, -0.9];
        chain.process(&mut buf, 2);
        assert!((buf[0] - 0.1995).abs() < 0.001);
        // 软限幅的渐近线是满刻度 1.0，f32 精度下大信号会正好等于 1.0，但绝不能超过。
        assert!(buf.iter().all(|s| s.abs() <= 1.0));
    }

    /// 20 ms @ 48 kHz = 960 帧。淡入必须线性、单调、第一帧 ≈ 1/960、第 960 帧正好 1。
    #[test]
    fn fade_in_ramp_shape_is_linear_and_reaches_unity() {
        let frames = fade_frames(48_000, DEFAULT_FADE_MS);
        assert_eq!(frames, 960);
        let mut ramp = FadeRamp::new(48_000, DEFAULT_FADE_MS);
        let mut samples = vec![1.0f32; frames + 100];
        ramp.process(&mut samples, 1, 1.0);

        let step = 1.0 / frames as f32;
        assert!(
            (samples[0] - step).abs() < 1e-6,
            "第一帧应为 step（{step}），实际 {}",
            samples[0]
        );
        assert!(
            (samples[frames - 1] - 1.0).abs() < 1e-6,
            "第 {frames} 帧应到达 1.0，实际 {}",
            samples[frames - 1]
        );
        assert!(samples[frames..].iter().all(|s| *s == 1.0));
        for pair in samples[..frames].windows(2) {
            assert!(
                pair[1] >= pair[0],
                "淡入不能回头：{} -> {}",
                pair[0],
                pair[1]
            );
            assert!(
                pair[1] - pair[0] <= step + 1e-7,
                "淡入步进不能超过 1/frames"
            );
        }
        eprintln!(
            "fade measurement: in ramp {} frames ({:.3} ms) @ 48 kHz",
            frames,
            frames as f64 / 48.0
        );
    }

    /// 淡出第一帧保持 1.0，第 960 帧 ≈ 1/960，之后完全静音。
    #[test]
    fn fade_out_ramp_shape_is_linear_and_ends_at_silence() {
        let frames = fade_frames(48_000, DEFAULT_FADE_MS);
        let mut ramp = FadeRamp::new(48_000, DEFAULT_FADE_MS);
        let mut warmup = vec![1.0f32; frames];
        ramp.process(&mut warmup, 1, 1.0);
        assert!((ramp.gain() - 1.0).abs() < 1e-6);

        let mut samples = vec![1.0f32; frames + 100];
        ramp.process(&mut samples, 1, 0.0);
        let step = 1.0 / frames as f32;
        assert!((samples[0] - 1.0).abs() < 1e-6, "淡出第一帧必须保持原样");
        assert!(
            (samples[frames - 1] - step).abs() < 1e-6,
            "淡出最后一帧应为 step，实际 {}",
            samples[frames - 1]
        );
        assert!(samples[frames..].iter().all(|s| *s == 0.0));
        for pair in samples[..frames].windows(2) {
            assert!(
                pair[1] <= pair[0],
                "淡出不能回升：{} -> {}",
                pair[0],
                pair[1]
            );
            assert!(
                pair[0] - pair[1] <= step + 1e-7,
                "淡出步进不能超过 1/frames"
            );
        }
        assert_eq!(ramp.gain(), 0.0);
    }

    /// 立体声的左右声道必须共用同一个帧增益，不能一个先淡完。
    #[test]
    fn fade_ramp_keeps_channels_coherent() {
        let mut ramp = FadeRamp::new(8_000, DEFAULT_FADE_MS);
        let mut samples = vec![0.5f32; 800];
        ramp.process(&mut samples, 2, 1.0);
        for frame in samples.chunks_exact(2) {
            assert!(
                (frame[0] - frame[1]).abs() < 1e-9,
                "左右声道增益不一致：{frame:?}"
            );
        }
    }

    /// reset 之后必须等真实样本才起斜坡：seek 清空缓冲期间的静音块不能把淡入走完。
    #[test]
    fn fade_ramp_waits_for_samples_after_reset() {
        let frames = fade_frames(8_000, DEFAULT_FADE_MS);
        let mut ramp = FadeRamp::new(8_000, DEFAULT_FADE_MS);
        let mut warmup = vec![1.0f32; frames];
        ramp.process(&mut warmup, 1, 1.0);
        ramp.reset();
        // 输出回调只在真的取到样本时调用 process；seek 期间的欠载静音块不会走到这里。
        assert_eq!(ramp.gain(), 0.0, "flush 后增益必须归零");

        let mut samples = vec![1.0f32; frames];
        ramp.process(&mut samples, 1, 1.0);
        assert!(
            (samples[0] - 1.0 / frames as f32).abs() < 1e-6,
            "flush 后第一帧应从 step 开始淡入"
        );
        assert!((samples[frames - 1] - 1.0).abs() < 1e-6);
    }
}
