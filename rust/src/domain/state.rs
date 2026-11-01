//! 副本视图（ReplicaState）
//! -----------------------
//! 归约器产出的本地视图。**所有容器都用 `BTreeMap` / `BTreeSet`**：
//! Rust 的默认 `HashMap` 用随机种子，迭代顺序在不同进程间不确定 ——
//! 平时无害，在 CRDT 里等于每次开局都掷一次骰子。
//! 而收敛性要求「同一组 op 必然得到同一视图」，包括遍历顺序。
//! 用有序容器，顺序就成了键的字典序，任何设备算出来都一样。

use std::collections::{BTreeMap, BTreeSet};

use crate::domain::model::{
    CertificateEvidence, CertificateKind, CarouselKind, ContestKind, ContestPrize, DealKind,
    DealStatus, Hlts, IssueState, NovelStatus, Op, PatchChapter, PatchState, ProfileLink,
    ReportCategory, ReplicaCertificate, ReplicaChapter, ReplicaNovel, ReplicaTranslation,
};

#[derive(Debug, Clone)]
pub struct ShelfEntry {
    pub novel_id: String,
    pub added_at: Hlts,
    pub actor: String,
}

#[derive(Debug, Clone)]
pub struct Review {
    pub id: String,
    pub actor: String,
    pub novel_id: String,
    pub chapter_no: u32,
    pub body: String,
    pub rating: u8,
    pub spoiler: bool,
    pub created_at: Hlts,
    pub cid: Option<String>,
}

// 表情计数在 `selectors::ReactionTally`：它是对 `reactions` 的派生统计，
// 不是视图里的一条记录，所以只留一份，避免同名两个类型。

#[derive(Debug, Clone)]
pub struct Profile {
    pub peer_id: String,
    pub name: String,
    pub bio: String,
    pub avatar_seed: Option<String>,
    pub links: Vec<ProfileLink>,
    /// 上次改名的 epoch ms（0 = 从未改过，即系统派生名）
    pub name_changed_at: i64,
    pub updated_at: Hlts,
}

#[derive(Debug, Clone)]
pub struct Progress {
    pub novel_id: String,
    pub chapter_no: u32,
    pub at: String,
}

#[derive(Debug, Clone)]
pub struct RewardRecord {
    pub key: String,
    pub op_id: String,
    pub from: String,
    pub to: String,
    pub amount: i64,
    pub action: String,
    pub target: Option<String>,
    pub reason: Option<String>,
    pub at: Hlts,
}

#[derive(Debug, Clone)]
pub struct ReplicaWrap {
    pub key: String,
    pub op_id: String,
    pub from: String,
    pub amount: i64,
    pub op_ids: Vec<String>,
    pub to_address: String,
    pub chain_id: u64,
    pub tx_hash: String,
    pub onchain_id: String,
    pub at: Hlts,
}

#[derive(Debug, Clone)]
pub struct PublisherRecord {
    pub id: String,
    pub peer: String,
    pub name: String,
    pub tagline: String,
    pub about: String,
    pub genres: Vec<String>,
    pub verified: bool,
    pub updated_at: Hlts,
}

/// 赛事记录 —— **不存 status**。
/// 状态取决于「现在几点」，而现在几点不是 op log 的一部分；
/// 存进去就等于让每个节点的答案取决于它几点开机。
#[derive(Debug, Clone)]
pub struct ContestRecord {
    pub id: String,
    pub publisher_peer: String,
    pub publisher_name: String,
    pub kind: ContestKind,
    pub title: String,
    pub tagline: String,
    pub rules: String,
    pub theme: Option<String>,
    pub genre: String,
    pub deadline: String,
    pub announce_at: String,
    pub min_words: u64,
    pub max_words: u64,
    pub allow_ongoing: bool,
    pub prizes: Vec<ContestPrize>,
    pub updated_at: Hlts,
}

#[derive(Debug, Clone)]
pub struct EntryRecord {
    pub key: String,
    pub contest_id: String,
    pub novel_id: String,
    pub actor: String,
    pub at: Hlts,
}

#[derive(Debug, Clone)]
pub struct StarEntry {
    pub novel_id: String,
    pub actor: String,
    pub at: Hlts,
}

#[derive(Debug, Clone)]
pub struct ForkRecord {
    pub id: String,
    pub novel_id: String,
    pub source_id: String,
    pub source_title: String,
    pub source_peer: String,
    pub by: String,
    pub by_name: String,
    pub note: Option<String>,
    pub at: Hlts,
}

#[derive(Debug, Clone)]
pub struct IssueRecord {
    pub id: String,
    pub novel_id: String,
    pub issue_id: String,
    pub title: String,
    pub body: String,
    pub author_peer: String,
    pub author_name: String,
    pub state: IssueState,
    pub closed_by: Option<String>,
    pub at: Hlts,
    pub received_at: String,
}

#[derive(Debug, Clone)]
pub struct PatchRecord {
    pub id: String,
    pub novel_id: String,
    pub patch_id: String,
    pub title: String,
    pub body: String,
    pub author_peer: String,
    pub author_name: String,
    pub state: PatchState,
    pub chapters: Vec<PatchChapter>,
    pub at: Hlts,
    pub received_at: String,
}

#[derive(Debug, Clone)]
pub struct MergeRecord {
    pub id: String,
    pub novel_id: String,
    pub patch_id: String,
    /// patch 作者（整合后进入贡献者名单）
    pub author: String,
    /// 整合者
    pub by: String,
    pub chapters: Vec<PatchChapter>,
    pub note: Option<String>,
    pub at: Hlts,
}

#[derive(Debug, Clone)]
pub struct GroupRecord {
    pub id: String,
    pub novel_id: String,
    pub name: Option<String>,
    pub named_at: Option<Hlts>,
    pub named_by: Option<String>,
    pub updated_at: Hlts,
}

#[derive(Debug, Clone)]
pub struct ContestPlacementRecord {
    pub place: u32,
    pub novel_id: String,
    pub novel_title: String,
    pub author_peer: String,
    pub author_name: String,
    pub note: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ContestResultRecord {
    pub id: String,
    pub contest_id: String,
    pub publisher_peer: String,
    pub placements: Vec<ContestPlacementRecord>,
    pub at: Hlts,
    pub received_at: String,
}

#[derive(Debug, Clone)]
pub struct DealRecord {
    pub id: String,
    pub deal_id: String,
    pub novel_id: String,
    pub novel_title: String,
    pub author_peer: String,
    pub author_name: String,
    pub publisher_peer: String,
    pub publisher_name: String,
    pub kind: DealKind,
    pub amount: i64,
    pub terms: String,
    pub status: DealStatus,
    pub at: Hlts,
    pub received_at: String,
}

#[derive(Debug, Clone)]
pub struct ReportRecord {
    pub id: String,
    pub novel_id: String,
    pub reporter: String,
    pub reporter_name: String,
    pub chapter_no: Option<u32>,
    pub category: ReportCategory,
    pub note: String,
    pub at: Hlts,
    pub received_at: String,
}

#[derive(Debug, Clone)]
pub struct ResponseRecord {
    pub id: String,
    pub novel_id: String,
    pub author: String,
    pub author_name: String,
    pub body: String,
    pub at: Hlts,
    pub received_at: String,
}

#[derive(Debug, Clone)]
pub struct ViewRecord {
    pub id: String,
    pub novel_id: String,
    pub chapter_no: u32,
    pub actor: String,
    pub at: Hlts,
}

/// 零散贡献记录（校对、评审等）。
/// key = `contrib:<novelId>:<contributor>` —— 同一身份对同一作品只有一条。
#[derive(Debug, Clone)]
pub struct ContributionRecord {
    pub id: String,
    pub novel_id: String,
    pub contributor: String,
    pub contributor_name: String,
    pub kind: String,
    pub items: u32,
    pub scope: Option<String>,
    pub note: Option<String>,
    pub at: Hlts,
    pub received_at: String,
}

/// 一条勋章授予记录。同一枚勋章被多人授予 -> 多条记录，界面只算一枚。
#[derive(Debug, Clone)]
pub struct BadgeGrantRecord {
    pub id: String,
    pub target_peer: String,
    pub badge_id: String,
    pub granter: String,
    pub granter_name: String,
    pub note: Option<String>,
    pub at: Hlts,
    pub received_at: String,
}

/// 一条阅读时长事件。
#[derive(Debug, Clone)]
pub struct ReadTickRecord {
    pub id: String,
    pub actor: String,
    pub novel_id: String,
    pub chapter_no: u32,
    pub seconds: u32,
    pub at: Hlts,
}

/// 首页轮播位。`started_at` / `expires_at` / `fee` 都是归约器写入的派生事实，
/// 「现在是否还在展示」由读取侧的当前时间判断，不写回记录。
#[derive(Debug, Clone)]
pub struct CarouselRecord {
    pub id: String,
    pub title: String,
    pub subtitle: String,
    pub kind: CarouselKind,
    pub target_id: Option<String>,
    pub href: String,
    pub by: String,
    pub by_name: String,
    pub started_at: i64,
    pub expires_at: i64,
    pub fee: i64,
    pub at: Hlts,
    pub op_id: String,
}

/// 一条信任背书。只见 A 对 B 的背书不算「互证」——
/// 互证 = A→B 与 B→A 都存在；信任传播只看互证边（见 `selectors::my_trust`）。
#[derive(Debug, Clone)]
pub struct AttestRecord {
    pub id: String,
    pub actor: String,
    pub target: String,
    pub weight: u32,
    pub note: Option<String>,
    pub at: Hlts,
    pub received_at: String,
}

/// 归约出来的本地视图。
///
/// `revision` 只是给界面用的变更计数，不参与归约结果本身。
#[derive(Debug, Clone, Default)]
pub struct ReplicaState {
    pub novels: BTreeMap<String, ReplicaNovel>,
    pub chapters: BTreeMap<String, ReplicaChapter>,
    pub shelf: BTreeMap<String, ShelfEntry>,
    pub reviews: BTreeMap<String, Review>,
    /// `reaction:<actor>:<novelId>:<kind>` -> 已反应的身份集合（去重后取并集）
    pub reactions: BTreeMap<String, BTreeSet<String>>,
    pub profiles: BTreeMap<String, Profile>,
    pub progress: BTreeMap<String, Progress>,
    pub rewards: BTreeMap<String, RewardRecord>,
    pub wraps: BTreeMap<String, ReplicaWrap>,
    pub publishers: BTreeMap<String, PublisherRecord>,
    pub contests: BTreeMap<String, ContestRecord>,
    pub entries: BTreeMap<String, EntryRecord>,
    pub translations: BTreeMap<String, ReplicaTranslation>,
    pub certificates: BTreeMap<String, ReplicaCertificate>,
    pub stars: BTreeMap<String, StarEntry>,
    pub forks: BTreeMap<String, ForkRecord>,
    pub issues: BTreeMap<String, IssueRecord>,
    pub patches: BTreeMap<String, PatchRecord>,
    pub merges: BTreeMap<String, MergeRecord>,
    pub groups: BTreeMap<String, GroupRecord>,
    pub contest_results: BTreeMap<String, ContestResultRecord>,
    pub deals: BTreeMap<String, DealRecord>,
    pub reports: BTreeMap<String, ReportRecord>,
    pub responses: BTreeMap<String, ResponseRecord>,
    pub views: BTreeMap<String, ViewRecord>,
    /// 零散贡献：`contrib:<novelId>:<contributor>`
    pub contributions: BTreeMap<String, ContributionRecord>,
    /// 社区授予的勋章：`badge:<target>:<badgeId>:<granter>`
    pub badge_grants: BTreeMap<String, BadgeGrantRecord>,
    /// 阅读时长事件：`read:<actor>:<novelId>:<chapterNo>:<seq>`
    pub read_ticks: BTreeMap<String, ReadTickRecord>,
    /// 首页轮播位：`carousel:<id>`
    pub carousels: BTreeMap<String, CarouselRecord>,
    /// 信任背书：`attest:<actor>:<target>`（每对身份一条，LWW）
    pub attestations: BTreeMap<String, AttestRecord>,

    /// 门控未通过、等前提 op 到位后重试的 op
    pub pending_gated: Vec<Op>,
    /// 只有 CID、正文还没拉到的内容块
    pub pending: BTreeSet<String>,
    /// 变更计数（供界面判断是否需要重算）
    pub revision: u64,
}

impl ReplicaState {
    pub fn new() -> Self {
        Self::default()
    }

    /// 视图指纹：用于验证「乱序 / 重复投递后各节点算出同一结果」。
    /// 因为容器有序，序列化出来的字节流本身就是确定性的。
    pub fn fingerprint(&self) -> String {
        use std::hash::{Hash, Hasher};
        let mut h = std::collections::hash_map::DefaultHasher::new();
        for (k, v) in &self.novels {
            k.hash(&mut h);
            v.title.hash(&mut h);
            v.updated_at.hash(&mut h);
            v.episodes.hash(&mut h);
            v.words.hash(&mut h);
        }
        for (k, v) in &self.chapters {
            k.hash(&mut h);
            v.title.hash(&mut h);
            v.published_at.hash(&mut h);
        }
        for k in self.shelf.keys() {
            k.hash(&mut h);
        }
        for (k, v) in &self.rewards {
            k.hash(&mut h);
            v.amount.hash(&mut h);
        }
        for (k, v) in &self.reactions {
            k.hash(&mut h);
            v.len().hash(&mut h);
        }
        for (k, v) in &self.contests {
            k.hash(&mut h);
            v.title.hash(&mut h);
        }
        for (k, v) in &self.deals {
            k.hash(&mut h);
            v.status.hash(&mut h);
        }
        for (k, v) in &self.groups {
            k.hash(&mut h);
            v.name.hash(&mut h);
        }
        for (k, v) in &self.views {
            k.hash(&mut h);
            v.chapter_no.hash(&mut h);
        }
        for (k, v) in &self.carousels {
            k.hash(&mut h);
            v.title.hash(&mut h);
            v.started_at.hash(&mut h);
        }
        for (k, v) in &self.attestations {
            k.hash(&mut h);
            v.actor.hash(&mut h);
            v.target.hash(&mut h);
            v.weight.hash(&mut h);
        }
        self.revision.hash(&mut h);
        format!("{:016x}", h.finish())
    }
}

/// 证书在视图里的派生字段（对应 `ReplicaCertificate` 的构造参数）
pub struct CertificateView {
    pub id: String,
    pub kind: CertificateKind,
    pub target_peer: String,
    pub issuer_peer: String,
    pub issuer_name: String,
    pub note: String,
    pub evidence: CertificateEvidence,
    pub at: Hlts,
    pub received_at: String,
}

impl CertificateView {
    pub fn into_replica(self) -> ReplicaCertificate {
        ReplicaCertificate {
            id: self.id,
            kind: self.kind,
            target_peer: self.target_peer,
            issuer_peer: self.issuer_peer,
            issuer_name: self.issuer_name,
            note: self.note,
            evidence: self.evidence,
            at: self.at,
            received_at: self.received_at,
        }
    }
}

/// 作品状态在视图里的展示名（界面层按语言翻译，这里只给 slug）
pub fn status_slug(s: NovelStatus) -> &'static str {
    match s {
        NovelStatus::Ongoing => "ongoing",
        NovelStatus::Completed => "completed",
        NovelStatus::Hiatus => "hiatus",
    }
}