//! 奖励币（Alighieri Coin）发行与分配规则
//! ---------------------------------------
//! 三条基本原则：
//!  1. **一切发放都必须来自可验证的行为**，而不是「时间到了自动到账」。
//!     时间只能决定上限，不能单独作为发钱依据。
//!  2. **按 peerId 去重**。同一个身份反复做同一件事，只算第一次。
//!  3. **算式公开可复算**。任何人拿同一批操作都能算出同一个总账，
//!     也就没人能偷偷改小数点。
//!
//! ⚠️ 诚实说明：这套规则**不能**真正防住有动机的攻击者。
//! 去中心化系统里没有权威可以判定「你是不是同一个人换了新身份」，
//! 所以理论上可以批量生成 peerId 刷币。这里的做法是提高成本、降低收益，
//! 而不是杜绝 —— 这是去中心化的固有限制，不是实现缺陷。

/// 币的符号代码
pub const COIN_SYMBOL: &str = "ALC";
/// 精度：整数币
pub const COIN_DECIMALS: u32 = 0;
pub const COIN_ICON: &str = "◈";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RewardAction {
    /// 首次认真读完一话
    ReadChapter,
    /// 首次读完一整部（至少 20 话）
    FinishNovel,
    /// 给作品点赞
    Like,
    /// 收藏作品
    Bookmark,
    /// 写下有效评价（≥20 字）
    Review,
    /// 投稿发布新作品
    Publish,
    /// 作品被他人首次收藏时的分成（作者侧）
    AuthorBookmarkShare,
}

impl RewardAction {
    pub fn as_str(&self) -> &'static str {
        match self {
            RewardAction::ReadChapter => "readChapter",
            RewardAction::FinishNovel => "finishNovel",
            RewardAction::Like => "like",
            RewardAction::Bookmark => "bookmark",
            RewardAction::Review => "review",
            RewardAction::Publish => "publish",
            RewardAction::AuthorBookmarkShare => "authorBookmarkShare",
        }
    }

    /// 各行为的基准单价（单位：币）
    pub fn rate(&self) -> i64 {
        match self {
            RewardAction::ReadChapter => 2,
            RewardAction::FinishNovel => 60,
            RewardAction::Like => 1,
            RewardAction::Bookmark => 3,
            RewardAction::Review => 8,
            RewardAction::Publish => 50,
            RewardAction::AuthorBookmarkShare => 20,
        }
    }

    /// 每日上限：防止单个身份靠堆量刷币
    pub fn daily_cap(&self) -> Option<i64> {
        match self {
            RewardAction::ReadChapter => Some(120),
            RewardAction::Like => Some(30),
            RewardAction::Review => Some(40),
            _ => None,
        }
    }

    /// 行为名对应的字典键 —— **只存键，不存文案**，五种语言各自取词
    pub fn label_key(&self) -> &'static str {
        match self {
            RewardAction::ReadChapter => "wallet.rules.read",
            RewardAction::FinishNovel => "wallet.rules.finishNovel",
            RewardAction::Like => "wallet.rules.like",
            RewardAction::Bookmark => "wallet.rules.bookmark",
            RewardAction::Review => "wallet.rules.review",
            RewardAction::Publish => "wallet.rules.post",
            RewardAction::AuthorBookmarkShare => "wallet.rules.share",
        }
    }
}

/// 作者收益公式：不是线性的，而是随累计被阅读量递减（幂律）。
///
/// ```text
/// reward = base × (uniqueViews ^ 0.5) / (1 + totalViews / 1000)
/// ```
///
/// - 平方根让头部作者仍有优势，但不至于赢家通吃；
/// - 分母让「被反复刷」的热门作品收益快速衰减，抑制标题党；
/// - 只依赖独立阅读数而非总点击，抑制刷量。
pub fn author_reward(unique_views: u64, total_views: u64, base: Option<i64>) -> i64 {
    let base = base.unwrap_or(RewardAction::AuthorBookmarkShare.rate());
    if unique_views == 0 {
        return 0;
    }
    let raw = base as f64 * (unique_views as f64).sqrt() / (1.0 + total_views as f64 / 1000.0);
    raw.floor() as i64
}

/// 读者「认真阅读」判定。
///
/// 基线取 500 字/分钟：网络小说的典型速读速度，3000 字的一话约 6 分钟读完。
/// 读得太快是误点，读得太慢是挂机，两头都拿不到币。
pub fn reading_reward(dwell_ms: u64, words: u64) -> i64 {
    // 低于 20 秒基本是误点
    if dwell_ms < 20_000 {
        return 0;
    }
    let expected_ms = (words as f64 / 500.0) * 60_000.0;
    let ratio = dwell_ms as f64 / expected_ms.max(1.0);
    if ratio < 0.4 {
        return 0; // 明显没读完
    }
    if ratio > 6.0 {
        return 0; // 挂机
    }
    let factor = if (0.9..=2.0).contains(&ratio) { 1.0 } else { 0.5 };
    (RewardAction::ReadChapter.rate() as f64 * factor).floor() as i64
}

/// 奖励发放的幂等键。
///
/// 所有节点的 op log 里，同一个 key 只会有一条生效记录。
///
/// 为什么可以放心用真实时钟：幂等键只在**写入方**那一侧生成一次，
/// 归约器读的是 `body.idempotencyKey`，不会重算，
/// 所以两个节点不会因为本地时钟不同而算出不同的键，收敛性不受影响。
///
/// 代价要说清楚：日上限按 UTC 日切分，对 UTC+8 的读者来说是本地 08:00 重置。
pub fn reward_key(actor: &str, action: RewardAction, target: &str, now_ms: u64) -> String {
    let bucket = match action {
        // 读 / 点赞这类行为按「天」分桶，保证每天每话只算一次
        RewardAction::ReadChapter | RewardAction::Like => (now_ms / 86_400_000).to_string(),
        _ => "once".to_string(),
    };
    format!("reward:{actor}:{}:{target}:{bucket}", action.as_str())
}

/// 今天已经发了多少（按 action 分桶的幂等键前缀匹配由调用方完成）
pub fn daily_total(records: &[(String, i64)], action: RewardAction, now_ms: u64) -> i64 {
    let bucket = (now_ms / 86_400_000).to_string();
    let marker = format!(":{}:", action.as_str());
    records
        .iter()
        .filter(|(k, _)| k.contains(&marker) && k.ends_with(&format!(":{bucket}")))
        .map(|(_, v)| *v)
        .sum()
}

/// 是否还在这个行为的今日上限内
pub fn within_daily_cap(action: RewardAction, already_today: i64, amount: i64) -> bool {
    match action.daily_cap() {
        None => true,
        Some(cap) => already_today + amount <= cap,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn too_fast_reading_earns_nothing() {
        assert_eq!(reading_reward(5_000, 3000), 0); // 不足 20 秒：误点
        assert_eq!(reading_reward(30_000, 3000), 0); // ratio = 0.083 < 0.4：明显没读完
    }

    #[test]
    fn idle_tab_earns_nothing() {
        // 3000 字读了两小时
        assert_eq!(reading_reward(7_200_000, 3000), 0);
    }

    #[test]
    fn normal_reading_earns_full() {
        // 3000 字，预期 360 秒；读 400 秒 -> ratio ≈ 1.11 -> 满额
        assert_eq!(reading_reward(400_000, 3000), 2);
    }

    #[test]
    fn author_reward_is_concave() {
        let a = author_reward(100, 100, None);
        let b = author_reward(400, 400, None);
        assert!(b > a);
        // 4 倍阅读量换不到 4 倍收益
        assert!(b < a * 4);
        assert_eq!(author_reward(0, 1000, None), 0);
    }

    #[test]
    fn idempotency_key_buckets_by_day() {
        let day0 = reward_key("peerA", RewardAction::ReadChapter, "n1:1", 86_400_000 - 1);
        let day1 = reward_key("peerA", RewardAction::ReadChapter, "n1:1", 86_400_000);
        assert_ne!(day0, day1);
        // 一次性行为永远同一个键
        assert_eq!(
            reward_key("peerA", RewardAction::Publish, "n1", 0),
            reward_key("peerA", RewardAction::Publish, "n1", 9_999_999_999)
        );
    }
}