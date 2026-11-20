//! 配对与认证用到的密码学原语（全部来自 `ring`）。
//!
//! - 配对：双方各生成一个临时 X25519 密钥对交换公钥，共享秘密和用户核对的 6 位配对码一起
//!   派生配对密钥（`pair_key`）。旁听者拿不到 X25519 共享秘密；中间人必须当场猜对配对码，
//!   而每个配对码只给一次机会。
//! - 长期密钥：`HMAC(pair_key, "long-term")`，双方各自存一份（不在网络上传输）。
//! - 每次连接：双方各出一个随机数，用长期密钥对整个握手记录做 HMAC，互相证明知道密钥。

use lekis_types::{LekisError, Result};
use ring::rand::{SecureRandom, SystemRandom};
use ring::{agreement, hmac};

/// 握手双方的身份和随机数（所有 MAC 都绑定它，防止重放到别的会话）。
#[derive(Debug, Clone)]
pub(crate) struct Transcript {
    pub client_id: String,
    pub server_id: String,
    pub client_nonce: String,
    pub server_nonce: String,
}

impl Transcript {
    fn parts(&self) -> [&[u8]; 4] {
        [
            self.client_id.as_bytes(),
            self.server_id.as_bytes(),
            self.client_nonce.as_bytes(),
            self.server_nonce.as_bytes(),
        ]
    }
}

/// `n` 字节安全随机数，十六进制。
pub(crate) fn random_hex(n: usize) -> Result<String> {
    let mut buf = vec![0u8; n];
    SystemRandom::new()
        .fill(&mut buf)
        .map_err(|_| LekisError::internal("system random unavailable"))?;
    Ok(hex::encode(buf))
}

/// 6 位数字配对码（拒绝采样，保证均匀）。
pub(crate) fn pairing_code() -> Result<String> {
    let rng = SystemRandom::new();
    loop {
        let mut buf = [0u8; 4];
        rng.fill(&mut buf)
            .map_err(|_| LekisError::internal("system random unavailable"))?;
        let n = u32::from_le_bytes(buf);
        // 4_294_000_000 是 1_000_000 的整数倍，超出部分丢掉重来。
        if n < 4_294_000_000 {
            return Ok(format!("{:06}", n % 1_000_000));
        }
    }
}

/// 对若干段数据做 HMAC-SHA256（每段带长度前缀，避免拼接歧义），十六进制输出。
pub(crate) fn mac(key: &[u8], label: &str, parts: &[&[u8]]) -> String {
    let key = hmac::Key::new(hmac::HMAC_SHA256, key);
    let mut ctx = hmac::Context::with_key(&key);
    for part in std::iter::once(label.as_bytes()).chain(parts.iter().copied()) {
        ctx.update(&(part.len() as u64).to_be_bytes());
        ctx.update(part);
    }
    hex::encode(ctx.sign().as_ref())
}

/// 常数时间比较两个十六进制 MAC。
pub(crate) fn mac_eq(expected: &str, got: &str) -> bool {
    let (a, b) = (expected.as_bytes(), got.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// 一次性的 X25519 密钥对。
pub(crate) struct Ephemeral {
    private: agreement::EphemeralPrivateKey,
    /// 公钥（十六进制）。
    pub public_hex: String,
}

impl Ephemeral {
    pub(crate) fn generate() -> Result<Self> {
        let rng = SystemRandom::new();
        let private = agreement::EphemeralPrivateKey::generate(&agreement::X25519, &rng)
            .map_err(|_| LekisError::internal("x25519 keygen failed"))?;
        let public = private
            .compute_public_key()
            .map_err(|_| LekisError::internal("x25519 public key failed"))?;
        Ok(Self {
            private,
            public_hex: hex::encode(public.as_ref()),
        })
    }

    /// 和对方公钥协商出共享秘密。
    pub(crate) fn agree(self, peer_public_hex: &str) -> Result<Vec<u8>> {
        let peer =
            hex::decode(peer_public_hex).map_err(|_| LekisError::invalid("bad peer public key"))?;
        let peer = agreement::UnparsedPublicKey::new(&agreement::X25519, peer);
        agreement::agree_ephemeral(self.private, &peer, |secret| secret.to_vec())
            .map_err(|_| LekisError::invalid("x25519 agreement failed"))
    }
}

/// 配对密钥：共享秘密 + 配对码 + 握手记录 + 双方公钥。
pub(crate) fn pair_key(
    shared: &[u8],
    code: &str,
    t: &Transcript,
    client_public: &str,
    server_public: &str,
) -> Vec<u8> {
    let [a, b, c, d] = t.parts();
    let hexed = mac(
        shared,
        "lekis-connect-pair-v1",
        &[
            code.as_bytes(),
            a,
            b,
            c,
            d,
            client_public.as_bytes(),
            server_public.as_bytes(),
        ],
    );
    hex::decode(hexed).unwrap_or_default()
}

/// 配对确认 MAC（`side` 是 `"c"` 或 `"s"`）。
pub(crate) fn pair_confirm(pair_key: &[u8], side: &str) -> String {
    mac(pair_key, "lekis-connect-confirm", &[side.as_bytes()])
}

/// 从配对密钥派生长期密钥。
pub(crate) fn long_term_key(pair_key: &[u8]) -> Vec<u8> {
    hex::decode(mac(pair_key, "lekis-connect-long-term", &[])).unwrap_or_default()
}

/// 已配对设备每次连接时的认证 MAC（`side` 是 `"c"` 或 `"s"`）。
pub(crate) fn auth_mac(key: &[u8], side: &str, t: &Transcript) -> String {
    let [a, b, c, d] = t.parts();
    mac(key, "lekis-connect-auth-v1", &[side.as_bytes(), a, b, c, d])
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    fn transcript() -> Transcript {
        Transcript {
            client_id: "c".into(),
            server_id: "s".into(),
            client_nonce: "n1".into(),
            server_nonce: "n2".into(),
        }
    }

    #[test]
    fn both_sides_derive_the_same_key_only_with_the_same_code() {
        let a = Ephemeral::generate().unwrap();
        let b = Ephemeral::generate().unwrap();
        let (pa, pb) = (a.public_hex.clone(), b.public_hex.clone());
        let sa = a.agree(&pb).unwrap();
        let sb = b.agree(&pa).unwrap();
        assert_eq!(sa, sb);
        let t = transcript();
        let ka = pair_key(&sa, "123456", &t, &pa, &pb);
        let kb = pair_key(&sb, "123456", &t, &pa, &pb);
        assert_eq!(ka, kb);
        let wrong = pair_key(&sb, "123457", &t, &pa, &pb);
        assert!(!mac_eq(&pair_confirm(&ka, "c"), &pair_confirm(&wrong, "c")));
        assert_ne!(long_term_key(&ka), long_term_key(&wrong));
    }

    #[test]
    fn pairing_code_is_six_digits() {
        for _ in 0..50 {
            let code = pairing_code().unwrap();
            assert_eq!(code.len(), 6);
            assert!(code.bytes().all(|b| b.is_ascii_digit()));
        }
    }

    #[test]
    fn auth_mac_binds_side_and_transcript() {
        let key = b"k";
        let t = transcript();
        assert_ne!(auth_mac(key, "c", &t), auth_mac(key, "s", &t));
        let mut t2 = t.clone();
        t2.server_nonce = "other".into();
        assert_ne!(auth_mac(key, "c", &t), auth_mac(key, "c", &t2));
    }
}
