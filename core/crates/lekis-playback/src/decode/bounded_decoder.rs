//! 区间裁剪解码器：支持 CUE + 整轨音频分轨播放。
//!
//! 将任意底层 [`Decoder`]（FLAC / APE / WAV / TTA / DSD……）限制在 `[start_ms, end_ms)` 区间内：
//! - 打开时自动 seek 到 `start_ms`；
//! - `duration_ms()` 返回分轨时长；
//! - `decode_next` / `decode_next_native` 精确按帧截断在 `end_ms`；
//! - `seek(pos_ms)` 映射到 `start_ms + pos_ms` 并重置剩余帧计数。

use super::{Decoder, NativeSampleFormat, PcmFormat};
use lekis_types::{AudioProps, Result};

/// 对任意 [`Decoder`] 加上 `[start_ms, end_ms)` 区间限制的包装器。
pub struct BoundedDecoder {
    inner: Box<dyn Decoder>,
    start_ms: u64,
    end_ms: Option<u64>,
    duration_ms: Option<u64>,
    /// 从当前位置到 `end_ms` 还剩多少帧（`None` 表示播到底层流 EOF）。
    remaining_frames: Option<u64>,
}

impl BoundedDecoder {
    /// 打开并定位到 `start_ms`。
    pub fn new(mut inner: Box<dyn Decoder>, start_ms: u64, end_ms: Option<u64>) -> Result<Self> {
        let total_inner = inner.duration_ms();
        let clamped_end = match (end_ms, total_inner) {
            (Some(end), Some(total)) => Some(end.min(total)),
            (Some(end), None) => Some(end),
            (None, total) => total,
        };
        let duration_ms = clamped_end.map(|end| end.saturating_sub(start_ms));
        if start_ms > 0 {
            let _ = inner.seek(start_ms)?;
        }
        let fmt = inner.format();
        let remaining_frames = end_ms.map(|end| {
            let span_ms = end.saturating_sub(start_ms);
            span_ms.saturating_mul(u64::from(fmt.sample_rate)) / 1_000
        });
        Ok(Self {
            inner,
            start_ms,
            end_ms,
            duration_ms,
            remaining_frames,
        })
    }

    fn trim_len(&mut self, added_samples: usize) -> usize {
        let Some(rem_frames) = self.remaining_frames else {
            return added_samples;
        };
        let channels = usize::from(self.inner.format().channels.max(1));
        let added_frames = (added_samples / channels) as u64;
        if added_frames <= rem_frames {
            self.remaining_frames = Some(rem_frames - added_frames);
            added_samples
        } else {
            self.remaining_frames = Some(0);
            (rem_frames as usize).saturating_mul(channels)
        }
    }
}

impl Decoder for BoundedDecoder {
    fn props(&self) -> &AudioProps {
        self.inner.props()
    }

    fn format(&self) -> PcmFormat {
        self.inner.format()
    }

    fn duration_ms(&self) -> Option<u64> {
        self.duration_ms
    }

    fn decode_next(&mut self, out: &mut Vec<f32>) -> Result<bool> {
        if self.remaining_frames == Some(0) {
            return Ok(false);
        }
        let before = out.len();
        if !self.inner.decode_next(out)? {
            return Ok(false);
        }
        let added = out.len() - before;
        let keep = self.trim_len(added);
        out.truncate(before + keep);
        Ok(keep > 0)
    }

    fn seek(&mut self, position_ms: u64) -> Result<u64> {
        let clamped = match self.duration_ms {
            Some(dur) => position_ms.min(dur),
            None => position_ms,
        };
        let target_abs = self.start_ms.saturating_add(clamped);
        let actual_abs = self.inner.seek(target_abs)?;
        let actual_rel = actual_abs.saturating_sub(self.start_ms);
        let fmt = self.inner.format();
        self.remaining_frames = self.end_ms.map(|end| {
            let rem_ms = end.saturating_sub(actual_abs);
            rem_ms.saturating_mul(u64::from(fmt.sample_rate)) / 1_000
        });
        Ok(actual_rel)
    }

    fn native_format(&self) -> Option<NativeSampleFormat> {
        self.inner.native_format()
    }

    fn decode_next_native(&mut self, out: &mut Vec<i32>) -> Result<bool> {
        if self.remaining_frames == Some(0) {
            return Ok(false);
        }
        let before = out.len();
        if !self.inner.decode_next_native(out)? {
            return Ok(false);
        }
        let added = out.len() - before;
        let keep = self.trim_len(added);
        out.truncate(before + keep);
        Ok(keep > 0)
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::decode::SymphoniaDecoder;

    #[test]
    fn bounds_a_wav_track_between_start_and_end_ms() {
        // 1 second WAV at 8000 Hz stereo
        let bytes = crate::decode::symphonia_decoder::tests::wav_bytes(8_000, 2, 8_000);
        let inner = Box::new(
            SymphoniaDecoder::open_source(Box::new(std::io::Cursor::new(bytes)), Some("wav"))
                .unwrap(),
        );
        // Slice 200ms..600ms => 400ms => 3200 frames => 6400 samples
        let mut bounded = BoundedDecoder::new(inner, 200, Some(600)).unwrap();
        assert_eq!(bounded.duration_ms(), Some(400));
        let mut out = Vec::new();
        while bounded.decode_next(&mut out).unwrap() {}
        assert_eq!(out.len(), 6_400);

        // Seek to 100ms within slice (= 300ms absolute) => 300ms remaining => 4800 samples
        let pos = bounded.seek(100).unwrap();
        assert!((pos as i64 - 100).abs() <= 10);
        let mut after_seek = Vec::new();
        while bounded.decode_next(&mut after_seek).unwrap() {}
        assert!((after_seek.len() as i64 - 4_800).abs() <= 320);
    }
}
