//! 界面视图结构
//! -------------
//! 归约器产出的是「事实」，界面要的是「卡片」。这两层分开，
//! 是为了让派生统计（star 数、PV、评价数）只在一处计算 ——
//! 每个页面各写一份的话，迟早会在两个页面上看到两个数字。

/// 目录 / 榜单 / 书架共用的作品卡片
#[derive(Debug, Clone, Default)]
pub struct NovelCard {
    pub id: String,
    pub title: String,
    pub author_name: String,
    pub author_peer: String,
    pub genre: String,
    pub genre_name: String,
    pub tags: Vec<String>,
    pub synopsis: String,
    /// 卡片的「醒目语」—— 从简介里取出的第一句话。
    /// 本站不做封面（见 README），信息层级是「书名 › 醒目语 › 分类标签 › 统计数字」。
    pub tagline: String,
    pub status: String,
    pub episodes: u32,
    pub words: u64,
    pub first_published_at: String,
    pub updated_at: String,
    /// HLC 里的物理时间（毫秒），榜单与排序用它，避免反复解析字符串
    pub updated_at_ms: u64,
    pub latest_no: u32,
    pub latest_title: String,
    pub latest_at: String,
    pub license: String,
    pub license_name: String,
    pub fork_of: Option<String>,
    /// 作者自填的奖项（与 Web 的 `award` 一致；公布名次另见 `award_place`）
    pub award: Option<String>,
    /// 从赛事公布结果派生的名次（0 = 未获奖）
    pub award_place: u32,
    /// 从这部作品衍生出去的作品数
    pub forks: u64,
    /// 作者 + 已整合提案作者（去重）
    pub contributors: u64,
    /// 打开且尚未整合的提案数
    pub open_patches: u64,

    pub stars: u64,
    pub bookmarks: u64,
    pub reviews: u64,
    pub likes: u64,
    pub insightful: u64,
    pub cry: u64,

    pub pv_total: u64,
    pub pv_weekly: u64,
    pub unique_readers: u64,

    /// 是否在我的书架里（书架只在自己设备上可见）
    pub in_shelf: bool,
    pub starred_by_me: bool,
    /// 收藏时间（毫秒；未收藏为 0），书架按它排序并显示「X 前加入」
    pub shelf_added_at_ms: u64,
    /// 本机在这部作品上读到的最后一话（0 = 还没开始）
    pub progress_no: u32,
    /// 阅读进度写入时间（毫秒），用于「继续阅读」排序
    pub progress_at_ms: u64,
    /// 本机审查策略是否已屏蔽（举报票数达到本机阈值）
    pub flagged: bool,
    pub deleted: bool,
    /// 名次（榜单页用；0 = 未上榜）
    pub rank: u32,
    /// 榜单分数（界面上不显示，但排序要靠它）
    pub score: f64,
}

#[derive(Debug, Clone, Default)]
pub struct ChapterView {
    pub novel_id: String,
    pub no: u32,
    pub title: String,
    pub words: u64,
    pub published_at: String,
    pub published_at_ms: u64,
    pub volume: Option<String>,
    /// 整合进来的章节带贡献者署名
    pub contributor: Option<String>,
    pub paragraphs: Vec<String>,
    /// 正文尚未同步到本机（只有 CID）
    pub missing_body: bool,
}

#[derive(Debug, Clone, Default)]
pub struct ReviewView {
    pub id: String,
    pub actor: String,
    pub author_name: String,
    pub novel_id: String,
    pub chapter_no: u32,
    pub body: String,
    pub rating: u8,
    pub spoiler: bool,
    pub created_at: String,
    pub created_at_ms: u64,
}

#[derive(Debug, Clone, Default)]
pub struct LedgerEntry {
    pub key: String,
    pub op_id: String,
    pub from: String,
    pub from_name: String,
    pub to: String,
    pub amount: i64,
    pub action: String,
    /// 行为名的字典键（界面按语言取词）
    pub action_label_key: String,
    pub target: Option<String>,
    /// 广播出去就固定的原文，不随界面语言变
    pub reason: Option<String>,
    pub at: String,
    pub at_ms: u64,
    /// 是否已随 reward.wrap 上链锁定
    pub wrapped: bool,
}

/// 钱包「持仓榜」的一行：按收到的奖励累计（与 Web 的 `state.rewards` 口径一致）。
#[derive(Debug, Clone, Default)]
pub struct WalletHolder {
    pub peer: String,
    pub name: String,
    pub coins: i64,
}

/// 钱包「收入构成」的一行：本机收到的奖励按行为聚合。
#[derive(Debug, Clone, Default)]
pub struct WalletIncome {
    pub action: String,
    pub label_key: String,
    pub amount: i64,
}

/// 钱包页「算一下」用的示例值 —— 算式在域层，界面只负责显示。
#[derive(Debug, Clone, Default)]
pub struct RewardExampleView {
    /// 作者分成基数（wallet.rules.share 的 rate）
    pub author_share_rate: i64,
    /// authorReward(unique=1000, total=5000)
    pub author_example: i64,
    /// readingReward(words=3000, dwell=180s)
    pub read_example: i64,
    /// readingReward(words=3000, dwell=5s)
    pub idle_example: i64,
}

#[derive(Debug, Clone, Default)]
pub struct ContestCard {
    pub id: String,
    pub publisher_peer: String,
    pub publisher_name: String,
    pub kind: String,
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
    /// 状态在读取时派生（open / judging / finished），不进记录
    pub status: String,
    pub days_left: i64,
    pub entries: u64,
    pub my_entry: Option<String>,
    /// 名次是否已公布
    pub has_result: bool,
    /// 主办方承诺的奖项（冠亚季军 + 附加权益）
    pub prizes: Vec<ContestPrizeView>,
}

/// 赛事奖项。名次存 "1"/"2"/"3"，展示时按语言取词。
#[derive(Debug, Clone, Default)]
pub struct ContestPrizeView {
    pub place: String,
    pub coins: i64,
    pub extras: String,
}

/// 一条赛事报名（主办方公布名次时用）
#[derive(Debug, Clone, Default)]
pub struct ContestEntryView {
    pub contest_id: String,
    pub novel_id: String,
    pub novel_title: String,
    pub author_peer: String,
    pub author_name: String,
    pub at_ms: u64,
}

#[derive(Debug, Clone, Default)]
pub struct PublisherCard {
    pub id: String,
    pub peer: String,
    pub name: String,
    pub tagline: String,
    pub about: String,
    pub genres: Vec<String>,
    pub verified: bool,
    /// 名下赛事总数（含已结束）
    pub contests: u64,
    /// 名下仍在征稿的赛事数
    pub open_contests: u64,
    /// 旗下作品数 / 去重作者数
    pub works: u64,
    pub authors: u64,
    /// 从公开账本统计的累计赛事奖金支出
    pub rewards_paid: i64,
    /// 交易总数（保留给旧界面）
    pub deals: u64,
    /// 入驻 / 最近更新时间（毫秒）
    pub updated_at_ms: u64,
}

/// 一条首页轮播位（跨 FFI 的扁平结构）
#[derive(Debug, Clone, Default)]
pub struct CarouselView {
    pub id: String,
    pub title: String,
    pub subtitle: String,
    /// `novel` / `author` / `publisher` / `link`（界面按语言取词）
    pub kind: String,
    pub target_id: Option<String>,
    pub href: String,
    /// 付款人（来自 op.actor，不信任 body）
    pub by: String,
    pub by_name: String,
    pub started_at_ms: u64,
    pub expires_at_ms: u64,
    pub fee: i64,
    /// 是否属于本机身份
    pub mine: bool,
}

/// 轮播位页面需要的全部派生状态。
#[derive(Debug, Clone, Default)]
pub struct CarouselStateView {
    pub active: Vec<CarouselView>,
    /// 本机身份买过的全部轮播位（新的在前）
    pub mine: Vec<CarouselView>,
    pub peer_id: String,
    pub balance: i64,
    pub fee: i64,
    pub slots: u32,
    pub window_days: u32,
    pub spent: i64,
    /// 距离下次可购买还有多久（毫秒；0 = 现在就能买）
    pub cooldown_ms: u64,
    /// `none` / `identity` / `cooldown` / `full` / `balance`
    pub block_reason: String,
}

#[derive(Debug, Clone, Default)]
pub struct DealCard {
    pub id: String,
    pub deal_id: String,
    pub novel_id: String,
    pub novel_title: String,
    pub author_peer: String,
    pub author_name: String,
    pub publisher_peer: String,
    pub publisher_name: String,
    pub kind: String,
    pub amount: i64,
    pub terms: String,
    pub status: String,
    pub at_ms: u64,
    /// 报酬是否已真的转过账（以公开账本为准，而不是以按钮点没点为准）
    pub paid_on_ledger: bool,
    pub is_author: bool,
    pub is_publisher: bool,
    /// 作者现在可以接受 / 拒绝
    pub can_respond: bool,
    /// 出版社现在可以确认付款 / 取消
    pub can_settle: bool,
}

#[derive(Debug, Clone, Default)]
pub struct IssueCard {
    pub id: String,
    pub novel_id: String,
    pub issue_id: String,
    pub title: String,
    pub body: String,
    pub author_peer: String,
    pub author_name: String,
    pub state: String,
    pub at_ms: u64,
    pub can_close: bool,
}

#[derive(Debug, Clone, Default)]
pub struct PatchCard {
    pub id: String,
    pub novel_id: String,
    pub patch_id: String,
    pub title: String,
    pub body: String,
    pub author_peer: String,
    pub author_name: String,
    pub state: String,
    pub at_ms: u64,
    /// 提案基于的章节版本之后被改过 -> 冲突
    pub has_conflict: bool,
    pub merged: bool,
    pub chapter_nos: Vec<u32>,
    pub chapters: Vec<PatchChapterView>,
    pub can_merge: bool,
    pub can_close: bool,
}

/// 提案里的一话（整合前先让维护者看清正文）
#[derive(Debug, Clone, Default)]
pub struct PatchChapterView {
    pub no: u32,
    pub title: String,
    pub volume: Option<String>,
    pub paragraphs: Vec<String>,
    pub words: u64,
    pub based_on: Option<String>,
    pub contributor: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct ReportCard {
    pub id: String,
    pub novel_id: String,
    pub novel_title: String,
    pub reporter: String,
    pub reporter_name: String,
    pub chapter_no: Option<u32>,
    pub category: String,
    pub note: String,
    pub at_ms: u64,
    /// 作者的申辩（若有）
    pub response: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct BadgeCard {
    pub id: String,
    pub earned: bool,
    /// 第一次被授予的时间（HLC）；未获得为空
    pub earned_at: String,
    /// 授予者 peerId（去重；界面上显示笔名由调用方补）
    pub granters: Vec<String>,
    /// 授予者写下的理由
    pub notes: Vec<String>,
}

#[derive(Debug, Clone, Default)]
pub struct TranslationView {
    pub novel_id: String,
    pub chapter_no: u32,
    pub lang: String,
    pub actor: String,
    pub translator: String,
    pub paragraphs: Vec<String>,
    pub note: Option<String>,
    pub at_ms: u64,
}

#[derive(Debug, Clone, Default)]
pub struct CertificateCard {
    pub id: String,
    pub kind: String,
    pub target_peer: String,
    pub target_name: String,
    pub issuer_peer: String,
    pub issuer_name: String,
    pub note: String,
    pub peak_work_title: String,
    pub peak_work_clicks: u64,
    pub peak_year: i32,
    pub years_writing: f64,
    pub at_ms: u64,
    /// op 的记录级签名是否验证通过（历史记录可能没有签名）
    pub issuer_verified: bool,
}

/* ------------------------- 协作 / 贡献 / 交易 ------------------------- */

#[derive(Debug, Clone, Default)]
pub struct ContributorCard {
    pub peer: String,
    pub name: String,
    pub is_author: bool,
    pub is_maintainer: bool,
    pub chapters: u32,
    pub words: u64,
    pub translations: u32,
    pub ancillary_items: u32,
    /// 贡献图谱里的全局比例（0-1）
    pub share_ratio: f64,
}

#[derive(Debug, Clone, Default)]
pub struct MergeCard {
    pub id: String,
    pub novel_id: String,
    pub patch_id: String,
    pub author: String,
    pub author_name: String,
    pub by: String,
    pub by_name: String,
    pub chapter_nos: Vec<u32>,
    pub note: Option<String>,
    pub at_ms: u64,
}

#[derive(Debug, Clone, Default)]
pub struct GroupCard {
    pub novel_id: String,
    /// 贡献者是否达到成组下限
    pub exists: bool,
    pub name: String,
    /// 是否被成员命名过（false = 还是默认名）
    pub custom_named: bool,
    pub members: Vec<String>,
    pub member_names: Vec<String>,
    pub min_members: u32,
}

#[derive(Debug, Clone, Default)]
pub struct GraphShareView {
    pub peer: String,
    pub name: String,
    pub kind: String,
    pub pool_ratio: f64,
    pub ratio: f64,
    pub weight: f64,
    pub basis: String,
}

/// 贡献图谱：钱该分给谁，是算出来的，不是谁拍板说了算
#[derive(Debug, Clone, Default)]
pub struct ContributionGraphView {
    pub novel_id: String,
    pub canon_pool: f64,
    pub translation_pool: f64,
    pub ancillary_pool: f64,
    pub total: f64,
    pub shares: Vec<GraphShareView>,
}

#[derive(Debug, Clone, Default)]
pub struct ForkCard {
    pub id: String,
    pub novel_id: String,
    pub novel_title: String,
    pub source_id: String,
    pub source_title: String,
    pub source_peer: String,
    pub by: String,
    pub by_name: String,
    pub note: Option<String>,
    pub at_ms: u64,
}

#[derive(Debug, Clone, Default)]
pub struct AwardCard {
    pub contest_id: String,
    pub contest_title: String,
    pub place: u32,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct CertificateEligibilityView {
    pub years_writing: u32,
    pub years_ok: bool,
    pub started_at: Option<String>,
    pub peak_novel_id: Option<String>,
    pub peak_work_title: String,
    pub peak_work_clicks: u64,
    pub peak_year: i32,
    pub peak_ok: bool,
    pub eligible: bool,
}

/* ------------------------- 上链 / 赞助 ------------------------- */

#[derive(Debug, Clone, Default)]
pub struct WrappableOpView {
    pub op_id: String,
    pub amount: i64,
    pub action: String,
    pub action_label_key: String,
    pub reason: Option<String>,
    pub at_ms: u64,
}

#[derive(Debug, Clone, Default)]
pub struct WrapCoverageView {
    /// 桥接配置是否齐全（peerId + https apiUrl + 合约地址）
    pub configured: bool,
    /// 配置项自检失败的原因（空 = 通过）
    pub config_errors: Vec<String>,
    pub peer_id: String,
    /// 站内余额（收到的 - 转出的 - 已上链锁定的）
    pub balance: i64,
    /// 已被 reward.wrap 消费掉的量
    pub wrapped: i64,
    /// 本机账本里还能上链的量（尚未扣掉节点侧已经花掉的）
    pub available: i64,
    /// 尚未传播到桥接节点的量（节点侧可上链额度低于本机时）
    pub pending: i64,
    pub node_reachable: bool,
    pub node_total: i64,
    pub node_available: i64,
    pub node_wrapped: i64,
    pub ops: Vec<WrappableOpView>,
}

/// 客户端 → 桥接节点的签名申领（Dart 侧负责 HTTP）
#[derive(Debug, Clone, Default)]
pub struct WrapRequestView {
    pub peer_id: String,
    pub amount: i64,
    pub op_ids: Vec<String>,
    pub to_address: String,
    pub nonce: String,
    pub hash: String,
    pub signature: String,
}

#[derive(Debug, Clone, Default)]
pub struct WrapCard {
    pub id: String,
    pub from_peer: String,
    pub from_name: String,
    pub amount: i64,
    pub op_ids: Vec<String>,
    pub to_address: String,
    pub chain_id: u64,
    pub tx_hash: String,
    pub onchain_id: String,
    pub at_ms: u64,
}

#[derive(Debug, Clone, Default)]
pub struct SponsorMethodView {
    pub id: String,
    pub name_key: String,
    pub hint_key: String,
    /// 收款码内容 / 钱包地址；空 = 未配置
    pub code: String,
    pub configured: bool,
    pub presets: Vec<i64>,
    /// ¥ / USDT / ETH
    pub unit: String,
    pub chain_id: u64,
    /// USDT 的公开合约地址（供用户核对）
    pub contract: String,
}

#[derive(Debug, Clone, Default)]
pub struct ProfileCard {
    pub peer_id: String,
    pub name: String,
    /// 是否为系统派生名（作者页据此标注「自定义笔名」）
    pub derived_name: bool,
    pub bio: String,
    pub avatar_seed: Option<String>,
    pub works: u64,
    pub total_words: u64,
    pub chapters: u64,
    /// 本机可见的读者反应总数（点赞 + 收藏×2 + 评价×3，近似点击量）
    pub clicks: u64,
    /// 收到他人在自己作品上的评价条数
    pub reviews_from_others: u64,
    /// 收到他人打赏的笔数 / 总额
    pub tips_from_others: u64,
    pub tips_total: i64,
    /// 报名过的赛事数 / 作为译者发布的译文数
    pub contest_entries: u64,
    pub translations: u64,
    /// 在站天数（从第一篇作品算起）
    pub tenure_days: u64,
    /// 首篇到最近一篇的跨度（天）
    pub span_days: u64,
    /// 最长连续产出年数
    pub continuous_years: u32,
    /// 被整合进他人作品的提案数
    pub contributions: u64,
    /// 达到成组下限的作品中，我是贡献者的作品数
    pub group_memberships: u64,
    /// 公布结果中名次属于我的作品数
    pub contest_wins: u64,
    /// 向我发出且已接受 / 已支付的交易数
    pub accepted_deals: u64,
    /// 最早一篇作品的发表时间
    pub joined_at: Option<String>,
    pub badges: Vec<BadgeCard>,
    pub link_platform: Vec<String>,
    pub link_url: Vec<String>,
    pub link_label: Vec<String>,
    /// 距上次改名是否已满 30 天（冷却期判定只在界面层，因为归约器必须是纯函数）
    pub can_rename: bool,
    pub next_rename_at_ms: i64,
}

/// 本机在某一部作品上的阅读进度。
#[derive(Debug, Clone, Default)]
pub struct ProgressView {
    pub novel_id: String,
    pub chapter_no: u32,
    pub at_ms: u64,
}

/// 赛事名次（只公布名次与作品，不公布评委打分细节）。
#[derive(Debug, Clone, Default)]
pub struct ContestPlacementView {
    pub place: u32,
    pub novel_id: String,
    pub novel_title: String,
    pub author_peer: String,
    pub author_name: String,
    pub note: Option<String>,
    /// 奖金是否已经在公开账本上转给作者（不是按钮点没点）
    pub prize_paid: bool,
}