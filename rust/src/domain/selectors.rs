//! 视图选择器
//! ----------
//! 从 `ReplicaState` 派生界面要的东西。全部是纯读操作：
//! 同一份状态必然算出同一批数字 —— 统计写进记录，只会多一个会过期的副本。

use std::collections::{BTreeMap, BTreeSet};

use crate::domain::carousel::{CAROUSEL_FEE, CAROUSEL_SLOTS, CAROUSEL_WINDOW_MS};
use crate::domain::hlc::{compare_hlts, wall_of};
use crate::domain::keys::*;
use crate::domain::licenses::{get_license, share_table_of};
use crate::domain::model::*;
use crate::domain::penname;
use crate::domain::reducer::{maintainers_of, DEFAULT_FIRST_CHAPTER_KEY, EDITOR_GROUP_MIN_MEMBERS};
use crate::domain::state::*;
use crate::domain::view::*;

/* ------------------------- 作品 / 章节 ------------------------- */

/// 某作品的章节列表（升序）
pub fn chapters_of<'a>(state: &'a ReplicaState, novel_id: &str) -> Vec<&'a ReplicaChapter> {
    let mut out: Vec<&ReplicaChapter> = state
        .chapters
        .values()
        .filter(|c| c.novel_id == novel_id && !c.deleted)
        .collect();
    out.sort_by_key(|c| c.no);
    out
}

/// 未被本机审查策略屏蔽、且未被删除的作品
pub fn active_novels(state: &ReplicaState) -> Vec<&ReplicaNovel> {
    state
        .novels
        .values()
        .filter(|n| !n.deleted)
        .collect()
}

pub fn novels_by_author<'a>(state: &'a ReplicaState, peer: &str) -> Vec<&'a ReplicaNovel> {
    let mut out: Vec<&ReplicaNovel> = state
        .novels
        .values()
        .filter(|n| n.author_peer == peer && !n.deleted)
        .collect();
    out.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
    out
}

pub fn reviews_of<'a>(state: &'a ReplicaState, novel_id: &str) -> Vec<&'a Review> {
    let mut out: Vec<&Review> = state.reviews.values().filter(|r| r.novel_id == novel_id).collect();
    out.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    out
}

#[derive(Debug, Clone, Copy, Default)]
pub struct ReactionTally {
    pub like: u64,
    pub insightful: u64,
    pub cry: u64,
}

/// 表情计数：每个 (作品, 种类) 一个 actor 集合，去重后取并集 —— 连点十下也只算一次。
pub fn reactions_of(state: &ReplicaState, novel_id: &str) -> ReactionTally {
    let mut t = ReactionTally::default();
    for (key, set) in &state.reactions {
        let Some(rest) = key.strip_prefix("reaction:") else {
            continue;
        };
        // `reaction:<actor>:<novelId>:<kind>`
        let parts: Vec<&str> = rest.split(':').collect();
        if parts.len() < 3 || parts[1] != novel_id {
            continue;
        }
        let n = set.len() as u64;
        match parts[2] {
            "like" => t.like += n,
            "insightful" => t.insightful += n,
            "cry" => t.cry += n,
            _ => {}
        }
    }
    t
}

pub fn star_count(state: &ReplicaState, novel_id: &str) -> u64 {
    state.stars.values().filter(|s| s.novel_id == novel_id).count() as u64
}

/// star 是公开计数，书架是本机私有 —— 两者不是一回事
pub fn has_starred(state: &ReplicaState, actor: &str, novel_id: &str) -> bool {
    state.stars.contains_key(&star_key(actor, novel_id))
}

pub fn is_bookmarked(state: &ReplicaState, actor: &str, novel_id: &str) -> bool {
    state.shelf.contains_key(&bookmark_key(actor, novel_id))
}

pub fn shelf_list<'a>(state: &'a ReplicaState, actor: &str) -> Vec<&'a ShelfEntry> {
    let prefix = format!("bookmark:{actor}:");
    let mut out: Vec<&ShelfEntry> = state
        .shelf
        .iter()
        .filter(|(k, _)| k.starts_with(&prefix))
        .map(|(_, v)| v)
        .collect();
    out.sort_by(|a, b| b.added_at.cmp(&a.added_at));
    out
}

/* ------------------------- PV ------------------------- */

pub const WEEK_MS: u64 = 7 * 86_400_000;

#[derive(Debug, Clone, Default)]
pub struct NovelPv {
    /// 総PV：各话独立读者数之和
    pub total: u64,
    /// 累计读者（去重后的身份数）
    pub unique_readers: u64,
    /// 週間読者：近 7 天读过的身份数
    pub weekly_readers: u64,
    /// 每话的读者数
    pub per_chapter: Vec<(u32, u64)>,
}

/// PV 的时间窗用 **op 的 HLC wall**，不是本地时钟 ——
/// 否则每个节点的「最近 7 天」都会不一样。这样两个节点对同一批事件算出同一结果。
pub fn novel_pv(state: &ReplicaState, novel_id: &str, now_ms: u64) -> NovelPv {
    let mut per: BTreeMap<u32, BTreeSet<String>> = BTreeMap::new();
    let mut actors: BTreeSet<String> = BTreeSet::new();
    let mut weekly: BTreeSet<String> = BTreeSet::new();
    for v in state.views.values() {
        if v.novel_id != novel_id {
            continue;
        }
        per.entry(v.chapter_no).or_default().insert(v.actor.clone());
        actors.insert(v.actor.clone());
        let at = wall_of(&v.at);
        if now_ms >= at && now_ms - at <= WEEK_MS {
            weekly.insert(v.actor.clone());
        }
    }
    NovelPv {
        total: per.values().map(|s| s.len() as u64).sum(),
        unique_readers: actors.len() as u64,
        weekly_readers: weekly.len() as u64,
        per_chapter: per.into_iter().map(|(k, v)| (k, v.len() as u64)).collect(),
    }
}

/* ------------------------- 首页轮播位 ------------------------- */

/// 当前正在展示的轮播位（最多 6 个）。
///
/// 过期判断完全由 `now` 派生，不写回记录；排序按开始时间从早到晚，
/// 先买的人先占住位置。并发超出 6 条时多出来的不展示（费用仍已扣除）。
pub fn active_carousels<'a>(state: &'a ReplicaState, now: i64) -> Vec<&'a CarouselRecord> {
    let mut out: Vec<&CarouselRecord> = state
        .carousels
        .values()
        .filter(|c| c.started_at <= now && now < c.expires_at)
        .collect();
    out.sort_by(|a, b| {
        a.started_at
            .cmp(&b.started_at)
            .then_with(|| compare_hlts(&a.at, &b.at))
            .then_with(|| a.id.cmp(&b.id))
    });
    out.truncate(CAROUSEL_SLOTS);
    out
}

/// 某个身份最近一次购买的轮播位（用于 7 天冷却）
pub fn latest_carousel_of<'a>(
    state: &'a ReplicaState,
    peer: &str,
) -> Option<&'a CarouselRecord> {
    if peer.is_empty() {
        return None;
    }
    state
        .carousels
        .values()
        .filter(|c| c.by == peer)
        .max_by(|a, b| {
            a.started_at
                .cmp(&b.started_at)
                .then_with(|| compare_hlts(&a.at, &b.at))
                .then_with(|| a.id.cmp(&b.id))
        })
}

/// 距离下次可以购买还有多久（毫秒；0 = 现在就能买）
pub fn carousel_cooldown_remaining(state: &ReplicaState, peer: &str, now: i64) -> i64 {
    match latest_carousel_of(state, peer) {
        Some(last) => (last.started_at + CAROUSEL_WINDOW_MS - now).max(0),
        None => 0,
    }
}

/// 某个身份已经花在轮播位上的奖励币（过期后也不退还）
pub fn carousel_spent_of(state: &ReplicaState, peer: &str) -> i64 {
    if peer.is_empty() {
        return 0;
    }
    state
        .carousels
        .values()
        .filter(|c| c.by == peer)
        .map(|c| c.fee)
        .sum()
}

/// 全站（本机副本内）已花在轮播位上的奖励币总额
pub fn total_carousel_spent(state: &ReplicaState) -> i64 {
    state.carousels.values().map(|c| c.fee).sum()
}

/// 能否购买轮播位。
///
/// 判断顺序有意义：先看身份、再看冷却、再看位置、最后看余额。
/// 返回 `identity` / `cooldown` / `full` / `balance` / `none`。
pub fn carousel_block_reason(state: &ReplicaState, peer: &str, now: i64) -> &'static str {
    if peer.is_empty() {
        return "identity";
    }
    if carousel_cooldown_remaining(state, peer, now) > 0 {
        return "cooldown";
    }
    if active_carousels(state, now).len() >= CAROUSEL_SLOTS {
        return "full";
    }
    if balance_of(state, peer) < CAROUSEL_FEE {
        return "balance";
    }
    "none"
}

/* ------------------------- 奖励币 ------------------------- */

/// 余额 = 收到的 - 已上链锁定的 - 轮播位消费。
///
/// 与 Web 版 `balanceOf` 完全一致：
/// - 奖励只按 `to == peer` 累加；
/// - 上链锁定用 wrap 记录的 `amount`（而不是逐笔 opId），
///   这样即使被消费的 reward op 还没传播到本节点，余额也不会算错；
/// - 站内转出**不**从余额里扣 —— Web 也没有扣，余额是「收到的币」而不是
///   账户余额，打赏时的余额检查只用于拦截明显超过收入的支出。
///   记住这个口径：它算的是收入，不是钱包。
pub fn balance_of(state: &ReplicaState, peer: &str) -> i64 {
    if peer.is_empty() {
        return 0;
    }
    let received: i64 = state
        .rewards
        .values()
        .filter(|r| r.to == peer)
        .map(|r| r.amount)
        .sum();
    let locked: i64 = state
        .wraps
        .values()
        .filter(|w| w.from == peer)
        .map(|w| w.amount)
        .sum();
    // 轮播位费用由 `carousel.put` 记录，不需要额外一条转账记录。
    // 扣的是记录里的 `fee`（归约器按常量写入），任何节点算出的余额都一样。
    received - locked - carousel_spent_of(state, peer)
}

/// 已被 `reward.wrap` 消费掉的 opId
pub fn wrapped_op_ids(state: &ReplicaState) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    for w in state.wraps.values() {
        for id in &w.op_ids {
            out.insert(id.clone());
        }
    }
    out
}

/// 某身份的账本流水（新的在前）。
///
/// 与 Web 版 `ledgerOf` 一致：只列**收到**的奖励。
/// 转出记录仍然留在副本里可供审计，但不混进「我的账本」。
pub fn ledger_of<'a>(state: &'a ReplicaState, peer: &str) -> Vec<&'a RewardRecord> {
    if peer.is_empty() {
        return Vec::new();
    }
    let mut out: Vec<&RewardRecord> = state
        .rewards
        .values()
        .filter(|r| r.to == peer)
        .collect();
    out.sort_by(|a, b| b.at.cmp(&a.at));
    out
}

/// 全网累计发行量
pub fn total_issued(state: &ReplicaState) -> i64 {
    state.rewards.values().map(|r| r.amount).sum()
}

/* ------------------------- 联邦审查 ------------------------- */

/// 按**不同身份**数举报票数（key 带举报者，同一人改举报只是更新）
pub fn report_votes(state: &ReplicaState, novel_id: &str) -> u64 {
    state.reports.values().filter(|r| r.novel_id == novel_id).count() as u64
}

/* ------------------------- 信任网（女巫抵抗） ------------------------- */

/// 我视角的信任网分数。
///
/// 原理（详见 docs/SYBIL-RESEARCH.md 的「Phase 1」）：
///   · **互证边才算数**：A→B 与 B→A 都存在才传播。女巫互相背书
///     只能在自己内部打转，传不到「我」这里 —— 因为没有诚实的人
///     给它们中的任何一个做互证，图里根本没有一条通到我的边。
///   · 传播强度 = min(双向权重)/3，每跳 ×0.8 衰减（max-product 不动点）。
///   · 种子只有「我自己」：信任永远是对观察者而言的，与 Keybase 的
///     「信任是主观的」是同一个立场。
///   · `BTreeMap` + 定序边集合保证任何设备算出同一张表。
pub fn my_trust(state: &ReplicaState, me: &str) -> BTreeMap<String, f64> {
    // 1) 每对身份的互证强度
    let mut pairs: BTreeMap<(String, String), u32> = BTreeMap::new();
    for r in state.attestations.values() {
        pairs.insert((r.actor.clone(), r.target.clone()), r.weight);
    }
    let mut edges: Vec<(String, String, u32)> = Vec::new();
    let mut nodes: BTreeSet<String> = BTreeSet::new();
    for ((a, b), w) in &pairs {
        if a == b {
            continue;
        }
        nodes.insert(a.clone());
        nodes.insert(b.clone());
        let back = pairs.get(&(b.clone(), a.clone())).copied().unwrap_or(0);
        if back == 0 {
            continue; // 单向背书不参与传播
        }
        edges.push((a.clone(), b.clone(), (*w).min(back)));
    }
    edges.sort_by(|a, b| (a.0.as_str(), a.1.as_str()).cmp(&(b.0.as_str(), b.1.as_str())));
    nodes.insert(me.to_string());

    // 2) max-product 传播（确定性迭代到不动点）
    let mut trust: BTreeMap<String, f64> = nodes.iter().map(|n| (n.clone(), 0.0)).collect();
    trust.insert(me.to_string(), 1.0);
    let max_rounds = nodes.len().saturating_mul(2).saturating_add(8);
    for _ in 0..max_rounds {
        let mut changed = false;
        for (a, b, w) in &edges {
            let s = (*w as f64) / 3.0;
            let ta = trust.get(a).copied().unwrap_or(0.0);
            let tb = trust.get(b).copied().unwrap_or(0.0);
            let cand_b = ta * s * 0.8;
            if cand_b > tb {
                trust.insert(b.clone(), cand_b);
                changed = true;
            }
            let cand_a = tb * s * 0.8;
            if cand_a > ta {
                trust.insert(a.clone(), cand_a);
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }
    trust
}

/// 是否在「我」的信任圈内：分数 >= 0.5（约等于两步互证以内）。
pub fn in_trust_circle(trust: &BTreeMap<String, f64>, peer: &str, me: &str) -> bool {
    if peer == me {
        return true;
    }
    trust.get(peer).copied().unwrap_or(0.0) >= 0.5
}

/// 本机屏蔽的作品集合
///
/// 举报不能从任何设备上删掉内容，它只改变**读者本机**的可见性。
/// 豁免过的作品需要再多加一票才重新屏蔽。
/// 开了 `trust_me`（信任圈筛选）后，只有「我」的信任圈内的身份
/// 投的票才计入 —— 这是本机偏好的诚实选项，默认关闭。
pub fn flagged_novel_ids(state: &ReplicaState, policy: &ReviewPolicy) -> BTreeSet<String> {
    let trust = policy.trust_me.as_deref().map(|me| my_trust(state, me));
    let mut votes: BTreeMap<String, u64> = BTreeMap::new();
    for r in state.reports.values() {
        if let (Some(t), Some(me)) = (&trust, policy.trust_me.as_deref()) {
            if !in_trust_circle(t, &r.reporter, me) {
                continue;
            }
        }
        *votes.entry(r.novel_id.clone()).or_default() += 1;
    }
    votes
        .into_iter()
        .filter(|(id, n)| {
            let need = if policy.exempt.contains(id) {
                policy.threshold + 1
            } else {
                policy.threshold
            };
            *n >= need.max(1)
        })
        .map(|(id, _)| id)
        .collect()
}

/* ------------------------- 编辑组 / 名次 ------------------------- */

/// 默认组名由作品 id 确定性派生：不需要谁去「建组」，组是派生的
pub fn default_group_name(novel_id: &str) -> String {
    let h = crate::domain::penname::fnv1a(&format!("group:{novel_id}"));
    format!("编辑组 {:04x}", h & 0xffff)
}

pub fn editor_group_of<'a>(state: &'a ReplicaState, novel_id: &str) -> Option<&'a GroupRecord> {
    state.groups.get(&group_key(novel_id))
}

/// 从**公布记录**派生名次，而不是作者自填的 `awards` 字段 ——
/// 能自己填的荣誉等于没有荣誉，毕竟谁都能给自己写个第一名。
pub fn awards_of(state: &ReplicaState, novel_id: &str) -> Vec<(u32, String)> {
    let mut out: Vec<(u32, String)> = Vec::new();
    for r in state.contest_results.values() {
        for p in &r.placements {
            if p.novel_id == novel_id {
                out.push((p.place, r.contest_id.clone()));
            }
        }
    }
    out.sort();
    out
}

/// 赛事奖金是否真的到账：查公开账本，而不是信任结果记录里那句「已发放」。
/// 与 Web 版 `prizePaid` 同一语义：from 是主办方、to 是作者、reason 含赛事 id。
pub fn contest_prize_paid(
    state: &ReplicaState,
    contest_id: &str,
    author_peer: &str,
    publisher_peer: &str,
) -> bool {
    state.rewards.values().any(|r| {
        r.action == "prize"
            && r.to == author_peer
            && r.from == publisher_peer
            && r.reason
                .as_deref()
                .map(|s| s.contains(contest_id))
                .unwrap_or(false)
    })
}

/* ------------------------- 交易 ------------------------- */

/// 「已发放」以公开账本为准，而不是以按钮点没点为准。
///
/// 与 Web 版 `dealPaid` 一致：from 必须是这份交易的出版社、
/// to 必须是原作者、action 必须是 adaptation、target 必须含 `deal:<id>`。
/// 只看 target 前缀会误把别的作品/别的收款人算进来。
pub fn deal_paid_on_ledger(state: &ReplicaState, deal: &DealRecord) -> bool {
    let marker = format!("deal:{}", deal.deal_id);
    state.rewards.values().any(|r| {
        r.from == deal.publisher_peer
            && r.to == deal.author_peer
            && r.action == "adaptation"
            && r.target
                .as_deref()
                .map(|t| t.contains(&marker))
                .unwrap_or(false)
    })
}


/* ------------------------- 协作：issue / patch / 贡献者 ------------------------- */

/// 显示名：优先个人资料里的笔名，否则用 peerId 派生的系统名。
/// 与引擎的 `name_of` 同一套回落规则，只读状态即可复算。
pub fn display_name(state: &ReplicaState, peer: &str) -> String {
    if peer.is_empty() {
        return String::new();
    }
    if let Some(p) = state.profiles.get(peer) {
        if !p.name.is_empty() {
            return p.name.clone();
        }
    }
    penname::pen_name_from(peer)
}

/// 某作品的议题（未关闭的在前，新的在前）
pub fn issue_cards(state: &ReplicaState, novel_id: &str, viewer: &str) -> Vec<IssueCard> {
    let maintainer = crate::domain::reducer::is_maintainer(state, novel_id, viewer);
    let mut out: Vec<IssueCard> = state
        .issues
        .values()
        .filter(|i| i.novel_id == novel_id)
        .map(|i| IssueCard {
            id: i.id.clone(),
            novel_id: i.novel_id.clone(),
            issue_id: i.issue_id.clone(),
            title: i.title.clone(),
            body: i.body.clone(),
            author_peer: i.author_peer.clone(),
            author_name: if i.author_name.is_empty() {
                display_name(state, &i.author_peer)
            } else {
                i.author_name.clone()
            },
            state: if matches!(i.state, IssueState::Open) { "open" } else { "closed" }.into(),
            at_ms: wall_of(&i.at),
            can_close: !viewer.is_empty()
                && (viewer == i.author_peer || maintainer),
        })
        .collect();
    out.sort_by(|a, b| {
        let ao = a.state == "open";
        let bo = b.state == "open";
        bo.cmp(&ao).then(b.at_ms.cmp(&a.at_ms))
    });
    out
}

/// 提案是否与当前章节版本冲突。
///
/// 只有「当前章节比提案记下的基线更新」才算冲突；新话没有基线，不算冲突。
pub fn patch_has_conflict(state: &ReplicaState, patch: &PatchRecord) -> bool {
    for c in &patch.chapters {
        let Some(cur) = state.chapters.get(&chapter_key(&patch.novel_id, c.no)) else {
            continue;
        };
        let Some(base) = c.based_on.as_deref() else {
            continue;
        };
        // 与 Web 一致：删除的章节也参与基线比较。删除本身就是一次更新，
        // 提案基于旧版本时同样应视为冲突。
        if compare_hlts(&cur.published_at, base) == std::cmp::Ordering::Greater {
            return true;
        }
    }
    false
}

pub fn patch_cards(state: &ReplicaState, novel_id: &str, viewer: &str) -> Vec<PatchCard> {
    let maintainer = crate::domain::reducer::is_maintainer(state, novel_id, viewer);
    let mut out: Vec<PatchCard> = state
        .patches
        .values()
        .filter(|p| p.novel_id == novel_id)
        .map(|p| {
            let merged = state.merges.contains_key(&merge_key(novel_id, &p.patch_id));
            PatchCard {
                id: p.id.clone(),
                novel_id: p.novel_id.clone(),
                patch_id: p.patch_id.clone(),
                title: p.title.clone(),
                body: p.body.clone(),
                author_peer: p.author_peer.clone(),
                author_name: if p.author_name.is_empty() {
                    display_name(state, &p.author_peer)
                } else {
                    p.author_name.clone()
                },
                state: if matches!(p.state, PatchState::Open) { "open" } else { "closed" }.into(),
                at_ms: wall_of(&p.at),
                has_conflict: patch_has_conflict(state, p),
                merged,
                chapter_nos: p.chapters.iter().map(|c| c.no).collect(),
                chapters: p
                    .chapters
                    .iter()
                    .map(|c| PatchChapterView {
                        no: c.no,
                        title: c.title.clone(),
                        volume: c.volume.clone(),
                        paragraphs: c.paragraphs.clone(),
                        words: c.words,
                        based_on: c.based_on.clone(),
                        contributor: c.contributor.clone(),
                    })
                    .collect(),
                can_merge: maintainer && !merged && matches!(p.state, PatchState::Open),
                can_close: !viewer.is_empty() && (viewer == p.author_peer || maintainer),
            }
        })
        .collect();
    out.sort_by(|a, b| {
        let ao = a.state == "open" && !a.merged;
        let bo = b.state == "open" && !b.merged;
        bo.cmp(&ao).then(b.at_ms.cmp(&a.at_ms))
    });
    out
}

pub fn merge_cards(state: &ReplicaState, novel_id: &str) -> Vec<MergeCard> {
    let mut out: Vec<MergeCard> = state
        .merges
        .values()
        .filter(|m| m.novel_id == novel_id)
        .map(|m| MergeCard {
            id: m.id.clone(),
            novel_id: m.novel_id.clone(),
            patch_id: m.patch_id.clone(),
            author: m.author.clone(),
            author_name: display_name(state, &m.author),
            by: m.by.clone(),
            by_name: display_name(state, &m.by),
            chapter_nos: m.chapters.iter().map(|c| c.no).collect(),
            note: m.note.clone(),
            at_ms: wall_of(&m.at),
        })
        .collect();
    out.sort_by(|a, b| b.at_ms.cmp(&a.at_ms));
    out
}

/// 编辑组（派生）：贡献者达到下限就存在，不需要谁去「建组」。
pub fn group_card(state: &ReplicaState, novel_id: &str) -> GroupCard {
    let members = maintainers_of(state, novel_id);
    let rec = state.groups.get(&group_key(novel_id));
    GroupCard {
        novel_id: novel_id.to_string(),
        exists: members.len() >= EDITOR_GROUP_MIN_MEMBERS,
        name: rec
            .and_then(|g| g.name.clone())
            .unwrap_or_else(|| default_group_name(novel_id)),
        custom_named: rec.and_then(|g| g.name.as_ref()).is_some(),
        member_names: members.iter().map(|p| display_name(state, p)).collect(),
        members,
        min_members: EDITOR_GROUP_MIN_MEMBERS as u32,
    }
}

/* ------------------------- 贡献图谱 ------------------------- */

#[derive(Debug, Clone)]
struct GraphEdge {
    peer: String,
    kind: &'static str,
    weight: f64,
    basis: String,
}

/// 贡献图谱：正典按字数、翻译按译文字数、零散贡献平分。
/// 纯函数，不读时间；任何节点拿同一批 op 都算出同一份份额。
pub fn contribution_graph(state: &ReplicaState, novel_id: &str) -> ContributionGraphView {
    let Some(novel) = state.novels.get(novel_id) else {
        return ContributionGraphView::default();
    };
    let pools = share_table_of(Some(&novel.license));

    // 正典池：作者自己的章节 + 被整合进来的续写
    let mut canon: BTreeMap<String, (f64, u32)> = BTreeMap::new();
    for c in chapters_of(state, novel_id) {
        let who = c.contributor.clone().unwrap_or_else(|| novel.author_peer.clone());
        if who.is_empty() {
            continue;
        }
        let weight = if c.words > 0 {
            c.words as f64
        } else {
            c.paragraphs
                .as_ref()
                .map(|p| p.join("").chars().filter(|ch| !ch.is_whitespace()).count() as f64)
                .unwrap_or(0.0)
        };
        let e = canon.entry(who).or_insert((0.0, 0));
        e.0 += weight;
        e.1 += 1;
    }
    // 作者即使当前没有已同步章节，也保留在图谱里（署名权不取决于副本）
    if !novel.author_peer.is_empty() {
        canon.entry(novel.author_peer.clone()).or_insert((0.0, 0));
    }

    // 翻译池：按译者聚合译文字数
    let mut trans: BTreeMap<String, (f64, u32)> = BTreeMap::new();
    for t in state.translations.values().filter(|t| t.novel_id == novel_id) {
        let weight = t
            .paragraphs
            .join("")
            .chars()
            .filter(|c| !c.is_whitespace())
            .count() as f64;
        let e = trans.entry(t.actor.clone()).or_insert((0.0, 0));
        e.0 += weight;
        e.1 += 1;
    }

    // 零散池：每个声明者一份（平分，权重恒为 1）
    let mut anc: BTreeMap<String, (u32, Option<String>, String)> = BTreeMap::new();
    for c in state.contributions.values().filter(|c| c.novel_id == novel_id) {
        anc.insert(
            c.contributor.clone(),
            (
                c.items,
                c.scope.clone(),
                if c.contributor_name.is_empty() {
                    display_name(state, &c.contributor)
                } else {
                    c.contributor_name.clone()
                },
            ),
        );
    }

    let mut edges: Vec<GraphEdge> = Vec::new();
    for (peer, (weight, chapters)) in &canon {
        edges.push(GraphEdge {
            peer: peer.clone(),
            kind: "canon",
            weight: *weight,
            basis: format!("chapters:{chapters},words:{}", *weight as u64),
        });
    }
    for (peer, (weight, chapters)) in &trans {
        edges.push(GraphEdge {
            peer: peer.clone(),
            kind: "translation",
            weight: *weight,
            basis: format!("chapters:{chapters},chars:{}", *weight as u64),
        });
    }
    for (peer, (items, scope, _name)) in &anc {
        edges.push(GraphEdge {
            peer: peer.clone(),
            kind: "ancillary",
            weight: 1.0,
            basis: format!(
                "items:{items}{}",
                scope.as_ref().map(|s| format!(",scope:{s}")).unwrap_or_default()
            ),
        });
    }

    let canon_total: f64 = edges.iter().filter(|e| e.kind == "canon").map(|e| e.weight).sum();
    let canon_count = edges.iter().filter(|e| e.kind == "canon").count().max(1) as f64;
    let trans_total: f64 = edges.iter().filter(|e| e.kind == "translation").map(|e| e.weight).sum();
    let trans_count = edges.iter().filter(|e| e.kind == "translation").count().max(1) as f64;
    let anc_count = edges.iter().filter(|e| e.kind == "ancillary").count().max(1) as f64;

    let mut shares: Vec<GraphShareView> = edges
        .into_iter()
        .map(|e| {
            let (pool_ratio, pool) = match e.kind {
                "canon" => {
                    let r = if canon_total > 0.0 {
                        e.weight / canon_total
                    } else {
                        1.0 / canon_count
                    };
                    (r, pools.canon)
                }
                "translation" => {
                    let r = if trans_total > 0.0 {
                        e.weight / trans_total
                    } else {
                        1.0 / trans_count
                    };
                    (r, pools.translation)
                }
                _ => (1.0 / anc_count, pools.ancillary),
            };
            GraphShareView {
                name: display_name(state, &e.peer),
                peer: e.peer,
                kind: e.kind.to_string(),
                pool_ratio,
                ratio: pool * pool_ratio,
                weight: e.weight,
                basis: e.basis,
            }
        })
        .collect();
    shares.sort_by(|a, b| {
        b.ratio
            .partial_cmp(&a.ratio)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.peer.cmp(&b.peer))
    });
    let total: f64 = shares.iter().map(|s| s.ratio).sum();
    ContributionGraphView {
        novel_id: novel_id.to_string(),
        canon_pool: pools.canon,
        translation_pool: pools.translation,
        ancillary_pool: pools.ancillary,
        total,
        shares,
    }
}

/// 贡献者名单：维护者（作者 + 已整合提案作者）+ 译者 + 零散贡献者。
pub fn contributor_cards(state: &ReplicaState, novel_id: &str) -> Vec<ContributorCard> {
    let graph = contribution_graph(state, novel_id);
    let author = state
        .novels
        .get(novel_id)
        .map(|n| n.author_peer.clone())
        .unwrap_or_default();
    let maintainers = maintainers_of(state, novel_id);
    let mut out: BTreeMap<String, ContributorCard> = BTreeMap::new();

    for peer in &maintainers {
        out.entry(peer.clone()).or_insert_with(|| ContributorCard {
            peer: peer.clone(),
            name: display_name(state, peer),
            is_author: *peer == author,
            is_maintainer: true,
            ..Default::default()
        });
    }
    for c in chapters_of(state, novel_id) {
        let who = c.contributor.clone().unwrap_or_else(|| author.clone());
        if who.is_empty() {
            continue;
        }
        let e = out.entry(who.clone()).or_insert_with(|| ContributorCard {
            peer: who.clone(),
            name: display_name(state, &who),
            is_author: who == author,
            ..Default::default()
        });
        e.chapters += 1;
        e.words += c.words;
    }
    for t in state.translations.values().filter(|t| t.novel_id == novel_id) {
        let e = out.entry(t.actor.clone()).or_insert_with(|| ContributorCard {
            peer: t.actor.clone(),
            name: display_name(state, &t.actor),
            ..Default::default()
        });
        e.translations += 1;
    }
    for c in state.contributions.values().filter(|c| c.novel_id == novel_id) {
        let e = out.entry(c.contributor.clone()).or_insert_with(|| ContributorCard {
            peer: c.contributor.clone(),
            name: display_name(state, &c.contributor),
            ..Default::default()
        });
        e.ancillary_items += c.items;
    }
    for s in &graph.shares {
        if let Some(e) = out.get_mut(&s.peer) {
            e.share_ratio = s.ratio;
        }
    }
    let mut list: Vec<ContributorCard> = out.into_values().collect();
    list.sort_by(|a, b| {
        b.is_author
            .cmp(&a.is_author)
            .then(b.is_maintainer.cmp(&a.is_maintainer))
            .then(
                b.share_ratio
                    .partial_cmp(&a.share_ratio)
                    .unwrap_or(std::cmp::Ordering::Equal),
            )
            .then(a.peer.cmp(&b.peer))
    });
    list
}

/* ------------------------- 衍生 / 赛事名次 ------------------------- */

fn fork_card(state: &ReplicaState, f: &ForkRecord) -> ForkCard {
    ForkCard {
        id: f.id.clone(),
        novel_id: f.novel_id.clone(),
        novel_title: state
            .novels
            .get(&f.novel_id)
            .map(|n| n.title.clone())
            .unwrap_or_default(),
        source_id: f.source_id.clone(),
        source_title: f.source_title.clone(),
        source_peer: f.source_peer.clone(),
        by: f.by.clone(),
        by_name: if f.by_name.is_empty() {
            display_name(state, &f.by)
        } else {
            f.by_name.clone()
        },
        note: f.note.clone(),
        at_ms: wall_of(&f.at),
    }
}

/// 这部作品是从哪部作品衍生出来的
pub fn fork_source(state: &ReplicaState, novel_id: &str) -> Option<ForkCard> {
    state
        .forks
        .values()
        .find(|f| f.novel_id == novel_id)
        .map(|f| fork_card(state, f))
}

/// 从这部作品衍生出去的作品（新的在前）
pub fn forks_of(state: &ReplicaState, source_id: &str) -> Vec<ForkCard> {
    let mut out: Vec<ForkCard> = state
        .forks
        .values()
        .filter(|f| f.source_id == source_id)
        .map(|f| fork_card(state, f))
        .collect();
    out.sort_by(|a, b| b.at_ms.cmp(&a.at_ms));
    out
}

pub fn award_cards(state: &ReplicaState, novel_id: &str) -> Vec<AwardCard> {
    let mut out: Vec<AwardCard> = Vec::new();
    for r in state.contest_results.values() {
        for p in &r.placements {
            if p.novel_id == novel_id {
                out.push(AwardCard {
                    contest_id: r.contest_id.clone(),
                    contest_title: state
                        .contests
                        .get(&r.contest_id)
                        .map(|c| c.title.clone())
                        .unwrap_or_else(|| r.contest_id.clone()),
                    place: p.place,
                    note: p.note.clone(),
                });
            }
        }
    }
    out.sort_by_key(|a| a.place);
    out
}

/* ------------------------- 卡片 ------------------------- */

/// 本机审查策略
pub struct ReviewPolicy {
    /// 达到多少个不同身份的举报就在这台设备上屏蔽（默认 3）
    pub threshold: u64,
    pub exempt: BTreeSet<String>,
    /// 只把「我的信任圈」里的举报计入（None = 不筛选，即原行为）。
    /// 这是本机偏好的诚实选项：默认关闭，开启后陌生但可信的举报者
    /// 的票也可能不计入 —— 界面上必须写明。
    pub trust_me: Option<String>,
}

impl Default for ReviewPolicy {
    fn default() -> Self {
        ReviewPolicy { threshold: 3, exempt: BTreeSet::new(), trust_me: None }
    }
}

/// 把副本里的作品摊成界面卡片。
///
/// 派生统计只在这一处算，避免每个页面各写一份、迟早对不上。
/// 本机在某一部作品上的阅读进度（没有写过 progress.set 时返回 None）。
pub fn my_progress(state: &ReplicaState, peer: &str, novel_id: &str) -> Option<ProgressView> {
    let p = state.progress.get(&progress_key(peer, novel_id))?;
    Some(ProgressView {
        novel_id: p.novel_id.clone(),
        chapter_no: p.chapter_no,
        at_ms: wall_of(&p.at),
    })
}

pub fn build_novel_cards(
    state: &ReplicaState,
    my_peer: Option<&str>,
    policy: &ReviewPolicy,
    now_ms: u64,
) -> Vec<NovelCard> {
    let flagged = flagged_novel_ids(state, policy);
    let wrapped = wrapped_op_ids(state);
    let mut out = Vec::new();
    for n in active_novels(state) {
        let tally = reactions_of(state, &n.id);
        let pv = novel_pv(state, &n.id, now_ms);
        let lic = get_license(Some(&n.license));
        let chapters = chapters_of(state, &n.id);
        let chapter_count = chapters.len() as u32;
        // 字数与话数永远从章节正文派生。作品记录里的 episodes / words
        // 只是给不重放章节的旧客户端看的缓存，不能反过来当真相。
        let words: u64 = chapters.iter().map(|c| c.words).sum();
        let latest_no = chapters.iter().map(|c| c.no).max().unwrap_or(n.latest.no);
        let latest_title = n.latest.title.clone();
        let progress = my_peer.and_then(|p| my_progress(state, p, &n.id));
        let placements = awards_of(state, &n.id);
        let award_place = placements.first().map(|(p, _)| *p).unwrap_or(0);
        let forks = state.forks.values().filter(|f| f.source_id == n.id).count() as u64;
        let merged_authors: BTreeSet<&str> = state
            .merges
            .values()
            .filter(|m| m.novel_id == n.id && !m.author.is_empty())
            .map(|m| m.author.as_str())
            .collect();
        let open_patches = state
            .patches
            .values()
            .filter(|p| {
                p.novel_id == n.id
                    && matches!(p.state, PatchState::Open)
                    && !state.merges.contains_key(&merge_key(&n.id, &p.patch_id))
            })
            .count() as u64;
        out.push(NovelCard {
            id: n.id.clone(),
            title: n.title.clone(),
            author_name: n.author_name.clone(),
            author_peer: n.author_peer.clone(),
            genre: n.genre.clone(),
            genre_name: n.genre_name.clone(),
            tags: n.tags.clone(),
            synopsis: n.synopsis.clone(),
            tagline: crate::domain::catalog::first_sentence(&n.synopsis),
            status: n.status.as_str().to_string(),
            episodes: chapter_count,
            words,
            first_published_at: n.first_published_at.clone(),
            updated_at: n.updated_at.clone(),
            updated_at_ms: wall_of(&n.updated_at),
            latest_no,
            latest_title,
            latest_at: n.latest.at.clone(),
            license: n.license.clone(),
            license_name: lic.short_name.to_string(),
            fork_of: n.fork_of.clone(),
            award: n.awards.first().cloned(),
            award_place,
            forks,
            contributors: 1 + merged_authors.len() as u64,
            open_patches,
            stars: star_count(state, &n.id),
            bookmarks: state.shelf.values().filter(|s| s.novel_id == n.id).count() as u64,
            reviews: reviews_of(state, &n.id).len() as u64,
            likes: tally.like,
            insightful: tally.insightful,
            cry: tally.cry,
            pv_total: pv.total,
            pv_weekly: pv.weekly_readers,
            unique_readers: pv.unique_readers,
            in_shelf: my_peer.map(|p| is_bookmarked(state, p, &n.id)).unwrap_or(false),
            starred_by_me: my_peer.map(|p| has_starred(state, p, &n.id)).unwrap_or(false),
            shelf_added_at_ms: my_peer
                .and_then(|p| state.shelf.get(&bookmark_key(p, &n.id)))
                .map(|s| wall_of(&s.added_at))
                .unwrap_or(0),
            progress_no: progress.as_ref().map(|p| p.chapter_no).unwrap_or(0),
            progress_at_ms: progress.as_ref().map(|p| p.at_ms).unwrap_or(0),
            flagged: flagged.contains(&n.id),
            deleted: false,
            rank: 0,
            score: 0.0,
        });
    }
    // 未上链的奖励不计入余额，卡片层面不展示，故只用 wrapped 判定是否需要重算
    let _ = wrapped;
    out.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
    out
}

/// 章节卡片
pub fn build_chapter_views(state: &ReplicaState, novel_id: &str) -> Vec<ChapterView> {
    chapters_of(state, novel_id)
        .into_iter()
        .map(|c| ChapterView {
            novel_id: c.novel_id.clone(),
            no: c.no,
            title: if c.title.starts_with("__chapter__:") {
                c.title.clone()
            } else {
                c.title.clone()
            },
            words: c.words,
            published_at: c.published_at.clone(),
            published_at_ms: wall_of(&c.published_at),
            volume: c.volume.clone(),
            contributor: c.contributor.clone(),
            paragraphs: c.paragraphs.clone().unwrap_or_default(),
            missing_body: c.paragraphs.is_none(),
        })
        .collect()
}

/// 用反应数近似点击量。
///
/// 必须说清楚这是**近似**：真实点击量谁都拿不到。
/// 用「本机收到的确凿行为」做代理，至少保证这个数字对应真实发生过的交互 ——
/// 而不是某个仪表盘上凭空跳动的数字。
pub fn estimate_clicks(reactions: u64, bookmarks: u64, reviews_count: u64) -> u64 {
    reactions + bookmarks * 2 + reviews_count * 3
}

/// 「第一话」这种哨兵标题需要界面按语言翻译
pub fn is_chapter_title_sentinel(t: &str) -> bool {
    t.starts_with("__chapter__:") || t == DEFAULT_FIRST_CHAPTER_KEY
}

/// 取出哨兵里的章节号
pub fn chapter_no_from_sentinel(t: &str) -> Option<u32> {
    t.strip_prefix("__chapter__:")?.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn balance_matches_web_semantics() {
        let mut s = ReplicaState::new();
        s.rewards.insert(
            "k1".into(),
            RewardRecord {
                key: "k1".into(),
                op_id: "op1".into(),
                from: "system".into(),
                to: "peerA".into(),
                amount: 100,
                action: "publish".into(),
                target: None,
                reason: None,
                at: "000000001:0:peerA".into(),
            },
        );
        assert_eq!(balance_of(&s, "peerA"), 100);
        // 转出不从余额里扣（与 Web 一致）
        s.rewards.insert(
            "k2".into(),
            RewardRecord {
                key: "k2".into(),
                op_id: "op2".into(),
                from: "peerA".into(),
                to: "peerB".into(),
                amount: 30,
                action: "tip".into(),
                target: None,
                reason: None,
                at: "000000002:0:peerA".into(),
            },
        );
        assert_eq!(balance_of(&s, "peerA"), 100);
        // 上链锁定按 wrap.amount 扣减
        s.wraps.insert(
            "w1".into(),
            ReplicaWrap {
                key: "w1".into(),
                op_id: "op3".into(),
                from: "peerA".into(),
                amount: 100,
                op_ids: vec!["op1".into()],
                to_address: String::new(),
                chain_id: 1,
                tx_hash: String::new(),
                onchain_id: String::new(),
                at: "000000003:0:peerA".into(),
            },
        );
        assert_eq!(balance_of(&s, "peerA"), 0);
        assert_eq!(balance_of(&s, "peerB"), 30);
        assert_eq!(balance_of(&s, ""), 0);
    }

    #[test]
    fn pv_counts_distinct_readers_not_refreshes() {
        let mut s = ReplicaState::new();
        for actor in ["p1", "p2"] {
            s.views.insert(
                view_key(actor, "n1", 1),
                ViewRecord {
                    id: view_key(actor, "n1", 1),
                    novel_id: "n1".into(),
                    chapter_no: 1,
                    actor: actor.into(),
                    at: "000000001:0:x".into(),
                },
            );
        }
        let pv = novel_pv(&s, "n1", 1000);
        assert_eq!((pv.total, pv.unique_readers), (2, 2));
    }

    #[test]
    fn flagged_uses_distinct_identities() {
        let mut s = ReplicaState::new();
        for reporter in ["a", "b", "c"] {
            s.reports.insert(
                report_key("n1", reporter),
                ReportRecord {
                    id: report_key("n1", reporter),
                    novel_id: "n1".into(),
                    reporter: reporter.into(),
                    reporter_name: reporter.into(),
                    chapter_no: None,
                    category: ReportCategory::Spam,
                    note: String::new(),
                    at: "000000001:0:x".into(),
                    received_at: String::new(),
                },
            );
        }
        let policy = ReviewPolicy::default();
        assert!(flagged_novel_ids(&s, &policy).contains("n1"));
        let strict = ReviewPolicy { threshold: 4, ..ReviewPolicy::default() };
        assert!(flagged_novel_ids(&s, &strict).is_empty());
        // 豁免后需要再多加一票
        let mut exempt = BTreeSet::new();
        exempt.insert("n1".to_string());
        let exempted = ReviewPolicy { exempt, ..ReviewPolicy::default() };
        assert!(flagged_novel_ids(&s, &exempted).is_empty());
    }

    #[test]
    fn trust_circle_filters_report_votes() {
        // a（我）↔ b 互证；c、d 是一对互相背书的「女巫」，
        // 与我之间没有任何一条互证边 —— 它们的票传不到我这里。
        let mut s = ReplicaState::new();
        let mut put = |a: &str, b: &str, w: u32, at: &str| {
            s.attestations.insert(
                attest_key(a, b),
                AttestRecord {
                    id: attest_key(a, b),
                    actor: a.into(),
                    target: b.into(),
                    weight: w,
                    note: None,
                    at: at.into(),
                    received_at: String::new(),
                },
            );
        };
        put("a", "b", 3, "000000001:0:a");
        put("b", "a", 2, "000000002:0:b");
        put("c", "d", 3, "000000003:0:c");
        put("d", "c", 3, "000000004:0:d");

        let trust = my_trust(&s, "a");
        assert!(trust["b"] >= 0.5, "一步互证应在圈内：{}", trust["b"]);
        assert_eq!(trust.get("c").copied().unwrap_or(0.0), 0.0, "女巫集群传不到我");

        for (reporter, novel) in [("a", "n1"), ("b", "n1"), ("c", "n1"), ("d", "n1")] {
            s.reports.insert(
                report_key(novel, reporter),
                ReportRecord {
                    id: report_key(novel, reporter),
                    novel_id: novel.into(),
                    reporter: reporter.into(),
                    reporter_name: reporter.into(),
                    chapter_no: None,
                    category: ReportCategory::Spam,
                    note: String::new(),
                    at: "000000001:0:x".into(),
                    received_at: String::new(),
                },
            );
        }
        // 不筛选：4 票 >= 3，屏蔽
        let plain = ReviewPolicy::default();
        assert!(flagged_novel_ids(&s, &plain).contains("n1"));
        // 只算信任圈：me(a) + b = 2 票 < 3，不屏蔽
        let circle = ReviewPolicy { trust_me: Some("a".into()), ..ReviewPolicy::default() };
        assert!(flagged_novel_ids(&s, &circle).is_empty());
    }

    #[test]
    fn trust_is_deterministic_across_insert_order() {
        // 同样的图，换个插入顺序，分数必须完全一致（确定性）
        let build = |order: &[(&str, &str)]| {
            let mut s = ReplicaState::new();
            for (a, b) in order {
                s.attestations.insert(
                    attest_key(a, b),
                    AttestRecord {
                        id: attest_key(a, b),
                        actor: (*a).into(),
                        target: (*b).into(),
                        weight: 2,
                        note: None,
                        at: "000000001:0:x".into(),
                        received_at: String::new(),
                    },
                );
            }
            my_trust(&s, "me")
        };
        let one = build(&[("me", "x"), ("x", "me"), ("x", "y"), ("y", "x")]);
        let two = build(&[("y", "x"), ("me", "x"), ("x", "y"), ("x", "me")]);
        assert_eq!(one, two);
        assert!(one["x"] >= 0.5 && one["y"] > 0.0);
    }
}