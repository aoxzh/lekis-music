//! 纯 Rust True Audio（TTA）解码器适配器（基于 `oxideav-tta`）。
//!
//! 逐帧按需解码 TTA1 无损音频，支持 seek 表精准跳转与 16/24-bit 比特完美输出。

use super::{Decoder, NativeSampleFormat, PcmFormat};
use lekis_types::{AudioProps, Codec, ErrorCode, LekisError, Result};
use oxideav_tta::{FrameDescriptor, StreamHeader};
use std::io::Read;

/// TTA 文件最大允许读入内存的字节数（512 MiB，防畸形输入耗尽内存）。
const MAX_TTA_BYTES: u64 = 512 * 1024 * 1024;

/// TTA1 解码器。
pub struct TtaAudioDecoder {
    bytes: Vec<u8>,
    header: StreamHeader,
    frames: Vec<FrameDescriptor>,
    seek_table_ok: bool,
    props: AudioProps,
    pcm: PcmFormat,
    duration_ms: Option<u64>,
    native: Option<NativeSampleFormat>,
    next_frame: usize,
    skip_samples_in_frame: usize,
    eof: bool,
}

impl TtaAudioDecoder {
    /// 从任意 `Read` 流读取并解析 TTA1 帧索引。
    pub fn open<R: Read>(reader: R) -> Result<Self> {
        let mut bytes = Vec::new();
        reader
            .take(MAX_TTA_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| LekisError::new(ErrorCode::Io, format!("read tta stream failed: {e}")))?;
        if bytes.len() as u64 > MAX_TTA_BYTES {
            return Err(LekisError::new(
                ErrorCode::Unsupported,
                "tta file exceeds 512 MiB size limit",
            ));
        }
        Self::from_bytes(bytes)
    }

    /// 从完整 TTA1 字节缓冲构造解码器。
    pub fn from_bytes(bytes: Vec<u8>) -> Result<Self> {
        let (header, frames, seek_table_ok) = {
            let parsed = oxideav_tta::Decoder::new(&bytes)
                .map_err(|e| LekisError::new(ErrorCode::Decode, format!("open tta failed: {e}")))?;
            (parsed.header, parsed.frames, parsed.seek_table_crc_ok)
        };
        if header.sample_rate == 0 || header.channels == 0 {
            return Err(LekisError::new(
                ErrorCode::Decode,
                "tta header has zero sample rate or channels",
            ));
        }
        let duration_ms = if header.total_samples > 0 {
            Some(
                u64::from(header.total_samples).saturating_mul(1_000)
                    / u64::from(header.sample_rate),
            )
        } else {
            None
        };
        let bitrate_kbps = duration_ms.and_then(|ms| {
            (bytes.len() as u64)
                .saturating_mul(8)
                .checked_div(ms)
                .and_then(|v| u32::try_from(v).ok())
        });
        let bit_depth = u8::try_from(header.bits_per_sample).ok();
        let native = match header.bits_per_sample {
            8 | 16 | 24 => Some(NativeSampleFormat::Int {
                bits: header.bits_per_sample as u8,
            }),
            _ => None,
        };
        let props = AudioProps {
            codec: Codec::Tta,
            sample_rate: header.sample_rate,
            bit_depth,
            channels: header.channels.min(255) as u8,
            bitrate_kbps,
        };
        let pcm = PcmFormat {
            sample_rate: header.sample_rate,
            channels: header.channels,
        };
        Ok(Self {
            bytes,
            header,
            frames,
            seek_table_ok,
            props,
            pcm,
            duration_ms,
            native,
            next_frame: 0,
            skip_samples_in_frame: 0,
            eof: false,
        })
    }

    fn decode_next_i32(&mut self) -> Result<Option<(Vec<i32>, usize)>> {
        if self.eof || self.next_frame >= self.frames.len() {
            self.eof = true;
            return Ok(None);
        }
        let idx = self.next_frame;
        self.next_frame += 1;
        let frame = &self.frames[idx];
        let off = frame.file_offset as usize;
        let end = off.saturating_add(frame.disk_size as usize);
        if end > self.bytes.len() {
            self.eof = true;
            return Ok(None);
        }
        let samples = oxideav_tta::decode_frame(&self.header, frame, &self.bytes[off..end])
            .map_err(|e| {
                LekisError::new(ErrorCode::Decode, format!("tta decode frame {idx}: {e}"))
            })?;
        let skip = self
            .skip_samples_in_frame
            .saturating_mul(usize::from(self.pcm.channels.max(1)));
        self.skip_samples_in_frame = 0;
        let start = skip.min(samples.len());
        Ok(Some((samples, start)))
    }
}

impl Decoder for TtaAudioDecoder {
    fn props(&self) -> &AudioProps {
        &self.props
    }

    fn format(&self) -> PcmFormat {
        self.pcm
    }

    fn duration_ms(&self) -> Option<u64> {
        self.duration_ms
    }

    fn decode_next(&mut self, out: &mut Vec<f32>) -> Result<bool> {
        let scale = match self.header.bits_per_sample {
            8 => 128.0f32,
            16 => 32_768.0f32,
            24 => 8_388_608.0f32,
            other => {
                return Err(LekisError::new(
                    ErrorCode::Unsupported,
                    format!("unsupported tta bit depth: {other}"),
                ))
            }
        };
        loop {
            let Some((samples, start)) = self.decode_next_i32()? else {
                return Ok(false);
            };
            let slice = &samples[start..];
            if slice.is_empty() {
                continue;
            }
            out.reserve(slice.len());
            for &s in slice {
                out.push(s as f32 / scale);
            }
            return Ok(true);
        }
    }

    fn seek(&mut self, position_ms: u64) -> Result<u64> {
        if !self.seek_table_ok {
            return Err(LekisError::new(
                ErrorCode::Unsupported,
                "tta seek table CRC failed; stream is unseekable",
            ));
        }
        let requested = match self.duration_ms {
            Some(total) => position_ms.min(total),
            None => position_ms,
        };
        let target_sample = (requested.saturating_mul(u64::from(self.pcm.sample_rate)) / 1_000)
            .min(u64::from(self.header.total_samples.saturating_sub(1)));
        let mut cursor = 0u64;
        let mut target_frame = 0usize;
        let mut skip_in_frame = 0usize;
        for (i, frame) in self.frames.iter().enumerate() {
            let count = u64::from(frame.sample_count);
            if target_sample < cursor + count || i + 1 == self.frames.len() {
                target_frame = i;
                skip_in_frame = (target_sample.saturating_sub(cursor)) as usize;
                break;
            }
            cursor += count;
        }
        self.next_frame = target_frame;
        self.skip_samples_in_frame = skip_in_frame;
        self.eof = false;
        let actual_ms = target_sample.saturating_mul(1_000) / u64::from(self.pcm.sample_rate);
        Ok(actual_ms)
    }

    fn native_format(&self) -> Option<NativeSampleFormat> {
        self.native
    }

    fn decode_next_native(&mut self, out: &mut Vec<i32>) -> Result<bool> {
        let shift: u32 = match self.header.bits_per_sample {
            8 => 24,
            16 => 16,
            24 => 8,
            _ => {
                return Err(LekisError::new(
                    ErrorCode::Unsupported,
                    "tta stream has no bit-perfect sample format",
                ))
            }
        };
        loop {
            let Some((samples, start)) = self.decode_next_i32()? else {
                return Ok(false);
            };
            let slice = &samples[start..];
            if slice.is_empty() {
                continue;
            }
            out.reserve(slice.len());
            for &s in slice {
                out.push(s.wrapping_shl(shift));
            }
            return Ok(true);
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn roundtrips_tta_encode_decode_and_seek() {
        let rate = 44_100u32;
        let channels = 2u16;
        let frames = 44_100usize; // 1 second
        let mut pcm = Vec::with_capacity(frames * usize::from(channels));
        for i in 0..frames {
            let v = ((i % 500) as i32 * 40 - 10_000).clamp(-32_000, 32_000);
            pcm.push(v);
            pcm.push(-v);
        }
        let encoded = oxideav_tta::encode(&pcm, channels, 16, rate).unwrap();
        let mut dec = TtaAudioDecoder::from_bytes(encoded).unwrap();
        assert_eq!(dec.props().codec, Codec::Tta);
        assert_eq!(
            dec.format(),
            PcmFormat {
                sample_rate: rate,
                channels
            }
        );
        assert_eq!(dec.duration_ms(), Some(1_000));
        assert_eq!(
            dec.native_format(),
            Some(NativeSampleFormat::Int { bits: 16 })
        );

        let mut decoded = Vec::new();
        while dec.decode_next(&mut decoded).unwrap() {}
        assert_eq!(decoded.len(), pcm.len());
        assert!((decoded[0] - (pcm[0] as f32 / 32_768.0)).abs() < 1e-5);

        // Seek to 500ms and verify remaining samples
        let actual = dec.seek(500).unwrap();
        assert!((actual as i64 - 500).abs() <= 5);
        let mut tail = Vec::new();
        while dec.decode_next(&mut tail).unwrap() {}
        let expected_start = 22_050 * 2;
        assert_eq!(tail.len(), pcm.len() - expected_start);
        assert!((tail[0] - (pcm[expected_start] as f32 / 32_768.0)).abs() < 1e-5);
    }
}
