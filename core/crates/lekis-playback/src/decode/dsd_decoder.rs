//! 纯 Rust DSD（DSF / DFF）实时转 PCM 解码器（基于 `dsd2pcm`）。
//!
//! 通过 `dsd2pcm::dsf::DsfReader` / `dsd2pcm::dff::DffReader` 流式读取 1-bit DSD 数据，
//! 经每声道独立的 32× FIR 低通抽取器（`Decimator`，88.2 kHz for DSD64、176.4 kHz for DSD128……）
//! 实时转换为高精度 f32 / 24-bit 左对齐 PCM，支持精确 seek。

use super::{Decoder, NativeSampleFormat, PcmFormat};
use dsd2pcm::decimator::{self, Cutoff, Decimator, PcmRate, GRID_TO_UNIT, IDLE};
use dsd2pcm::dff::DffReader;
use dsd2pcm::dsf::DsfReader;
use dsd2pcm::io::{DsdInfo, DsdRead};
use lekis_types::{AudioProps, Codec, ErrorCode, LekisError, Result};
use std::io::{Read, Seek, SeekFrom};

/// 每次从 DSD 容器读取的每声道字节数（4096 字节 = 32768 个 DSD 样本 ≈ 11.6 ms @ DSD64）。
const READ_BYTES_PER_CH: usize = 4_096;

/// 抽取器尾部冲刷用的静音字节数（覆盖 FIR 滤波器群延迟）。
const FLUSH_IDLE_BYTES: usize = 512;

/// DSF / DFF 通用读取器（需要支持重置到开头以实现 seek）。
enum DsdContainer<R: Read + Seek + Send> {
    Dsf(DsfReader<R>),
    Dff(DffReader<R>),
}

impl<R: Read + Seek + Send> DsdContainer<R> {
    fn open(mut reader: R) -> Result<(Self, bool)> {
        reader
            .seek(SeekFrom::Start(0))
            .map_err(|e| LekisError::new(ErrorCode::Io, format!("seek dsd start: {e}")))?;
        let mut magic = [0u8; 4];
        reader
            .read_exact(&mut magic)
            .map_err(|e| LekisError::new(ErrorCode::Decode, format!("read dsd magic: {e}")))?;
        reader
            .seek(SeekFrom::Start(0))
            .map_err(|e| LekisError::new(ErrorCode::Io, format!("rewind dsd start: {e}")))?;
        match &magic {
            b"DSD " => {
                let r = DsfReader::new(reader).map_err(|e| {
                    LekisError::new(ErrorCode::Decode, format!("open dsf failed: {e}"))
                })?;
                Ok((Self::Dsf(r), true))
            }
            b"FRM8" => {
                let r = DffReader::new(reader).map_err(|e| {
                    LekisError::new(ErrorCode::Decode, format!("open dff failed: {e}"))
                })?;
                Ok((Self::Dff(r), false))
            }
            _ => Err(LekisError::new(
                ErrorCode::Decode,
                "unrecognized DSD container (expected DSF or DFF)",
            )),
        }
    }

    fn info(&self) -> DsdInfo {
        match self {
            Self::Dsf(r) => r.info(),
            Self::Dff(r) => r.info(),
        }
    }

    fn read_bytes(&mut self, max_bytes: usize, out: &mut [Vec<u8>]) -> Result<usize> {
        match self {
            Self::Dsf(r) => r.read_bytes(max_bytes, out),
            Self::Dff(r) => r.read_bytes(max_bytes, out),
        }
        .map_err(|e| LekisError::new(ErrorCode::Decode, format!("dsd read failed: {e}")))
    }
}

/// DSD 实时抽取解码器。
///
/// 由于 `dsd2pcm::DsfReader` / `DffReader` 不暴露内部 `R` 的随机 seek，
/// 这里通过保存原始 `Seek` 流（配合 `Rc`/`Option` 不可跨线程，因此改用枚举按需重建：
/// `DsfReader`/`DffReader` 没有 `into_inner`，所以我们包一层 `SharedReader` 共享同一个 `R`）。
pub struct DsdAudioDecoder<R: Read + Seek + Send> {
    /// 共享底层读取器：容器和 seek 重建共用同一句柄（都在单解码线程上调用）。
    shared: std::sync::Arc<std::sync::Mutex<R>>,
    container: DsdContainer<LockedReader<R>>,
    is_dsf: bool,
    dsd_info: DsdInfo,
    decimators: Vec<Decimator>,
    props: AudioProps,
    pcm: PcmFormat,
    duration_ms: Option<u64>,
    total_pcm_frames: u64,
    emitted_pcm_frames: u64,
    skip_pcm_frames: u64,
    /// DSD 每声道已读取的字节数（只用于诊断 / seek 跳过）。
    dsd_bufs: Vec<Vec<u8>>,
    pcm_ch_bufs: Vec<Vec<f64>>,
    eof: bool,
    flushed: bool,
}

struct LockedReader<R> {
    inner: std::sync::Arc<std::sync::Mutex<R>>,
}

impl<R> Clone for LockedReader<R> {
    fn clone(&self) -> Self {
        Self {
            inner: self.inner.clone(),
        }
    }
}

impl<R: Read> Read for LockedReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let mut guard = self
            .inner
            .lock()
            .map_err(|_| std::io::Error::other("dsd reader lock poisoned"))?;
        guard.read(buf)
    }
}

impl<R: Seek> Seek for LockedReader<R> {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        let mut guard = self
            .inner
            .lock()
            .map_err(|_| std::io::Error::other("dsd reader lock poisoned"))?;
        guard.seek(pos)
    }
}

impl<R: Read + Seek + Send> DsdAudioDecoder<R> {
    /// 打开一个 DSF 或 DFF 字节流。
    pub fn open(reader: R) -> Result<Self> {
        let shared = std::sync::Arc::new(std::sync::Mutex::new(reader));
        let handle = LockedReader {
            inner: shared.clone(),
        };
        let (container, is_dsf) = DsdContainer::open(handle)?;
        let info = container.info();
        if info.sample_rate == 0 || info.channels == 0 {
            return Err(LekisError::new(
                ErrorCode::Decode,
                "dsd header has zero sample rate or channels",
            ));
        }
        // Decimator(Hz88200) 是固定 32× 抽取：
        // DSD64 (2.8224 MHz) → 88.2 kHz, DSD128 → 176.4 kHz, DSD256 → 352.8 kHz,
        // 48k×64 (3.072 MHz) → 96 kHz。
        let decimation = PcmRate::Hz88200.decimation(); // 32
        let pcm_rate = (u64::from(info.sample_rate) / decimation).max(1) as u32;
        let total_pcm_frames = info.samples.div_ceil(decimation);
        let duration_ms = if info.samples > 0 {
            Some(info.samples.saturating_mul(1_000) / u64::from(info.sample_rate))
        } else {
            None
        };
        let channels = info.channels;
        let decimators = build_decimators(channels)?;
        let props = AudioProps {
            codec: Codec::Dsd,
            sample_rate: info.sample_rate,
            bit_depth: Some(1),
            channels: channels.min(255) as u8,
            bitrate_kbps: Some(
                (u64::from(info.sample_rate).saturating_mul(u64::from(channels)) / 1_000) as u32,
            ),
        };
        let pcm = PcmFormat {
            sample_rate: pcm_rate,
            channels,
        };
        let nch = usize::from(channels);
        Ok(Self {
            shared,
            container,
            is_dsf,
            dsd_info: info,
            decimators,
            props,
            pcm,
            duration_ms,
            total_pcm_frames,
            emitted_pcm_frames: 0,
            skip_pcm_frames: 0,
            dsd_bufs: vec![Vec::with_capacity(READ_BYTES_PER_CH); nch],
            pcm_ch_bufs: vec![Vec::with_capacity(READ_BYTES_PER_CH); nch],
            eof: false,
            flushed: false,
        })
    }

    /// 解码下一批每声道 f64 样本（仍在 2^26 网格上），返回实际帧数。
    fn decode_block_grid(&mut self) -> Result<usize> {
        if self.eof || self.emitted_pcm_frames >= self.total_pcm_frames {
            self.eof = true;
            return Ok(0);
        }
        let nch = usize::from(self.pcm.channels);
        loop {
            for b in &mut self.dsd_bufs {
                b.clear();
            }
            for b in &mut self.pcm_ch_bufs {
                b.clear();
            }
            let read_bytes = self
                .container
                .read_bytes(READ_BYTES_PER_CH, &mut self.dsd_bufs)?;
            if read_bytes > 0 {
                for ch in 0..nch {
                    self.decimators[ch].push(&self.dsd_bufs[ch], &mut self.pcm_ch_bufs[ch]);
                }
            } else if !self.flushed {
                self.flushed = true;
                let idle = [IDLE; FLUSH_IDLE_BYTES];
                for ch in 0..nch {
                    self.decimators[ch].push(&idle, &mut self.pcm_ch_bufs[ch]);
                }
            } else {
                self.eof = true;
                return Ok(0);
            }

            let frames = self.pcm_ch_bufs.iter().map(Vec::len).min().unwrap_or(0);
            if frames == 0 {
                if self.flushed {
                    self.eof = true;
                    return Ok(0);
                }
                continue;
            }
            return Ok(frames);
        }
    }
}

fn build_decimators(channels: u16) -> Result<Vec<Decimator>> {
    let mut out = Vec::with_capacity(usize::from(channels));
    for _ in 0..channels {
        out.push(
            Decimator::new(PcmRate::Hz88200, Cutoff::Standard)
                .map_err(|e| LekisError::internal(format!("dsd decimator init: {e}")))?,
        );
    }
    Ok(out)
}

impl<R: Read + Seek + Send> Decoder for DsdAudioDecoder<R> {
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
        let nch = usize::from(self.pcm.channels);
        loop {
            let frames = self.decode_block_grid()?;
            if frames == 0 {
                return Ok(false);
            }
            let skip = (self.skip_pcm_frames as usize).min(frames);
            self.skip_pcm_frames = self.skip_pcm_frames.saturating_sub(skip as u64);
            let remaining = self
                .total_pcm_frames
                .saturating_sub(self.emitted_pcm_frames) as usize;
            let usable = (frames - skip).min(remaining);
            if usable == 0 {
                if remaining == 0 {
                    self.eof = true;
                    return Ok(false);
                }
                continue;
            }
            out.reserve(usable * nch);
            // DSD 基准电平比 PCM 低 6 dB（SACD 规范）；用 +6 dB（2×）补偿回常规响度并限幅到 [-1, 1]。
            let scale = GRID_TO_UNIT * 2.0;
            #[allow(clippy::needless_range_loop)]
            for i in skip..skip + usable {
                for ch_buf in self.pcm_ch_bufs.iter().take(nch) {
                    let s = (ch_buf[i] * scale).clamp(-1.0, 1.0) as f32;
                    out.push(s);
                }
            }
            self.emitted_pcm_frames += usable as u64;
            if self.emitted_pcm_frames >= self.total_pcm_frames {
                self.eof = true;
            }
            return Ok(true);
        }
    }

    fn seek(&mut self, position_ms: u64) -> Result<u64> {
        let requested = match self.duration_ms {
            Some(total) => position_ms.min(total),
            None => position_ms,
        };
        let target_pcm_frame = (requested.saturating_mul(u64::from(self.pcm.sample_rate)) / 1_000)
            .min(self.total_pcm_frames);
        // 重建容器与抽取器，然后按 4 字节/PCM 帧（32 bit DSD / 8）快速跳过前缀字节。
        let handle = LockedReader {
            inner: self.shared.clone(),
        };
        let (container, _) = DsdContainer::open(handle)?;
        self.container = container;
        self.decimators = build_decimators(self.pcm.channels)?;
        self.eof = false;
        self.flushed = false;

        let target_dsd_bytes = target_pcm_frame.saturating_mul(4); // 32 DSD bits = 4 bytes per PCM frame
                                                                   // 留出 256 字节的预热窗口让抽取器稳定，再精确跳过多出的 PCM 帧。
        let warmup_bytes = target_dsd_bytes.min(256);
        let mut skip_bytes = target_dsd_bytes - warmup_bytes;
        while skip_bytes > 0 {
            let chunk = (skip_bytes as usize).min(64 * 1024);
            for b in &mut self.dsd_bufs {
                b.clear();
            }
            let got = self.container.read_bytes(chunk, &mut self.dsd_bufs)?;
            if got == 0 {
                break;
            }
            skip_bytes = skip_bytes.saturating_sub(got as u64);
        }
        self.skip_pcm_frames = warmup_bytes / 4;
        self.emitted_pcm_frames = target_pcm_frame;
        let _ = (self.is_dsf, self.dsd_info);
        let actual_ms = target_pcm_frame.saturating_mul(1_000) / u64::from(self.pcm.sample_rate);
        Ok(actual_ms)
    }

    fn native_format(&self) -> Option<NativeSampleFormat> {
        Some(NativeSampleFormat::Int { bits: 24 })
    }

    fn decode_next_native(&mut self, out: &mut Vec<i32>) -> Result<bool> {
        let nch = usize::from(self.pcm.channels);
        let mut q_ch: Vec<Vec<i32>> = vec![Vec::new(); nch];
        loop {
            let frames = self.decode_block_grid()?;
            if frames == 0 {
                return Ok(false);
            }
            let skip = (self.skip_pcm_frames as usize).min(frames);
            self.skip_pcm_frames = self.skip_pcm_frames.saturating_sub(skip as u64);
            let remaining = self
                .total_pcm_frames
                .saturating_sub(self.emitted_pcm_frames) as usize;
            let usable = (frames - skip).min(remaining);
            if usable == 0 {
                if remaining == 0 {
                    self.eof = true;
                    return Ok(false);
                }
                continue;
            }
            let gain = decimator::db_to_linear(6.0);
            for (ch, q_buf) in q_ch.iter_mut().enumerate().take(nch) {
                q_buf.clear();
                decimator::quantise(&self.pcm_ch_bufs[ch][skip..skip + usable], gain, q_buf);
            }
            out.reserve(usable * nch);
            #[allow(clippy::needless_range_loop)]
            for i in 0..usable {
                for ch_buf in &q_ch {
                    // 24-bit 有符号整数左对齐到高 24 位（PLY-05）。
                    out.push(ch_buf[i].wrapping_shl(8));
                }
            }
            self.emitted_pcm_frames += usable as u64;
            if self.emitted_pcm_frames >= self.total_pcm_frames {
                self.eof = true;
            }
            return Ok(true);
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use dsd2pcm::dff::DffWriter;
    use dsd2pcm::dsf::DsfWriter;
    use dsd2pcm::io::DsdWrite;
    use std::io::Cursor;

    fn make_dsf_bytes(bytes_per_ch: usize) -> Vec<u8> {
        let mut cur = Cursor::new(Vec::new());
        let mut writer = DsfWriter::new(&mut cur, 2, 2_822_400, None).unwrap();
        let data = vec![vec![0x69u8; bytes_per_ch]; 2];
        writer.write_bytes(&data).unwrap();
        writer.finish((bytes_per_ch as u64) * 8).unwrap();
        cur.into_inner()
    }

    fn make_dff_bytes(bytes_per_ch: usize) -> Vec<u8> {
        let mut cur = Cursor::new(Vec::new());
        let mut writer = DffWriter::new(&mut cur, 2, 2_822_400).unwrap();
        let data = vec![vec![0x69u8; bytes_per_ch]; 2];
        writer.write_bytes(&data).unwrap();
        writer.finish((bytes_per_ch as u64) * 8).unwrap();
        cur.into_inner()
    }

    #[test]
    fn decodes_dsf_and_dff_to_88200_pcm() {
        for bytes in [make_dsf_bytes(8_192), make_dff_bytes(8_192)] {
            let mut dec = DsdAudioDecoder::open(Cursor::new(bytes)).unwrap();
            assert_eq!(dec.props().codec, Codec::Dsd);
            assert_eq!(
                dec.format(),
                PcmFormat {
                    sample_rate: 88_200,
                    channels: 2
                }
            );
            let mut out = Vec::new();
            while dec.decode_next(&mut out).unwrap() {}
            // 8192 bytes * 8 bits / 32 decimation = 2048 PCM frames * 2 channels = 4096 samples
            assert_eq!(out.len(), 4_096);
            // Idle pattern 0x69 decimates to near-zero silence
            assert!(out.iter().all(|s| s.abs() < 0.01));

            // Seek midway
            let actual = dec.seek(10).unwrap();
            assert!((actual as i64 - 10).abs() <= 2);
            let mut tail = Vec::new();
            while dec.decode_next(&mut tail).unwrap() {}
            assert!(!tail.is_empty());
            assert!(tail.len() < 4_096);
        }
    }
}
