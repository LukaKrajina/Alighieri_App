//! 站点配置 + 排序 / 检索 / 榜单（纯函数）
//! --------------------------------------
//! ⚠️ 这里**没有预置作品**。
//!
//! 站内每一本小说都由某位读者自己发布，署名是他的身份。
//! 没有任何「示例书单」—— 首页空着不代表功能坏了，只是还没人开写。
//! 在有人投稿之前，这里确实是空的，这是真实状态，不是还没做完。
//!
//! 本文件只保留两类东西：
//!   1. 站点级配置（分类表、连载状态、榜单周期）
//!   2. 纯函数（排序、检索、热度排名），跑在本机副本算出的卡片上

use crate::domain::view::NovelCard;

pub struct GenreDef {
    pub slug: &'static str,
    /// 回落到中文的字面量，只在字典缺键时用
    pub name: &'static str,
    pub desc: &'static str,
}

/// 分类表。
///
/// `name` / `desc` 是回落字面量，界面一律走 `genre.<slug>` 字典键。
/// 两套都留着是因为本文件是纯数据、不碰界面，
/// `get_genre_name()` 也得对未知 slug 有个不崩的返回值 —— 分类可以没见过，界面不能。
pub const GENRES: [GenreDef; 12] = [
    GenreDef { slug: "isekai", name: "异世界", desc: "转生・转移・召唤" },
    GenreDef { slug: "fantasy", name: "奇幻", desc: "剑与魔法・精灵・龙" },
    GenreDef { slug: "romance", name: "恋爱", desc: "甜宠・虐恋・修罗场" },
    GenreDef { slug: "scifi", name: "科幻", desc: "赛博・宇宙・未来" },
    GenreDef { slug: "mystery", name: "推理", desc: "悬疑・本格・反转" },
    GenreDef { slug: "horror", name: "恐怖", desc: "怪谈・诅咒・都市传说" },
    GenreDef { slug: "school", name: "校园", desc: "青春・社团・考试" },
    GenreDef { slug: "game", name: "游戏", desc: "VRMMO・穿越・满级" },
    GenreDef { slug: "history", name: "历史", desc: "战国・幕末・架空" },
    GenreDef { slug: "battle", name: "战斗", desc: "热血・英雄・魔王" },
    GenreDef { slug: "daily", name: "日常", desc: "慢活・治愈・群像" },
    GenreDef { slug: "cooking", name: "料理", desc: "美食・食堂・开店" },
];

pub fn get_genre_name(slug: &str) -> &'static str {
    GENRES.iter().find(|g| g.slug == slug).map(|g| g.name).unwrap_or("全部")
}

pub fn get_genre_desc(slug: &str) -> &'static str {
    GENRES.iter().find(|g| g.slug == slug).map(|g| g.desc).unwrap_or("")
}

/// 「没有卷」时使用的哨兵值。
///
/// 卷名是作者写的，属于内容，不翻译；但「作者没分卷」这个状态是界面概念，
/// 要按语言显示。所以未分卷的章节必须存这个哨兵，由目录页翻译它 ——
/// **不能**把「正文」这样的中文词直接写进记录。
pub const DEFAULT_VOLUME_KEY: &str = "__unvolumed__";

/* ------------------------- 排序 ------------------------- */

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SortKey {
    Update,
    Episodes,
    Words,
    New,
    Author,
}

impl SortKey {
    pub fn parse(s: &str) -> Self {
        match s {
            "episodes" => SortKey::Episodes,
            "words" => SortKey::Words,
            "new" => SortKey::New,
            "author" => SortKey::Author,
            _ => SortKey::Update,
        }
    }
    pub fn as_str(&self) -> &'static str {
        match self {
            SortKey::Update => "update",
            SortKey::Episodes => "episodes",
            SortKey::Words => "words",
            SortKey::New => "new",
            SortKey::Author => "author",
        }
    }
}

pub fn sort_novels(list: &mut [NovelCard], sort: SortKey) {
    match sort {
        SortKey::Episodes => list.sort_by(|a, b| b.episodes.cmp(&a.episodes).then(a.id.cmp(&b.id))),
        SortKey::Words => list.sort_by(|a, b| b.words.cmp(&a.words).then(a.id.cmp(&b.id))),
        SortKey::New => list.sort_by(|a, b| {
            a.first_published_at
                .cmp(&b.first_published_at)
                .then(a.id.cmp(&b.id))
        }),
        SortKey::Author => list.sort_by(|a, b| a.author_name.cmp(&b.author_name).then(a.id.cmp(&b.id))),
        SortKey::Update => list.sort_by(|a, b| {
            b.updated_at
                .cmp(&a.updated_at)
                .then(a.id.cmp(&b.id))
        }),
    }
}

/* ------------------------- 检索 ------------------------- */

pub struct SearchParams {
    pub q: String,
    pub genre: String,
    pub status: String,
    pub tag: String,
    pub sort: SortKey,
}

impl Default for SearchParams {
    fn default() -> Self {
        SearchParams {
            q: String::new(),
            genre: String::new(),
            status: String::new(),
            tag: String::new(),
            sort: SortKey::Update,
        }
    }
}

pub fn search_novels(list: &[NovelCard], p: &SearchParams) -> Vec<NovelCard> {
    let q = p.q.trim().to_lowercase();
    let mut out: Vec<NovelCard> = list
        .iter()
        .filter(|n| {
            if !p.genre.is_empty() && p.genre != "all" && n.genre != p.genre {
                return false;
            }
            if !p.status.is_empty() && p.status != "all" && n.status != p.status {
                return false;
            }
            if !p.tag.is_empty() && !n.tags.iter().any(|t| t == &p.tag) {
                return false;
            }
            if !q.is_empty() {
                let hay = format!(
                    "{} {} {} {}",
                    n.title,
                    n.author_name,
                    n.synopsis,
                    n.tags.join(" ")
                )
                .to_lowercase();
                if !hay.contains(&q) {
                    return false;
                }
            }
            true
        })
        .cloned()
        .collect();
    sort_novels(&mut out, p.sort);
    out
}

/* ------------------------- 榜单 ------------------------- */

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RankingPeriod {
    Daily,
    Weekly,
    Monthly,
    Quarter,
    Total,
}

impl RankingPeriod {
    pub fn parse(s: &str) -> Self {
        match s {
            "daily" => RankingPeriod::Daily,
            "weekly" => RankingPeriod::Weekly,
            "monthly" => RankingPeriod::Monthly,
            "quarter" => RankingPeriod::Quarter,
            _ => RankingPeriod::Total,
        }
    }
    pub fn as_str(&self) -> &'static str {
        match self {
            RankingPeriod::Daily => "daily",
            RankingPeriod::Weekly => "weekly",
            RankingPeriod::Monthly => "monthly",
            RankingPeriod::Quarter => "quarter",
            RankingPeriod::Total => "total",
        }
    }
    /// 半衰期（毫秒）；total 为无限
    pub fn half_life(&self) -> f64 {
        match self {
            RankingPeriod::Daily => 86_400_000.0,
            RankingPeriod::Weekly => 7.0 * 86_400_000.0,
            RankingPeriod::Monthly => 30.0 * 86_400_000.0,
            RankingPeriod::Quarter => 90.0 * 86_400_000.0,
            RankingPeriod::Total => f64::INFINITY,
        }
    }
    /// 字典键（「日榜 / 24小时」是界面标签，要在五种语言下显示）
    pub fn label_key(&self) -> String {
        format!("rank.period.{}", self.as_str())
    }
}

pub const RANKING_PERIODS: [RankingPeriod; 5] = [
    RankingPeriod::Daily,
    RankingPeriod::Weekly,
    RankingPeriod::Monthly,
    RankingPeriod::Quarter,
    RankingPeriod::Total,
];

/// 热度排序。
///
/// 只排「你这台设备收到的内容」，不做跨节点聚合 ——
/// 所以它是「你看到的网络里的热度」，不是全网真实热度。
/// 界面上必须照这个意思措辞，否则就等于撒了一个随时会被证伪的谎。
pub fn rank_novels(list: &[NovelCard], period: RankingPeriod, now_ms: u64) -> Vec<NovelCard> {
    let half_life = period.half_life();
    let score = |n: &NovelCard| -> f64 {
        let eps = if n.episodes == 0 { 1.0 } else { n.episodes as f64 };
        if half_life.is_infinite() {
            return eps;
        }
        let age = if n.updated_at_ms > 0 && now_ms > n.updated_at_ms {
            (now_ms - n.updated_at_ms) as f64
        } else {
            0.0
        };
        let freshness = 0.5f64.powf(age / half_life);
        eps * (0.35 + 0.65 * freshness) + n.words as f64 / 200_000.0
    };
    let mut out: Vec<NovelCard> = list.to_vec();
    for n in out.iter_mut() {
        n.score = score(n);
    }
    out.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.id.cmp(&b.id))
    });
    for (i, n) in out.iter_mut().enumerate() {
        n.rank = (i as u32) + 1;
    }
    out
}

/* ------------------------- 工具 ------------------------- */

/// 从简介提取一句话，用作卡片上的醒目语
pub fn first_sentence(s: &str) -> String {
    let flat: String = s.split_whitespace().collect::<Vec<_>>().join(" ");
    let flat = flat.trim();
    if flat.is_empty() {
        return String::new();
    }
    // 取到第一个句末标点（中英文都认）
    for (i, c) in flat.char_indices() {
        if i >= 90 {
            break;
        }
        if matches!(c, '。' | '！' | '？' | '!' | '?' | '．') {
            // 句末标点本身要保留：用字符长度而不是字节下标，否则会切在 UTF-8 中间
            let end = i + c.len_utf8();
            return flat[..end].trim().to_string();
        }
    }
    flat.chars().take(92).collect::<String>().trim().to_string()
}

/// 字数统计：与 Web 版一致，去掉空白后数字
pub fn count_words(paragraphs: &[String]) -> u64 {
    paragraphs
        .join("")
        .chars()
        .filter(|c| !c.is_whitespace())
        .count() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn card(id: &str, title: &str, eps: u32, words: u64, updated: u64) -> NovelCard {
        NovelCard {
            id: id.into(),
            title: title.into(),
            episodes: eps,
            words,
            updated_at_ms: updated,
            ..Default::default()
        }
    }

    #[test]
    fn first_sentence_stops_at_punctuation() {
        assert_eq!(first_sentence("第一句。第二句。"), "第一句。");
        // 没有标点就按 92 个字符截断（注意是字符数，不是字节数）
        assert_eq!(
            first_sentence(&"没有标点的很长的一句话".repeat(10)).chars().count(),
            92
        );
        assert_eq!(first_sentence(""), "");
    }

    #[test]
    fn ranking_favours_recent_activity() {
        let now = 100 * 86_400_000u64;
        // 话数相同：这时决定名次的只有新旧（0.35 的地板分意味着大部头不会被时间拉下来）
        let list = vec![
            card("a", "旧作", 10, 1000, now - 80 * 86_400_000),
            card("b", "新作", 10, 1000, now - 86_400_000),
        ];
        let ranked = rank_novels(&list, RankingPeriod::Weekly, now);
        assert_eq!(ranked[0].id, "b", "一周半衰期下，最近更新的应当靠前");
        assert_eq!(ranked[0].rank, 1);
        // 总榜不看时间
        let total = rank_novels(&list, RankingPeriod::Total, now);
        assert_eq!(total[0].id, "a");
    }

    #[test]
    fn ranking_is_deterministic_for_equal_scores() {
        let now = 5u64;
        let list = vec![
            card("z", "Z", 1, 1, now),
            card("a", "A", 1, 1, now),
            card("m", "M", 1, 1, now),
        ];
        let r1 = rank_novels(&list, RankingPeriod::Total, now);
        let r2 = rank_novels(&list, RankingPeriod::Total, now);
        let ids1: Vec<_> = r1.iter().map(|c| c.id.clone()).collect();
        let ids2: Vec<_> = r2.iter().map(|c| c.id.clone()).collect();
        assert_eq!(ids1, ids2);
        // 同分时按 id 字典序，而不是碰巧的插入顺序
        assert_eq!(ids1, vec!["a", "m", "z"]);
    }

    #[test]
    fn search_filters_and_sorts() {
        let mut list = vec![
            card("n1", "异世界的猫", 5, 1000, 300),
            card("n2", "校园的猫", 50, 9000, 100),
        ];
        list[0].genre = "isekai".into();
        list[1].genre = "school".into();
        let found = search_novels(
            &list,
            &SearchParams {
                q: "猫".into(),
                genre: "isekai".into(),
                ..Default::default()
            },
        );
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].id, "n1");
    }
}
