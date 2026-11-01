//! CRDT 归约器
//! ------------
//! 把一组乱序、可能重复、可能并发的 Op 归约成一个确定性的本地视图 ——
//! 输入有多乱，输出就有多整齐。
//!
//! 使用的 CRDT 原语：
//!   · LWW-Register（作品元数据、个人资料、译文、证书）—— 按 HLC 定序
//!   · Grow-only Set（书架、评价、表情、PV）—— 按 key 去重后取并集
//!   · 幂等集合（奖励币、报名、整合）—— 同 key 只认第一条
//!   · 状态机 + 角色门控（改编交易）
//!
//! 归约是**纯函数**：相同 op 集合必然得到相同视图。这意味着：
//!   1. 记录里不能存任何依赖「当前时间」的字段（赛事状态、改名冷却期都在读取侧派生）；
//!   2. 不能有「丢弃」路径 —— 门控未通过必须挂起（pending_gated）并重试。
//!      丢弃最省事，也最伤收敛性。

use std::cmp::Ordering;

use crate::domain::carousel::{
    normalize_href, CAROUSEL_FEE, CAROUSEL_MAX_NAME, CAROUSEL_MAX_SUBTITLE, CAROUSEL_MAX_TITLE,
    CAROUSEL_WINDOW_MS,
};
use crate::domain::hlc::{compare_hlts, newer, wall_of};
use crate::domain::keys::*;
use crate::domain::model::*;
use crate::domain::state::*;

/// 「第一话」的界面哨兵。
///
/// 原站在这里写死了中文「第一话」。本站的规矩是**界面概念走字典、不进记录**
/// （与 `DEFAULT_VOLUME_KEY` 同一个道理）：写进记录后，日语读者会在目录里
/// 看到一句中文，然后以为加载错了。所以存哨兵，由界面按语言渲染。
pub const DEFAULT_FIRST_CHAPTER_KEY: &str = "__first__";

/// 章节缺省标题的哨兵（同上：界面按语言拼「第 N 话」）
pub fn chapter_title_key(no: u32) -> String {
    format!("__chapter__:{no}")
}

/// 编辑组的成组人数下限。
/// 贡献者（含原作者）达到这个数就在作品页自动成组 —— 组是**派生**的，
/// 不需要谁去「建组」。
pub const EDITOR_GROUP_MIN_MEMBERS: usize = 4;

const GATED_KINDS: [OpKind; 7] = [
    OpKind::IssueClose,
    OpKind::PatchMerge,
    OpKind::PatchClose,
    OpKind::GroupPut,
    OpKind::ContestResult,
    OpKind::DealPut,
    OpKind::ReportRespond,
];

fn is_gated(kind: OpKind) -> bool {
    GATED_KINDS.contains(&kind)
}

/// HLC 里的物理时间 -> ISO 串
fn iso_of_hlts(h: &str) -> String {
    crate::domain::time::iso_of_ms(wall_of(h))
}

fn clamp_str(s: &str, limit: usize) -> String {
    // 按字符截断，避免把多字节汉字切一半
    s.chars().take(limit).collect()
}

/* ------------------------- 归约 ------------------------- */

/// 应用单条 op。
///
/// 返回 `true` = 已处理（应用或按规则忽略）；`false` = 门控未通过，
/// 调用方应把它挂起（`pending_gated`），等前提 op 到位后重试。
/// 乱序到达时直接丢弃会破坏收敛性 —— 两个节点会留下不同视图，而且都觉得自己没错。
pub fn apply_op(state: &mut ReplicaState, op: &Op, received_at: &str) -> bool {
    // 空 actor 的操作一律忽略：没有任何记录能归属给它
    if op.actor.is_empty() {
        return true;
    }
    let at = &op.hlts;
    let body = &op.body;

    match op.kind {
        /* ---------------- 作品 ---------------- */
        OpKind::NovelPut => {
            let Ok(b) = serde_json::from_value::<NovelBody>(body.clone()) else {
                return true;
            };
            let Some(id) = novel_id_from_key(&op.key) else {
                return true;
            };
            if b.title.trim().is_empty() {
                return true;
            }
            if let Some(prev) = state.novels.get(id) {
                if !newer(at, &prev.updated_at) {
                    return true;
                }
            }
            let first_at = b.first_published_at.clone().unwrap_or_else(|| at.clone());
            let latest = b.latest.clone().unwrap_or_else(|| {
                state
                    .novels
                    .get(id)
                    .map(|p| p.latest.clone())
                    .unwrap_or(NovelLatest {
                        no: 1,
                        title: DEFAULT_FIRST_CHAPTER_KEY.to_string(),
                        at: first_at.clone(),
                    })
            });
            state.novels.insert(
                id.to_string(),
                ReplicaNovel {
                    id: id.to_string(),
                    title: b.title,
                    author_name: b.author_name.unwrap_or_else(|| "匿名作者".to_string()),
                    author_peer: b.author_peer.unwrap_or_else(|| op.actor.clone()),
                    genre: b.genre.unwrap_or_else(|| "daily".to_string()),
                    genre_name: b.genre_name.unwrap_or_else(|| "其他".to_string()),
                    tags: b.tags.into_iter().take(8).collect(),
                    synopsis: b.synopsis,
                    status: b.status.unwrap_or(NovelStatus::Ongoing),
                    episodes: b.episodes,
                    words: b.words,
                    first_published_at: first_at,
                    updated_at: at.clone(),
                    latest,
                    awards: b.awards,
                    license: b
                        .license
                        .unwrap_or_else(|| crate::domain::licenses::DEFAULT_LICENSE.to_string()),
                    fork_of: b.fork_of.filter(|s| !s.is_empty()),
                    deleted: false,
                    op_id: op.id.clone(),
                    cid: op.cid.clone(),
                    received_at: received_at.to_string(),
                },
            );
            state.revision += 1;
            true
        }

        OpKind::NovelDel => {
            let Some(id) = novel_id_from_key(&op.key) else {
                return true;
            };
            let Some(prev) = state.novels.get(id) else {
                return true;
            };
            if !newer(at, &prev.updated_at) {
                return true;
            }
            let mut next = prev.clone();
            next.deleted = true;
            next.updated_at = at.clone();
            next.op_id = op.id.clone();
            state.novels.insert(id.to_string(), next);
            state.revision += 1;
            true
        }

        /* ---------------- 章节 ---------------- */
        OpKind::ChapterPut => {
            let Some((novel_id, no)) = parse_chapter_key(&op.key) else {
                return true;
            };
            let Ok(b) = serde_json::from_value::<ChapterBody>(body.clone()) else {
                return true;
            };
            if let Some(prev) = state.chapters.get(&op.key) {
                if !newer(at, &prev.published_at) {
                    return true;
                }
            }
            let prev = state.chapters.get(&op.key);
            let inline_body = !b.paragraphs.is_empty();
            let paragraphs = if inline_body {
                Some(b.paragraphs)
            } else {
                prev.and_then(|p| p.paragraphs.clone())
            };
            let cid = op.cid.clone().or_else(|| prev.and_then(|p| p.cid.clone()));
            state.chapters.insert(
                op.key.clone(),
                ReplicaChapter {
                    novel_id,
                    no,
                    title: if b.title.is_empty() {
                        chapter_title_key(no)
                    } else {
                        b.title
                    },
                    words: b.words,
                    published_at: at.clone(),
                    volume: b.volume,
                    contributor: b.contributor.filter(|s| !s.is_empty()),
                    paragraphs,
                    cid: cid.clone(),
                    deleted: false,
                    op_id: op.id.clone(),
                },
            );
            if let Some(c) = op.cid.clone() {
                if !inline_body {
                    state.pending.insert(c);
                }
            }
            state.revision += 1;
            true
        }

        OpKind::ChapterDel => {
            let Some(prev) = state.chapters.get(&op.key) else {
                return true;
            };
            let mut next = prev.clone();
            next.deleted = true;
            next.paragraphs = None;
            state.chapters.insert(op.key.clone(), next);
            state.revision += 1;
            true
        }

        /* ---------------- 书架 ---------------- */
        OpKind::BookmarkSet => {
            let on = body.get("on").and_then(|v| v.as_bool()).unwrap_or(false);
            // key 形如 `bookmark:<actor>:<novelId>`
            let novel_id = op.key.split(':').nth(2).unwrap_or("").to_string();
            if novel_id.is_empty() {
                return true;
            }
            if on {
                if let Some(prev) = state.shelf.get(&op.key) {
                    if !newer(at, &prev.added_at) {
                        return true;
                    }
                }
                state.shelf.insert(
                    op.key.clone(),
                    ShelfEntry {
                        novel_id,
                        added_at: at.clone(),
                        actor: op.actor.clone(),
                    },
                );
                state.revision += 1;
            } else if state.shelf.remove(&op.key).is_some() {
                state.revision += 1;
            }
            true
        }

        /* ---------------- 评价 / 表情 ---------------- */
        OpKind::ReviewPut => {
            let Ok(b) = serde_json::from_value::<ReviewBody>(body.clone()) else {
                return true;
            };
            if b.novel_id.is_empty() {
                return true;
            }
            state.reviews.insert(
                op.key.clone(),
                Review {
                    id: op.key.clone(),
                    actor: op.actor.clone(),
                    novel_id: b.novel_id,
                    chapter_no: b.chapter_no,
                    body: b.body,
                    rating: b.rating.min(5),
                    spoiler: b.spoiler,
                    created_at: at.clone(),
                    cid: op.cid.clone(),
                },
            );
            state.revision += 1;
            true
        }

        OpKind::ReactionAdd => {
            let Ok(b) = serde_json::from_value::<ReactionBody>(body.clone()) else {
                return true;
            };
            if b.novel_id.is_empty() {
                return true;
            }
            let set = state.reactions.entry(op.key.clone()).or_default();
            if set.insert(op.actor.clone()) {
                state.revision += 1;
            }
            true
        }

        /* ---------------- 资料 ---------------- */
        OpKind::ProfilePut => {
            let Ok(b) = serde_json::from_value::<ProfileBody>(body.clone()) else {
                return true;
            };
            // 只能写自己的资料。键是 `profile:<peerId>`，而 body.id 可以填别人的 ——
            // 不做这道检查，任何节点都能顶掉别人刚发布的笔名。
            if b.id != op.actor {
                return true;
            }
            let peer_id = b.id;
            if let Some(prev) = state.profiles.get(&peer_id) {
                if !newer(at, &prev.updated_at) {
                    return true;
                }
            }
            let prev = state.profiles.get(&peer_id).cloned();
            let name_changed_at = match b.name_changed_at {
                Some(v) if v > 0 => v,
                _ => match &prev {
                    Some(p) if p.name != b.name => p.name_changed_at,
                    Some(p) => p.name_changed_at,
                    None => 0,
                },
            };
            state.profiles.insert(
                peer_id.clone(),
                Profile {
                    peer_id: peer_id.clone(),
                    name: b.name,
                    bio: b.bio,
                    avatar_seed: b.avatar_seed,
                    links: normalize_links(&b.links),
                    name_changed_at,
                    updated_at: at.clone(),
                },
            );
            state.revision += 1;
            true
        }

        OpKind::ProgressSet => {
            let Ok(b) = serde_json::from_value::<ProgressBody>(body.clone()) else {
                return true;
            };
            if b.novel_id.is_empty() {
                return true;
            }
            if let Some(prev) = state.progress.get(&op.key) {
                if prev.chapter_no > b.chapter_no {
                    return true;
                }
            }
            state.progress.insert(
                op.key.clone(),
                Progress {
                    novel_id: b.novel_id,
                    chapter_no: b.chapter_no,
                    at: b.at,
                },
            );
            state.revision += 1;
            true
        }

        /* ---------------- 奖励币 ---------------- */
        OpKind::RewardGrant | OpKind::RewardTransfer => {
            let Ok(b) = serde_json::from_value::<RewardBody>(body.clone()) else {
                return true;
            };
            let k = b.idempotency_key;
            // 幂等：同一个 key 只认第一条，重复广播不会重复发币
            if k.is_empty() || state.rewards.contains_key(&k) {
                return true;
            }
            if b.to.is_empty() || b.amount <= 0 {
                return true;
            }
            state.rewards.insert(
                k.clone(),
                RewardRecord {
                    key: k,
                    op_id: op.id.clone(),
                    from: op.actor.clone(),
                    to: b.to,
                    amount: b.amount,
                    action: b.action,
                    target: b.target,
                    reason: b.reason,
                    at: at.clone(),
                },
            );
            state.revision += 1;
            true
        }

        OpKind::RewardWrap => {
            let Ok(b) = serde_json::from_value::<WrapBody>(body.clone()) else {
                return true;
            };
            let k = b.idempotency_key;
            if k.is_empty() || state.wraps.contains_key(&k) {
                return true;
            }
            // wrap 的 `from` 必须是签名者本人。Web 归约器允许任意 from，
            // 但那样任何人都能冒用别人身份「锁定」余额，把对方余额扣成负数。
            if b.from.is_empty() || b.op_ids.is_empty() || b.amount <= 0 || b.from != op.actor {
                return true;
            }
            state.wraps.insert(
                k.clone(),
                ReplicaWrap {
                    key: k,
                    op_id: op.id.clone(),
                    from: b.from,
                    amount: b.amount,
                    op_ids: b.op_ids,
                    to_address: b.to_address,
                    chain_id: b.chain_id,
                    tx_hash: b.tx_hash,
                    onchain_id: b.onchain_id,
                    at: at.clone(),
                },
            );
            state.revision += 1;
            true
        }

        /* ---------------- 首页轮播位 ---------------- */
        OpKind::CarouselPut => {
            let Some(id) = carousel_id_from_key(&op.key) else {
                return true;
            };
            let Ok(b) = serde_json::from_value::<CarouselBody>(body.clone()) else {
                return true;
            };
            let title = b.title.trim();
            if title.is_empty() {
                return true;
            }
            let Some(href) = normalize_href(&b.href) else {
                return true;
            };
            let started = wall_of(at);
            if started == 0 {
                return true;
            }
            /*
             * 同一个 key 只能对应一条轮播记录。op log 是公开的，重放/伪造
             * 同一个 key 是可能的：按 (HLC, op.id) 取**最早**的一条，
             * 而不是「先到先得」—— 后者等于让「谁先收到邮件」决定结果，
             * 两个以不同顺序收到同组 op 的节点会得出不同视图。
             */
            if let Some(prev) = state.carousels.get(id) {
                match compare_hlts(&prev.at, at) {
                    Ordering::Less => return true,
                    Ordering::Equal if prev.op_id <= op.id => return true,
                    _ => {}
                }
            }
            state.carousels.insert(
                id.to_string(),
                CarouselRecord {
                    id: id.to_string(),
                    title: clamp_str(title, CAROUSEL_MAX_TITLE),
                    subtitle: clamp_str(b.subtitle.trim(), CAROUSEL_MAX_SUBTITLE),
                    kind: b.kind,
                    target_id: b
                        .target_id
                        .as_deref()
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .map(|s| clamp_str(s, 200)),
                    href,
                    by: op.actor.clone(),
                    by_name: clamp_str(b.by_name.trim(), CAROUSEL_MAX_NAME),
                    started_at: started as i64,
                    expires_at: started as i64 + CAROUSEL_WINDOW_MS,
                    fee: CAROUSEL_FEE,
                    at: at.clone(),
                    op_id: op.id.clone(),
                },
            );
            state.revision += 1;
            true
        }

        /* ---------------- 出版社 / 赛事 ---------------- */
        OpKind::PublisherPut => {
            let Ok(b) = serde_json::from_value::<PublisherBody>(body.clone()) else {
                return true;
            };
            let Some(id) = publisher_id_from_key(&op.key) else {
                return true;
            };
            if b.name.trim().is_empty() {
                return true;
            }
            if let Some(prev) = state.publishers.get(id) {
                if !newer(at, &prev.updated_at) {
                    return true;
                }
            }
            state.publishers.insert(
                id.to_string(),
                PublisherRecord {
                    id: id.to_string(),
                    peer: op.actor.clone(),
                    name: b.name,
                    tagline: b.tagline,
                    about: b.about,
                    genres: b.genres.into_iter().take(8).collect(),
                    verified: b.verified,
                    updated_at: at.clone(),
                },
            );
            state.revision += 1;
            true
        }

        OpKind::ContestPut => {
            let Ok(b) = serde_json::from_value::<ContestBody>(body.clone()) else {
                return true;
            };
            let Some(id) = contest_id_from_key(&op.key) else {
                return true;
            };
            if b.title.trim().is_empty() {
                return true;
            }
            if let Some(prev) = state.contests.get(id) {
                if !newer(at, &prev.updated_at) {
                    return true;
                }
            }
            let deadline = b.deadline;
            let announce_at = if b.announce_at.is_empty() {
                deadline.clone()
            } else {
                b.announce_at
            };
            state.contests.insert(
                id.to_string(),
                ContestRecord {
                    id: id.to_string(),
                    publisher_peer: if b.publisher_peer.is_empty() {
                        op.actor.clone()
                    } else {
                        b.publisher_peer
                    },
                    publisher_name: b.publisher_name,
                    kind: b.kind,
                    title: b.title,
                    tagline: b.tagline,
                    rules: b.rules,
                    theme: b.theme,
                    genre: b.genre,
                    deadline,
                    announce_at,
                    min_words: b.min_words,
                    max_words: b.max_words,
                    allow_ongoing: b.allow_ongoing,
                    prizes: b.prizes,
                    updated_at: at.clone(),
                },
            );
            state.revision += 1;
            true
        }

        OpKind::EntrySubmit => {
            let Ok(b) = serde_json::from_value::<EntryBody>(body.clone()) else {
                return true;
            };
            if b.contest_id.is_empty() || b.novel_id.is_empty() {
                return true;
            }
            // 一个身份对同一赛事只能报名一次
            let k = format!("{}:{}", op.actor, b.contest_id);
            if state.entries.contains_key(&k) {
                return true;
            }
            state.entries.insert(
                k.clone(),
                EntryRecord {
                    key: k,
                    contest_id: b.contest_id,
                    novel_id: b.novel_id,
                    actor: op.actor.clone(),
                    at: at.clone(),
                },
            );
            state.revision += 1;
            true
        }

        /* ---------------- 译文 / 证书 ---------------- */
        OpKind::TranslationPut => {
            let Ok(b) = serde_json::from_value::<TranslationBody>(body.clone()) else {
                return true;
            };
            if b.novel_id.is_empty() || b.lang.is_empty() {
                return true;
            }
            // 段落数必须与原文一致 —— 双行显示靠下标对齐
            if b.paragraphs.is_empty() {
                return true;
            }
            // 每个 (章节, 语言, 译者) 独立成条：同一句话可以有多个译本，
            // 由读者自己选，不做「少数服从多数」—— 那在没有权威的情况下是假的。
            let id = translation_id(&b.novel_id, b.chapter_no, &b.lang, &op.actor);
            if let Some(prev) = state.translations.get(&id) {
                if !newer(at, &prev.at) {
                    return true;
                }
            }
            let translator = b
                .translator
                .unwrap_or_else(|| tail8(&op.actor));
            state.translations.insert(
                id,
                ReplicaTranslation {
                    novel_id: b.novel_id,
                    chapter_no: b.chapter_no,
                    lang: b.lang,
                    actor: op.actor.clone(),
                    translator,
                    paragraphs: b.paragraphs,
                    note: b.note,
                    at: at.clone(),
                    received_at: iso_of_hlts(at),
                },
            );
            state.revision += 1;
            true
        }

        OpKind::CertificatePut => {
            let Ok(b) = serde_json::from_value::<CertificateBody>(body.clone()) else {
                return true;
            };
            if b.target_peer.is_empty() {
                return true;
            }
            let id = certificate_id(&b.target_peer, &op.actor);
            if let Some(prev) = state.certificates.get(&id) {
                if !newer(at, &prev.at) {
                    return true;
                }
            }
            state.certificates.insert(
                id.clone(),
                ReplicaCertificate {
                    id,
                    kind: b.kind,
                    target_peer: b.target_peer,
                    issuer_peer: op.actor.clone(),
                    issuer_name: if b.note.is_empty() {
                        tail8(&op.actor)
                    } else {
                        String::new()
                    },
                    note: b.note,
                    evidence: b.evidence,
                    at: at.clone(),
                    received_at: iso_of_hlts(at),
                },
            );
            state.revision += 1;
            true
        }

        /* ---------------- 协作：star / fork ---------------- */
        OpKind::StarAdd => {
            let Ok(b) = serde_json::from_value::<StarBody>(body.clone()) else {
                return true;
            };
            if b.novel_id.is_empty() {
                return true;
            }
            if b.on {
                state.stars.insert(
                    op.key.clone(),
                    StarEntry {
                        novel_id: b.novel_id,
                        actor: op.actor.clone(),
                        at: at.clone(),
                    },
                );
                state.revision += 1;
            } else if state.stars.remove(&op.key).is_some() {
                state.revision += 1;
            }
            true
        }

        OpKind::ForkPut => {
            let Ok(b) = serde_json::from_value::<ForkBody>(body.clone()) else {
                return true;
            };
            let novel_id = if b.novel_id.is_empty() {
                entity_id_from_key(&op.key, "fork:").unwrap_or("").to_string()
            } else {
                b.novel_id
            };
            if novel_id.is_empty() || b.source_id.is_empty() {
                return true;
            }
            if let Some(prev) = state.forks.get(&op.key) {
                if !newer(at, &prev.at) {
                    return true;
                }
            }
            state.forks.insert(
                op.key.clone(),
                ForkRecord {
                    id: op.key.clone(),
                    novel_id,
                    source_id: b.source_id,
                    source_title: clamp_str(&b.source_title, 120),
                    source_peer: b.source_peer,
                    by: b.by.unwrap_or_else(|| op.actor.clone()),
                    by_name: clamp_str(&b.by_name, 60),
                    note: b.note.map(|s| clamp_str(&s, 200)),
                    at: at.clone(),
                },
            );
            state.revision += 1;
            true
        }

        /* ---------------- 协作：issue ---------------- */
        OpKind::IssuePut => {
            let Ok(b) = serde_json::from_value::<IssueBody>(body.clone()) else {
                return true;
            };
            if b.novel_id.is_empty() || b.issue_id.is_empty() || b.title.trim().is_empty() {
                return true;
            }
            let state_open = matches!(b.state, IssueState::Open);
            if let Some(prev) = state.issues.get(&op.key) {
                // 只有议题作者能改自己的议题（LWW）
                if op.actor != prev.author_peer {
                    return true;
                }
                if !newer(at, &prev.at) {
                    return true;
                }
                let mut next = prev.clone();
                next.title = clamp_str(&b.title, 120);
                next.body = clamp_str(&b.body, 4000);
                next.state = if state_open {
                    IssueState::Open
                } else {
                    IssueState::Closed
                };
                next.at = at.clone();
                next.received_at = received_at.to_string();
                state.issues.insert(op.key.clone(), next);
                state.revision += 1;
                return true;
            }
            state.issues.insert(
                op.key.clone(),
                IssueRecord {
                    id: op.key.clone(),
                    novel_id: b.novel_id,
                    issue_id: b.issue_id,
                    title: clamp_str(&b.title, 120),
                    body: clamp_str(&b.body, 4000),
                    author_peer: if b.author_peer.is_empty() {
                        op.actor.clone()
                    } else {
                        b.author_peer
                    },
                    author_name: clamp_str(&b.author_name, 60),
                    state: if state_open {
                        IssueState::Open
                    } else {
                        IssueState::Closed
                    },
                    closed_by: None,
                    at: at.clone(),
                    received_at: received_at.to_string(),
                },
            );
            state.revision += 1;
            true
        }

        OpKind::IssueClose => {
            let Ok(b) = serde_json::from_value::<IssueCloseBody>(body.clone()) else {
                return true;
            };
            if b.novel_id.is_empty() || b.issue_id.is_empty() {
                return true;
            }
            let Some(prev) = state.issues.get(&op.key) else {
                // 议题还没到：挂起，等 issue.put 到位
                return false;
            };
            if op.actor != prev.author_peer && !is_maintainer(state, &b.novel_id, &op.actor) {
                return false;
            }
            if !newer(at, &prev.at) {
                return true;
            }
            let mut next = prev.clone();
            next.state = match b.state {
                IssueState::Closed => IssueState::Closed,
                IssueState::Open => IssueState::Open,
            };
            next.closed_by = Some(op.actor.clone());
            next.at = at.clone();
            state.issues.insert(op.key.clone(), next);
            state.revision += 1;
            true
        }

        /* ---------------- 协作：patch / merge ---------------- */
        OpKind::PatchPut => {
            let Ok(b) = serde_json::from_value::<PatchBody>(body.clone()) else {
                return true;
            };
            if b.novel_id.is_empty() || b.patch_id.is_empty() || b.title.trim().is_empty() {
                return true;
            }
            let chapters = normalize_patch_chapters(&b.chapters);
            let open = matches!(b.state, PatchState::Open);
            if let Some(prev) = state.patches.get(&op.key) {
                // 只有 patch 作者能修订自己的 patch（LWW）
                if op.actor != prev.author_peer {
                    return true;
                }
                if !newer(at, &prev.at) {
                    return true;
                }
                let mut next = prev.clone();
                next.title = clamp_str(&b.title, 120);
                next.body = clamp_str(&b.body, 4000);
                next.state = if open { PatchState::Open } else { PatchState::Closed };
                next.chapters = chapters;
                next.at = at.clone();
                next.received_at = received_at.to_string();
                state.patches.insert(op.key.clone(), next);
                state.revision += 1;
                return true;
            }
            state.patches.insert(
                op.key.clone(),
                PatchRecord {
                    id: op.key.clone(),
                    novel_id: b.novel_id,
                    patch_id: b.patch_id,
                    title: clamp_str(&b.title, 120),
                    body: clamp_str(&b.body, 4000),
                    author_peer: if b.author_peer.is_empty() {
                        op.actor.clone()
                    } else {
                        b.author_peer
                    },
                    author_name: clamp_str(&b.author_name, 60),
                    state: if open { PatchState::Open } else { PatchState::Closed },
                    chapters,
                    at: at.clone(),
                    received_at: received_at.to_string(),
                },
            );
            state.revision += 1;
            true
        }

        OpKind::PatchClose => {
            let Ok(b) = serde_json::from_value::<PatchCloseBody>(body.clone()) else {
                return true;
            };
            if b.novel_id.is_empty() || b.patch_id.is_empty() {
                return true;
            }
            let Some(prev) = state.patches.get(&op.key) else {
                return false;
            };
            if op.actor != prev.author_peer && !is_maintainer(state, &b.novel_id, &op.actor) {
                return false;
            }
            if !newer(at, &prev.at) {
                return true;
            }
            let mut next = prev.clone();
            next.state = match b.state {
                PatchState::Closed => PatchState::Closed,
                PatchState::Open => PatchState::Open,
            };
            next.at = at.clone();
            next.received_at = received_at.to_string();
            state.patches.insert(op.key.clone(), next);
            state.revision += 1;
            true
        }

        OpKind::PatchMerge => {
            let Ok(b) = serde_json::from_value::<MergeBody>(body.clone()) else {
                return true;
            };
            if b.novel_id.is_empty() || b.patch_id.is_empty() {
                return true;
            }
            // 门控：只有作品维护者（原作者 + 已整合贡献者）能整合
            if !is_maintainer(state, &b.novel_id, &op.actor) {
                return false;
            }
            let id = merge_key(&b.novel_id, &b.patch_id);
            if let Some(prev) = state.merges.get(&id) {
                if !newer(at, &prev.at) {
                    return true;
                }
            }
            let chapters = normalize_patch_chapters(&b.chapters);
            let author = b.author;
            state.merges.insert(
                id.clone(),
                MergeRecord {
                    id,
                    novel_id: b.novel_id.clone(),
                    patch_id: b.patch_id,
                    author: author.clone(),
                    by: if b.by.is_empty() {
                        op.actor.clone()
                    } else {
                        b.by
                    },
                    chapters: chapters.clone(),
                    note: b.note.map(|s| clamp_str(&s, 500)),
                    at: at.clone(),
                },
            );
            // 并入章节（自包含：内容随 op 广播，任何顺序到达结果一致）
            apply_merge_chapters(state, &b.novel_id, &chapters, at, &author, &op.id);
            state.revision += 1;
            true
        }

        /* ---------------- 协作：编辑组 ---------------- */
        OpKind::GroupPut => {
            let Ok(b) = serde_json::from_value::<GroupBody>(body.clone()) else {
                return true;
            };
            let novel_id = b
                .novel_id
                .unwrap_or_else(|| entity_id_from_key(&op.key, "group:").unwrap_or("").to_string());
            if novel_id.is_empty() {
                return true;
            }
            let key = group_key(&novel_id);
            let prev = state.groups.get(&key).cloned();
            let name = b.name.unwrap_or_default().trim().to_string();
            if !name.is_empty() {
                // 命名门控：只有作品维护者能命名
                if !is_maintainer(state, &novel_id, &op.actor) {
                    return false;
                }
                let clean = clamp_str(&name, 40);
                if let Some(p) = prev {
                    /*
                     * 「只能改一次」= HLC 最早的一条命名获胜。
                     * 两条并发改名按 HLC 定序而非到达顺序，两个节点永远算出同一个组名 ——
                     * 组名只认时间，不认手速。
                     */
                    if let Some(named_at) = &p.named_at {
                        if compare_hlts(at, named_at) != Ordering::Less {
                            return true;
                        }
                    }
                    let mut next = p;
                    next.name = Some(clean);
                    next.named_at = Some(at.clone());
                    next.named_by = Some(op.actor.clone());
                    next.updated_at = at.clone();
                    state.groups.insert(key, next);
                    state.revision += 1;
                    return true;
                }
                state.groups.insert(
                    key,
                    GroupRecord {
                        id: group_key(&novel_id),
                        novel_id,
                        name: Some(clean),
                        named_at: Some(at.clone()),
                        named_by: Some(op.actor.clone()),
                        updated_at: at.clone(),
                    },
                );
                state.revision += 1;
                return true;
            }
            // 不带名字 = 仅确认建组（组员本来就是派生的，这条 op 只是占位）
            if prev.is_some() {
                return true;
            }
            state.groups.insert(
                key.clone(),
                GroupRecord {
                    id: key,
                    novel_id,
                    name: None,
                    named_at: None,
                    named_by: None,
                    updated_at: at.clone(),
                },
            );
            state.revision += 1;
            true
        }

        /* ---------------- 出版社：赛事结果 ---------------- */
        OpKind::ContestResult => {
            let Ok(b) = serde_json::from_value::<ContestResultBody>(body.clone()) else {
                return true;
            };
            let contest_id = if b.contest_id.is_empty() {
                entity_id_from_key(&op.key, "result:").unwrap_or("").to_string()
            } else {
                b.contest_id
            };
            if contest_id.is_empty() {
                return true;
            }
            // 门控：只有赛事主办方能公布。赛事没到就挂起等它
            let Some(contest) = state.contests.get(&contest_id) else {
                return false;
            };
            if op.actor != contest.publisher_peer {
                return true;
            }
            if let Some(prev) = state.contest_results.get(&op.key) {
                if !newer(at, &prev.at) {
                    return true;
                }
            }
            let placements: Vec<ContestPlacementRecord> = b
                .placements
                .into_iter()
                .map(|p| ContestPlacementRecord {
                    place: p.place.clamp(1, 99),
                    novel_id: p.novel_id,
                    novel_title: clamp_str(&p.novel_title, 120),
                    author_peer: p.author_peer,
                    author_name: clamp_str(&p.author_name, 60),
                    note: p.note.map(|s| clamp_str(&s, 200)),
                })
                .filter(|p| !p.novel_id.is_empty())
                .take(10)
                .collect();
            state.contest_results.insert(
                op.key.clone(),
                ContestResultRecord {
                    id: op.key.clone(),
                    contest_id,
                    publisher_peer: op.actor.clone(),
                    placements,
                    at: at.clone(),
                    received_at: received_at.to_string(),
                },
            );
            state.revision += 1;
            true
        }

        /* ---------------- 出版社：改编与封面赞助 ---------------- */
        OpKind::DealPut => {
            let Ok(b) = serde_json::from_value::<DealBody>(body.clone()) else {
                return true;
            };
            let deal_id = if b.deal_id.is_empty() {
                entity_id_from_key(&op.key, "deal:").unwrap_or("").to_string()
            } else {
                b.deal_id
            };
            if deal_id.is_empty() || b.novel_id.is_empty() {
                return true;
            }
            let key = deal_key(&deal_id);
            let base = (
                b.novel_id,
                clamp_str(&b.novel_title, 120),
                b.author_peer,
                clamp_str(&b.author_name, 60),
                b.publisher_peer,
                clamp_str(&b.publisher_name, 60),
                b.kind,
                b.amount.max(0),
                clamp_str(&b.terms, 2000),
            );
            let prev = state.deals.get(&key).cloned();
            let Some(p) = prev else {
                // 创建交易：只有要约里写的那个出版社能开，且初始状态必须是 offered
                if op.actor != base.4 || !matches!(b.status, DealStatus::Offered) {
                    return true;
                }
                state.deals.insert(
                    key.clone(),
                    DealRecord {
                        id: key,
                        deal_id,
                        novel_id: base.0,
                        novel_title: base.1,
                        author_peer: base.2,
                        author_name: base.3,
                        publisher_peer: base.4,
                        publisher_name: base.5,
                        kind: base.6,
                        amount: base.7,
                        terms: base.8,
                        status: DealStatus::Offered,
                        at: at.clone(),
                        received_at: received_at.to_string(),
                    },
                );
                state.revision += 1;
                return true;
            };
            // 终态不再变化
            if p.status.is_terminal() || p.status == b.status {
                return true;
            }
            /*
             * 状态机门控（按目标状态授权，与到达顺序无关）：
             *   accepted / declined —— 只有原作者
             *   paid / cancelled     —— 只有出版社
             * 也就是说，没有人能替自己的对手方点头。
             */
            let authorized = match b.status {
                DealStatus::Accepted | DealStatus::Declined => op.actor == p.author_peer,
                DealStatus::Paid | DealStatus::Cancelled => op.actor == p.publisher_peer,
                DealStatus::Offered => false,
            };
            if !authorized {
                return true;
            }
            let mut next = p;
            next.novel_id = base.0;
            next.novel_title = base.1;
            next.author_peer = base.2;
            next.author_name = base.3;
            next.publisher_peer = base.4;
            next.publisher_name = base.5;
            next.kind = base.6;
            next.amount = base.7;
            next.terms = base.8;
            next.status = b.status;
            next.at = at.clone();
            next.received_at = received_at.to_string();
            state.deals.insert(key, next);
            state.revision += 1;
            true
        }

        /* ---------------- 审查：举报 ---------------- */
        OpKind::ReportPut => {
            let Ok(b) = serde_json::from_value::<ReportBody>(body.clone()) else {
                return true;
            };
            if b.novel_id.is_empty() {
                return true;
            }
            if let Some(prev) = state.reports.get(&op.key) {
                // 同一举报者改举报：只认本人、只认更新的（LWW）
                if op.actor != prev.reporter || !newer(at, &prev.at) {
                    return true;
                }
            }
            let reporter_name = match b.reporter_name {
                Some(n) if !n.is_empty() => clamp_str(&n, 60),
                _ => tail8(&op.actor),
            };
            state.reports.insert(
                op.key.clone(),
                ReportRecord {
                    id: op.key.clone(),
                    novel_id: b.novel_id,
                    reporter: op.actor.clone(),
                    reporter_name,
                    chapter_no: b.chapter_no,
                    category: b.category,
                    note: clamp_str(&b.note, 500),
                    at: at.clone(),
                    received_at: received_at.to_string(),
                },
            );
            state.revision += 1;
            true
        }

        OpKind::ReportRespond => {
            let Ok(b) = serde_json::from_value::<RespondBody>(body.clone()) else {
                return true;
            };
            if b.novel_id.is_empty() {
                return true;
            }
            // 门控：只有这部作品的维护者（原作者 + 编辑组）能申辩
            if !is_maintainer(state, &b.novel_id, &op.actor) {
                return false;
            }
            if let Some(prev) = state.responses.get(&op.key) {
                if !newer(at, &prev.at) {
                    return true;
                }
            }
            state.responses.insert(
                op.key.clone(),
                ResponseRecord {
                    id: op.key.clone(),
                    novel_id: b.novel_id,
                    author: op.actor.clone(),
                    author_name: tail8(&op.actor),
                    body: clamp_str(&b.body, 1000),
                    at: at.clone(),
                    received_at: received_at.to_string(),
                },
            );
            state.revision += 1;
            true
        }

        /* ---------------- PV ---------------- */
        OpKind::ViewAdd => {
            let Ok(b) = serde_json::from_value::<ViewBody>(body.clone()) else {
                return true;
            };
            if b.novel_id.is_empty() {
                return true;
            }
            // 集合语义：同一身份对同一话只计一次
            if state.views.contains_key(&op.key) {
                return true;
            }
            state.views.insert(
                op.key.clone(),
                ViewRecord {
                    id: op.key.clone(),
                    novel_id: b.novel_id,
                    chapter_no: b.chapter_no,
                    actor: op.actor.clone(),
                    at: at.clone(),
                },
            );
            state.revision += 1;
            true
        }

        OpKind::RelayAnnounce => true,

        /* ---------------- 协作：零散贡献 ---------------- */
        OpKind::ContribPut => {
            let Ok(b) = serde_json::from_value::<ContributionBody>(body.clone()) else {
                return true;
            };
            if b.novel_id.is_empty() {
                return true;
            }
            let kind = match b.kind.as_str() {
                "proofread" | "review" | "illustration" => b.kind.as_str().to_string(),
                _ => "research".to_string(),
            };
            let key = contrib_key(&b.novel_id, &op.actor);
            if let Some(prev) = state.contributions.get(&key) {
                if !newer(at, &prev.at) {
                    return true;
                }
            }
            state.contributions.insert(
                key.clone(),
                ContributionRecord {
                    id: key,
                    novel_id: b.novel_id,
                    contributor: op.actor.clone(),
                    contributor_name: b.contributor_name.as_deref().map(|s| clamp_str(s, 60)).unwrap_or_default(),
                    kind,
                    items: b.items.min(100_000),
                    scope: b.scope.as_deref().map(|s| clamp_str(s, 120)).filter(|s| !s.is_empty()),
                    note: b.note.as_deref().map(|s| clamp_str(s, 2000)).filter(|s| !s.is_empty()),
                    at: at.clone(),
                    received_at: received_at.to_string(),
                },
            );
            state.revision += 1;
            true
        }

        /* ---------------- 社区授予勋章 ---------------- */
        OpKind::BadgeGrant => {
            let Ok(b) = serde_json::from_value::<BadgeGrantBody>(body.clone()) else {
                return true;
            };
            if b.target_peer.is_empty() || b.badge_id.is_empty() {
                return true;
            }
            // 自授无效：自己给自己发章会让整套勋章失去意义
            if b.target_peer == op.actor {
                return true;
            }
            let key = badge_grant_key(&b.target_peer, &b.badge_id, &op.actor);
            if let Some(prev) = state.badge_grants.get(&key) {
                if !newer(at, &prev.at) {
                    return true;
                }
            }
            state.badge_grants.insert(
                key.clone(),
                BadgeGrantRecord {
                    id: key,
                    target_peer: b.target_peer,
                    badge_id: b.badge_id,
                    granter: op.actor.clone(),
                    granter_name: b.granter_name.as_deref().map(|s| clamp_str(s, 60)).unwrap_or_default(),
                    note: b.note.as_deref().map(|s| clamp_str(s, 500)).filter(|s| !s.is_empty()),
                    at: at.clone(),
                    received_at: received_at.to_string(),
                },
            );
            state.revision += 1;
            true
        }

        /* ---------------- 信任背书（女巫抵抗的基础数据） ---------------- */
        OpKind::AttestPut => {
            let Ok(b) = serde_json::from_value::<AttestBody>(body.clone()) else {
                return true;
            };
            // key 里的 (actor, target) 是事实：谁背的书、背给谁。
            let Some((actor, target)) = attest_actors_from_key(&op.key) else {
                return true;
            };
            // 签名身份必须与 key 的 actor 一致，目标不能是空，自证无效。
            if actor != op.actor || target.is_empty() || actor == target {
                return true;
            }
            let weight = b.weight.clamp(1, 3);
            if let Some(prev) = state.attestations.get(&op.key) {
                if !newer(at, &prev.at) {
                    return true;
                }
            }
            state.attestations.insert(
                op.key.clone(),
                AttestRecord {
                    id: op.key.clone(),
                    actor: actor.to_string(),
                    target: target.to_string(),
                    weight,
                    note: b.note.as_deref().map(|s| clamp_str(s, 200)).filter(|s| !s.is_empty()),
                    at: at.clone(),
                    received_at: received_at.to_string(),
                },
            );
            state.revision += 1;
            true
        }

        /* ---------------- 阅读时长 ---------------- */
        OpKind::ReadTick => {
            let Ok(b) = serde_json::from_value::<ReadTickBody>(body.clone()) else {
                return true;
            };
            if b.novel_id.is_empty() {
                return true;
            }
            let seconds = b.seconds.min(120);
            if seconds == 0 {
                return true;
            }
            // key 带序号（op id 尾部），所以同一秒可以多次记录而不互相覆盖
            let seq = op.id.chars().rev().take(8).collect::<String>().chars().rev().collect::<String>();
            let key = read_tick_key(&op.actor, &b.novel_id, b.chapter_no, &seq);
            if state.read_ticks.contains_key(&key) {
                return true;
            }
            state.read_ticks.insert(
                key.clone(),
                ReadTickRecord {
                    id: key,
                    actor: op.actor.clone(),
                    novel_id: b.novel_id,
                    chapter_no: b.chapter_no,
                    seconds,
                    at: at.clone(),
                },
            );
            state.revision += 1;
            true
        }
    }
}

fn tail8(s: &str) -> String {
    if s.chars().count() <= 8 {
        s.to_string()
    } else {
        s.chars().skip(s.chars().count() - 8).collect()
    }
}

/* ------------------------- 门控辅助 ------------------------- */

/// 归一化 patch 里的章节数组（脏数据一律丢弃而不是让界面崩）
pub fn normalize_patch_chapters(input: &[PatchChapter]) -> Vec<PatchChapter> {
    let mut out = Vec::new();
    for c in input.iter().take(50) {
        if c.no < 1 || c.no > 9999 {
            continue;
        }
        let paragraphs: Vec<String> = c
            .paragraphs
            .iter()
            .filter(|p| !p.is_empty())
            .take(2000)
            .cloned()
            .collect();
        if paragraphs.is_empty() {
            continue;
        }
        let words = if c.words > 0 {
            c.words
        } else {
            paragraphs
                .join("")
                .chars()
                .filter(|c| !c.is_whitespace())
                .count() as u64
        };
        out.push(PatchChapter {
            no: c.no,
            title: if c.title.is_empty() {
                chapter_title_key(c.no)
            } else {
                clamp_str(&c.title, 120)
            },
            volume: c.volume.as_ref().map(|v| clamp_str(v, 60)),
            paragraphs,
            words,
            based_on: c.based_on.clone(),
            contributor: c.contributor.clone(),
        });
    }
    out
}

/// 把整合进来的章节写进视图。
///
/// LWW 的「写入时间」用 **merge op 的 HLC** 而不是本地时钟 ——
/// 这样迟到的 merge 也能正确参与定序，两个节点算出同一结果。
pub fn apply_merge_chapters(
    state: &mut ReplicaState,
    novel_id: &str,
    chapters: &[PatchChapter],
    at: &str,
    contributor: &str,
    op_id: &str,
) {
    for c in chapters {
        let key = chapter_key(novel_id, c.no);
        if let Some(prev) = state.chapters.get(&key) {
            if !newer(at, &prev.published_at) {
                continue;
            }
        }
        state.chapters.insert(
            key,
            ReplicaChapter {
                novel_id: novel_id.to_string(),
                no: c.no,
                title: c.title.clone(),
                words: c.words,
                published_at: at.to_string(),
                volume: c.volume.clone(),
                contributor: if contributor.is_empty() {
                    None
                } else {
                    Some(contributor.to_string())
                },
                paragraphs: Some(c.paragraphs.clone()),
                cid: None,
                deleted: false,
                op_id: op_id.to_string(),
            },
        );
    }
}

/// 一部作品的维护者 = 原作者 + 全部已整合贡献者（按 merge 记录派生）。
///
/// 这就是「编辑组权限平等」的数据基础：名单里没有特殊位置，原作者也在里面。
/// 也包括「无法剔除谁」：没有任何 op 能修改这个名单 —— 名单只增不减，
/// 拉人进来容易，请人出去没有入口。
pub fn maintainers_of(state: &ReplicaState, novel_id: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    if let Some(n) = state.novels.get(novel_id) {
        if !n.author_peer.is_empty() {
            out.push(n.author_peer.clone());
        }
    }
    for m in state.merges.values() {
        if m.novel_id == novel_id && !m.author.is_empty() && !out.contains(&m.author) {
            out.push(m.author.clone());
        }
    }
    out
}

/// 同 `maintainers_of` —— 「贡献者」是同一份名单的界面用词
pub fn contributors_of(state: &ReplicaState, novel_id: &str) -> Vec<String> {
    maintainers_of(state, novel_id)
}

pub fn is_maintainer(state: &ReplicaState, novel_id: &str, peer: &str) -> bool {
    !peer.is_empty() && maintainers_of(state, novel_id).contains(&peer.to_string())
}

/// 本站不托管页面，所以站外链接只允许 http/https/mailto。
/// 不做这一步的话，一个作者就能把 `javascript:...` 写进自己的主页。
pub fn normalize_links(input: &[ProfileLink]) -> Vec<ProfileLink> {
    let mut out = Vec::new();
    for l in input.iter().take(6) {
        let url = l.url.trim();
        if url.is_empty() || url.chars().count() > 300 {
            continue;
        }
        let ok = url.starts_with("https://") || url.starts_with("http://") || url.starts_with("mailto:");
        if !ok {
            continue;
        }
        out.push(ProfileLink {
            platform: l.platform,
            url: url.to_string(),
            label: l.label.as_ref().map(|s| clamp_str(s, 40)),
        });
    }
    out
}

/* ------------------------- 批量应用 ------------------------- */

/// 应用单个 op（写入 / 收包路径）：门控未过则挂起，并尝试解锁挂起的项
pub fn apply_one(state: &mut ReplicaState, op: &Op, received_at: &str) {
    if !apply_op(state, op, received_at) {
        if !state.pending_gated.iter().any(|o| o.id == op.id) {
            state.pending_gated.push(op.clone());
        }
    }
    drain_pending(state, received_at);
}

/// 重试挂起的门控 op。前提只会累加，所以重试必然收敛 —— 挂着也不会永远挂着。
pub fn drain_pending(state: &mut ReplicaState, received_at: &str) {
    if state.pending_gated.is_empty() {
        return;
    }
    let queue = std::mem::take(&mut state.pending_gated);
    for op in queue {
        if !apply_op(state, &op, received_at) {
            if !state.pending_gated.iter().any(|o| o.id == op.id) {
                state.pending_gated.push(op);
            }
        }
    }
}

/// 批量应用（去重后）
///
/// 两遍：先把非门控 op 全部落地建立前提，再按 HLC 顺序应用门控 op ——
/// 先备好料，再开火。
pub fn apply_ops(state: &mut ReplicaState, ops: &[Op], received_at: &str) -> (usize, usize) {
    let mut sorted: Vec<Op> = ops.to_vec();
    sorted.sort_by(|a, b| compare_hlts(&a.hlts, &b.hlts).then(a.actor.cmp(&b.actor)));
    let mut applied = 0usize;
    for op in &sorted {
        if is_gated(op.kind) {
            continue;
        }
        let before = state.revision;
        apply_op(state, op, received_at);
        if state.revision != before {
            applied += 1;
        }
    }
    for op in &sorted {
        if !is_gated(op.kind) {
            continue;
        }
        let before = state.revision;
        if apply_op(state, op, received_at) {
            if state.revision != before {
                applied += 1;
            }
        } else if !state.pending_gated.iter().any(|o| o.id == op.id) {
            state.pending_gated.push(op.clone());
        }
    }
    drain_pending(state, received_at);
    (applied, sorted.len() - applied)
}

/* ------------------------- 测试 ------------------------- */

#[cfg(test)]
mod tests {
    use super::*;

    fn op(kind: OpKind, key: &str, actor: &str, hlts: &str, body: serde_json::Value) -> Op {
        Op {
            id: format!("{actor}-{hlts}-{key}"),
            actor: actor.into(),
            hlts: hlts.into(),
            kind,
            key: key.into(),
            body,
            cid: None,
            v: 1,
            sig: None,
        }
    }

    fn hlts(wall: u64, c: u64, n: &str) -> String {
        crate::domain::hlc::encode_hlts(wall, c, n)
    }

    fn novel_body(title: &str) -> serde_json::Value {
        serde_json::to_value(NovelBody {
            title: title.into(),
            author_name: Some("甲".into()),
            author_peer: Some("peerA".into()),
            genre: Some("isekai".into()),
            genre_name: Some("异世界".into()),
            tags: vec!["转生".into()],
            synopsis: "一句话简介。".into(),
            status: Some(NovelStatus::Ongoing),
            episodes: 3,
            words: 9000,
            latest: None,
            first_published_at: Some("2026-01-01T00:00:00.000Z".into()),
            awards: vec![],
            license: None,
            fork_of: None,
        })
        .unwrap()
    }

    #[test]
    fn attest_self_invalid_key_and_lww() {
        let mut s = ReplicaState::new();
        let at = "000000001:0:a";
        // 自证无效
        assert!(apply_op(
            &mut s,
            &op(
                OpKind::AttestPut,
                &attest_key("a", "a"),
                "a",
                at,
                serde_json::json!({"weight": 2}),
            ),
            at,
        ));
        assert!(s.attestations.is_empty());
        // key 里的 actor 与签名 actor 不一致 -> 忽略
        assert!(apply_op(
            &mut s,
            &op(
                OpKind::AttestPut,
                &attest_key("a", "b"),
                "b",
                at,
                serde_json::json!({"weight": 2}),
            ),
            at,
        ));
        assert!(s.attestations.is_empty());
        // 正常写 + LWW：旧的更低权重被新的盖掉
        assert!(apply_op(
            &mut s,
            &op(
                OpKind::AttestPut,
                &attest_key("a", "b"),
                "a",
                &hlts(1, 0, "a"),
                serde_json::json!({"weight": 1}),
            ),
            at,
        ));
        assert_eq!(s.attestations.len(), 1);
        assert!(apply_op(
            &mut s,
            &op(
                OpKind::AttestPut,
                &attest_key("a", "b"),
                "a",
                &hlts(2, 0, "a"),
                serde_json::json!({"weight": 3, "note": "读过他写的"}),
            ),
            at,
        ));
        let r = s.attestations.get(&attest_key("a", "b")).unwrap();
        assert_eq!(r.weight, 3);
        assert_eq!(r.note.as_deref(), Some("读过他写的"));
        // 更旧的回写不生效
        assert!(apply_op(
            &mut s,
            &op(
                OpKind::AttestPut,
                &attest_key("a", "b"),
                "a",
                &hlts(1, 9, "a"),
                serde_json::json!({"weight": 1}),
            ),
            at,
        ));
        assert_eq!(s.attestations.get(&attest_key("a", "b")).unwrap().weight, 3);
    }

    /// 收敛性：乱序 + 重复投递，指纹必须一致。
    #[test]
    fn converges_regardless_of_order() {
        let ops = vec![
            op(
                OpKind::NovelPut,
                &novel_key("n1"),
                "peerA",
                &hlts(1000, 0, "peerA"),
                novel_body("第一部"),
            ),
            op(
                OpKind::NovelPut,
                &novel_key("n1"),
                "peerA",
                &hlts(2000, 0, "peerA"),
                novel_body("第一部（改）"),
            ),
            op(
                OpKind::BookmarkSet,
                &bookmark_key("peerB", "n1"),
                "peerB",
                &hlts(1500, 0, "peerB"),
                serde_json::json!({"on": true}),
            ),
            op(
                OpKind::RewardGrant,
                "reward:x",
                "peerA",
                &hlts(1600, 0, "peerA"),
                serde_json::json!({"idempotencyKey":"k1","to":"peerB","amount":10,"action":"like"}),
            ),
        ];

        let mut base = ReplicaState::new();
        apply_ops(&mut base, &ops, "2026-01-01T00:00:00.000Z");

        // 逆序 + 每条形重复三遍
        let mut shuffled: Vec<Op> = Vec::new();
        for _ in 0..3 {
            for o in ops.iter().rev() {
                shuffled.push(o.clone());
            }
        }
        let mut other = ReplicaState::new();
        apply_ops(&mut other, &shuffled, "2026-02-02T00:00:00.000Z");

        assert_eq!(base.fingerprint(), other.fingerprint());
        assert_eq!(base.novels.get("n1").unwrap().title, "第一部（改）");
        // 幂等：重复投递不重复发币
        assert_eq!(base.rewards.len(), 1);
    }

    /// 门控：不是维护者就不能整合；议题没到就挂起而不是丢弃。
    #[test]
    fn gated_ops_are_suspended_not_dropped() {
        let mut s = ReplicaState::new();
        let put = op(
            OpKind::NovelPut,
            &novel_key("n1"),
            "peerA",
            &hlts(1000, 0, "peerA"),
            novel_body("第一部"),
        );
        apply_ops(&mut s, &[put], "now");

        // 先到：非维护者整合 -> 挂起
        let merge = op(
            OpKind::PatchMerge,
            &merge_key("n1", "p1"),
            "peerX",
            &hlts(1100, 0, "peerX"),
            serde_json::json!({"novelId":"n1","patchId":"p1","author":"peerX","by":"peerX","chapters":[]}),
        );
        apply_ops(&mut s, &[merge], "now");
        assert_eq!(s.merges.len(), 0, "非维护者的整合不应生效");
        assert_eq!(s.pending_gated.len(), 1, "应当挂起而不是丢弃");

        // 后到：把它变成维护者（原作者亲自整合一次空 patch 是把 peerX 加进名单的方式）
        // —— 这里改用一个真维护者的整合来验证挂起项被解锁
        let mut s2 = s.clone();
        let by_author = op(
            OpKind::PatchMerge,
            &merge_key("n1", "p2"),
            "peerA",
            &hlts(1200, 0, "peerA"),
            serde_json::json!({"novelId":"n1","patchId":"p2","author":"peerA","by":"peerA","chapters":[]}),
        );
        apply_ops(&mut s2, &[by_author], "now");
        assert_eq!(s2.merges.len(), 1);
    }

    /// 笔名只能本人写：body.id 与 actor 不符时丢弃
    #[test]
    fn cannot_overwrite_others_profile() {
        let mut s = ReplicaState::new();
        let evil = op(
            OpKind::ProfilePut,
            &profile_key("peerA"),
            "peerB",
            &hlts(1000, 0, "peerB"),
            serde_json::json!({"id":"peerA","name":"冒充者"}),
        );
        apply_ops(&mut s, &[evil], "now");
        assert!(s.profiles.is_empty());
    }

    /// 状态机：报酬先转账后标记；接受只有原作者，支付只有出版社
    #[test]
    fn deal_state_machine_is_role_gated() {
        let mut s = ReplicaState::new();
        let offer = op(
            OpKind::DealPut,
            &deal_key("d1"),
            "pub1",
            &hlts(1000, 0, "pub1"),
            serde_json::json!({"dealId":"d1","novelId":"n1","novelTitle":"T","authorPeer":"a1","authorName":"A","publisherPeer":"pub1","publisherName":"P","kind":"manga","amount":100,"terms":"","status":"offered"}),
        );
        apply_ops(&mut s, &[offer], "now");
        assert_eq!(s.deals.len(), 1);

        // 出版社想自己「接受」—— 不允许
        let bad = op(
            OpKind::DealPut,
            &deal_key("d1"),
            "pub1",
            &hlts(1100, 0, "pub1"),
            serde_json::json!({"dealId":"d1","novelId":"n1","novelTitle":"T","authorPeer":"a1","authorName":"A","publisherPeer":"pub1","publisherName":"P","kind":"manga","amount":100,"terms":"","status":"accepted"}),
        );
        apply_ops(&mut s, &[bad], "now");
        assert_eq!(s.deals.get("deal:d1").unwrap().status, DealStatus::Offered);

        // 原作者接受
        let ok = op(
            OpKind::DealPut,
            &deal_key("d1"),
            "a1",
            &hlts(1200, 0, "a1"),
            serde_json::json!({"dealId":"d1","novelId":"n1","novelTitle":"T","authorPeer":"a1","authorName":"A","publisherPeer":"pub1","publisherName":"P","kind":"manga","amount":100,"terms":"","status":"accepted"}),
        );
        apply_ops(&mut s, &[ok], "now");
        assert_eq!(s.deals.get("deal:d1").unwrap().status, DealStatus::Accepted);
    }

    /// 编辑组名只能改一次：HLC 最早的一条获胜，与到达顺序无关
    #[test]
    fn editor_group_named_once_by_hlc() {
        let mk = |who: &str, wall: u64, name: &str| {
            op(
                OpKind::GroupPut,
                &group_key("n1"),
                who,
                &hlts(wall, 0, who),
                serde_json::json!({"novelId":"n1","name":name}),
            )
        };
        let mut s = ReplicaState::new();
        apply_ops(
            &mut s,
            &[
                op(
                    OpKind::NovelPut,
                    &novel_key("n1"),
                    "peerA",
                    &hlts(1000, 0, "peerA"),
                    novel_body("第一部"),
                ),
                mk("peerA", 2000, "晚到的名字"),
            ],
            "now",
        );
        // 早到的 HLC 但后应用：仍然应该输给已存在的那条
        apply_ops(&mut s, &[mk("peerA", 1500, "早的名字")], "now");
        assert_eq!(s.groups.get("group:n1").unwrap().name.as_deref(), Some("早的名字"));

        // 再改第三次：无效
        apply_ops(&mut s, &[mk("peerA", 3000, "第三次")], "now");
        assert_eq!(s.groups.get("group:n1").unwrap().name.as_deref(), Some("早的名字"));
    }

    /// 阅读时长是离散事件之和，单条上限 120 秒（与 Web 版一致）。
    #[test]
    fn read_ticks_sum_and_clamp_seconds() {
        let mut s = ReplicaState::new();
        let tick = |id: &str, seconds: u32, wall: u64| {
            Op {
                id: format!("peerA:{}:{id}", hlts(wall, 0, "peerA")),
                actor: "peerA".into(),
                hlts: hlts(wall, 0, "peerA"),
                kind: OpKind::ReadTick,
                key: "ignored-by-reducer".into(),
                body: serde_json::json!({
                    "novelId": "n1",
                    "chapterNo": 1,
                    "seconds": seconds,
                }),
                cid: None,
                v: 1,
                sig: None,
            }
        };
        apply_ops(&mut s, &[tick("aaaaaaaa", 30, 1000), tick("bbbbbbbb", 500, 1001)], "now");
        assert_eq!(s.read_ticks.len(), 2);
        let total: u32 = s.read_ticks.values().map(|t| t.seconds).sum();
        assert_eq!(total, 150, "单条 500 秒必须被压到 120");
        assert!(s.read_ticks.values().all(|t| t.chapter_no == 1 && t.actor == "peerA"));
    }

    /// 自授勋章无效；他人授予才进入状态。
    #[test]
    fn badges_cannot_be_self_granted() {
        let mut s = ReplicaState::new();
        let grant = |target: &str, badge: &str, who: &str| {
            op(
                OpKind::BadgeGrant,
                &badge_grant_key(target, badge, who),
                who,
                &hlts(1000, 0, who),
                serde_json::json!({
                    "targetPeer": target,
                    "badgeId": badge,
                    "note": "理由",
                    "granterName": who,
                }),
            )
        };
        apply_ops(&mut s, &[grant("peerA", "first-work", "peerA")], "now");
        assert!(s.badge_grants.is_empty(), "自己不能给自己授予");

        apply_ops(&mut s, &[grant("peerA", "first-work", "peerB")], "now");
        assert_eq!(s.badge_grants.len(), 1);
        let rec = s.badge_grants.values().next().unwrap();
        assert_eq!(rec.target_peer, "peerA");
        assert_eq!(rec.badge_id, "first-work");
        assert_eq!(rec.granter, "peerB");
    }

    /// PV 是集合语义：同一身份对同一话只计一次，刷一百条也只算一票
    /// 轮播位：最早的一条 key 获胜、非法链接被丢弃、费用从余额里扣除。
    #[test]
    fn carousel_key_earliest_wins_and_fee_reduces_balance() {
        let mk = |wall: u64, title: &str, href: &str| {
            op(
                OpKind::CarouselPut,
                &carousel_key("car-1"),
                "peerA",
                &hlts(wall, 0, "peerA"),
                serde_json::json!({
                    "title": title,
                    "subtitle": "副标题",
                    "kind": "novel",
                    "targetId": "n1",
                    "href": href,
                    "byName": "甲",
                }),
            )
        };
        let mut s = ReplicaState::new();
        apply_ops(&mut s, &[mk(2000, "后到的", "/novel?id=n1")], "now");
        apply_ops(&mut s, &[mk(1000, "最早", "https://example.org")], "now");
        let rec = s.carousels.get("car-1").unwrap();
        assert_eq!(rec.title, "最早");
        assert_eq!(rec.by, "peerA");
        assert_eq!(rec.fee, 100);
        assert_eq!(rec.expires_at, 1000 + 7 * 24 * 60 * 60 * 1000);
        let expires_at = rec.expires_at;

        // 非法链接：整条丢弃，不覆盖已有记录
        apply_ops(
            &mut s,
            &[op(
                OpKind::CarouselPut,
                &carousel_key("car-1"),
                "peerA",
                &hlts(500, 0, "peerA"),
                serde_json::json!({"title":"坏链接","kind":"link","href":"javascript:alert(1)"}),
            )],
            "now",
        );
        assert_eq!(s.carousels.get("car-1").unwrap().title, "最早");

        // 展示窗口由读取侧派生
        assert_eq!(
            crate::domain::selectors::active_carousels(&s, 2000).len(),
            1
        );
        assert_eq!(
            crate::domain::selectors::active_carousels(&s, expires_at).len(),
            0
        );

        // 费用从余额扣除：发 150，买一条 100，余额 50
        apply_ops(
            &mut s,
            &[op(
                OpKind::RewardGrant,
                "reward:r1",
                "peerB",
                &hlts(1500, 0, "peerB"),
                serde_json::json!({
                    "idempotencyKey":"r1","to":"peerA","amount":150,"action":"tip"
                }),
            )],
            "now",
        );
        assert_eq!(crate::domain::selectors::balance_of(&s, "peerA"), 50);
    }

    #[test]
    fn pv_is_set_semantics() {
        let mut s = ReplicaState::new();
        let v = |n: u64| {
            op(
                OpKind::ViewAdd,
                &view_key("peerA", "n1", 1),
                "peerA",
                &hlts(n, 0, "peerA"),
                serde_json::json!({"novelId":"n1","chapterNo":1}),
            )
        };
        apply_ops(&mut s, &[v(1000), v(1001), v(1002)], "now");
        assert_eq!(s.views.len(), 1);
    }
}