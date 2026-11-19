//! 基于 symphonia 的 [`Decoder`] 实现。
//!
//! 支持的容器/编码取决于 symphonia 启用的 feature（workspace 里是 `features = ["all"]`）：
//! MP3、AAC（ADTS / MP4）、ALAC、FLAC、WAV、AIFF、OGG Vorbis、CAF、MKV 等。
//!
//! **关于无缝播放（PLY-01）**：MP3/AAC 的编码器延迟和尾部填充由 demuxer 写进
//! `Packet::trim_start` / `Packet::trim_end`，symphonia 的解码器在 `gapless = true`（默认）
//! 时会在每个包上自动裁掉这些帧（见 symphonia-bundle-mp3 的 `decoder.rs`）。
//! 所以我们不需要自己算 LAME 延迟，只要别关掉 gapless。

use super::{Decoder, NativeSampleFormat, PcmFormat};
use lekis_types::{AudioProps, Codec, ErrorCode, LekisError, Result};
use symphonia::core::audio::sample::SampleFormat;
use symphonia::core::audio::GenericAudioBufferRef;
use symphonia::core::codecs::audio::well_known as codec_ids;
use symphonia::core::codecs::audio::{AudioCodecParameters, AudioDecoder, AudioDecoderOptions};
use symphonia::core::errors::Error as SymError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo, TrackType};
use symphonia::core::io::{MediaSource, MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::MetadataOptions;
use symphonia::core::units::{Time, TimeBase};

/// symphonia 解码器。
pub struct SymphoniaDecoder {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn AudioDecoder>,
    track_id: u32,
    /// 曲目时间基，用于把 duration / seek 结果换算成毫秒。
    time_base: Option<TimeBase>,
    /// 已输出的总样本数（= 帧数 × 声道数）。
    samples_out: u64,
    /// seek 之后需要丢掉的前导帧数（Accurate seek 落在目标点之前时补齐用）。
    skip_frames: u64,
    pcm: PcmFormat,
    props: AudioProps,
    duration_ms: Option<u64>,
    /// 复用缓冲区，避免每包都分配。
    scratch: Vec<f32>,
    /// 比特完美链路用的复用缓冲区（左对齐 i32 / f32 位模式）。
    scratch_native: Vec<i32>,
    /// 浮点源走比特完美链路时的 f32 中转缓冲。
    scratch_float: Vec<f32>,
    /// 原生样本格式（PLY-05）。
    native: Option<NativeSampleFormat>,
    eof: bool,
}

/// 一次解码要往哪里写。
enum Sink<'a> {
    /// 共享模式链路：f32 交错样本。
    F32(&'a mut Vec<f32>),
    /// 比特完美链路：左对齐 i32（整数源）或 f32 位模式（浮点源）。
    Native(&'a mut Vec<i32>, NativeSampleFormat),
}

impl SymphoniaDecoder {
    /// 从本地文件打开。
    pub fn open_file(file: std::fs::File, extension: Option<&str>) -> Result<Self> {
        let byte_len = file.metadata().ok().map(|m| m.len());
        Self::open_boxed(Box::new(file), extension, byte_len)
    }

    /// 从任意 symphonia 媒体源打开（本地文件、VFS 适配器……）。
    pub fn open_source(
        source: Box<dyn MediaSource + Send + Sync>,
        extension: Option<&str>,
    ) -> Result<Self> {
        let byte_len = source.byte_len();
        Self::open_boxed(source, extension, byte_len)
    }

    fn open_boxed(
        source: Box<dyn MediaSource + Send + Sync>,
        extension: Option<&str>,
        byte_len: Option<u64>,
    ) -> Result<Self> {
        let mss = MediaSourceStream::new(source, MediaSourceStreamOptions::default());
        let mut hint = Hint::new();
        if let Some(ext) = extension {
            hint.with_extension(ext);
        }
        // MP3 的 Xing 索引 / FLAC seektable 提前建好，拖动进度条时才不会卡（PLY-08）。
        let mut fmt_opts = FormatOptions::default();
        fmt_opts.prebuild_seek_index = true;

        let format = symphonia::default::get_probe()
            .probe(&hint, mss, fmt_opts, MetadataOptions::default())
            .map_err(|e| LekisError::new(ErrorCode::Decode, format!("probe failed: {e}")))?;

        let (track_id, codec_params, time_base, duration_ms, num_frames) = {
            let track = format
                .default_track(TrackType::Audio)
                .ok_or_else(|| LekisError::new(ErrorCode::Decode, "no audio track found"))?;
            let params = track
                .codec_params
                .as_ref()
                .and_then(|p| p.audio())
                .ok_or_else(|| {
                    LekisError::new(ErrorCode::Decode, "audio track has no codec parameters")
                })?
                .clone();
            let duration_ms = track_duration_ms(track, &params);
            (
                track.id,
                params,
                track.time_base,
                duration_ms,
                track.num_frames,
            )
        };
        let _ = num_frames;

        // gapless = true（默认）：按 Packet 的 trim 信息裁掉 MP3/AAC 的编码器延迟和填充。
        let decoder = symphonia::default::get_codecs()
            .make_audio_decoder(&codec_params, &AudioDecoderOptions::default())
            .map_err(|e| {
                LekisError::new(
                    ErrorCode::Unsupported,
                    format!("unsupported codec {:?}: {e}", codec_params.codec),
                )
            })?;

        // 少数容器把采样率放在解码器里，解一帧才知道；这里先用 44100 兜底，
        // 真正的值在第一次 decode 时从 AudioSpec 覆盖。
        let sample_rate = codec_params.sample_rate.unwrap_or(44_100);
        let channels = codec_params
            .channels
            .as_ref()
            .map(|c| c.count())
            .filter(|c| *c > 0)
            .unwrap_or(2) as u16;

        let native = native_format_of(&codec_params);

        let props = AudioProps {
            codec: map_codec(&codec_params),
            sample_rate,
            bit_depth: codec_params
                .bits_per_sample
                .and_then(|b| u8::try_from(b).ok()),
            channels: channels.min(255) as u8,
            // 容器里没有平均码率字段：用「文件大小 / 时长」估算（VBR 时是平均值）。
            bitrate_kbps: estimate_bitrate(byte_len, duration_ms),
        };

        Ok(Self {
            format,
            decoder,
            track_id,
            time_base,
            samples_out: 0,
            skip_frames: 0,
            pcm: PcmFormat {
                sample_rate,
                channels,
            },
            props,
            duration_ms,
            scratch: Vec::new(),
            scratch_native: Vec::new(),
            scratch_float: Vec::new(),
            native,
            eof: false,
        })
    }

    /// 已输出的样本数（帧数 × 声道）。
    pub fn samples_out(&self) -> u64 {
        self.samples_out
    }

    /// 解码下一个包，按 `sink` 要求的表示写出去。
    fn decode_into(&mut self, sink: Sink<'_>) -> Result<bool> {
        if self.eof {
            return Ok(false);
        }
        loop {
            let packet = match self.format.next_packet() {
                Ok(Some(packet)) => packet,
                Ok(None) => {
                    self.eof = true;
                    return Ok(false);
                }
                Err(SymError::ResetRequired) => {
                    // 链式 OGG 之类：当作结尾处理（symphonia 官方示例也这么说）。
                    self.eof = true;
                    return Ok(false);
                }
                Err(SymError::IoError(e)) => {
                    return Err(LekisError::new(
                        ErrorCode::Io,
                        format!("read packet failed: {e}"),
                    ))
                }
                Err(e) => {
                    tracing::debug!(target: "playback::decode", error = %e, "format error, treating as end of stream");
                    self.eof = true;
                    return Ok(false);
                }
            };
            if packet.track_id != self.track_id {
                continue;
            }
            match self.decoder.decode(&packet) {
                Ok(decoded) => {
                    if decoded.frames() == 0 {
                        continue;
                    }
                    // 借用冲突：decoded 借了 self.decoder，所以先把需要的字段拆出来。
                    let spec_rate = decoded.spec().rate();
                    let spec_channels = decoded.spec().channels().count();
                    let total = decoded.samples_interleaved();
                    match &sink {
                        Sink::F32(_) => {
                            self.scratch.resize(total, 0.0);
                            decoded.copy_to_slice_interleaved(self.scratch.as_mut_slice());
                        }
                        Sink::Native(_, native) => {
                            self.scratch_native.resize(total, 0);
                            copy_native(
                                &decoded,
                                *native,
                                &mut self.scratch_native,
                                &mut self.scratch_float,
                            );
                        }
                    }
                    if spec_rate > 0
                        && spec_channels > 0
                        && (spec_rate != self.pcm.sample_rate
                            || spec_channels != self.pcm.channels as usize)
                    {
                        self.pcm.sample_rate = spec_rate;
                        self.pcm.channels = spec_channels.min(255) as u16;
                        self.props.sample_rate = spec_rate;
                        self.props.channels = (self.pcm.channels.min(255)) as u8;
                    }
                    let mut start = 0usize;
                    if self.skip_frames > 0 {
                        let per_frame = usize::from(self.pcm.channels.max(1));
                        let skip = (self.skip_frames as usize).saturating_mul(per_frame);
                        self.skip_frames = 0;
                        start = skip.min(total);
                    }
                    match sink {
                        Sink::F32(out) => out.extend_from_slice(&self.scratch[start..]),
                        Sink::Native(out, _) => {
                            out.extend_from_slice(&self.scratch_native[start..]);
                        }
                    }
                    self.samples_out += (total - start) as u64;
                    return Ok(true);
                }
                Err(SymError::DecodeError(_)) | Err(SymError::IoError(_)) => {
                    // 坏包跳过（symphonia 官方示例同样的处理）。
                    continue;
                }
                Err(e) => {
                    tracing::debug!(target: "playback::decode", error = %e, "decoder error, treating as end of stream");
                    self.eof = true;
                    return Ok(false);
                }
            }
        }
    }
}

/// 把一包解码结果按原生格式拷出来（比特完美链路）。
///
/// - 整数源：symphonia 的整数 → i32 转换全是无损的**左移**（i16 `<< 16`、i24 `<< 8`，
///   无符号先减偏置），FLAC 解码器本身就输出左对齐的 i32。所以这里得到的是左对齐 i32，
///   有效位以下全是零。
/// - 浮点源：f32 原样拷贝，再取位模式。
fn copy_native(
    decoded: &GenericAudioBufferRef<'_>,
    native: NativeSampleFormat,
    out: &mut [i32],
    float_scratch: &mut Vec<f32>,
) {
    match native {
        NativeSampleFormat::Int { .. } => decoded.copy_to_slice_interleaved::<i32, _>(out),
        NativeSampleFormat::Float32 => {
            float_scratch.resize(out.len(), 0.0);
            decoded.copy_to_slice_interleaved::<f32, _>(float_scratch.as_mut_slice());
            for (dst, src) in out.iter_mut().zip(float_scratch.iter()) {
                *dst = src.to_bits() as i32;
            }
        }
    }
}

/// 根据编码参数推断原生样本格式。`None` = 不支持比特完美（f64、未知编码）。
fn native_format_of(params: &AudioCodecParameters) -> Option<NativeSampleFormat> {
    let declared_bits = params
        .bits_per_sample
        .and_then(|b| u8::try_from(b).ok())
        .filter(|b| (1..=32).contains(b));
    if let Some(format) = params.sample_format {
        let width = match format {
            SampleFormat::U8 | SampleFormat::S8 => 8,
            SampleFormat::U16 | SampleFormat::S16 => 16,
            SampleFormat::U24 | SampleFormat::S24 => 24,
            SampleFormat::U32 | SampleFormat::S32 => 32,
            SampleFormat::F32 => return Some(NativeSampleFormat::Float32),
            SampleFormat::F64 => return None,
        };
        let bits = declared_bits.map(|b| b.min(width)).unwrap_or(width);
        return Some(NativeSampleFormat::Int { bits });
    }
    let id = params.codec;
    if id == codec_ids::CODEC_ID_PCM_F32LE
        || id == codec_ids::CODEC_ID_PCM_F32BE
        || id == codec_ids::CODEC_ID_PCM_F32LE_PLANAR
        || id == codec_ids::CODEC_ID_PCM_F32BE_PLANAR
    {
        return Some(NativeSampleFormat::Float32);
    }
    if id == codec_ids::CODEC_ID_PCM_F64LE
        || id == codec_ids::CODEC_ID_PCM_F64BE
        || id == codec_ids::CODEC_ID_PCM_F64LE_PLANAR
        || id == codec_ids::CODEC_ID_PCM_F64BE_PLANAR
    {
        return None;
    }
    // 无损整数编码：位深来自 STREAMINFO / 容器头。
    let lossless_int = id == codec_ids::CODEC_ID_FLAC
        || id == codec_ids::CODEC_ID_ALAC
        || id == codec_ids::CODEC_ID_WAVPACK
        || id == codec_ids::CODEC_ID_MONKEYS_AUDIO
        || id == codec_ids::CODEC_ID_TTA
        || is_pcm(id);
    if lossless_int {
        return declared_bits.map(|bits| NativeSampleFormat::Int { bits });
    }
    // 有损编码（MP3 / AAC / Vorbis / Opus）：解码器输出就是 f32，这里的"比特完美"
    // 指的是解码结果原样送到设备，不再经过任何处理。
    if id == codec_ids::CODEC_ID_MP1
        || id == codec_ids::CODEC_ID_MP2
        || id == codec_ids::CODEC_ID_MP3
        || id == codec_ids::CODEC_ID_AAC
        || id == codec_ids::CODEC_ID_VORBIS
        || id == codec_ids::CODEC_ID_OPUS
    {
        return Some(NativeSampleFormat::Float32);
    }
    None
}

impl Decoder for SymphoniaDecoder {
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
        self.decode_into(Sink::F32(out))
    }

    fn native_format(&self) -> Option<NativeSampleFormat> {
        self.native
    }

    fn decode_next_native(&mut self, out: &mut Vec<i32>) -> Result<bool> {
        let Some(native) = self.native else {
            return Err(LekisError::new(
                ErrorCode::Unsupported,
                "this stream has no bit-perfect sample format",
            ));
        };
        self.decode_into(Sink::Native(out, native))
    }

    fn seek(&mut self, position_ms: u64) -> Result<u64> {
        let requested = match self.duration_ms {
            Some(total) => position_ms.min(total),
            None => position_ms,
        };
        let nanos = i128::from(requested).saturating_mul(1_000_000);
        let Some(time) = Time::try_from_nanos_i128(nanos) else {
            return Err(LekisError::invalid(format!(
                "seek target {requested} ms out of range"
            )));
        };
        let seeked = self
            .format
            .seek(
                SeekMode::Accurate,
                SeekTo::Time {
                    time,
                    track_id: Some(self.track_id),
                },
            )
            .map_err(|e| LekisError::new(ErrorCode::Decode, format!("seek failed: {e}")))?;

        self.decoder.reset();
        self.eof = false;

        // Accurate seek 只保证落在目标点之前的最近同步点（对 WAV 这类按包切分的就是包边界，
        // 8000 Hz 下常见是 1152 帧一包）。所以还要多跳一点：把 required_ts 与 actual_ts
        // 之间的帧数记下来，下一次 decode 时丢弃，播放位置才会真正落在 `requested` 上。
        let skip_ns = match self.time_base {
            Some(tb) => {
                let req = tb.calc_time_saturating(seeked.required_ts).as_nanos();
                let act = tb.calc_time_saturating(seeked.actual_ts).as_nanos();
                (req - act).max(0)
            }
            None => 0,
        };
        let rate = i128::from(self.pcm.sample_rate.max(1));
        let skip_frames = (skip_ns.saturating_mul(rate) / 1_000_000_000).max(0);
        self.skip_frames = u64::try_from(skip_frames).unwrap_or(u64::MAX);
        // 既然下一次 decode 会把这几帧扔掉，实际输出位置就是请求的位置本身。
        self.samples_out = requested
            .saturating_mul(u64::from(self.pcm.sample_rate))
            .saturating_mul(u64::from(self.pcm.channels))
            / 1000;
        Ok(requested)
    }
}

/// 从 `Track` 的时长信息推毫秒数。
fn track_duration_ms(
    track: &symphonia::core::formats::Track,
    params: &AudioCodecParameters,
) -> Option<u64> {
    if let (Some(dur), Some(tb)) = (track.duration, track.time_base) {
        let time = tb.calc_duration(dur)?;
        let ms = time.as_millis();
        if ms > 0 {
            return Some(ms as u64);
        }
    }
    // 退路：帧数 ÷ 采样率。
    if let (Some(frames), Some(rate)) = (track.num_frames, params.sample_rate) {
        if rate > 0 {
            return Some(frames.saturating_mul(1000) / u64::from(rate));
        }
    }
    None
}

/// 用文件大小和时长估算平均码率（kbps）。
fn estimate_bitrate(byte_len: Option<u64>, duration_ms: Option<u64>) -> Option<u32> {
    let len = byte_len?;
    let ms = duration_ms?;
    if ms == 0 {
        return None;
    }
    // bits / second / 1000 = bytes * 8 * 1000 / ms / 1000
    let kbps = len.saturating_mul(8) / ms.max(1);
    u32::try_from(kbps).ok().filter(|v| *v > 0)
}

/// symphonia 的编码 ID → 领域里的 [`Codec`]。
fn map_codec(params: &AudioCodecParameters) -> Codec {
    let id = params.codec;
    if id == codec_ids::CODEC_ID_MP1
        || id == codec_ids::CODEC_ID_MP2
        || id == codec_ids::CODEC_ID_MP3
    {
        return Codec::Mp3;
    }
    if id == codec_ids::CODEC_ID_AAC {
        return Codec::Aac;
    }
    if id == codec_ids::CODEC_ID_ALAC {
        return Codec::Alac;
    }
    if id == codec_ids::CODEC_ID_FLAC {
        return Codec::Flac;
    }
    if id == codec_ids::CODEC_ID_VORBIS {
        return Codec::Vorbis;
    }
    if id == codec_ids::CODEC_ID_OPUS {
        return Codec::Opus;
    }
    if id == codec_ids::CODEC_ID_WAVPACK {
        return Codec::WavPack;
    }
    if id == codec_ids::CODEC_ID_MONKEYS_AUDIO {
        return Codec::Ape;
    }
    if id == codec_ids::CODEC_ID_TTA {
        return Codec::Tta;
    }
    // PCM 家族：WAV / AIFF 都是它，具体容器看不出来，统一报 Wav（AIFF 由扩展名区分）。
    if is_pcm(id) {
        return Codec::Wav;
    }
    Codec::Other(format!("{:?}", params.codec))
}

fn is_pcm(id: symphonia::core::codecs::audio::AudioCodecId) -> bool {
    // AudioCodecId 的内部值是私有的，没有转 u32 的公开 API，所以只能逐个比对已注册的 PCM 常量。
    const PCM_IDS: &[symphonia::core::codecs::audio::AudioCodecId] = &[
        codec_ids::CODEC_ID_PCM_S32LE,
        codec_ids::CODEC_ID_PCM_S32LE_PLANAR,
        codec_ids::CODEC_ID_PCM_S32BE,
        codec_ids::CODEC_ID_PCM_S32BE_PLANAR,
        codec_ids::CODEC_ID_PCM_S24LE,
        codec_ids::CODEC_ID_PCM_S24LE_PLANAR,
        codec_ids::CODEC_ID_PCM_S24BE,
        codec_ids::CODEC_ID_PCM_S24BE_PLANAR,
        codec_ids::CODEC_ID_PCM_S16LE,
        codec_ids::CODEC_ID_PCM_S16LE_PLANAR,
        codec_ids::CODEC_ID_PCM_S16BE,
        codec_ids::CODEC_ID_PCM_S16BE_PLANAR,
        codec_ids::CODEC_ID_PCM_S8,
        codec_ids::CODEC_ID_PCM_S8_PLANAR,
        codec_ids::CODEC_ID_PCM_U32LE,
        codec_ids::CODEC_ID_PCM_U32LE_PLANAR,
        codec_ids::CODEC_ID_PCM_U32BE,
        codec_ids::CODEC_ID_PCM_U32BE_PLANAR,
        codec_ids::CODEC_ID_PCM_U24LE,
        codec_ids::CODEC_ID_PCM_U24LE_PLANAR,
        codec_ids::CODEC_ID_PCM_U24BE,
        codec_ids::CODEC_ID_PCM_U24BE_PLANAR,
        codec_ids::CODEC_ID_PCM_U16LE,
        codec_ids::CODEC_ID_PCM_U16LE_PLANAR,
        codec_ids::CODEC_ID_PCM_U16BE,
        codec_ids::CODEC_ID_PCM_U16BE_PLANAR,
        codec_ids::CODEC_ID_PCM_U8,
        codec_ids::CODEC_ID_PCM_U8_PLANAR,
        codec_ids::CODEC_ID_PCM_F32LE,
        codec_ids::CODEC_ID_PCM_F32LE_PLANAR,
        codec_ids::CODEC_ID_PCM_F32BE,
        codec_ids::CODEC_ID_PCM_F32BE_PLANAR,
        codec_ids::CODEC_ID_PCM_F64LE,
        codec_ids::CODEC_ID_PCM_F64LE_PLANAR,
        codec_ids::CODEC_ID_PCM_F64BE,
        codec_ids::CODEC_ID_PCM_F64BE_PLANAR,
        codec_ids::CODEC_ID_PCM_ALAW,
        codec_ids::CODEC_ID_PCM_MULAW,
    ];
    PCM_IDS.contains(&id)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::decode::Decoder;

    /// 生成一个最小但合法的 16-bit PCM WAV：RIFF 头 + fmt + data。
    pub(crate) fn wav_bytes(sample_rate: u32, channels: u16, frames: usize) -> Vec<u8> {
        let bits = 16u16;
        let block_align = channels * bits / 8;
        let data_len = (frames as u32) * u32::from(block_align);
        let mut buf = Vec::with_capacity(44 + data_len as usize);
        buf.extend_from_slice(b"RIFF");
        buf.extend_from_slice(&(36 + data_len).to_le_bytes());
        buf.extend_from_slice(b"WAVE");
        buf.extend_from_slice(b"fmt ");
        buf.extend_from_slice(&16u32.to_le_bytes()); // fmt 块长度
        buf.extend_from_slice(&1u16.to_le_bytes()); // PCM
        buf.extend_from_slice(&channels.to_le_bytes());
        buf.extend_from_slice(&sample_rate.to_le_bytes());
        buf.extend_from_slice(&(sample_rate * u32::from(block_align)).to_le_bytes()); // byte rate
        buf.extend_from_slice(&block_align.to_le_bytes());
        buf.extend_from_slice(&bits.to_le_bytes());
        buf.extend_from_slice(b"data");
        buf.extend_from_slice(&data_len.to_le_bytes());
        // 采样值：左声道从 0 递增的锯齿，右声道取反，便于校验顺序。
        for i in 0..frames {
            let v = ((i % 1000) as i32 * 32 - 16_000) as i16;
            for ch in 0..channels {
                let s = if ch % 2 == 0 { v } else { v.wrapping_neg() };
                buf.extend_from_slice(&s.to_le_bytes());
            }
        }
        buf
    }

    #[test]
    fn decodes_generated_wav() {
        let rate = 44_100;
        let channels = 2u16;
        let frames = 4_410; // 0.1 秒
        let bytes = wav_bytes(rate, channels, frames);
        let cursor = std::io::Cursor::new(bytes);
        let mut dec =
            SymphoniaDecoder::open_source(Box::new(cursor), Some("wav")).expect("wav 应该能打开");
        assert_eq!(
            dec.format(),
            PcmFormat {
                sample_rate: rate,
                channels
            }
        );
        assert_eq!(dec.props().codec, Codec::Wav);
        let dur = dec.duration_ms().expect("wav 有时长");
        assert!((dur as i64 - 100).abs() <= 2, "duration = {dur}");

        let mut out = Vec::new();
        let mut blocks = 0;
        while dec.decode_next(&mut out).expect("decode") {
            blocks += 1;
            if blocks > 10_000 {
                break;
            }
        }
        assert_eq!(
            out.len(),
            frames * usize::from(channels),
            "样本数必须等于帧数 × 声道"
        );
        // 第一帧：左声道是 -16000/32768（负），右声道取反（正）。
        assert!(out[0] < 0.0, "left = {}", out[0]);
        assert!(out[1] > 0.0, "right = {}", out[1]);
        assert!((out[0] + out[1]).abs() < 1e-6);
        // 全部样本都在 [-1, 1]。
        assert!(out.iter().all(|s| s.abs() <= 1.0));
    }

    #[test]
    fn seek_lands_on_requested_frame() {
        let rate = 8_000;
        let channels = 2u16;
        let frames = 8_000; // 1 秒
        let bytes = wav_bytes(rate, channels, frames);
        let mut dec = SymphoniaDecoder::open_source(
            Box::new(std::io::Cursor::new(bytes.clone())),
            Some("wav"),
        )
        .expect("open wav");
        let actual = dec.seek(500).expect("seek to 500ms");
        assert!((actual as i64 - 500).abs() <= 20, "actual = {actual}");

        let mut out = Vec::new();
        assert!(dec.decode_next(&mut out).expect("decode after seek"));
        assert!(!out.is_empty());
        // 500ms 落在第 4000 帧：锯齿值应该是 (4000 % 1000)*32 - 16000 = -16000。
        // 换算成 f32 后约 -0.488。
        let expected = (-16_000f32) / 32_768.0;
        assert!(
            (out[0] - expected).abs() < 0.01,
            "first sample after seek = {}, expected ≈ {}",
            out[0],
            expected
        );
        // seek 之后样本数应该只剩一半左右。
        let mut total = out.len();
        while dec.decode_next(&mut out).expect("decode") {
            total = out.len();
        }
        let remaining = total / usize::from(channels);
        assert!(
            (3_900..=4_100).contains(&remaining),
            "remaining frames = {remaining}"
        );
    }
}
