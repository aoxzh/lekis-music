//! 纯 Rust Monkey's Audio（APE）解码器适配器（基于 `ape-decoder`）。
//!
//! 支持 8 / 16 / 24 / 32 bit 无损 APE 流式逐帧解码、精准 seek 和比特完美原生整数输出，
//! 适用于本地文件、NAS（`VfsMediaSource`）和 HTTP Range 流（`HttpRangeSource`）。

use super::{Decoder, NativeSampleFormat, PcmFormat};
use ape_decoder::ApeDecoder;
use lekis_types::{AudioProps, Codec, ErrorCode, LekisError, Result};
use std::io::{Read, Seek};

/// APE 解码器。
pub struct ApeAudioDecoder<R: Read + Seek + Send> {
    inner: ApeDecoder<R>,
    props: AudioProps,
    pcm: PcmFormat,
    duration_ms: Option<u64>,
    native: Option<NativeSampleFormat>,
    bits_per_sample: u16,
    is_floating_point: bool,
    is_signed_8bit: bool,
    is_big_endian: bool,
    next_frame: u32,
    total_frames: u32,
    skip_frames: u32,
    eof: bool,
}

impl<R: Read + Seek + Send> ApeAudioDecoder<R> {
    /// 打开一个 APE 字节流。
    pub fn open(reader: R) -> Result<Self> {
        let inner = ApeDecoder::new(reader)
            .map_err(|e| LekisError::new(ErrorCode::Decode, format!("open ape failed: {e}")))?;
        let info = inner.info().clone();
        if info.sample_rate == 0 || info.channels == 0 {
            return Err(LekisError::new(
                ErrorCode::Decode,
                "ape header has zero sample rate or channels",
            ));
        }
        let duration_ms = if info.duration_ms > 0 {
            Some(info.duration_ms)
        } else if info.total_samples > 0 {
            Some(info.total_samples.saturating_mul(1_000) / u64::from(info.sample_rate))
        } else {
            None
        };
        let bit_depth = u8::try_from(info.bits_per_sample).ok();
        let native = if info.is_floating_point && info.bits_per_sample == 32 {
            Some(NativeSampleFormat::Float32)
        } else if matches!(info.bits_per_sample, 8 | 16 | 24 | 32) && !info.is_floating_point {
            Some(NativeSampleFormat::Int {
                bits: info.bits_per_sample as u8,
            })
        } else {
            None
        };
        let props = AudioProps {
            codec: Codec::Ape,
            sample_rate: info.sample_rate,
            bit_depth,
            channels: info.channels.min(255) as u8,
            bitrate_kbps: (info.average_bitrate_kbps > 0).then_some(info.average_bitrate_kbps),
        };
        let pcm = PcmFormat {
            sample_rate: info.sample_rate,
            channels: info.channels,
        };
        Ok(Self {
            total_frames: info.total_frames,
            bits_per_sample: info.bits_per_sample,
            is_floating_point: info.is_floating_point,
            is_signed_8bit: info.is_signed_8bit,
            is_big_endian: info.is_big_endian,
            inner,
            props,
            pcm,
            duration_ms,
            native,
            next_frame: 0,
            skip_frames: 0,
            eof: false,
        })
    }

    fn decode_next_raw(&mut self) -> Result<Option<(Vec<u8>, usize)>> {
        if self.eof || self.next_frame >= self.total_frames {
            self.eof = true;
            return Ok(None);
        }
        let frame_idx = self.next_frame;
        self.next_frame += 1;
        let pcm_bytes = self.inner.decode_frame(frame_idx).map_err(|e| {
            LekisError::new(
                ErrorCode::Decode,
                format!("ape decode frame {frame_idx}: {e}"),
            )
        })?;
        let block_align = usize::from(self.inner.info().block_align.max(1));
        let skip_bytes = (self.skip_frames as usize).saturating_mul(block_align);
        self.skip_frames = 0;
        let start = skip_bytes.min(pcm_bytes.len());
        Ok(Some((pcm_bytes, start)))
    }
}

impl<R: Read + Seek + Send> Decoder for ApeAudioDecoder<R> {
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
        loop {
            let Some((pcm, start)) = self.decode_next_raw()? else {
                return Ok(false);
            };
            let slice = &pcm[start..];
            if slice.is_empty() {
                continue;
            }
            pcm_bytes_to_f32(
                slice,
                self.bits_per_sample,
                self.is_floating_point,
                self.is_signed_8bit,
                self.is_big_endian,
                out,
            )?;
            return Ok(true);
        }
    }

    fn seek(&mut self, position_ms: u64) -> Result<u64> {
        let requested = match self.duration_ms {
            Some(total) => position_ms.min(total),
            None => position_ms,
        };
        let target_sample = requested.saturating_mul(u64::from(self.pcm.sample_rate)) / 1_000;
        let seeked = self
            .inner
            .seek(target_sample)
            .map_err(|e| LekisError::new(ErrorCode::Decode, format!("ape seek failed: {e}")))?;
        self.next_frame = seeked.frame_index;
        self.skip_frames = seeked.skip_samples;
        self.eof = false;
        let actual_ms =
            seeked.actual_sample.saturating_mul(1_000) / u64::from(self.pcm.sample_rate);
        Ok(actual_ms)
    }

    fn native_format(&self) -> Option<NativeSampleFormat> {
        self.native
    }

    fn decode_next_native(&mut self, out: &mut Vec<i32>) -> Result<bool> {
        if self.native.is_none() {
            return Err(LekisError::new(
                ErrorCode::Unsupported,
                "ape stream has no bit-perfect sample format",
            ));
        }
        loop {
            let Some((pcm, start)) = self.decode_next_raw()? else {
                return Ok(false);
            };
            let slice = &pcm[start..];
            if slice.is_empty() {
                continue;
            }
            pcm_bytes_to_native_i32(
                slice,
                self.bits_per_sample,
                self.is_floating_point,
                self.is_signed_8bit,
                self.is_big_endian,
                out,
            )?;
            return Ok(true);
        }
    }
}

fn pcm_bytes_to_f32(
    bytes: &[u8],
    bits: u16,
    is_float: bool,
    is_signed_8: bool,
    is_be: bool,
    out: &mut Vec<f32>,
) -> Result<()> {
    match (bits, is_float) {
        (8, false) => {
            out.reserve(bytes.len());
            for &b in bytes {
                let s = if is_signed_8 {
                    (b as i8) as f32 / 128.0
                } else {
                    (i16::from(b) - 128) as f32 / 128.0
                };
                out.push(s);
            }
        }
        (16, false) => {
            out.reserve(bytes.len() / 2);
            for chunk in bytes.chunks_exact(2) {
                let v = if is_be {
                    i16::from_be_bytes([chunk[0], chunk[1]])
                } else {
                    i16::from_le_bytes([chunk[0], chunk[1]])
                };
                out.push(f32::from(v) / 32_768.0);
            }
        }
        (24, false) => {
            out.reserve(bytes.len() / 3);
            for chunk in bytes.chunks_exact(3) {
                let raw = if is_be {
                    i32::from_be_bytes([chunk[0], chunk[1], chunk[2], 0]) >> 8
                } else {
                    i32::from_le_bytes([0, chunk[0], chunk[1], chunk[2]]) >> 8
                };
                out.push((raw as f32) / 8_388_608.0);
            }
        }
        (32, false) => {
            out.reserve(bytes.len() / 4);
            for chunk in bytes.chunks_exact(4) {
                let v = if is_be {
                    i32::from_be_bytes([chunk[0], chunk[1], chunk[2], chunk[3]])
                } else {
                    i32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]])
                };
                out.push((v as f64 / 2_147_483_648.0) as f32);
            }
        }
        (32, true) => {
            out.reserve(bytes.len() / 4);
            for chunk in bytes.chunks_exact(4) {
                let v = if is_be {
                    f32::from_be_bytes([chunk[0], chunk[1], chunk[2], chunk[3]])
                } else {
                    f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]])
                };
                out.push(v);
            }
        }
        _ => {
            return Err(LekisError::new(
                ErrorCode::Unsupported,
                format!("unsupported ape bit depth: {bits}"),
            ))
        }
    }
    Ok(())
}

fn pcm_bytes_to_native_i32(
    bytes: &[u8],
    bits: u16,
    is_float: bool,
    is_signed_8: bool,
    is_be: bool,
    out: &mut Vec<i32>,
) -> Result<()> {
    match (bits, is_float) {
        (8, false) => {
            out.reserve(bytes.len());
            for &b in bytes {
                let s = if is_signed_8 {
                    i32::from(b as i8) << 24
                } else {
                    (i32::from(b) - 128) << 24
                };
                out.push(s);
            }
        }
        (16, false) => {
            out.reserve(bytes.len() / 2);
            for chunk in bytes.chunks_exact(2) {
                let v = if is_be {
                    i16::from_be_bytes([chunk[0], chunk[1]])
                } else {
                    i16::from_le_bytes([chunk[0], chunk[1]])
                };
                out.push(i32::from(v) << 16);
            }
        }
        (24, false) => {
            out.reserve(bytes.len() / 3);
            for chunk in bytes.chunks_exact(3) {
                let v = if is_be {
                    i32::from_be_bytes([chunk[0], chunk[1], chunk[2], 0])
                } else {
                    i32::from_le_bytes([0, chunk[0], chunk[1], chunk[2]])
                };
                out.push(v);
            }
        }
        (32, false) => {
            out.reserve(bytes.len() / 4);
            for chunk in bytes.chunks_exact(4) {
                let v = if is_be {
                    i32::from_be_bytes([chunk[0], chunk[1], chunk[2], chunk[3]])
                } else {
                    i32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]])
                };
                out.push(v);
            }
        }
        (32, true) => {
            out.reserve(bytes.len() / 4);
            for chunk in bytes.chunks_exact(4) {
                let v = if is_be {
                    f32::from_be_bytes([chunk[0], chunk[1], chunk[2], chunk[3]])
                } else {
                    f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]])
                };
                out.push(v.to_bits() as i32);
            }
        }
        _ => {
            return Err(LekisError::new(
                ErrorCode::Unsupported,
                format!("unsupported ape native bit depth: {bits}"),
            ))
        }
    }
    Ok(())
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn converts_16_and_24_bit_pcm_to_f32_and_native() {
        let mut f32_out = Vec::new();
        let mut native_out = Vec::new();
        let mut raw16 = Vec::new();
        raw16.extend_from_slice(&(-16_384i16).to_le_bytes());
        raw16.extend_from_slice(&(16_384i16).to_le_bytes());
        pcm_bytes_to_f32(&raw16, 16, false, false, false, &mut f32_out).unwrap();
        pcm_bytes_to_native_i32(&raw16, 16, false, false, false, &mut native_out).unwrap();
        assert!((f32_out[0] - (-0.5)).abs() < 1e-6);
        assert!((f32_out[1] - 0.5).abs() < 1e-6);
        assert_eq!(native_out[0], i32::from(-16_384i16) << 16);
        assert_eq!(native_out[1], i32::from(16_384i16) << 16);

        let mut f32_24 = Vec::new();
        let mut native_24 = Vec::new();
        let v: i32 = -4_194_304; // -0.5 in 24-bit signed
        let raw24 = &v.to_le_bytes()[..3];
        pcm_bytes_to_f32(raw24, 24, false, false, false, &mut f32_24).unwrap();
        pcm_bytes_to_native_i32(raw24, 24, false, false, false, &mut native_24).unwrap();
        assert!((f32_24[0] - (-0.5)).abs() < 1e-6);
        assert_eq!(native_24[0], v << 8);
    }
}
