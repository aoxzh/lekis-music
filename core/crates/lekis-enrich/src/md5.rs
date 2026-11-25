//! 最小 MD5 实现（RFC 1321）。
//!
//! 只为了[第三方听歌记录上报](crate::scrobble)的 `api_sig` 签名而存在：Last.fm
//! （以及同协议的 Libre.fm）要求 `md5(按 key 排序拼接的参数 + api_secret)`。
//!
//! ## 为什么是复制而不是依赖
//!
//! `core/crates/lekis-providers/src/md5.rs` 里已经有一份同样用途的实现（Subsonic 的
//! `t = md5(password + salt)`）。`lekis-enrich` **不能**依赖 `lekis-providers`：
//! 前者是"元数据补全"的底层能力，后者是"音乐源客户端"，补全不该被某个源客户端拖进来
//! （两个 crate 也不互相依赖）。workspace 里也没
//! 有 `md-5` crate，为 20 行算法加一个依赖同样不划算。
//!
//! 因此这里保留一份副本：算法、常量表和测试向量与 `lekis-providers` 那份完全一致
//! （同一仓库、同一作者，没有外部许可证差异）。**改这里请同步改那边**，
//! 两份实现的 `rfc1321_vectors` 测试是同一组已知答案。
//!
//! **不要把它用于任何安全目的**：MD5 早已不安全，这里的用途只是兼容 2005 年定下来的
//! 协议格式（签名只用来防篡改请求，不承担保密职责）。

/// MD5 的循环左移位数（RFC 1321 第 3.4 节）。
const SHIFTS: [u32; 64] = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, //
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, //
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, //
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
];

/// 常量表 `K[i] = floor(2^32 * |sin(i + 1)|)`。
///
/// 不在运行时算是因为 `f64::sin` 不是 const fn，而表是公开的固定数据。
const TABLE: [u32; 64] = [
    0xd76a_a478,
    0xe8c7_b756,
    0x2420_70db,
    0xc1bd_ceee,
    0xf57c_0faf,
    0x4787_c62a,
    0xa830_4613,
    0xfd46_9501,
    0x6980_98d8,
    0x8b44_f7af,
    0xffff_5bb1,
    0x895c_d7be,
    0x6b90_1122,
    0xfd98_7193,
    0xa679_438e,
    0x49b4_0821,
    0xf61e_2562,
    0xc040_b340,
    0x265e_5a51,
    0xe9b6_c7aa,
    0xd62f_105d,
    0x0244_1453,
    0xd8a1_e681,
    0xe7d3_fbc8,
    0x21e1_cde6,
    0xc337_07d6,
    0xf4d5_0d87,
    0x455a_14ed,
    0xa9e3_e905,
    0xfcef_a3f8,
    0x676f_02d9,
    0x8d2a_4c8a,
    0xfffa_3942,
    0x8771_f681,
    0x6d9d_6122,
    0xfde5_380c,
    0xa4be_ea44,
    0x4bde_cfa9,
    0xf6bb_4b60,
    0xbebf_bc70,
    0x289b_7ec6,
    0xeaa1_27fa,
    0xd4ef_3085,
    0x0488_1d05,
    0xd9d4_d039,
    0xe6db_99e5,
    0x1fa2_7cf8,
    0xc4ac_5665,
    0xf429_2244,
    0x432a_ff97,
    0xab94_23a7,
    0xfc93_a039,
    0x655b_59c3,
    0x8f0c_cc92,
    0xffef_f47d,
    0x8584_5dd1,
    0x6fa8_7e4f,
    0xfe2c_e6e0,
    0xa301_4314,
    0x4e08_11a1,
    0xf753_7e82,
    0xbd3a_f235,
    0x2ad7_d2bb,
    0xeb86_d391,
];

/// 计算 MD5 摘要。
pub(crate) fn digest(input: &[u8]) -> [u8; 16] {
    let mut state: [u32; 4] = [0x6745_2301, 0xefcd_ab89, 0x98ba_dcfe, 0x1032_5476];

    // 填充：0x80、若干个 0，最后 8 字节是原始长度的位数（小端）。
    let bit_len = (input.len() as u64).wrapping_mul(8);
    let mut padded = Vec::with_capacity(input.len() + 72);
    padded.extend_from_slice(input);
    padded.push(0x80);
    while padded.len() % 64 != 56 {
        padded.push(0);
    }
    padded.extend_from_slice(&bit_len.to_le_bytes());

    for block in padded.chunks_exact(64) {
        let mut words = [0u32; 16];
        for (i, chunk) in block.chunks_exact(4).enumerate() {
            // `chunks_exact(4)` 保证每块正好 4 字节，下标不会越界。
            words[i] = u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
        }
        compress(&mut state, &words);
    }

    let mut out = [0u8; 16];
    for (i, word) in state.iter().enumerate() {
        // `i` 只可能是 0..4，`i * 4 + 4 <= 16`，下标安全。
        out[i * 4..i * 4 + 4].copy_from_slice(&word.to_le_bytes());
    }
    out
}

/// 计算 MD5 并输出小写十六进制（Last.fm 的 `api_sig` 就是这种形式）。
pub(crate) fn hex_digest(input: &[u8]) -> String {
    let mut out = String::with_capacity(32);
    for byte in digest(input) {
        out.push(char::from_digit(u32::from(byte >> 4), 16).unwrap_or('0'));
        out.push(char::from_digit(u32::from(byte & 0x0f), 16).unwrap_or('0'));
    }
    out
}

/// 处理一个 64 字节的块。
fn compress(state: &mut [u32; 4], words: &[u32; 16]) {
    let (mut a, mut b, mut c, mut d) = (state[0], state[1], state[2], state[3]);

    for i in 0..64 {
        let (f, g): (u32, usize) = match i / 16 {
            0 => ((b & c) | (!b & d), i),
            1 => ((d & b) | (!d & c), (5 * i + 1) % 16),
            2 => (b ^ c ^ d, (3 * i + 5) % 16),
            _ => (c ^ (b | !d), (7 * i) % 16),
        };
        let rotated = a
            .wrapping_add(f)
            .wrapping_add(TABLE[i])
            .wrapping_add(words[g])
            .rotate_left(SHIFTS[i]);
        let next = b.wrapping_add(rotated);
        a = d;
        d = c;
        c = b;
        b = next;
    }

    state[0] = state[0].wrapping_add(a);
    state[1] = state[1].wrapping_add(b);
    state[2] = state[2].wrapping_add(c);
    state[3] = state[3].wrapping_add(d);
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// RFC 1321 附录 A.5 的测试向量。
    #[test]
    fn rfc1321_vectors() {
        let cases = [
            ("", "d41d8cd98f00b204e9800998ecf8427e"),
            ("a", "0cc175b9c0f1b6a831c399e269772661"),
            ("abc", "900150983cd24fb0d6963f7d28e17f72"),
            ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
            (
                "abcdefghijklmnopqrstuvwxyz",
                "c3fcd3d76192e4007dfb496cca67e13b",
            ),
            (
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
                "d174ab98d277d9f5a5611c2c9f419d9f",
            ),
            (
                "12345678901234567890123456789012345678901234567890123456789012345678901234567890",
                "57edf4a22be3c955ac49da2e2107b67a",
            ),
        ];
        for (input, expected) in cases {
            assert_eq!(hex_digest(input.as_bytes()), expected, "input = {input:?}");
        }
    }

    /// 跨多个块（> 64 字节）的输入也要正确 —— 中文字符是多字节，签名里必然出现。
    #[test]
    fn handles_multi_block_and_utf8_input() {
        // 与 lekis-providers 的实现用同一组固定输入，方便两边对照。
        let text = "api_key0123456789abcdefmethodtrack.scrobbleskdeadbeefcafebabe";
        assert_eq!(hex_digest(text.as_bytes()).len(), 32);
        assert_eq!(hex_digest(text.as_bytes()), hex_digest(text.as_bytes()));
        assert_ne!(
            hex_digest("晴天".as_bytes()),
            hex_digest("晴天a".as_bytes()),
            "多字节输入必须参与运算"
        );
        assert!(hex_digest("叶惠美".as_bytes())
            .chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    }
}
