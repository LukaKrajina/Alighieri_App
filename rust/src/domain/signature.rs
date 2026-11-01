//! 记录级签名
//! ------------
//! 每条网络 op 都带 `sig`，签名对象是「除 sig 之外的规范化 JSON」——
//! 改一个空格都算另一种说法。规范化规则与 Web 版 `lib/p2p/signature.ts` 完全一致：
//!
//!   · 对象键递归按字典序排列；
//!   · 只包含 `v,id,actor,hlts,kind,key,body` 与可选的 `cid`；
//!   · 不包含 `sig`；
//!   · UTF-8 JSON，无空格。
//!
//! 这样同一条 op 在任何设备上都序列化出同样的字节，签名才对得上。校验只需要
//! actor 的公钥 —— Ed25519 的 peerId 内联了公钥，省掉了公钥分发这一道。

use crate::domain::identity::{verify_signature, Identity};
use crate::domain::model::Op;

/// 规范化字节 = 签名对象
pub fn canonical_op_bytes(op: &Op) -> Vec<u8> {
    // 顶层字段按 Web 版的集合构造，再整体排序。
    let mut top = serde_json::Map::new();
    top.insert("v".into(), serde_json::Value::from(op.v));
    top.insert("id".into(), serde_json::Value::from(op.id.clone()));
    top.insert("actor".into(), serde_json::Value::from(op.actor.clone()));
    top.insert("hlts".into(), serde_json::Value::from(op.hlts.clone()));
    top.insert("kind".into(), serde_json::Value::from(op.kind.as_str()));
    top.insert("key".into(), serde_json::Value::from(op.key.clone()));
    top.insert("body".into(), op.body.clone());
    if let Some(cid) = op.cid.as_ref().filter(|s| !s.is_empty()) {
        top.insert("cid".into(), serde_json::Value::from(cid.clone()));
    }
    let mut out = String::new();
    write_canonical(&mut out, &serde_json::Value::Object(top));
    out.into_bytes()
}

/// 给一条 op 签名。失败（身份没有私钥）返回 false。
pub fn sign_op(identity: &Identity, op: &mut Op) -> bool {
    let bytes = canonical_op_bytes(op);
    match identity.sign_base64(&bytes) {
        Some(sig) => {
            op.sig = Some(sig);
            true
        }
        None => false,
    }
}

/// 验签。
/// `Some(true)` = 有效；`Some(false)` = 无效/被篡改；`None` = 无法验证（历史 op 没有 sig）。
pub fn verify_op(op: &Op) -> Option<bool> {
    let sig = op.sig.as_deref().filter(|s| !s.is_empty())?;
    if op.actor.is_empty() || op.id.is_empty() {
        return Some(false);
    }
    Some(verify_signature(&op.actor, &canonical_op_bytes(op), sig))
}

/// 与 `JSON.stringify` 对齐的确定性序列化 —— 不跟浏览器赌气，逐字节照做。
fn write_canonical(out: &mut String, value: &serde_json::Value) {
    match value {
        serde_json::Value::Null => out.push_str("null"),
        serde_json::Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        serde_json::Value::Number(n) => write_number(out, n),
        serde_json::Value::String(s) => {
            // serde_json 的字符串转义与 JSON.stringify 对齐：
            // 只转义控制字符、引号与反斜杠，不转义非 ASCII。
            out.push_str(&serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into()));
        }
        serde_json::Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_canonical(out, item);
            }
            out.push(']');
        }
        serde_json::Value::Object(map) => {
            out.push('{');
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            for (i, key) in keys.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&serde_json::to_string(key).unwrap_or_else(|_| "\"\"".into()));
                out.push(':');
                write_canonical(out, &map[*key]);
            }
            out.push('}');
        }
    }
}

fn write_number(out: &mut String, n: &serde_json::Number) {
    if let Some(i) = n.as_i64() {
        out.push_str(&i.to_string());
        return;
    }
    if let Some(u) = n.as_u64() {
        out.push_str(&u.to_string());
        return;
    }
    let Some(f) = n.as_f64() else {
        out.push_str("0");
        return;
    };
    if !f.is_finite() {
        out.push_str("null");
    } else if f == 0.0 {
        // JSON.stringify(-0) === "0"
        out.push('0');
    } else if f.fract() == 0.0 && f.abs() < 1e21 {
        // JSON.stringify(3.0) === "3"；serde_json 默认会输出 "3.0"
        out.push_str(&format!("{f:.0}"));
    } else {
        out.push_str(&format!("{f}"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::model::OpKind;

    fn sample() -> Op {
        Op {
            id: "p1:0001:abcd".into(),
            actor: "12D3KooWtest".into(),
            hlts: "000000001:0:p1".into(),
            kind: OpKind::NovelPut,
            key: "novel:n1".into(),
            body: serde_json::json!({ "title": "T", "b": 3.0, "a": [1, { "z": true, "y": null }] }),
            cid: None,
            v: 1,
            sig: None,
        }
    }

    #[test]
    fn canonical_keys_are_sorted_and_sig_is_excluded() {
        let op = sample();
        let s = String::from_utf8(canonical_op_bytes(&op)).unwrap();
        assert_eq!(
            s,
            r#"{"actor":"12D3KooWtest","body":{"a":[1,{"y":null,"z":true}],"b":3,"title":"T"},"hlts":"000000001:0:p1","id":"p1:0001:abcd","key":"novel:n1","kind":"novel.put","v":1}"#
        );
    }

    #[test]
    fn signature_roundtrip_and_tamper_detection() {
        let id = Identity::generate(0);
        let mut op = sample();
        op.actor = id.peer_id.clone();
        assert!(sign_op(&id, &mut op));
        assert_eq!(verify_op(&op), Some(true));
        op.body = serde_json::json!({ "title": "T2", "b": 3.0, "a": [1, { "z": true, "y": null }] });
        assert_eq!(verify_op(&op), Some(false));
        op.sig = None;
        assert_eq!(verify_op(&op), None);
    }
}