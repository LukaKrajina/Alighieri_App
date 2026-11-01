//! 身份即密钥
//! ----------
//! `/login` 没有账号密码，也没有「忘记密码」链接 —— 身份本身就是一把 Ed25519 私钥：
//!   - peerId = 公钥的 libp2p 多重哈希，同时是网络地址、作者署名
//!   - 「恢复短语」= 私钥种子的十六进制分组，可抄下来备份
//!   - 用恢复短语导入身份即可在新设备上重新署名
//!
//! ⚠️ 已知不足（与 Web 版一致，有意保留）：私钥以明文存本地，
//! 未接系统钥匙串 / 口令派生加密；恢复短语请自己收好。

use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};

/// libp2p 的 Ed25519 公钥是多哈希 `identity` 编码：
/// `0x00`(identity) `0x24`(长度 36) + protobuf 公钥 `0x08 0x01 0x12 0x20 <32 字节>`
///
/// 这 6 个字节的前缀决定了 base58 之后总是以 `12D3Koo…` 开头 ——
/// 于是桥接节点扫一眼前缀就知道「这是内联公钥，可以直接验签」。
const IDENTITY_PREFIX: [u8; 6] = [0x00, 0x24, 0x08, 0x01, 0x12, 0x20];

#[derive(Debug, Clone)]
pub struct Identity {
    pub peer_id: String,
    /// 私钥种子（32 字节，仅本机保存）
    pub seed: Vec<u8>,
    pub created_at_ms: u64,
}

impl Identity {
    pub fn generate(now_ms: u64) -> Identity {
        let seed: [u8; 32] = rand::random();
        Identity::from_seed(&seed, now_ms)
    }

    pub fn from_seed(seed: &[u8; 32], now_ms: u64) -> Identity {
        let sk = SigningKey::from_bytes(seed);
        let peer_id = peer_id_from_public_key(&sk.verifying_key());
        Identity {
            peer_id,
            seed: seed.to_vec(),
            created_at_ms: now_ms,
        }
    }

    pub fn from_recovery_phrase(phrase: &str, now_ms: u64) -> Option<Identity> {
        let hex: String = phrase.chars().filter(|c| c.is_ascii_hexdigit()).collect();
        if hex.len() < 32 || hex.len() % 2 != 0 {
            return None;
        }
        let bytes = hex_to_bytes(&hex)?;
        if bytes.len() < 32 {
            return None;
        }
        let mut seed = [0u8; 32];
        seed.copy_from_slice(&bytes[..32]);
        Some(Identity::from_seed(&seed, now_ms))
    }

    /// 恢复短语：种子按 4 位一组断开，便于人工抄写与核对
    pub fn recovery_phrase(&self) -> String {
        let hex: String = self.seed.iter().map(|b| format!("{b:02x}")).collect();
        hex.as_bytes()
            .chunks(4)
            .map(|c| String::from_utf8_lossy(c).to_string())
            .collect::<Vec<_>>()
            .join("-")
    }

    pub fn signing_key(&self) -> Option<SigningKey> {
        let seed: [u8; 32] = self.seed.clone().try_into().ok()?;
        Some(SigningKey::from_bytes(&seed))
    }

    /// 对一段字节签名，返回 base64（与桥接节点的 `signature` 字段一致）
    pub fn sign_base64(&self, msg: &[u8]) -> Option<String> {
        let sk = self.signing_key()?;
        let sig: Signature = sk.sign(msg);
        Some(base64_encode(sig.to_bytes().as_ref()))
    }

    /// 系统派生的笔名
    pub fn pen_name(&self) -> String {
        crate::domain::penname::pen_name_from(&self.peer_id)
    }

    pub fn default_bio(&self) -> &'static str {
        crate::domain::penname::default_bio(&self.peer_id)
    }

    /// peerId 的短显示（界面上永远与笔名同时出现，因为笔名必然可能重复）
    pub fn short_peer(&self) -> String {
        tail8(&self.peer_id)
    }
}

/// 公钥 -> libp2p peerId
pub fn peer_id_from_public_key(pk: &VerifyingKey) -> String {
    let mut bytes = Vec::with_capacity(38);
    bytes.extend_from_slice(&IDENTITY_PREFIX);
    bytes.extend_from_slice(&pk.to_bytes());
    bs58::encode(bytes).with_alphabet(bs58::Alphabet::BITCOIN).into_string()
}

/// peerId -> 公钥（只接受内联公钥的 identity 多哈希）
///
/// 桥接节点用它验签：`detail.from` 必须能被解出公钥，
/// 否则「任何人都能自称某个 peerId」。
pub fn public_key_from_peer_id(peer_id: &str) -> Option<VerifyingKey> {
    let bytes = bs58::decode(peer_id)
        .with_alphabet(bs58::Alphabet::BITCOIN)
        .into_vec()
        .ok()?;
    if bytes.len() < IDENTITY_PREFIX.len() + 32 {
        return None;
    }
    if &bytes[..IDENTITY_PREFIX.len()] != IDENTITY_PREFIX {
        return None;
    }
    let mut key = [0u8; 32];
    key.copy_from_slice(&bytes[IDENTITY_PREFIX.len()..IDENTITY_PREFIX.len() + 32]);
    VerifyingKey::from_bytes(&key).ok()
}

/// 用 peerId 验签（桥接节点 / 收到他人 op 时用）
pub fn verify_signature(peer_id: &str, msg: &[u8], sig_b64: &str) -> bool {
    let (Some(pk), Some(sig_bytes)) = (public_key_from_peer_id(peer_id), base64_decode(sig_b64)) else {
        return false;
    };
    let Ok(sig) = Signature::from_slice(&sig_bytes) else {
        return false;
    };
    use ed25519_dalek::Verifier;
    pk.verify(msg, &sig).is_ok()
}

fn tail8(s: &str) -> String {
    let n = s.chars().count();
    if n <= 8 {
        s.to_string()
    } else {
        s.chars().skip(n - 8).collect()
    }
}

/* ------------------------- 极简 base64 / hex ------------------------- */

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn base64_encode(input: &[u8]) -> String {
    let mut out = String::new();
    for chunk in input.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(B64[(n >> 18) as usize & 63] as char);
        out.push(B64[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { B64[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { B64[n as usize & 63] as char } else { '=' });
    }
    out
}

fn b64_val(c: u8) -> Option<u8> {
    match c {
        b'A'..=b'Z' => Some(c - b'A'),
        b'a'..=b'z' => Some(c - b'a' + 26),
        b'0'..=b'9' => Some(c - b'0' + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
}

pub fn base64_decode(input: &str) -> Option<Vec<u8>> {
    let s: Vec<u8> = input.bytes().filter(|c| !c.is_ascii_whitespace()).collect();
    let mut out = Vec::new();
    for chunk in s.chunks(4) {
        let vals: Vec<u8> = chunk
            .iter()
            .filter(|c| **c != b'=')
            .map(|c| b64_val(*c))
            .collect::<Option<Vec<u8>>>()?;
        if let Some(a) = vals.get(0) {
            if let Some(b) = vals.get(1) {
                out.push((a << 2) | (b >> 4));
                if let Some(c) = vals.get(2) {
                    out.push((b << 4) | (c >> 2));
                    if let Some(d) = vals.get(3) {
                        out.push((c << 6) | d);
                    }
                }
            }
        }
    }
    Some(out)
}

fn hex_to_bytes(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn peer_id_has_the_ed25519_prefix() {
        let id = Identity::generate(0);
        assert!(id.peer_id.starts_with("12D3Koo"), "实际：{}", id.peer_id);
    }

    #[test]
    fn recovery_phrase_roundtrip() {
        let id = Identity::generate(0);
        let phrase = id.recovery_phrase();
        let back = Identity::from_recovery_phrase(&phrase, 0).unwrap();
        assert_eq!(back.peer_id, id.peer_id);
        assert_eq!(back.seed, id.seed);
    }

    #[test]
    fn recovery_phrase_tolerates_separators_and_case() {
        let id = Identity::generate(0);
        let messy = id.recovery_phrase().replace('-', " ").to_uppercase();
        let back = Identity::from_recovery_phrase(&messy, 0).unwrap();
        assert_eq!(back.peer_id, id.peer_id);
    }

    #[test]
    fn signature_verifies_against_peer_id() {
        let id = Identity::generate(0);
        let sig = id.sign_base64(b"hello").unwrap();
        assert!(verify_signature(&id.peer_id, b"hello", &sig));
        assert!(!verify_signature(&id.peer_id, b"hello!", &sig));
        // 换一个身份验不过
        let other = Identity::generate(0);
        assert!(!verify_signature(&other.peer_id, b"hello", &sig));
    }

    #[test]
    fn garbage_peer_id_does_not_panic() {
        assert!(public_key_from_peer_id("not-a-peer").is_none());
        assert!(public_key_from_peer_id("").is_none());
    }

    #[test]
    fn base64_roundtrip() {
        for len in 0..12usize {
            let data: Vec<u8> = (0..len).map(|i| (i * 37 + 11) as u8).collect();
            let enc = base64_encode(&data);
            assert_eq!(base64_decode(&enc).unwrap(), data);
        }
    }
}