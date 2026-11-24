//! QQ local QRC wraps a zlib stream in a fixed, non-standard DES-EDE variant.
//! The key schedule, substitutions and little-endian word order are format constants.

use std::sync::LazyLock;

pub(super) const MAGIC: &[u8] = b"\x98\x25\xb0\xac\xe3\x02\x83\x68\xe8\xfc\x6c";
const MASK: [u64; 16] = [
    0xc34ad6ca9067f752,
    0xd8a166629f5b0900,
    0xc35e95239f13117e,
    0xd8923fbc90bb740e,
    0xc347743d90aa3f51,
    0xd8f411849fde951d,
    0xc3c609d59ffa66f9,
    0xd8f0f7a090a1d6f3,
    0xc3f3d6a190a0f7f0,
    0xd8f966fa9fd509c6,
    0xc31d95de9f8411f4,
    0xd8513faa903d7447,
    0xc30e74bb90bc3f92,
    0xd87e11139f23955e,
    0xc300095b9f6266a1,
    0xd852f76790cad64a,
];

const SUBSTITUTIONS: [[u64; 4]; 8] = [
    [
        0xe4d12fb83a6c5907,
        0x0f74e2d1a6cb9538,
        0x41e8d62bfc973a50,
        0xfc8249175b3ea06d,
    ],
    [
        0xf18e6b34972dc05a,
        0x3d47f28fc01a69b5,
        0x0e7ba4d158c6932f,
        0xd8a13f42b67c05e9,
    ],
    [
        0xa09e63f51dc7b428,
        0xd709346a285ecbf1,
        0xd6498f30b12c5ae7,
        0x1ad069874fe3b52c,
    ],
    [
        0x7de3069a1285bc4f,
        0xd8b56f03472c1ae9,
        0xa690cb7df13e5284,
        0x3f06aad8945bc72e,
    ],
    [
        0x2c417ab6853fd0e9,
        0xeb2c47d150fa3986,
        0x421bad78f9c5630e,
        0xb8c71e2d6f09a453,
    ],
    [
        0xc1af92680d34e75b,
        0xaf427c9561de0b38,
        0x9ef528c3704a1db6,
        0x432c95fabe17608d,
    ],
    [
        0x4b2ef08d3c975a61,
        0xd0b7491ae35c2f86,
        0x14bdc37eaf680592,
        0x6bd814a7950fe23c,
    ],
    [
        0xd2846fb1a93e50c7,
        0x1fd8a374c56b0e92,
        0x7b419ce206adf358,
        0x21e74a8dfc90356b,
    ],
];

fn select(input: u64, width: usize, positions: &[usize]) -> u64 {
    positions.iter().fold(0, |bits, index| {
        (bits << 1) | ((input >> (width - index - 1)) & 1)
    })
}

static ROUND_TABLE: LazyLock<[[u32; 64]; 8]> = LazyLock::new(|| {
    let perm = [
        15, 6, 19, 20, 28, 11, 27, 16, 0, 14, 22, 25, 4, 17, 30, 9, 1, 7, 23, 13, 31, 26, 2, 8, 18,
        12, 29, 5, 21, 10, 3, 24,
    ];
    std::array::from_fn(|group| {
        std::array::from_fn(|index| {
            let row = ((index & 32) >> 4) | (index & 1);
            let column = (index >> 1) & 15;
            let nibble = (SUBSTITUTIONS[group][row] >> (4 * (15 - column))) & 15;
            select(nibble << (4 * (7 - group)), 32, &perm) as u32
        })
    })
});

fn word_order(mut block: [u8; 8]) -> [u8; 8] {
    block[..4].reverse();
    block[4..].reverse();
    block
}

static KEYS: LazyLock<[[[u8; 8]; 16]; 3]> = LazyLock::new(|| {
    let key_parts = [*b"!@#)(NHL", *b"123ZXC!@", *b"!@#)(*$%"];
    std::array::from_fn(|stage| {
        let key = u64::from_be_bytes(word_order(key_parts[stage]));
        let mut left = select(
            key,
            64,
            &[
                56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18,
                10, 2, 59, 51, 43, 35,
            ],
        );
        let mut right = select(
            key,
            64,
            &[
                62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 60, 52, 44, 36, 28,
                20, 12, 4, 27, 19, 11, 3,
            ],
        );
        let mut rounds = std::array::from_fn(|round| {
            let shift = if matches!(round, 0 | 1 | 8 | 15) {
                1
            } else {
                2
            };
            let rotate = |half: u64| ((half << shift) | (half >> (28 - shift))) & 0xfffffff;
            left = rotate(left);
            right = rotate(right);
            let high = select(
                left,
                28,
                &[
                    13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15, 6, 26, 19,
                    12, 1,
                ],
            );
            let low = select(
                right << 1,
                29,
                &[
                    13, 24, 3, 9, 19, 27, 2, 12, 23, 17, 5, 20, 16, 21, 11, 28, 6, 25, 18, 14, 22,
                    8, 1, 4,
                ],
            );
            let bits = (high << 24) | low;
            std::array::from_fn(|group| ((bits >> (42 - 6 * group)) & 63) as u8)
        });
        if stage != 1 {
            rounds.reverse();
        }
        rounds
    })
});

static PERMS: LazyLock<([usize; 64], [usize; 64])> = LazyLock::new(|| {
    let forward =
        std::array::from_fn(|index| (7 - index % 8) * 8 + [1, 3, 5, 7, 0, 2, 4, 6][index / 8]);
    let mut inverse = [0; 64];
    for (index, &position) in forward.iter().enumerate() {
        inverse[position] = index;
    }
    (forward, inverse)
});

fn decrypt_block(block: [u8; 8]) -> [u8; 8] {
    let permuted = select(u64::from_be_bytes(word_order(block)), 64, &PERMS.0);
    let (mut left, mut right) = ((permuted >> 32) as u32, permuted as u32);
    for stage in KEYS.iter() {
        for key in stage {
            let mut window = right.rotate_right(1);
            let mut substituted = 0;
            for (table, group_key) in ROUND_TABLE.iter().zip(key) {
                substituted ^= table[((window >> 26) as u8 ^ group_key) as usize];
                window = window.rotate_left(4);
            }
            (left, right) = (right, left ^ substituted);
        }
        std::mem::swap(&mut left, &mut right);
    }
    word_order(select((u64::from(left) << 32) | u64::from(right), 64, &PERMS.1).to_be_bytes())
}

pub(super) fn unpack(file: &[u8]) -> Option<Vec<u8>> {
    let mut payload = if let Some(local) = file.strip_prefix(MAGIC) {
        let mut data = local.to_vec();
        for (offset, byte) in (MAGIC.len()..).zip(&mut data) {
            let index = if offset > 0x7fff {
                offset % 0x7fff
            } else {
                offset
            } % 128;
            *byte ^= MASK[index / 8].to_be_bytes()[index % 8];
        }
        data
    } else {
        let hex: Vec<_> = file
            .iter()
            .copied()
            .filter(|b| !b.is_ascii_whitespace())
            .collect();
        hex::decode(hex).ok()?
    };
    let blocks = payload.chunks_exact(8);
    if !blocks.remainder().is_empty() {
        return None;
    }
    for (index, block) in payload.chunks_exact_mut(8).enumerate() {
        let decoded = decrypt_block((*block).try_into().ok()?);
        if index == 0
            && (decoded[0] & 15 != 8 || u16::from_be_bytes([decoded[0], decoded[1]]) % 31 != 0)
        {
            return None;
        }
        block.copy_from_slice(&decoded);
    }
    super::inflate(&payload)
}
