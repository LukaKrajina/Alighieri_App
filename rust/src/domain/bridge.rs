//! 奖励币上链（ALC → CALC）协议
//! ================================
//! 这个模块是**纯函数**，不含网络、链、也不碰本地存储。
//! 客户端和桥接节点都从这里取同一套规则 —— 涉及钱的逻辑，不该只能靠点一遍界面来证明自己没坏。
//!
//! ## 威胁模型（先说清楚这套东西凭什么能信）
//!
//! `Op` 本身**没有签名字段**，`op.actor` 是一段可伪造的字符串。
//! 任何人都能造一条 `reward.grant`，把 `to` 写成自己、`amount` 写成 10^9，
//! 全程不需要任何权限。所以「读到一条 op 就发币」是不能做的。
//!
//! 那凭什么可信？靠的是**传输层的消息签名**，而不是 op 字段。
//! 于是规则是：**桥接节点只认「我直接收到、且 op.actor 等于已验证作者」的 op。**
//!
//! 剩下三个问题：
//!  1. **重放** —— 不按「余额」结算，而是**按 op 逐笔消费**。
//!  2. **冒名申领** —— 申领要用身份私钥对规范化载荷做 Ed25519 签名。
//!  3. **余额分歧** —— 不隐藏这件事，`coverage_of()` 如实算出节点侧认可多少。

use sha2::{Digest, Sha256};

/// 协议版本，进签名载荷，改格式必须升版本
pub const WRAP_VERSION: &str = "alc-wrap-v1";

/// 一次申领允许的最大数量。
/// 不是安全边界（桥接节点有自己的上限），而是防止客户端手滑填错数量。
pub const MAX_WRAP_PER_CLAIM: i64 = 100_000;

/// 一条申领最多能引用多少条 op（防止超大请求拖垮节点）
pub const MAX_OP_IDS: usize = 200;

/// 客户端 → 桥接节点的申领正文
#[derive(Debug, Clone)]
pub struct WrapClaim {
    /// 申领人 peerId
    pub peer_id: String,
    /// 上链数量（整数 ALC）
    pub amount: i64,
    /// 支撑这笔申领的 reward op 的 opId 列表
    pub op_ids: Vec<String>,
    /// 链上收款地址
    pub to_address: String,
    /// 随机串：让每次尝试唯一，防止签名被重放
    pub nonce: String,
}

/* ------------------------- 规范化载荷 ------------------------- */

/// 生成待签名字节。
///
/// 每个字段都用「长度:内容」前缀，**不是**用分隔符拼接：
/// 分隔符拼接遇到字段里含分隔符就会歧义，而 peerId / opId 都是外部输入。
/// opIds 先排序，这样签名与客户端碰巧的排列顺序无关。
pub fn canonical_wrap_payload(claim: &WrapClaim) -> Vec<u8> {
    let mut parts: Vec<String> = vec![WRAP_VERSION.to_string()];
    let amount = claim.amount.to_string();
    let addr = claim.to_address.to_lowercase();

    field(&mut parts, &claim.peer_id);
    field(&mut parts, &amount);
    let mut ids = claim.op_ids.clone();
    ids.sort();
    parts.push(ids.len().to_string());
    for id in &ids {
        field(&mut parts, id);
    }
    field(&mut parts, &addr);
    field(&mut parts, &claim.nonce);
    parts.join("\n").into_bytes()
}

fn field(parts: &mut Vec<String>, s: &str) {
    parts.push(format!("{}:{}", s.as_bytes().len(), s));
}

/// 载荷的 sha256，hex
pub fn hash_wrap_payload(claim: &WrapClaim) -> String {
    let mut hasher = Sha256::new();
    hasher.update(canonical_wrap_payload(claim));
    let out = hasher.finalize();
    out.iter().map(|b| format!("{b:02x}")).collect()
}

/* ------------------------- 一致性金标准向量 ------------------------- */

/// 规范化载荷有**多份实现**（Web 端 `lib/p2p/bridge-protocol.ts`、
/// 桥接节点 `bridge/src/index.ts`、以及本文件）。三份必须逐字节一致，
/// 否则签名永远验不过 —— 而这个 bug 表现为「所有申领都被拒」，现场极难定位。
///
/// 所以这里固定一组金标准向量，桥接节点启动时必须先跑一遍：
/// 对不上就拒绝启动。把静默的签名失败变成一声响亮的启动失败。
pub fn golden_claim() -> WrapClaim {
    WrapClaim {
        peer_id: "12D3KooWTEST".into(),
        amount: 100,
        // 故意乱序：必须被排成 opA, opB
        op_ids: vec!["opB".into(), "opA".into()],
        to_address: "0x0000000000000000000000000000000000000001".into(),
        nonce: "n1".into(),
    }
}

pub const GOLDEN_PAYLOAD_HEX: &str = "616c632d777261702d76310a31323a313244334b6f6f57544553540a333a3130300a320a333a6f70410a333a6f70420a34323a3078303030303030303030303030303030303030303030303030303030303030303030303030303030310a323a6e31";
pub const GOLDEN_HASH: &str = "6b352389b4edab7654a01c444de192c0e5b11b6bf221079a424f9c6b653bceac";

/// 自检：返回不一致的原因列表，空 = 通过
pub fn check_golden_vector() -> Vec<String> {
    let mut errs = Vec::new();
    let hex: String = canonical_wrap_payload(&golden_claim())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    if hex != GOLDEN_PAYLOAD_HEX {
        errs.push(format!("载荷字节与金标准不一致\n  期望 {GOLDEN_PAYLOAD_HEX}\n  实际 {hex}"));
    }
    let hash = hash_wrap_payload(&golden_claim());
    if hash != GOLDEN_HASH {
        errs.push(format!("载荷哈希与金标准不一致\n  期望 {GOLDEN_HASH}\n  实际 {hash}"));
    }
    errs
}

/* ------------------------- 请求校验 ------------------------- */

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WrapRejectReason {
    Ok,
    Shape,
    BadAddress,
    Amount,
    AmountLimit,
    TooManyOps,
    OpNotOwned,
    InsufficientCoverage,
}

impl WrapRejectReason {
    pub fn as_str(&self) -> &'static str {
        match self {
            WrapRejectReason::Ok => "ok",
            WrapRejectReason::Shape => "shape",
            WrapRejectReason::BadAddress => "badAddress",
            WrapRejectReason::Amount => "amount",
            WrapRejectReason::AmountLimit => "amountLimit",
            WrapRejectReason::TooManyOps => "tooManyOps",
            WrapRejectReason::OpNotOwned => "opNotOwned",
            WrapRejectReason::InsufficientCoverage => "insufficientCoverage",
        }
    }
}

/// EVM 地址的最小校验。
///
/// 只检查形状（`0x` + 40 位十六进制），**不做 EIP-55 校验和验证** ——
/// 大小写混写的 checksum 地址无法只靠正则判断，而且链上不区分大小写，
/// 真正决定钱去哪的是前 20 字节。
pub fn is_evm_address(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len() != 42 {
        return false;
    }
    if &b[..2] != b"0x" && &b[..2] != b"0X" {
        return false;
    }
    b[2..].iter().all(|c| c.is_ascii_hexdigit())
}

/// 纯结构校验，不联网、不查账 —— 签名验证在桥接节点那侧
pub fn validate_wrap_request(claim: &WrapClaim) -> WrapRejectReason {
    if claim.peer_id.is_empty() || claim.nonce.is_empty() {
        return WrapRejectReason::Shape;
    }
    // 铸到非法地址 = 币永久销毁，且合约不会报错（ERC20 允许 burn to 0）
    if !is_evm_address(&claim.to_address) {
        return WrapRejectReason::BadAddress;
    }
    if claim.amount <= 0 {
        return WrapRejectReason::Amount;
    }
    if claim.amount > MAX_WRAP_PER_CLAIM {
        return WrapRejectReason::AmountLimit;
    }
    if claim.op_ids.is_empty() || claim.op_ids.len() > MAX_OP_IDS {
        return WrapRejectReason::TooManyOps;
    }
    WrapRejectReason::Ok
}

/* ------------------------- 覆盖率 ------------------------- */

/// 逐笔算出「还能上链多少」。
///
/// **逐笔算而不是拿总额减**：总额减法在 opIds 与记录对不齐时会静默出错，
/// 而这里是账 —— 账不能靠大概。
pub struct Coverage {
    /// 尚未上链的总量
    pub wrappable: i64,
    /// 已经被别的申领消费掉的量
    pub wrapped: i64,
    /// 还没花掉的 opId（按 HLC 从旧到新）
    pub available: Vec<String>,
}

pub fn coverage_of(ledger: &[(String, i64, String)], wrapped: &[String]) -> Coverage {
    let mut available = Vec::new();
    let mut wrappable = 0i64;
    let mut spent = 0i64;
    for (op_id, amount, at) in ledger {
        if wrapped.contains(op_id) {
            spent += *amount;
            continue;
        }
        available.push((op_id.clone(), *amount, at.clone()));
        wrappable += *amount;
    }
    // 先花老币：剩下的余额更新鲜，也更贴近「奖励是可追溯的流水」这个叙事
    available.sort_by(|a, b| a.2.cmp(&b.2).then(a.0.cmp(&b.0)));
    Coverage {
        wrappable,
        wrapped: spent,
        available: available.into_iter().map(|(id, _, _)| id).collect(),
    }
}

/// 从可上链记录里挑出「刚好凑够 amount」的 opId 集合。
/// 挑最旧的几笔；凑不够返回 None。
pub fn select_wrappable_ops(available: &[(String, i64)], amount: i64) -> Option<Vec<String>> {
    if amount <= 0 {
        return None;
    }
    let mut picked = Vec::new();
    let mut sum = 0i64;
    for (id, amt) in available {
        if sum >= amount {
            break;
        }
        picked.push(id.clone());
        sum += *amt;
    }
    if sum < amount {
        return None;
    }
    Some(picked)
}

/// 申领 id：同一批 op 的唯一标识，也是 `reward.wrap` 的幂等键
pub fn wrap_id_for(op_ids: &[String]) -> String {
    let mut ids = op_ids.to_vec();
    ids.sort();
    format!("wrap:{}", ids.join("+"))
}

/// ALC → 链上最小单位（18 位，与 ERC-20 惯例一致）。
/// 返回字符串：这个数会超过 64 位整数范围，Dart / JS 的 int 放不下 ——
/// 拿整数硬存它，等于给财务埋一颗雷。
pub fn alc_to_units(alc: i64) -> String {
    if alc <= 0 {
        return "0".into();
    }
    let units = format!("{alc}{}", "0".repeat(18));
    // 去掉可能的前导零（alc 为正数时不会有，但保持稳健）
    units.trim_start_matches('0').to_string()
}

/// 链上最小单位 → ALC（界面显示用，不用于结算）
pub fn units_to_alc(units: &str) -> i64 {
    if units.len() <= 18 {
        return 0;
    }
    units[..units.len() - 18].parse().unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn golden_vector_matches_the_web_implementation() {
        assert!(
            check_golden_vector().is_empty(),
            "{:?}",
            check_golden_vector()
        );
    }

    #[test]
    fn payload_is_independent_of_op_order() {
        let mut a = golden_claim();
        let mut b = golden_claim();
        b.op_ids = vec!["opA".into(), "opB".into()];
        a.op_ids = vec!["opB".into(), "opA".into()];
        assert_eq!(canonical_wrap_payload(&a), canonical_wrap_payload(&b));
    }

    #[test]
    fn address_is_lowercased_before_hashing() {
        let mut a = golden_claim();
        a.to_address = "0xAB00000000000000000000000000000000000001".into();
        let mut b = golden_claim();
        b.to_address = "0xab00000000000000000000000000000000000001".into();
        assert_eq!(hash_wrap_payload(&a), hash_wrap_payload(&b));
    }

    #[test]
    fn evm_address_shape_only() {
        assert!(is_evm_address("0x0000000000000000000000000000000000000001"));
        assert!(is_evm_address("0xAB00000000000000000000000000000000000001"));
        assert!(!is_evm_address("0x000"));
        assert!(!is_evm_address("0000000000000000000000000000000000000001"));
        assert!(!is_evm_address("0xzz00000000000000000000000000000000000001"));
    }

    #[test]
    fn coverage_spends_oldest_first_and_never_double_counts() {
        let ledger = vec![
            ("op1".to_string(), 10i64, "aaa".to_string()),
            ("op2".to_string(), 20i64, "aab".to_string()),
            ("op3".to_string(), 5i64, "aac".to_string()),
        ];
        let c = coverage_of(&ledger, &["op1".to_string()]);
        assert_eq!(c.wrappable, 25);
        assert_eq!(c.wrapped, 10);
        assert_eq!(c.available, vec!["op2", "op3"]);
    }

    #[test]
    fn cannot_select_more_than_available() {
        let avail = vec![("op1".to_string(), 10i64)];
        assert!(select_wrappable_ops(&avail, 11).is_none());
        assert_eq!(select_wrappable_ops(&avail, 10), Some(vec!["op1".to_string()]));
    }

    #[test]
    fn units_conversion_roundtrip() {
        assert_eq!(alc_to_units(1), "1000000000000000000");
        assert_eq!(units_to_alc(&alc_to_units(123)), 123);
        assert_eq!(alc_to_units(0), "0");
    }
}