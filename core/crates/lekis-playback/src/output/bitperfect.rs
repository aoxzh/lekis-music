//! 比特完美（bit-perfect）输出：原生样本打包与输出路径选择。
//!
//! 解码器的原生样本链路（PLY-05）把整数 PCM 以**左对齐 i32** 传递（见
//! [`crate::decode::NativeSampleFormat`]）：16 bit 样本在高 16 位、24 bit 在高 24 位，
//! 低位全零；浮点源则以 f32 的位模式（`f32::to_bits`）放进 i32。
//!
//! 这里只做「按设备容器宽度取高位字节」的打包，不做任何算术：
//!
//! | 源格式 | 设备容器 | 打包 |
//! |---|---|---|
//! | Int 16 | 16 bit | 取高 2 字节 |
//! | Int 24 | 24 bit packed | 取高 3 字节 |
//! | Int 24 | 24-in-32 | 整个 i32（低 8 位本来就是零） |
//! | Int 32 | 32 bit | 整个 i32 |
//! | Float32 | 32 bit float | f32 位模式的 4 字节 |
//!
//! 所以只要采样率和声道数一致，送进设备的字节就是解码器输出的原始位模式，
//! 不经过 f32 转换、重采样、ReplayGain、音量或限幅。

use crate::decode::{NativeSampleFormat, PcmFormat};
use crate::output::OutputMode;

/// WASAPI / ALSA 等设备实际使用的样本容器。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NativePacking {
    /// 16 bit 有符号整数，2 字节。
    Int16,
    /// 24 bit 有符号整数，3 字节打包。
    Int24Packed,
    /// 24 bit 有效位放在 32 bit 容器里（高位对齐），4 字节。
    Int24In32,
    /// 32 bit 有符号整数，4 字节。
    Int32,
    /// 32 bit 浮点，4 字节。
    Float32,
}

impl NativePacking {
    /// 每个样本占几个字节。
    pub const fn container_bytes(self) -> usize {
        match self {
            Self::Int16 => 2,
            Self::Int24Packed => 3,
            Self::Int24In32 | Self::Int32 | Self::Float32 => 4,
        }
    }

    /// 有效位数。
    pub const fn valid_bits(self) -> u8 {
        match self {
            Self::Int16 => 16,
            Self::Int24Packed | Self::Int24In32 => 24,
            Self::Int32 | Self::Float32 => 32,
        }
    }

    /// 是否是浮点容器。
    pub const fn is_float(self) -> bool {
        matches!(self, Self::Float32)
    }
}

/// 某个源格式在设备上可尝试的容器，按优先级排列。
///
/// 只接受能**无损**承载源位深的容器：
/// - 16 bit → 16 bit；
/// - 24 bit → 24 bit packed，其次 24-in-32；
/// - 32 bit → 32 bit；
/// - 浮点 → float32。
///
/// 8 bit / 20 bit 等位深目前不做隐式补齐（补齐需要移位或量化，就不再是比特完美），
/// 返回空列表让上层退回共享模式。
pub fn packing_candidates(native: NativeSampleFormat) -> &'static [NativePacking] {
    match native {
        NativeSampleFormat::Int { bits: 16 } => &[NativePacking::Int16],
        NativeSampleFormat::Int { bits: 24 } => {
            &[NativePacking::Int24Packed, NativePacking::Int24In32]
        }
        NativeSampleFormat::Int { bits: 32 } => &[NativePacking::Int32],
        NativeSampleFormat::Float32 => &[NativePacking::Float32],
        NativeSampleFormat::Int { .. } => &[],
    }
}

/// 把左对齐 i32 样本按 `packing` 打包到 `out`，返回写入的字节数。
///
/// `out` 不够大时返回 0（不写半截数据）。函数不做分配，实时线程可以直接调用。
pub fn pack_into(samples: &[i32], packing: NativePacking, out: &mut [u8]) -> usize {
    let width = packing.container_bytes();
    let Some(total) = samples.len().checked_mul(width) else {
        return 0;
    };
    if out.len() < total {
        return 0;
    }
    for (sample, chunk) in samples.iter().zip(out[..total].chunks_exact_mut(width)) {
        match packing {
            NativePacking::Int16 => {
                // 左对齐 i32 的高 16 位就是原始 i16。
                let value = (sample >> 16) as i16;
                chunk.copy_from_slice(&value.to_le_bytes());
            }
            NativePacking::Int24Packed => {
                // 取高 24 位；算术右移保留符号，低 3 字节即 24 bit 补码。
                let value = sample >> 8;
                chunk.copy_from_slice(&value.to_le_bytes()[..3]);
            }
            NativePacking::Int24In32 | NativePacking::Int32 => {
                chunk.copy_from_slice(&sample.to_le_bytes());
            }
            NativePacking::Float32 => {
                // sample 里存的是 f32::to_bits 的位模式，原样写回。
                chunk.copy_from_slice(&sample.to_le_bytes());
            }
        }
    }
    total
}

/// 独占输出计划（格式协商结果，还没真正打开流）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NativePlan {
    /// 设备实际使用的采样率 / 声道数（与内容一致才算比特完美）。
    pub format: PcmFormat,
    /// 设备容器。
    pub packing: NativePacking,
}

/// 输出链路选择：原生比特完美，或共享模式的 f32 链路。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DecodePath {
    /// 解码器原生样本 → i32 环形缓冲 → WASAPI 独占，全程无转换。
    BitPerfect,
    /// 解码器 f32 → 可选重采样 → 共享模式输出。
    Shared,
}

/// 决定本次会话走哪条解码链路。
///
/// 只有同时满足「用户请求独占」「解码器有原生格式」「设备侧独占格式协商成功」才走比特完美；
/// 任何一项不满足都退回共享模式（由调用方打一条明确的 warning）。
pub(crate) fn choose_decode_path(
    requested: OutputMode,
    native: Option<NativeSampleFormat>,
    exclusive_ready: bool,
) -> DecodePath {
    if requested == OutputMode::Exclusive && native.is_some() && exclusive_ready {
        DecodePath::BitPerfect
    } else {
        DecodePath::Shared
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// 16 bit：取左对齐 i32 的高 16 位，小端字节和原始 i16 完全一致。
    #[test]
    fn packs_16_bit_left_aligned() {
        for value in [0i16, 1, -1, 12_345, -12_345, i16::MIN, i16::MAX] {
            let left_aligned = i32::from(value) << 16;
            let mut out = [0u8; 2];
            assert_eq!(
                pack_into(&[left_aligned], NativePacking::Int16, &mut out),
                2
            );
            assert_eq!(out, value.to_le_bytes(), "value = {value}");
        }
    }

    /// 24 bit packed：取左对齐 i32 的高 3 字节。
    #[test]
    fn packs_24_bit_packed() {
        let samples = [0x12_34_56_00i32, -0x01_00_00_00, 0x00_12_34_00];
        let expected: [[u8; 3]; 3] = [[0x56, 0x34, 0x12], [0x00, 0x00, 0xff], [0x34, 0x12, 0x00]];
        let mut out = [0u8; 9];
        assert_eq!(pack_into(&samples, NativePacking::Int24Packed, &mut out), 9);
        for (chunk, want) in out.chunks_exact(3).zip(expected) {
            assert_eq!(chunk, want);
        }
    }

    /// 24-in-32：低 8 位本来就是零，整个 i32 原样写出。
    #[test]
    fn packs_24_in_32() {
        let sample = 0x7f_ff_ff_00i32;
        let mut out = [0u8; 4];
        assert_eq!(pack_into(&[sample], NativePacking::Int24In32, &mut out), 4);
        assert_eq!(out, sample.to_le_bytes());
    }

    /// 32 bit 与浮点位模式都必须逐字节保持。
    #[test]
    fn packs_32_bit_and_float_bits() {
        let ints = [i32::MIN, -1, 0, 1, i32::MAX];
        let mut out = [0u8; 20];
        assert_eq!(pack_into(&ints, NativePacking::Int32, &mut out), 20);
        for (chunk, want) in out.chunks_exact(4).zip(ints) {
            assert_eq!(chunk, want.to_le_bytes());
        }

        let floats = [0.0f32, -0.0, 0.5, -1.0, f32::MIN_POSITIVE];
        let bits: Vec<i32> = floats.iter().map(|v| v.to_bits() as i32).collect();
        let mut out = [0u8; 20];
        assert_eq!(pack_into(&bits, NativePacking::Float32, &mut out), 20);
        for (chunk, want) in out.chunks_exact(4).zip(floats) {
            assert_eq!(chunk, want.to_bits().to_le_bytes());
        }
    }

    /// 输出缓冲区不够时不写半截数据。
    #[test]
    fn refuses_short_output_buffer() {
        let mut out = [0u8; 3];
        assert_eq!(pack_into(&[0, 0], NativePacking::Int16, &mut out), 0);
    }

    /// 容器候选只包含能无损承载源位深的格式。
    #[test]
    fn candidate_packings_are_lossless() {
        assert_eq!(
            packing_candidates(NativeSampleFormat::Int { bits: 16 }),
            &[NativePacking::Int16]
        );
        assert_eq!(
            packing_candidates(NativeSampleFormat::Int { bits: 24 }),
            &[NativePacking::Int24Packed, NativePacking::Int24In32]
        );
        assert_eq!(
            packing_candidates(NativeSampleFormat::Int { bits: 32 }),
            &[NativePacking::Int32]
        );
        assert_eq!(
            packing_candidates(NativeSampleFormat::Float32),
            &[NativePacking::Float32]
        );
        // 8 / 20 bit 需要补齐或移位，不属于比特完美路径。
        assert!(packing_candidates(NativeSampleFormat::Int { bits: 8 }).is_empty());
        assert!(packing_candidates(NativeSampleFormat::Int { bits: 20 }).is_empty());
    }

    /// 独占请求在任一条件不满足时必须退回共享，不能假装自己在比特完美。
    #[test]
    fn fallback_to_shared_when_bit_perfect_is_impossible() {
        let native = Some(NativeSampleFormat::Int { bits: 16 });
        assert_eq!(
            choose_decode_path(OutputMode::Exclusive, native, true),
            DecodePath::BitPerfect
        );
        assert_eq!(
            choose_decode_path(OutputMode::Shared, native, true),
            DecodePath::Shared,
            "用户选共享时不能用独占"
        );
        assert_eq!(
            choose_decode_path(OutputMode::Exclusive, None, true),
            DecodePath::Shared,
            "解码器没有原生格式时必须退回共享"
        );
        assert_eq!(
            choose_decode_path(OutputMode::Exclusive, native, false),
            DecodePath::Shared,
            "设备不接受独占格式时必须退回共享"
        );
    }
}
