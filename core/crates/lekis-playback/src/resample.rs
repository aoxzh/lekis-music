//! 格式转换：声道映射 + 采样率转换（PLY-07）。
//!
//! 设备不一定接受内容本来的格式：共享模式下的 WASAPI 一般固定 48 kHz 立体声，
//! 而曲目可能是 44.1 kHz、单声道、甚至 5.1。这里在**解码线程**上把内容格式转换成设备格式，
//! 输出回调只从环形缓冲里拿已经转好的样本 —— 实时线程里不做任何重采样。
//!
//! 两道工序：
//! 1. **声道映射**（声道数不同时）：单声道复制到所有声道、多声道下混成单声道取平均、
//!    多余的声部丢弃、设备多出来的声道补静音。
//! 2. **采样率转换**（采样率不同时）：rubato 的 [`FftFixedInOut`]，带 overlap 的 FFT 重采样，
//!    块长固定、输入输出帧数成整数比，适合「解码线程一次解一块」的用法。
//!
//! 转换级保留不足一块的尾样本（`pending`），下一次 [`FormatConverter::process`] 补上，
//! 所以解码块边界不会丢样本，也不会重复。
//!
//! 内容格式与设备格式完全一致时 [`FormatConverter::new`] 返回 `None`，解码线程走直通路径，
//! 不产生任何额外拷贝。

use crate::decode::PcmFormat;
use lekis_types::{ErrorCode, LekisError, Result};
use rubato::{FftFixedInOut, Resampler};

/// 重采样块的目标输入帧数（约 10 ms @44.1 kHz）。
///
/// rubato 会把它向上取整到 `gcd(输入率, 输出率)` 的整数倍，真实块长可能更大；
/// 48 kHz ↔ 44.1 kHz 时是 588 帧 → 640 帧。
const TARGET_CHUNK_FRAMES: usize = 512;

/// 解码线程里的「内容格式 → 设备格式」转换级。
///
/// 构造失败（采样率为 0、rubato 拒绝这组采样率）时返回错误，由会话层退回「不做转换」，
/// 这样即使重采样不可用也还能出声（只是会变调）。
pub struct FormatConverter {
    /// 内容格式（解码器输出的交错格式）。
    content: PcmFormat,
    /// 设备格式（环形缓冲里的交错格式）。
    device: PcmFormat,
    /// 每个设备声道的接线：从哪些内容声道按什么增益取。
    taps: Vec<Vec<(usize, f32)>>,
    /// 已解开、还没凑够一个重采样块的交错内容样本。
    pending: Vec<f32>,
    /// 重采样器；采样率相同时为 `None`（只做声道映射）。
    resampler: Option<FftFixedInOut<f32>>,
    /// 重采样器输入（planar，设备声道数 × `chunk_in` 帧）。
    planar_in: Vec<Vec<f32>>,
    /// 重采样器输出（planar，设备声道数 × `chunk_out` 帧）。
    planar_out: Vec<Vec<f32>>,
    /// 一个重采样块吃多少内容帧。
    chunk_in: usize,
    /// 一个重采样块吐多少设备帧。
    chunk_out: usize,
}

impl FormatConverter {
    /// 按内容格式与设备格式搭一个转换级；两者一致时返回 `None`（直通）。
    pub fn new(content: PcmFormat, device: PcmFormat) -> Result<Option<Self>> {
        if content.sample_rate == 0
            || content.channels == 0
            || device.sample_rate == 0
            || device.channels == 0
        {
            return Err(LekisError::invalid(
                "format converter needs non-empty formats",
            ));
        }
        if content == device {
            return Ok(None);
        }

        let content_ch = usize::from(content.channels);
        let device_ch = usize::from(device.channels);
        let mut converter = Self {
            content,
            device,
            taps: channel_map(content_ch, device_ch),
            pending: Vec::with_capacity(content_ch * TARGET_CHUNK_FRAMES * 2),
            resampler: None,
            planar_in: Vec::new(),
            planar_out: Vec::new(),
            chunk_in: 0,
            chunk_out: 0,
        };

        if content.sample_rate != device.sample_rate {
            let resampler = FftFixedInOut::<f32>::new(
                content.sample_rate as usize,
                device.sample_rate as usize,
                TARGET_CHUNK_FRAMES,
                device_ch,
            )
            .map_err(|e| {
                LekisError::new(
                    ErrorCode::Unsupported,
                    format!(
                        "cannot resample {} Hz -> {} Hz: {e}",
                        content.sample_rate, device.sample_rate
                    ),
                )
            })?;
            converter.chunk_in = resampler.input_frames_next();
            converter.chunk_out = resampler.output_frames_next();
            converter.planar_in = vec![vec![0.0; converter.chunk_in]; device_ch];
            converter.planar_out = vec![vec![0.0; converter.chunk_out]; device_ch];
            converter.resampler = Some(resampler);
            tracing::debug!(
                target: "playback::resample",
                content_rate = content.sample_rate,
                device_rate = device.sample_rate,
                chunk_in = converter.chunk_in,
                chunk_out = converter.chunk_out,
                "resampling content to the device sample rate"
            );
        }

        tracing::debug!(
            target: "playback::resample",
            content_channels = content.channels,
            device_channels = device.channels,
            "channel mapping enabled"
        );
        Ok(Some(converter))
    }

    /// 内容格式。
    pub fn content(&self) -> PcmFormat {
        self.content
    }

    /// 设备格式。
    pub fn device(&self) -> PcmFormat {
        self.device
    }

    /// 转换一块交错内容样本，把交错设备样本追加到 `out`。
    ///
    /// `input` 是解码器给的交错样本；长度不是整帧、或者凑不满一个重采样块时，
    /// 剩下的样本留在 `pending` 里等下一次调用，所以块边界不丢样本也不重复。
    /// `out` 不会被清空，调用方负责先 `clear()`。
    pub fn process(&mut self, input: &[f32], out: &mut Vec<f32>) {
        let in_ch = usize::from(self.content.channels);
        if in_ch == 0 || input.is_empty() {
            return;
        }
        self.pending.extend_from_slice(input);

        if self.resampler.is_some() {
            self.resample_pending(out);
        } else {
            self.map_pending(out);
        }
    }

    /// 曲目结束时把不足一块的尾巴补零、翻出去，供无缝拼接（PLY-01）使用。
    ///
    /// 重采样器是按固定块工作的：`process` 会把不足一块的输入留在 `pending` 里。
    /// 换曲时如果不处理，最多会丢掉一个块（48 kHz ↔ 44.1 kHz 时约 13 ms）的音频。
    /// 这里补零凑满一块，再按「有效输入帧数 × 输出/输入采样率」截掉补出来的静音。
    ///
    /// 只在解码线程、曲目边界调用，可以分配；实时回调不经过这里。
    pub fn finish(&mut self, out: &mut Vec<f32>) {
        let in_ch = usize::from(self.content.channels);
        if in_ch == 0 {
            return;
        }
        let pending_frames = self.pending.len() / in_ch;
        if pending_frames == 0 {
            return;
        }
        if self.resampler.is_none() {
            // 只做声道映射：pending 全是真实样本，直接翻出去。
            self.map_pending(out);
            return;
        }
        let valid_frames = (pending_frames as u64 * u64::from(self.device.sample_rate)
            + u64::from(self.content.sample_rate) / 2)
            / u64::from(self.content.sample_rate);
        let chunk_samples = self.chunk_in * in_ch;
        let missing = chunk_samples.saturating_sub(self.pending.len());
        self.pending.extend(std::iter::repeat_n(0.0, missing));

        let mut block = Vec::new();
        self.resample_pending(&mut block);
        let device_ch = usize::from(self.device.channels);
        let keep = usize::try_from(valid_frames)
            .unwrap_or(usize::MAX)
            .saturating_mul(device_ch)
            .min(block.len());
        out.extend_from_slice(&block[..keep]);
        self.pending.clear();
    }

    /// 丢弃残留样本并清空重采样器的 overlap（seek 后必须调用，否则会听到上一段的余音）。
    pub fn reset(&mut self) {
        self.pending.clear();
        if let Some(resampler) = self.resampler.as_mut() {
            resampler.reset();
        }
        for buffer in &mut self.planar_in {
            buffer.fill(0.0);
        }
        for buffer in &mut self.planar_out {
            buffer.fill(0.0);
        }
    }

    /// 采样率相同：只做声道映射，把 pending 里的整帧全部翻出去，剩下的半帧留着。
    fn map_pending(&mut self, out: &mut Vec<f32>) {
        let in_ch = usize::from(self.content.channels);
        let frames = self.pending.len() / in_ch;
        if frames == 0 {
            return;
        }
        out.reserve(frames * self.taps.len());
        for frame in 0..frames {
            let base = frame * in_ch;
            for taps in &self.taps {
                let mut acc = 0.0;
                for (channel, gain) in taps {
                    acc += self.pending[base + channel] * gain;
                }
                out.push(acc);
            }
        }
        self.pending.drain(..frames * in_ch);
    }

    /// 采样率不同：凑够一块就重采样一次，剩下的留到下次。
    fn resample_pending(&mut self, out: &mut Vec<f32>) {
        let in_ch = usize::from(self.content.channels);
        let device_ch = self.taps.len();
        let chunk_samples = self.chunk_in * in_ch;
        while self.pending.len() >= chunk_samples {
            {
                let chunk = &self.pending[..chunk_samples];
                for (channel, taps) in self.taps.iter().enumerate() {
                    let target = &mut self.planar_in[channel];
                    for (frame, sample) in target.iter_mut().enumerate() {
                        let base = frame * in_ch;
                        let mut acc = 0.0;
                        for (source, gain) in taps {
                            acc += chunk[base + source] * gain;
                        }
                        *sample = acc;
                    }
                }
            }

            let Some(resampler) = self.resampler.as_mut() else {
                return;
            };
            match resampler.process_into_buffer(&self.planar_in, &mut self.planar_out, None) {
                Ok((_, produced)) => {
                    out.reserve(produced * device_ch);
                    #[allow(clippy::needless_range_loop)]
                    for frame in 0..produced {
                        for channel in 0..device_ch {
                            out.push(self.planar_out[channel][frame]);
                        }
                    }
                }
                Err(e) => {
                    // 重采样失败不该让播放停掉：丢掉这一块，下一块继续。
                    tracing::warn!(target: "playback::resample", error = %e, "resample failed, dropping chunk");
                }
            }
            self.pending.drain(..chunk_samples);
        }
    }
}

/// 内容声道 → 设备声道的接线表：每个设备声道一组 `(内容声道下标, 增益)`。
///
/// 空数组表示该设备声道补静音。
fn channel_map(content_ch: usize, device_ch: usize) -> Vec<Vec<(usize, f32)>> {
    if content_ch == device_ch {
        return (0..device_ch).map(|channel| vec![(channel, 1.0)]).collect();
    }
    if content_ch == 1 {
        // 单声道内容：复制到所有设备声道（只放左声道会让人以为右耳坏了）。
        return (0..device_ch).map(|_| vec![(0, 1.0)]).collect();
    }
    if device_ch == 1 {
        // 多声道 → 单声道：取平均，避免直接相加削波。
        let gain = 1.0 / content_ch as f32;
        return vec![(0..content_ch).map(|channel| (channel, gain)).collect()];
    }
    // 其它情况（如 5.1 → 立体声）：前几个声道直通，多出来的声部丢弃；
    // 设备声部比内容多时，多出来的补静音。
    (0..device_ch)
        .map(|channel| {
            if channel < content_ch {
                vec![(channel, 1.0)]
            } else {
                Vec::new()
            }
        })
        .collect()
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    fn format(sample_rate: u32, channels: u16) -> PcmFormat {
        PcmFormat {
            sample_rate,
            channels,
        }
    }

    /// 格式一致时必须直通（零开销），不要白搭一个转换级。
    #[test]
    fn identical_formats_need_no_converter() {
        assert!(FormatConverter::new(format(44_100, 2), format(44_100, 2))
            .expect("same format")
            .is_none());
    }

    /// 空格式是调用方的 bug，必须报错而不是除零。
    #[test]
    fn empty_format_is_rejected() {
        assert!(FormatConverter::new(format(0, 2), format(48_000, 2)).is_err());
        assert!(FormatConverter::new(format(44_100, 0), format(48_000, 2)).is_err());
    }

    /// 44.1 kHz → 48 kHz：输出帧数跟着比例走（允许一个块的误差），信号不能全丢。
    #[test]
    fn resamples_to_device_rate() {
        let mut converter = FormatConverter::new(format(44_100, 2), format(48_000, 2))
            .expect("build converter")
            .expect("rates differ, converter must exist");

        // 100 ms 的内容：4410 帧立体声，左 0.5 右 -0.5（常数，重采样后仍然是常数）。
        let frames = 4_410;
        let mut input = Vec::with_capacity(frames * 2);
        for _ in 0..frames {
            input.push(0.5);
            input.push(-0.5);
        }
        let mut out = Vec::new();
        converter.process(&input, &mut out);

        let out_frames = out.len() / 2;
        let expected = frames as f64 * 48_000.0 / 44_100.0;
        // rubato 的块是 588 → 640 帧，喂 4410 帧只能吐出整块，允许一个块的缺口。
        assert!(
            (out_frames as f64) < expected,
            "不能凭空多出样本：{out_frames} vs {expected}"
        );
        assert!(
            (expected - out_frames as f64) <= 640.0,
            "流失的样本不应该超过一个块：{out_frames} vs {expected}"
        );
        // 常数信号重采样后还是常数（除了块边界的短暂过渡）。
        let tail = &out[out.len() - 2 * 640..];
        assert!(
            tail.iter().step_by(2).all(|s| (*s - 0.5).abs() < 0.05),
            "左声道重采样后应为 0.5"
        );
        assert!(
            tail.iter()
                .skip(1)
                .step_by(2)
                .all(|s| (*s + 0.5).abs() < 0.05),
            "右声道重采样后应为 -0.5"
        );
    }

    /// 单声道内容进立体声设备：两个声道都是同一份信号。
    #[test]
    fn mono_content_is_duplicated_to_stereo() {
        let mut converter = FormatConverter::new(format(48_000, 1), format(48_000, 2))
            .expect("build converter")
            .expect("channel counts differ");
        let mut out = Vec::new();
        converter.process(&[0.25, -0.25, 0.5, -0.5], &mut out);
        assert_eq!(out, vec![0.25, 0.25, -0.25, -0.25, 0.5, 0.5, -0.5, -0.5]);
    }

    /// 立体声内容进单声道设备：左右取平均。
    #[test]
    fn stereo_content_is_averaged_into_mono() {
        let mut converter = FormatConverter::new(format(48_000, 2), format(48_000, 1))
            .expect("build converter")
            .expect("channel counts differ");
        let mut out = Vec::new();
        converter.process(&[1.0, 0.0, -1.0, 1.0], &mut out);
        assert_eq!(out.len(), 2);
        assert!((out[0] - 0.5).abs() < 1e-6);
        assert!((out[1] - 0.0).abs() < 1e-6);
    }

    /// 立体声内容进 5.1 设备：前两个声道直通，剩下的补静音。
    #[test]
    fn missing_device_channels_are_silent() {
        let mut converter = FormatConverter::new(format(48_000, 2), format(48_000, 6))
            .expect("build converter")
            .expect("channel counts differ");
        let mut out = Vec::new();
        converter.process(&[0.5, -0.5], &mut out);
        assert_eq!(out.len(), 6);
        assert_eq!(out[0], 0.5);
        assert_eq!(out[1], -0.5);
        assert!(out[2..].iter().all(|s| *s == 0.0));
    }

    /// 不足一整帧的尾巴要留到下一次，不能丢也不许错位。
    #[test]
    fn partial_frame_is_carried_over() {
        let mut converter = FormatConverter::new(format(48_000, 2), format(48_000, 1))
            .expect("build converter")
            .expect("channel counts differ");
        let mut out = Vec::new();
        // 3 个样本 = 1.5 帧：只该吐出 1 帧。
        converter.process(&[1.0, 1.0, 0.0], &mut out);
        assert_eq!(out.len(), 1);
        assert!((out[0] - 1.0).abs() < 1e-6);
        // 下一次补上剩下的半个帧。
        out.clear();
        converter.process(&[0.0], &mut out);
        assert_eq!(out.len(), 1);
        assert!(out[0].abs() < 1e-6);
    }

    /// 曲目结束：不足一块的尾巴要补零翻出去，帧数按采样率比例截断。
    #[test]
    fn finish_flushes_the_resampler_tail() {
        let content = format(44_100, 2);
        let device = format(48_000, 2);
        let mut converter = FormatConverter::new(content, device)
            .expect("build converter")
            .expect("rates differ");

        // 1000 帧 = 一块（588）+ 412 帧尾巴。
        let frames = 1_000usize;
        let mut input = Vec::with_capacity(frames * 2);
        for _ in 0..frames {
            input.push(0.5);
            input.push(-0.5);
        }
        let mut out = Vec::new();
        converter.process(&input, &mut out);
        let before = out.len() / 2;
        assert!(before > 0, "process 至少应该吐出一块");

        converter.finish(&mut out);
        let total = out.len() / 2;
        let expected = frames as f64 * 48_000.0 / 44_100.0;
        assert!(
            (total as f64 - expected).abs() <= 2.0,
            "finish 后总帧数 {total}，期望 ≈ {expected}"
        );
        assert!(total > before, "finish 必须把尾巴补出来");
        // 补的是零，但截断后的尾部仍然应该是原来的常数信号。
        let tail = &out[out.len() - 128..];
        assert!(
            tail.iter().step_by(2).all(|s| (*s - 0.5).abs() < 0.05),
            "补零不能把有效尾巴盖掉"
        );
    }

    /// reset 之后残留样本必须清干净（seek 到别处不能带上上一段的尾巴）。
    #[test]
    fn reset_drops_pending_samples() {
        let mut converter = FormatConverter::new(format(44_100, 1), format(48_000, 1))
            .expect("build converter")
            .expect("rates differ");
        let mut out = Vec::new();
        converter.process(&[0.7; 100], &mut out);
        converter.reset();
        out.clear();
        // reset 之后喂静音，输出不能混进旧的 0.7。
        converter.process(&[0.0; 4_000], &mut out);
        assert!(out.iter().all(|s| s.abs() < 1e-6), "reset 后不该有旧样本");
    }

    /// 内容格式与设备格式都要如实报出来（会话层靠它们算缓冲容量和进度）。
    #[test]
    fn reports_both_formats() {
        let converter = FormatConverter::new(format(44_100, 2), format(48_000, 6))
            .expect("build converter")
            .expect("formats differ");
        assert_eq!(converter.content(), format(44_100, 2));
        assert_eq!(converter.device(), format(48_000, 6));
    }
}
