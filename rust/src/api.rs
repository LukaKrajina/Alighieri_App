//! Flutter 调用入口（flutter_rust_bridge 门面）
//! -------------------------------------------
//! 这一层只做三件事：把引擎的方法摊平、把参数换成跨 FFI 友好的类型、
//! 把 `Result` 的语义保留住。业务逻辑一律在 `engine` / `domain` 里。
//!
//! 为什么不让界面直接提交 op：写操作的顺序（先落盘、再广播）和
//! 幂等键的生成都只有一处需要正确，摊到界面上，迟早会有人漏掉一步。

use crate::domain::catalog::SearchParams;
use crate::domain::theme::Palette;
use crate::domain::view::*;
use crate::engine::{self, AttestationStats, InitReport, IdentityInfo, NodeStats, TrustEntryView, VaultStatus, WalletSummary};
use crate::store::Settings;

#[derive(Debug, Clone, Default)]
pub struct Genre {
    pub slug: String,
    pub name: String,
    pub desc: String,
}

#[derive(Debug, Clone, Default)]
pub struct EntryCheckView {
    pub ok: bool,
    /// 失败原因的字典键（界面按语言取词），成功时为空
    pub reason_key: String,
    pub need: i64,
    pub have: i64,
}

#[derive(Debug, Clone, Default)]
pub struct LicenseView {
    pub id: String,
    /// SPDX 标识；连载专用许可没有对应项
    pub spdx: Option<String>,
    pub key: String,
    pub short_name: String,
    pub name: String,
    pub category: String,
    pub summary: String,
    /// 条款要点存的是 **i18n 键**（`@` 前缀），由界面取词
    pub allows: Vec<String>,
    pub requires: Vec<String>,
    pub forbids: Vec<String>,
    pub commercial: bool,
    pub derivatives: bool,
    pub recommended: bool,
    /// 条款正文。**永远只有中文** —— 非官方译文可能造成法律上的误导
    pub text: String,
}

#[derive(Debug, Clone, Default)]
pub struct ContestKindView {
    pub id: String,
    pub label_key: String,
    pub short_key: String,
    pub desc_key: String,
    pub label: String,
    pub short: String,
    pub desc: String,
}

#[derive(Debug, Clone, Default)]
pub struct RewardRuleView {
    pub action: String,
    pub label_key: String,
    pub rate: i64,
    /// 每日上限；0 = 不限
    pub daily_cap: i64,
}

/// 提案里的一话（跨 FFI 的扁平结构）
#[derive(Debug, Clone, Default)]
pub struct PatchChapterInput {
    pub no: u32,
    pub title: String,
    pub paragraphs: Vec<String>,
    pub volume: Option<String>,
}

/// 赛事名次输入：标题与作者由引擎从本机副本补全，避免界面写错
#[derive(Debug, Clone, Default)]
pub struct ContestPlacementInput {
    pub place: u32,
    pub novel_id: String,
    pub note: Option<String>,
}

/// 赛事奖项输入。`place` 存 "1"/"2"/"3"，展示时由界面按语言取词。
#[derive(Debug, Clone, Default)]
pub struct ContestPrizeInput {
    pub place: String,
    pub coins: i64,
    pub extras: String,
}

/* ------------------------- 生命周期与身份 ------------------------- */

/// 许可证登记表（CC 系列 + 连载专用）
pub fn licenses() -> Vec<LicenseView> {
    crate::domain::licenses::LICENSES
        .iter()
        .map(|l| LicenseView {
            id: l.id.to_string(),
            spdx: l.spdx.map(|s| s.to_string()),
            key: l.key.to_string(),
            short_name: l.short_name.to_string(),
            name: l.name.to_string(),
            category: l.category.to_string(),
            summary: l.summary.to_string(),
            allows: l.allows.iter().map(|s| s.to_string()).collect(),
            requires: l.requires.iter().map(|s| s.to_string()).collect(),
            forbids: l.forbids.iter().map(|s| s.to_string()).collect(),
            commercial: l.commercial,
            derivatives: l.derivatives,
            recommended: l.recommended,
            text: l.text.to_string(),
        })
        .collect()
}

pub fn contest_kinds() -> Vec<ContestKindView> {
    crate::domain::contest::CONTEST_KIND_META
        .iter()
        .zip(crate::domain::contest::CONTEST_KINDS.iter())
        .map(|(m, k)| ContestKindView {
            id: k.as_str().to_string(),
            label_key: m.label_key.to_string(),
            short_key: m.short_key.to_string(),
            desc_key: m.desc_key.to_string(),
            label: m.label.to_string(),
            short: m.short.to_string(),
            desc: m.desc.to_string(),
        })
        .collect()
}

/// 奖励币的发放规则 —— 算式公开可复算，界面要照原样列出来
pub fn reward_rules() -> Vec<RewardRuleView> {
    use crate::domain::wallet::RewardAction;
    [
        RewardAction::ReadChapter,
        RewardAction::FinishNovel,
        RewardAction::Like,
        RewardAction::Bookmark,
        RewardAction::Review,
        RewardAction::Publish,
        RewardAction::AuthorBookmarkShare,
    ]
    .iter()
    .map(|a| RewardRuleView {
        action: a.as_str().to_string(),
        label_key: a.label_key().to_string(),
        rate: a.rate(),
        daily_cap: a.daily_cap().unwrap_or(0),
    })
    .collect()
}

pub fn init_app(data_dir: String) -> Result<InitReport, String> {
    engine::with(|e| e.init(&data_dir))
}

pub fn identity() -> Result<IdentityInfo, String> {
    engine::with(|e| e.identity_info())
}

/// 用恢复短语在新设备上重新署名
pub fn import_identity(recovery_phrase: String) -> Result<IdentityInfo, String> {
    engine::with(|e| e.import_identity(&recovery_phrase))
}

/* ------------------------- 身份保管：口令是钥匙，不是密码本 ------------------------- */

/// 身份保管现状：有没有身份 / 是否口令加密 / 本会话是否解锁。
pub fn vault_status() -> VaultStatus {
    engine::with_ref(|e| e.vault_status())
}

/// 设置（或修改）口令。口令最少 8 个字符；成功后磁盘上的明文消失 ——
/// 不是藏起来，是真的没了。
pub fn set_passphrase(passphrase: String) -> Result<(), String> {
    engine::with(|e| e.set_passphrase(&passphrase))
}

/// 用口令解锁加密身份。口令错误 = 校验失败，返回可读错误。
pub fn unlock_vault(passphrase: String) -> Result<IdentityInfo, String> {
    engine::with(|e| e.unlock_vault(&passphrase))
}

/// 立即锁定：内存里的私钥当场丢弃，本会话内不再能签名 ——
/// 丢得很干净，没有回收站。
pub fn lock_vault() -> Result<(), String> {
    engine::with(|e| e.lock_vault())
}

/// 移除口令，身份改回明文落盘。需要先解锁。
pub fn remove_passphrase() -> Result<(), String> {
    engine::with(|e| e.remove_passphrase())
}

/// 口令强度提示（weak / fair / strong），界面用它给反馈，不是安全策略 ——
/// 它只负责提醒，不负责保证。
pub fn passphrase_strength(passphrase: String) -> String {
    crate::vault::passphrase_strength(&passphrase).to_string()
}

pub fn update_profile(name: String, bio: String) -> Result<(), String> {
    engine::with(|e| e.set_profile(&name, &bio))
}

/// 站外链接（跨 FFI 的扁平结构，避免直接把 serde 枚举暴露给 Dart）
#[derive(Debug, Clone, Default)]
pub struct ProfileLinkInput {
    pub platform: String,
    pub url: String,
    pub label: Option<String>,
}

pub fn set_profile_links(links: Vec<ProfileLinkInput>) -> Result<(), String> {
    let parsed = links
        .into_iter()
        .filter(|l| !l.url.trim().is_empty())
        .map(|l| crate::domain::model::ProfileLink {
            platform: crate::domain::model::LinkPlatform::parse(&l.platform),
            url: l.url.trim().to_string(),
            label: l.label.map(|s| s.trim().to_string()).filter(|s| !s.is_empty()),
        })
        .collect();
    engine::with(|e| e.set_profile_links(parsed))
}

/* ------------------------- 发布 ------------------------- */

pub fn publish_novel(
    title: String,
    synopsis: String,
    genre: String,
    tags: Vec<String>,
    status: String,
    license: String,
) -> Result<String, String> {
    engine::with(|e| e.publish_novel(&title, &synopsis, &genre, tags, &status, &license))
}

pub fn publish_chapter(
    novel_id: String,
    no: u32,
    title: String,
    paragraphs: Vec<String>,
    volume: Option<String>,
) -> Result<(), String> {
    engine::with(|e| e.publish_chapter(&novel_id, no, &title, paragraphs, volume))
}

/// 发布即广播，`novel.del` 只是本机视图上的覆盖 ——
/// 它删不掉别人设备上已经收到的副本，界面上必须照这个意思措辞。
pub fn delete_novel(novel_id: String) -> Result<(), String> {
    engine::with(|e| e.delete_novel(&novel_id))
}

/// 修改自己作品的资料（书名 / 简介 / 分类 / 标签 / 状态 / 许可）。
pub fn update_novel(
    novel_id: String,
    title: String,
    synopsis: String,
    genre: String,
    tags: Vec<String>,
    status: String,
    license: String,
) -> Result<(), String> {
    engine::with(|e| {
        e.update_novel(&novel_id, &title, &synopsis, &genre, tags, &status, &license)
    })
}

pub fn delete_chapter(novel_id: String, no: u32) -> Result<(), String> {
    engine::with(|e| e.delete_chapter(&novel_id, no))
}

/* ------------------------- 目录 / 榜单 ------------------------- */

pub fn list_novels(
    q: String,
    genre: String,
    status: String,
    tag: String,
    sort: String,
) -> Vec<NovelCard> {
    engine::with_ref(|e| {
        e.novels(SearchParams {
            q,
            genre,
            status,
            tag,
            sort: crate::domain::catalog::SortKey::parse(&sort),
        })
    })
}

pub fn ranking(period: String, genre: String) -> Vec<NovelCard> {
    engine::with_ref(|e| e.ranking(&period, &genre))
}

pub fn get_novel(novel_id: String) -> Option<NovelCard> {
    engine::with_ref(|e| e.novel(&novel_id))
}

pub fn get_chapters(novel_id: String) -> Vec<ChapterView> {
    engine::with_ref(|e| e.chapters(&novel_id))
}

pub fn genres() -> Vec<Genre> {
    engine::with_ref(|e| {
        e.genres()
            .into_iter()
            .map(|(slug, name, desc)| Genre { slug, name, desc })
            .collect()
    })
}

/* ------------------------- 阅读：先读，再谈读后感 ------------------------- */

/// 读完一话：记一次 PV，并按停留时长发币。返回本次得到的币数。
pub fn finish_reading(novel_id: String, chapter_no: u32, dwell_ms: u64, words: u64) -> Result<i64, String> {
    engine::with(|e| e.finish_reading(&novel_id, chapter_no, dwell_ms, words))
}

pub fn set_progress(novel_id: String, chapter_no: u32) -> Result<(), String> {
    engine::with(|e| e.set_progress(&novel_id, chapter_no))
}

/// 阅读器每累计 30 秒调用一次。Web 版把单次时长钳制在 0–120 秒，
/// 这里保留同样边界，避免休眠恢复后的一个巨大 tick 把评价门槛直接刷满。
pub fn record_read_tick(novel_id: String, chapter_no: u32, seconds: u32) -> Result<(), String> {
    engine::with(|e| e.record_read_tick(&novel_id, chapter_no, seconds))
}

/// 本机在某部作品 / 某一话上累计的阅读秒数（chapter_no = 0 表示整部）。
pub fn my_read_seconds(novel_id: String, chapter_no: u32) -> u64 {
    engine::with_ref(|e| e.my_read_seconds(&novel_id, chapter_no))
}

/// 任意身份在某一话 / 整部作品上的阅读秒数（勋章授予面板用来解释进度）。
pub fn read_seconds(peer: String, novel_id: String, chapter_no: u32) -> u64 {
    engine::with_ref(|e| e.read_seconds_of(&peer, &novel_id, chapter_no))
}

pub fn read_chapters(peer: String, novel_id: String) -> u64 {
    engine::with_ref(|e| e.read_chapters_of(&peer, &novel_id))
}

pub fn set_bookmark(novel_id: String, on: bool) -> Result<(), String> {
    engine::with(|e| e.set_bookmark(&novel_id, on))
}

/// star 是同步给所有节点的公开计数，书架只在自己设备上可见 —— 两回事。
/// 而且 star 不计入任何评定（排行榜、勋章都不看它）。
pub fn set_star(novel_id: String, on: bool) -> Result<(), String> {
    engine::with(|e| e.set_star(&novel_id, on))
}

pub fn add_review(
    novel_id: String,
    chapter_no: u32,
    body: String,
    rating: u8,
    spoiler: bool,
) -> Result<(), String> {
    engine::with(|e| e.add_review(&novel_id, chapter_no, &body, rating, spoiler))
}

pub fn get_reviews(novel_id: String) -> Vec<ReviewView> {
    engine::with_ref(|e| e.reviews(&novel_id))
}

pub fn add_reaction(novel_id: String, kind: String) -> Result<(), String> {
    engine::with(|e| e.add_reaction(&novel_id, &kind))
}

/* ------------------------- 译文：各译各的，读者自己挑 ------------------------- */

pub fn get_translations(novel_id: String, chapter_no: u32, lang: String) -> Vec<TranslationView> {
    engine::with_ref(|e| e.translations(&novel_id, chapter_no, &lang))
}

/// 任何读者都能补一份译文，以自己的身份署名，随 op log 同步出去。
/// 同一句话的多个译本全部保留，由读者自己选 —— 不做「多数票」。
pub fn put_translation(
    novel_id: String,
    chapter_no: u32,
    lang: String,
    paragraphs: Vec<String>,
    note: Option<String>,
    translator: Option<String>,
) -> Result<(), String> {
    engine::with(|e| {
        e.put_translation(&novel_id, chapter_no, &lang, paragraphs, note, translator)
    })
}

/* ------------------------- 奖励币 ------------------------- */

pub fn wallet() -> WalletSummary {
    engine::with_ref(|e| e.wallet())
}

pub fn tip(to_peer: String, amount: i64, reason: Option<String>) -> Result<(), String> {
    engine::with(|e| e.tip(&to_peer, amount, reason))
}

/* ------------------------- 首页轮播位 ------------------------- */

pub fn carousel_state() -> CarouselStateView {
    engine::with_ref(|e| e.carousel_state())
}

/// 购买一条轮播位。失败信息形如 `carousel-cooldown` / `carousel-full` /
/// `carousel-balance` / `carousel-title` / `carousel-href`，界面按字典翻译。
pub fn submit_carousel(
    title: String,
    subtitle: String,
    kind: String,
    target_id: String,
    href: String,
    by_name: String,
) -> Result<String, String> {
    engine::with(|e| {
        e.submit_carousel(&title, &subtitle, &kind, &target_id, &href, &by_name)
    })
}

/* ------------------------- 出版社 / 赛事 ------------------------- */

pub fn publishers() -> Vec<PublisherCard> {
    engine::with_ref(|e| e.publishers())
}

/// 发布一条 `publisher.put` 就是入驻 —— 没有审核表。
/// 「已验证」是展示性标记，任何节点都能自称出版社，
/// 所以招牌挂得再大，也别当成营业执照。
pub fn put_publisher(
    name: String,
    tagline: String,
    about: String,
    genres: Vec<String>,
) -> Result<String, String> {
    engine::with(|e| e.put_publisher(&name, &tagline, &about, genres))
}

pub fn contests() -> Vec<ContestCard> {
    engine::with_ref(|e| e.contests())
}

pub fn put_contest(
    publisher_peer: String,
    theme: String,
    title: String,
    kind: String,
    tagline: String,
    rules: String,
    genre: String,
    deadline: String,
    announce_at: String,
    min_words: u64,
    max_words: u64,
    allow_ongoing: bool,
    prizes: Vec<ContestPrizeInput>,
) -> Result<String, String> {
    engine::with(|e| {
        e.put_contest(
            &publisher_peer,
            &theme,
            &title,
            &kind,
            &tagline,
            &rules,
            &genre,
            &deadline,
            &announce_at,
            min_words,
            max_words,
            allow_ongoing,
            prizes
                .into_iter()
                .map(|p| crate::domain::model::ContestPrize {
                    place: p.place,
                    coins: p.coins,
                    extras: p.extras,
                })
                .collect(),
        )
    })
}

/// 报名前先自检：给出具体差距，而不是让作者传上去之后才发现白忙一场
pub fn check_entry(contest_id: String, novel_id: String) -> EntryCheckView {
    let (ok, reason_key, need, have) = engine::with_ref(|e| e.check_entry(&contest_id, &novel_id));
    EntryCheckView { ok, reason_key, need, have }
}

pub fn submit_entry(contest_id: String, novel_id: String) -> Result<(), String> {
    engine::with(|e| e.submit_entry(&contest_id, &novel_id))
}

/// 赛事公布的名次（未公布为空）
pub fn contest_results(contest_id: String) -> Vec<ContestPlacementView> {
    engine::with_ref(|e| e.contest_results(&contest_id))
}

/// 某场赛事的报名列表（公布名次时选作品用）
pub fn contest_entries(contest_id: String) -> Vec<ContestEntryView> {
    engine::with_ref(|e| e.contest_entries(&contest_id))
}

/* ------------------------- 联邦审查：举报只改本机可见性 ------------------------- */

pub fn reports() -> Vec<ReportCard> {
    engine::with_ref(|e| e.reports())
}

/* ------------------------- 信任网（女巫抵抗） ------------------------- */

/// 我视角的信任网（分数降序，不含我自己）。分数 >= 0.5 即「圈内」。
pub fn my_trust_scores() -> Vec<TrustEntryView> {
    engine::with_ref(|e| e.my_trust_view())
}

/// 信任网统计：背书条数 / 互证边数。
pub fn attestation_stats() -> AttestationStats {
    engine::with_ref(|e| e.attestation_stats())
}

/// 给另一个身份背书。只有互相背书（互证）才进入彼此的信任网。
pub fn attest_identity(target_peer: String, note: Option<String>) -> Result<(), String> {
    engine::with(|e| e.attest_identity(&target_peer, note.as_deref()))
}

/// 举报**不能**从任何设备上删掉内容，它只改变读者本机的可见性 ——
/// 举报是拉窗帘，不是拆房子。
pub fn report_novel(
    novel_id: String,
    category: String,
    note: String,
    chapter_no: Option<u32>,
    reporter_name: Option<String>,
) -> Result<(), String> {
    engine::with(|e| e.report_novel(&novel_id, &category, &note, chapter_no, reporter_name))
}

/// 作者申辩：不取消任何举报，只是让看到警示的人同时看到作者的说法
pub fn respond_report(novel_id: String, body: String) -> Result<(), String> {
    engine::with(|e| e.respond_to_report(&novel_id, &body))
}

/// 「仍要查看」：本机豁免。豁免后再被举报需要多一票才重新屏蔽。
pub fn set_exempt(novel_id: String, exempt: bool) -> Result<(), String> {
    engine::with(|e| e.set_exempt(&novel_id, exempt))
}

/* ------------------------- 作者 ------------------------- */

pub fn profile(peer: String) -> ProfileCard {
    engine::with_ref(|e| e.profile(&peer))
}

/// 社区授予勋章：任意身份都能授予别人（不能自授）。
pub fn grant_badge(target_peer: String, badge_id: String, note: String) -> Result<(), String> {
    engine::with(|e| e.grant_badge(&target_peer, &badge_id, &note))
}

/// 零散贡献声明（校对 / 评审 / 插图 / 资料）。
pub fn put_contribution(
    novel_id: String,
    kind: String,
    items: u32,
    scope: String,
    note: String,
) -> Result<(), String> {
    engine::with(|e| e.put_contribution(&novel_id, &kind, items, &scope, &note))
}

/* ------------------------- 协作：议题 / 提案 / 贡献 ------------------------- */

pub fn issues(novel_id: String) -> Vec<IssueCard> {
    engine::with_ref(|e| e.issues(&novel_id))
}

/// 开一个议题（任何有身份的人都能开）
pub fn put_issue(novel_id: String, title: String, body: String) -> Result<String, String> {
    engine::with(|e| e.put_issue(&novel_id, &title, &body))
}

/// 关闭 / 重开议题：议题作者或作品维护者
pub fn close_issue(novel_id: String, issue_id: String, closed: bool) -> Result<(), String> {
    engine::with(|e| e.close_issue(&novel_id, &issue_id, closed))
}

pub fn patches(novel_id: String) -> Vec<PatchCard> {
    engine::with_ref(|e| e.patches(&novel_id))
}

/// 提交章节增改提案；冲突检测在读取侧按基线版本派生
pub fn put_patch(
    novel_id: String,
    title: String,
    body: String,
    chapters: Vec<PatchChapterInput>,
) -> Result<String, String> {
    let chapters = chapters
        .into_iter()
        .map(|c| crate::domain::model::PatchChapter {
            no: c.no,
            title: c.title,
            paragraphs: c.paragraphs,
            volume: c.volume,
            words: 0,
            based_on: None,
            contributor: None,
        })
        .collect();
    engine::with(|e| e.put_patch(&novel_id, &title, &body, chapters))
}

/// 整合提案：只有维护者可以；冲突不阻止人工整合（界面会先警告）
pub fn merge_patch(novel_id: String, patch_id: String, note: String) -> Result<(), String> {
    engine::with(|e| e.merge_patch(&novel_id, &patch_id, &note))
}

pub fn close_patch(novel_id: String, patch_id: String, closed: bool) -> Result<(), String> {
    engine::with(|e| e.close_patch(&novel_id, &patch_id, closed))
}

pub fn merges(novel_id: String) -> Vec<MergeCard> {
    engine::with_ref(|e| e.merges(&novel_id))
}

pub fn contributors(novel_id: String) -> Vec<ContributorCard> {
    engine::with_ref(|e| e.contributors(&novel_id))
}

/// 贡献图谱：正典按字数、翻译按字数、零散贡献平分
pub fn contribution_graph(novel_id: String) -> ContributionGraphView {
    engine::with_ref(|e| e.contribution_graph(&novel_id))
}

pub fn editor_group(novel_id: String) -> GroupCard {
    engine::with_ref(|e| e.group(&novel_id))
}

/// 给编辑组命名（只能成功一次；只有维护者可以）
pub fn rename_group(novel_id: String, name: String) -> Result<(), String> {
    engine::with(|e| e.rename_group(&novel_id, &name))
}

/* ------------------------- 出版社：交易 / 名次 ------------------------- */

pub fn deals_for_novel(novel_id: String) -> Vec<DealCard> {
    engine::with_ref(|e| e.deals_for_novel(&novel_id))
}

/// 与我有关的交易（我是作者或出版社）
pub fn my_deals() -> Vec<DealCard> {
    engine::with_ref(|e| e.my_deals())
}

/// 出版社发出改编 / 封面赞助要约（需先入驻出版社）
pub fn offer_deal(novel_id: String, kind: String, amount: i64, terms: String) -> Result<String, String> {
    engine::with(|e| e.offer_deal(&novel_id, &kind, amount, &terms))
}

pub fn respond_deal(deal_id: String, accept: bool) -> Result<(), String> {
    engine::with(|e| e.respond_deal(&deal_id, accept))
}

/// 确认付款（按贡献图谱拆账）或取消交易
pub fn settle_deal(deal_id: String, pay: bool) -> Result<(), String> {
    engine::with(|e| e.settle_deal(&deal_id, pay))
}

/// 公布赛事名次：只有主办方能公布
pub fn publish_contest_result(
    contest_id: String,
    placements: Vec<ContestPlacementInput>,
) -> Result<(), String> {
    let rows = placements
        .into_iter()
        .map(|p| (p.place, p.novel_id, p.note))
        .collect();
    engine::with(|e| e.publish_contest_result(&contest_id, rows))
}

/// 发放赛事奖金：金额取自公布时设置的奖项，只有主办方能发。
pub fn pay_contest_prize(contest_id: String, novel_id: String) -> Result<(), String> {
    engine::with(|e| e.pay_contest_prize(&contest_id, &novel_id))
}

/* ------------------------- 证书 / 衍生 / 名次 ------------------------- */

/// 作家能力证书（由他人背书，不能自授）
pub fn certificates(peer: String) -> Vec<CertificateCard> {
    engine::with_ref(|e| e.certificates(&peer))
}

pub fn put_certificate(
    target_peer: String,
    note: String,
    started_at: String,
    years_writing: f64,
    peak_work_title: String,
    peak_work_clicks: u64,
    peak_year: i32,
) -> Result<(), String> {
    engine::with(|e| {
        e.put_certificate(
            &target_peer,
            &note,
            &started_at,
            years_writing,
            &peak_work_title,
            peak_work_clicks,
            peak_year,
        )
    })
}

/// 本机可见的达成情况（只是提示，不构成审核）
pub fn certificate_eligibility(peer: String) -> CertificateEligibilityView {
    engine::with_ref(|e| e.certificate_eligibility(&peer))
}

/// 以别人的作品为源头开自己的连载（新作品 + 溯源记录）
pub fn publish_fork(
    source_id: String,
    title: String,
    synopsis: String,
    genre: String,
    tags: Vec<String>,
    status: String,
    license: String,
) -> Result<String, String> {
    engine::with(|e| {
        e.publish_fork(&source_id, &title, &synopsis, &genre, tags, &status, &license)
    })
}

pub fn awards(novel_id: String) -> Vec<AwardCard> {
    engine::with_ref(|e| e.awards(&novel_id))
}

pub fn forks_of(novel_id: String) -> Vec<ForkCard> {
    engine::with_ref(|e| e.forks_of(&novel_id))
}

pub fn fork_source(novel_id: String) -> Option<ForkCard> {
    engine::with_ref(|e| e.fork_source(&novel_id))
}

/* ------------------------- 上链 / 赞助 ------------------------- */

/// 本机账本覆盖率（节点侧额度由 Dart 侧查询 /coverage 后合并展示）
pub fn wrap_coverage() -> WrapCoverageView {
    engine::with_ref(|e| e.wrap_coverage())
}

/// 构造并签名一次申领；HTTP 提交在 Dart 侧做，签名不离开本机
pub fn build_wrap_request(amount: i64, to_address: String) -> Result<WrapRequestView, String> {
    engine::with_ref(|e| e.build_wrap_request(amount, &to_address))
}

/// 桥接节点成功铸币后固化本次上链
pub fn record_wrap(
    amount: i64,
    op_ids: Vec<String>,
    to_address: String,
    chain_id: u64,
    tx_hash: String,
    onchain_id: String,
) -> Result<(), String> {
    engine::with(|e| {
        e.record_wrap(amount, op_ids, &to_address, chain_id, &tx_hash, &onchain_id)
    })
}

pub fn wrap_records() -> Vec<WrapCard> {
    engine::with_ref(|e| e.wrap_cards())
}

/// 赞助方式（默认全空 -> 界面显示待配置，不生成假收款码）
pub fn sponsor_methods() -> Vec<SponsorMethodView> {
    engine::with_ref(|e| e.sponsor_methods())
}

/* ------------------------- 设置与主题 ------------------------- */

pub fn settings() -> Settings {
    engine::with_ref(|e| e.settings.clone())
}

pub fn update_settings(next: Settings) -> Result<(), String> {
    engine::with(|e| {
        let turned_on = !e.settings.auto_merge && next.auto_merge;
        e.settings = next;
        e.save_settings()?;
        // 与 Web 一致：打开开关时立即处理已经收到的无冲突提案。
        if turned_on {
            e.auto_merge_now();
        }
        Ok(())
    })
}

/// 整套设计令牌由「色相 + 饱和度」推导，明暗两套各自协调
pub fn palette() -> Palette {
    engine::with_ref(|e| e.palette())
}

/* ------------------------- 网络与运维：断网也能本地读写 ------------------------- */

pub fn stats() -> NodeStats {
    engine::with_ref(|e| e.stats())
}

/// 启动监听与后台对账。port = 0 表示让系统分配。
pub fn start_network(port: u16, peers: Vec<String>) -> Result<u32, String> {
    engine::with(|e| e.start_network(port, peers).map(|p| p as u32))
}

pub fn sync_now(addr: String) -> Result<u64, String> {
    engine::with(|e| e.sync_with(&addr).map(|n| n as u64))
}

pub fn add_peer(addr: String) {
    engine::with(|e| e.add_peer(&addr))
}

/// 立刻跑一轮 DHT 发现（网络页「重试」按钮）。
pub fn retry_discovery() {
    engine::with_ref(|e| e.retry_discovery())
}

/// 把后台线程收到的 op 归约进本机视图。界面空闲时轮询即可。
pub fn pump() -> u64 {
    engine::with(|e| e.pump() as u64)
}

pub fn trim_oplog(keep: usize) -> Result<u64, String> {
    engine::with(|e| e.trim(keep).map(|n| n as u64))
}

pub fn wipe_all() -> Result<(), String> {
    engine::with(|e| e.wipe())
}

/// 尚未封装成语义方法的操作走这里（kind 用 `novel.put` 这类字面量）
pub fn submit_raw(kind: String, key: String, body_json: String) -> Result<String, String> {
    engine::with(|e| e.submit_raw(&kind, &key, &body_json))
}

/* ------------------------- 自检 ------------------------- */

/// 启动时跑一遍：规范化载荷的金标准向量、许可证登记表。
/// 为空数组表示通过。涉及钱与签名的东西不该只能靠点界面来验证 ——
/// 手速再快，也快不过回归测试。
pub fn self_check() -> Vec<String> {
    crate::self_check()
}

pub fn now_millis() -> u64 {
    engine::now_ms()
}