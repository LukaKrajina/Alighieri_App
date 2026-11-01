//! 私钥保管（口令派生加密）
//! --------------------------
//! 与 Web 版 `lib/p2p/keyvault.ts` 同一套参数：
//!   · 口令 -> PBKDF2-SHA256（310,000 轮，OWASP 2023 建议值）-> AES-256-GCM 密钥
//!   · 每次加密用新的 16 字节 salt / 12 字节 nonce（同样的口令也得到不同密文）
//!   · AES-GCM 自带完整性校验：口令错了会解密失败，而不是解出乱码身份
//!     —— 错得干脆，不留半真半假的幻觉
//!
//! 刻意不做的两件事（与 Web 版一致）：
//!   1. **不提供「找回口令」。** 私钥只在这台设备上，没有服务器持有它，
//!      也不存在后门 —— 与「恢复短语」的语义一致；丢了就是丢了，没有抽屉可翻。
//!   2. **不把口令存下来用于自动解锁。** 自动解锁等于没加密；
//!      解锁只在本会话有效，锁定/重启后需要重新输入 —— 省事的代价通常是省掉安全。
//!
//! 这里的纯函数（派生密钥、加密、解密、强度提示）都在这个文件里，
//! 具体完成格式见 `store.rs` 的 `IdentityFile::Encrypted`。

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use pbkdf2::pbkdf2_hmac;
use sha2::Sha256;

pub const PBKDF2_ITERATIONS: u32 = 310_000;
pub const SALT_BYTES: usize = 16;
pub const NONCE_BYTES: usize = 12;
/// 口令最短长度。再短的话，口令的密钥空间比 Ed25519 私钥小太多，
/// 加密只是给人虚假的安全感 —— 界面必须如实说明，别让人以为上了锁就万事大吉。
pub const MIN_PASSPHRASE_LEN: usize = 8;

/// 加密后的私钥信封（字段是 base64，落盘时整体写进 identity.json）。
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct EncryptedIdentity {
    /// 版本号，未来换参数（迭代次数等）时靠它区分
    pub v: u32,
    /// PBKDF2 迭代次数（写进信封，换参数时老信封还能解）
    pub iters: u32,
    pub salt: String,
    pub nonce: String,
    /// 密文（含 GCM tag）
    pub data: String,
}

impl EncryptedIdentity {
    pub const CURRENT_V: u32 = 1;
}

fn derive_key(passphrase: &str, salt: &[u8], iters: u32) -> [u8; 32] {
    let mut key = [0u8; 32];
    pbkdf2_hmac::<Sha256>(passphrase.as_bytes(), salt, iters, &mut key);
    key
}

/// 用口令加密字节。太短的口令直接拒绝。
pub fn seal(plaintext: &[u8], passphrase: &str) -> Result<EncryptedIdentity, String> {
    if passphrase.chars().count() < MIN_PASSPHRASE_LEN {
        return Err("passphrase-too-short".into());
    }
    let salt: [u8; SALT_BYTES] = rand::random();
    let nonce_bytes: [u8; NONCE_BYTES] = rand::random();
    let key = derive_key(passphrase, &salt, PBKDF2_ITERATIONS);
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|e| format!("无法初始化加密器：{e}"))?;
    let data = cipher
        .encrypt(Nonce::from_slice(&nonce_bytes), plaintext)
        .map_err(|e| format!("加密失败：{e}"))?;
    Ok(EncryptedIdentity {
        v: EncryptedIdentity::CURRENT_V,
        iters: PBKDF2_ITERATIONS,
        salt: crate::domain::identity::base64_encode(&salt),
        nonce: crate::domain::identity::base64_encode(&nonce_bytes),
        data: crate::domain::identity::base64_encode(&data),
    })
}

/// 用口令解密。口令错误会得到 GCM 校验失败（返回 Err），而不是乱码。
pub fn open(boxed: &EncryptedIdentity, passphrase: &str) -> Result<Vec<u8>, String> {
    if boxed.v != EncryptedIdentity::CURRENT_V {
        return Err("unsupported-keyvault".into());
    }
    let Some(salt) = crate::domain::identity::base64_decode(&boxed.salt) else {
        return Err("密钥文件损坏（salt）".into());
    };
    let Some(nonce_bytes) = crate::domain::identity::base64_decode(&boxed.nonce) else {
        return Err("密钥文件损坏（nonce）".into());
    };
    let Some(data) = crate::domain::identity::base64_decode(&boxed.data) else {
        return Err("密钥文件损坏（data）".into());
    };
    if nonce_bytes.len() != NONCE_BYTES {
        return Err("密钥文件损坏（nonce 长度）".into());
    }
    let key = derive_key(passphrase, &salt, boxed.iters);
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|e| format!("无法初始化解密器：{e}"))?;
    cipher
        .decrypt(Nonce::from_slice(&nonce_bytes), data.as_slice())
        .map_err(|_| "passphrase-wrong".to_string())
}

/// 口令强度提示（界面用，不是安全策略）。
///
/// 只做最朴素的判断：长度 + 字符种类。不假装能测出「密码好不好」——
/// 那需要词典与常见口令库，这里只负责粗略提醒。
pub fn passphrase_strength(passphrase: &str) -> &'static str {
    let kinds = [(|c: char| c.is_ascii_lowercase()),
                 (|c: char| c.is_ascii_uppercase()),
                 (|c: char| c.is_ascii_digit()),
                 (|c: char| !c.is_ascii_alphanumeric())]
        .iter()
        .filter(|f| passphrase.chars().any(|c| f(c)))
        .count();
    let long = passphrase.chars().count() >= 12;
    if passphrase.chars().count() >= MIN_PASSPHRASE_LEN && (kinds >= 2 || long) {
        if long && kinds >= 3 {
            "strong"
        } else {
            "fair"
        }
    } else {
        "weak"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let plaintext = b"0123456789abcdef0123456789abcdef{\"seed\":\"ab\"}";
        let boxed = seal(plaintext, "correct horse battery staple").unwrap();
        assert_eq!(boxed.iters, PBKDF2_ITERATIONS);
        assert_eq!(open(&boxed, "correct horse battery staple").unwrap(), plaintext);
    }

    #[test]
    fn wrong_passphrase_fails_not_garbage() {
        let boxed = seal(b"secret-bytes", "right passphrase").unwrap();
        assert_eq!(open(&boxed, "wrong passphrase").unwrap_err(), "passphrase-wrong");
    }

    #[test]
    fn tampered_ciphertext_fails() {
        let mut boxed = seal(b"secret", "right passphrase").unwrap();
        // 翻转密文第一个字节 -> GCM tag 校验必须失败
        let mut data = crate::domain::identity::base64_decode(&boxed.data).unwrap();
        data[0] ^= 0x01;
        boxed.data = crate::domain::identity::base64_encode(&data);
        assert!(open(&boxed, "right passphrase").is_err());
    }

    #[test]
    fn too_short_passphrase_rejected() {
        assert_eq!(seal(b"secret", "short").unwrap_err(), "passphrase-too-short");
        assert!(seal(b"secret", "longenough").is_ok());
    }

    #[test]
    fn same_passphrase_gives_different_ciphertext() {
        let a = seal(b"secret", "same passphrase").unwrap();
        let b = seal(b"secret", "same passphrase").unwrap();
        assert_ne!(a.salt, b.salt);
        assert_ne!(a.nonce, b.nonce);
        assert_ne!(a.data, b.data);
    }

    #[test]
    fn strength_labels() {
        assert_eq!(passphrase_strength("abc"), "weak");
        assert_eq!(passphrase_strength("abcdefgh"), "weak");
        assert_eq!(passphrase_strength("abcDEFgh"), "fair");
        assert_eq!(passphrase_strength("abcdefgh12"), "fair");
        assert_eq!(passphrase_strength("long-enough-12"), "strong");
        assert_eq!(passphrase_strength("Ab0!defghijkl"), "strong");
    }
}