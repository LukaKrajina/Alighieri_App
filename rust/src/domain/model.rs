//! Op 与 CRDT 负载的数据形状
//! -------------------------
//! 与 Web 版 `lib/p2p/types.ts` 一一对应。字段顺序与命名保持一致，
//! 这样两侧序列化出的 JSON 可以互相投递 —— 少一个字段，对面就当没听懂。

use serde::{Deserialize, Serialize};

/* ------------------------- Op ------------------------- */

/// HLC 时间戳字符串：`"wall:counter:node"`
pub type Hlts = String;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum OpKind {
    #[serde(rename = "novel.put")]
    NovelPut,
    #[serde(rename = "novel.del")]
    NovelDel,
    #[serde(rename = "chapter.put")]
    ChapterPut,
    #[serde(rename = "chapter.del")]
    ChapterDel,
    #[serde(rename = "bookmark.set")]
    BookmarkSet,
    #[serde(rename = "review.put")]
    ReviewPut,
    #[serde(rename = "reaction.add")]
    ReactionAdd,
    #[serde(rename = "profile.put")]
    ProfilePut,
    #[serde(rename = "progress.set")]
    ProgressSet,
    #[serde(rename = "reward.grant")]
    RewardGrant,
    #[serde(rename = "reward.transfer")]
    RewardTransfer,
    #[serde(rename = "reward.wrap")]
    RewardWrap,
    #[serde(rename = "publisher.put")]
    PublisherPut,
    #[serde(rename = "contest.put")]
    ContestPut,
    #[serde(rename = "entry.submit")]
    EntrySubmit,
    #[serde(rename = "translation.put")]
    TranslationPut,
    #[serde(rename = "certificate.put")]
    CertificatePut,
    #[serde(rename = "relay.announce")]
    RelayAnnounce,
    #[serde(rename = "star.add")]
    StarAdd,
    #[serde(rename = "fork.put")]
    ForkPut,
    #[serde(rename = "issue.put")]
    IssuePut,
    #[serde(rename = "issue.close")]
    IssueClose,
    #[serde(rename = "patch.put")]
    PatchPut,
    #[serde(rename = "patch.merge")]
    PatchMerge,
    #[serde(rename = "patch.close")]
    PatchClose,
    #[serde(rename = "group.put")]
    GroupPut,
    #[serde(rename = "contest.result")]
    ContestResult,
    #[serde(rename = "deal.put")]
    DealPut,
    #[serde(rename = "report.put")]
    ReportPut,
    #[serde(rename = "report.respond")]
    ReportRespond,
    #[serde(rename = "view.add")]
    ViewAdd,
    /// 零散贡献声明（校对 / 评审 / 插图 / 资料）
    #[serde(rename = "contrib.put")]
    ContribPut,
    /// 阅读时长事件（每累计 30 秒一条）
    #[serde(rename = "read.tick")]
    ReadTick,
    /// 社区授予勋章
    #[serde(rename = "badge.grant")]
    BadgeGrant,
    /// 首页轮播位（作者 / 出版社用奖励币购买，每条展示 7 天）
    #[serde(rename = "carousel.put")]
    CarouselPut,
    /// 信任网：身份 A 为身份 B 背书（A 收到过 B 的背书才算互证）。
    /// 这是女巫抵抗的基础数据 —— 见 docs/SYBIL-RESEARCH.md。
    #[serde(rename = "attest.put")]
    AttestPut,
}

impl OpKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            OpKind::NovelPut => "novel.put",
            OpKind::NovelDel => "novel.del",
            OpKind::ChapterPut => "chapter.put",
            OpKind::ChapterDel => "chapter.del",
            OpKind::BookmarkSet => "bookmark.set",
            OpKind::ReviewPut => "review.put",
            OpKind::ReactionAdd => "reaction.add",
            OpKind::ProfilePut => "profile.put",
            OpKind::ProgressSet => "progress.set",
            OpKind::RewardGrant => "reward.grant",
            OpKind::RewardTransfer => "reward.transfer",
            OpKind::RewardWrap => "reward.wrap",
            OpKind::PublisherPut => "publisher.put",
            OpKind::ContestPut => "contest.put",
            OpKind::EntrySubmit => "entry.submit",
            OpKind::TranslationPut => "translation.put",
            OpKind::CertificatePut => "certificate.put",
            OpKind::RelayAnnounce => "relay.announce",
            OpKind::StarAdd => "star.add",
            OpKind::ForkPut => "fork.put",
            OpKind::IssuePut => "issue.put",
            OpKind::IssueClose => "issue.close",
            OpKind::PatchPut => "patch.put",
            OpKind::PatchMerge => "patch.merge",
            OpKind::PatchClose => "patch.close",
            OpKind::GroupPut => "group.put",
            OpKind::ContestResult => "contest.result",
            OpKind::DealPut => "deal.put",
            OpKind::ReportPut => "report.put",
            OpKind::ReportRespond => "report.respond",
            OpKind::ViewAdd => "view.add",
            OpKind::ContribPut => "contrib.put",
            OpKind::ReadTick => "read.tick",
            OpKind::BadgeGrant => "badge.grant",
            OpKind::CarouselPut => "carousel.put",
            OpKind::AttestPut => "attest.put",
        }
    }
}

/// 一条广播出去的操作。
///
/// `body` 用 `serde_json::Value`，因为每种操作各有自己的负载形状，
/// 而 op log 的读写（落盘 / 网络）只需要它是「一段可序列化的 JSON」。
/// 归约器按 `kind` 把它解析成具体结构。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Op {
    pub id: String,
    pub actor: String,
    pub hlts: Hlts,
    pub kind: OpKind,
    pub key: String,
    pub body: serde_json::Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cid: Option<String>,
    #[serde(default = "protocol_version")]
    pub v: u32,
    /// 记录级 Ed25519 签名（base64）。升级前的历史 op 没有这一项。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sig: Option<String>,
}

fn protocol_version() -> u32 {
    1
}

/// 信任背书（`attest.put`）的负载。key = `attest:<actor>:<target>`，
/// 所以「谁给谁背书」由 key 决定，body 只带权重与一句话理由 ——
/// 关系摆在明面上，解释可以很短。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AttestBody {
    /// 背书强度 1..=3，缺省 1。0 会被归约器丢弃（不是撤销）。
    #[serde(default = "default_attest_weight")]
    pub weight: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

fn default_attest_weight() -> u32 {
    1
}

/* ------------------------- 枚举 ------------------------- */

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NovelStatus {
    Ongoing,
    Completed,
    Hiatus,
}

impl NovelStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            NovelStatus::Ongoing => "ongoing",
            NovelStatus::Completed => "completed",
            NovelStatus::Hiatus => "hiatus",
        }
    }
    pub fn parse(s: &str) -> Self {
        match s {
            "completed" => NovelStatus::Completed,
            "hiatus" => NovelStatus::Hiatus,
            _ => NovelStatus::Ongoing,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ReactionKind {
    Like,
    Insightful,
    Cry,
}

impl ReactionKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            ReactionKind::Like => "like",
            ReactionKind::Insightful => "insightful",
            ReactionKind::Cry => "cry",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LinkPlatform {
    X,
    Bilibili,
    Tiktok,
    Youtube,
    Github,
    Weibo,
    Discord,
    Website,
    Email,
    Other,
}

impl LinkPlatform {
    pub fn parse(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "x" | "twitter" => LinkPlatform::X,
            "bilibili" | "b站" => LinkPlatform::Bilibili,
            "tiktok" | "douyin" => LinkPlatform::Tiktok,
            "youtube" | "yt" => LinkPlatform::Youtube,
            "github" | "gh" => LinkPlatform::Github,
            "weibo" => LinkPlatform::Weibo,
            "discord" => LinkPlatform::Discord,
            "email" | "mail" | "mailto" => LinkPlatform::Email,
            "website" | "site" | "homepage" => LinkPlatform::Website,
            _ => LinkPlatform::Other,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ContestKind {
    CallForWriting,
    Battle,
    Theme,
    Edit,
}

impl ContestKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            ContestKind::CallForWriting => "call-for-writing",
            ContestKind::Battle => "battle",
            ContestKind::Theme => "theme",
            ContestKind::Edit => "edit",
        }
    }
    pub fn parse(s: &str) -> Self {
        match s {
            "battle" => ContestKind::Battle,
            "theme" => ContestKind::Theme,
            "edit" => ContestKind::Edit,
            _ => ContestKind::CallForWriting,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DealKind {
    Manga,
    Anime,
    Game,
    Cover,
}

impl DealKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            DealKind::Manga => "manga",
            DealKind::Anime => "anime",
            DealKind::Game => "game",
            DealKind::Cover => "cover",
        }
    }
    pub fn parse(s: &str) -> Self {
        match s {
            "anime" => DealKind::Anime,
            "game" => DealKind::Game,
            "cover" => DealKind::Cover,
            _ => DealKind::Manga,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DealStatus {
    Offered,
    Accepted,
    Declined,
    Paid,
    Cancelled,
}

impl DealStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            DealStatus::Offered => "offered",
            DealStatus::Accepted => "accepted",
            DealStatus::Declined => "declined",
            DealStatus::Paid => "paid",
            DealStatus::Cancelled => "cancelled",
        }
    }
    /// 终态：不再变化
    pub fn is_terminal(&self) -> bool {
        matches!(
            self,
            DealStatus::Paid | DealStatus::Declined | DealStatus::Cancelled
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ReportCategory {
    Spam,
    Illegal,
    Copyright,
    Hate,
    Other,
}

impl ReportCategory {
    pub fn as_str(&self) -> &'static str {
        match self {
            ReportCategory::Spam => "spam",
            ReportCategory::Illegal => "illegal",
            ReportCategory::Copyright => "copyright",
            ReportCategory::Hate => "hate",
            ReportCategory::Other => "other",
        }
    }
    /// 脏数据一律归入 other，而不是让界面崩
    pub fn parse(s: &str) -> Self {
        match s {
            "spam" => ReportCategory::Spam,
            "illegal" => ReportCategory::Illegal,
            "copyright" => ReportCategory::Copyright,
            "hate" => ReportCategory::Hate,
            _ => ReportCategory::Other,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum IssueState {
    Open,
    Closed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PatchState {
    Open,
    Closed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum CertificateKind {
    AlighieriWriter,
}

/// 轮播位链接类型。与 Web 版 `CarouselKind` 一致。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CarouselKind {
    Novel,
    Author,
    Publisher,
    /// 未知类型一律归入外部链接，与 Web 版 `CAROUSEL_KINDS.includes(...) ? ... : "link"` 一致
    #[serde(other)]
    Link,
}

impl CarouselKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            CarouselKind::Novel => "novel",
            CarouselKind::Author => "author",
            CarouselKind::Publisher => "publisher",
            CarouselKind::Link => "link",
        }
    }
    /// 脏数据一律归入 link（外部链接），而不是让界面崩
    pub fn parse(s: &str) -> Self {
        match s {
            "novel" => CarouselKind::Novel,
            "author" => CarouselKind::Author,
            "publisher" => CarouselKind::Publisher,
            _ => CarouselKind::Link,
        }
    }
}

/* ------------------------- 负载 ------------------------- */

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NovelLatest {
    pub no: u32,
    pub title: String,
    pub at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NovelBody {
    pub title: String,
    #[serde(default)]
    pub author_name: Option<String>,
    #[serde(default)]
    pub author_peer: Option<String>,
    #[serde(default)]
    pub genre: Option<String>,
    #[serde(default)]
    pub genre_name: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub synopsis: String,
    #[serde(default)]
    pub status: Option<NovelStatus>,
    #[serde(default)]
    pub episodes: u32,
    #[serde(default)]
    pub words: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latest: Option<NovelLatest>,
    #[serde(default)]
    pub first_published_at: Option<String>,
    #[serde(default)]
    pub awards: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub license: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fork_of: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChapterBody {
    pub novel_id: String,
    pub no: u32,
    pub title: String,
    pub paragraphs: Vec<String>,
    pub words: u64,
    pub published_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub volume: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contributor: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReviewBody {
    pub novel_id: String,
    /// 0 = 对整部作品的评价
    pub chapter_no: u32,
    pub body: String,
    pub rating: u8,
    #[serde(default)]
    pub spoiler: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReactionBody {
    pub novel_id: String,
    pub kind: ReactionKind,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProfileLink {
    pub platform: LinkPlatform,
    pub url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfileBody {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub bio: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_seed: Option<String>,
    #[serde(default)]
    pub links: Vec<ProfileLink>,
    /// 上次改名的 epoch ms；冷却期判定只在界面层，不进归约
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name_changed_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProgressBody {
    pub novel_id: String,
    pub chapter_no: u32,
    pub at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RewardBody {
    pub idempotency_key: String,
    pub to: String,
    pub amount: i64,
    #[serde(default)]
    pub action: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    /// 广播出去的 op 内容：发出去就固定了，保持原文
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WrapBody {
    pub idempotency_key: String,
    pub from: String,
    pub amount: i64,
    pub op_ids: Vec<String>,
    pub to_address: String,
    pub chain_id: u64,
    pub tx_hash: String,
    pub onchain_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PublisherBody {
    pub name: String,
    #[serde(default)]
    pub tagline: String,
    #[serde(default)]
    pub about: String,
    #[serde(default)]
    pub genres: Vec<String>,
    #[serde(default)]
    pub verified: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContestPrize {
    pub place: String,
    pub coins: i64,
    #[serde(default)]
    pub extras: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContestBody {
    pub publisher_peer: String,
    pub publisher_name: String,
    pub kind: ContestKind,
    pub title: String,
    #[serde(default)]
    pub tagline: String,
    #[serde(default)]
    pub rules: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub theme: Option<String>,
    #[serde(default)]
    pub genre: String,
    pub deadline: String,
    pub announce_at: String,
    #[serde(default)]
    pub min_words: u64,
    #[serde(default)]
    pub max_words: u64,
    #[serde(default)]
    pub allow_ongoing: bool,
    #[serde(default)]
    pub prizes: Vec<ContestPrize>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EntryBody {
    pub contest_id: String,
    pub novel_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranslationBody {
    pub novel_id: String,
    pub chapter_no: u32,
    /// BCP-47 主标签
    pub lang: String,
    /// 与原文等长 —— 双行显示靠下标对齐
    pub paragraphs: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub translator: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CertificateEvidence {
    pub started_at: String,
    pub years_writing: f64,
    pub peak_work_title: String,
    pub peak_work_clicks: u64,
    pub peak_year: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CertificateBody {
    pub target_peer: String,
    pub kind: CertificateKind,
    #[serde(default)]
    pub note: String,
    pub evidence: CertificateEvidence,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StarBody {
    pub novel_id: String,
    /// 同键 `on:false` = 取消
    pub on: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ForkBody {
    pub novel_id: String,
    pub source_id: String,
    pub source_title: String,
    pub source_peer: String,
    #[serde(default)]
    pub by: Option<String>,
    #[serde(default)]
    pub by_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IssueBody {
    pub novel_id: String,
    pub issue_id: String,
    pub title: String,
    pub body: String,
    pub author_peer: String,
    pub author_name: String,
    pub state: IssueState,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IssueCloseBody {
    pub novel_id: String,
    pub issue_id: String,
    pub state: IssueState,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PatchChapter {
    pub no: u32,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub volume: Option<String>,
    pub paragraphs: Vec<String>,
    #[serde(default)]
    pub words: u64,
    /// 基于哪一版章节 —— 之后章节被改过的会标出冲突
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub based_on: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contributor: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PatchBody {
    pub novel_id: String,
    pub patch_id: String,
    pub title: String,
    pub body: String,
    pub author_peer: String,
    pub author_name: String,
    pub state: PatchState,
    pub chapters: Vec<PatchChapter>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PatchCloseBody {
    pub novel_id: String,
    pub patch_id: String,
    pub state: PatchState,
}

/// 自包含：章节内容随 op 广播，任何到达顺序都算出同一结果
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MergeBody {
    pub novel_id: String,
    pub patch_id: String,
    /// patch 作者（整合后进入贡献者名单）
    pub author: String,
    /// 整合者
    pub by: String,
    pub chapters: Vec<PatchChapter>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GroupBody {
    pub novel_id: Option<String>,
    /// 缺省 = 仅确认建组
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContestPlacement {
    /// 1 = 冠军
    pub place: u32,
    pub novel_id: String,
    pub novel_title: String,
    pub author_peer: String,
    pub author_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContestResultBody {
    pub contest_id: String,
    pub publisher_peer: String,
    pub placements: Vec<ContestPlacement>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DealBody {
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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReportBody {
    pub novel_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chapter_no: Option<u32>,
    pub category: ReportCategory,
    #[serde(default)]
    pub note: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reporter_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RespondBody {
    pub novel_id: String,
    pub body: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ViewBody {
    pub novel_id: String,
    pub chapter_no: u32,
}

/* ------------------------- 本轮新增的协作负载 ------------------------- */

/// 阅读时长事件。总时长 = 所有事件秒数之和，与到达顺序无关。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadTickBody {
    pub novel_id: String,
    pub chapter_no: u32,
    /// 本次记录的秒数（上限 120，防止伪造天文数字）
    pub seconds: u32,
}

/// 社区授予勋章。自授无效（归约器丢弃 `target_peer == op.actor`）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BadgeGrantBody {
    pub target_peer: String,
    pub badge_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub granter_name: Option<String>,
}

/// 零散贡献声明。同一身份对同一作品只有一条（LWW）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContributionBody {
    pub novel_id: String,
    /// `proofread` / `review` / `illustration` / `research`
    pub kind: String,
    pub items: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contributor_name: Option<String>,
}

/// 首页轮播位。
///
/// `by` 不放进 body：付款人永远是 `op.actor`，由归约器写入记录。
/// 费用也不放进 body：费用是站点规则（`CAROUSEL_FEE`），由归约器按常量写入 ——
/// 谁付的钱、付了多少，都不归 body 自己声明。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CarouselBody {
    pub title: String,
    #[serde(default)]
    pub subtitle: String,
    #[serde(default = "default_carousel_kind")]
    pub kind: CarouselKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_id: Option<String>,
    pub href: String,
    #[serde(default)]
    pub by_name: String,
}

fn default_carousel_kind() -> CarouselKind {
    CarouselKind::Link
}

/* ------------------------- 归约结果（副本视图） ------------------------- */

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplicaNovel {
    pub id: String,
    pub title: String,
    pub author_name: String,
    pub author_peer: String,
    pub genre: String,
    pub genre_name: String,
    pub tags: Vec<String>,
    pub synopsis: String,
    pub status: NovelStatus,
    pub episodes: u32,
    pub words: u64,
    pub first_published_at: String,
    pub updated_at: Hlts,
    pub latest: NovelLatest,
    pub awards: Vec<String>,
    pub license: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fork_of: Option<String>,
    pub deleted: bool,
    pub op_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cid: Option<String>,
    pub received_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplicaChapter {
    pub novel_id: String,
    pub no: u32,
    pub title: String,
    pub words: u64,
    pub published_at: Hlts,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub volume: Option<String>,
    /// 整合进来的章节带贡献者署名；直接发布的不带（= 作品作者）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contributor: Option<String>,
    /// 正文可能只存了 CID，还没拉到本机
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub paragraphs: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cid: Option<String>,
    pub deleted: bool,
    pub op_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplicaTranslation {
    pub novel_id: String,
    pub chapter_no: u32,
    pub lang: String,
    pub actor: String,
    pub translator: String,
    pub paragraphs: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    pub at: Hlts,
    pub received_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplicaCertificate {
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
