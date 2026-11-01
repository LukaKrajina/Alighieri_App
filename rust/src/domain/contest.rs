//! 出版社 / 征文大赛 —— 站点级配置与共用元数据
//! -------------------------------------------
//! 这里**没有内置出版社，也没有内置大赛**。
//!
//! 和作品一样：出版社也是某个真实身份（peerId）发布出来的，
//! 大赛由出版社身份发起，作者投稿参赛同样是它自己发的一条操作。
//! 因此在有人入驻之前，出版社页与大赛页是空的 —— 那是真实状态，
//! 不是等着被填的占位符。
//!
//! 本文件只保留「站点自己定的」东西：大赛类型的词汇表 + 纯函数
//! （状态派生、剩余天数、报名自检）。

use crate::domain::model::ContestKind;
use crate::domain::time::{days_left, parse_iso_ms};

pub const CONTEST_KINDS: [ContestKind; 4] = [
    ContestKind::CallForWriting,
    ContestKind::Battle,
    ContestKind::Theme,
    ContestKind::Edit,
];

/// 赛事类型的展示文案。
///
/// `*_key` 是字典键，由界面用当前语言取词；
/// `label` / `short` / `desc` 是**回落到中文的字面量**，只在键缺失时用。
/// 两套都要留着：未知 kind 必须有个不崩的显示值 —— 界面可以没词，但不能白屏。
pub struct ContestKindMeta {
    pub label_key: &'static str,
    pub short_key: &'static str,
    pub desc_key: &'static str,
    pub label: &'static str,
    pub short: &'static str,
    pub desc: &'static str,
}

pub const CONTEST_KIND_META: [ContestKindMeta; 4] = [
    ContestKindMeta {
        label_key: "contest.kinds.call-for-writing",
        short_key: "contest.kinds.call-for-writing.short",
        desc_key: "contest.kinds.call-for-writing.desc",
        label: "征文大赛",
        short: "征文",
        desc: "面向所有作者征稿，按字数与完结度评选，奖金和推荐位一并发放。",
    },
    ContestKindMeta {
        label_key: "contest.kinds.battle",
        short_key: "contest.kinds.battle.short",
        desc_key: "contest.kinds.battle.desc",
        label: "小说比赛",
        short: "对决",
        desc: "同一命题、同一字数上限，限定时间内写完，正文对照评审。",
    },
    ContestKindMeta {
        label_key: "contest.kinds.theme",
        short_key: "contest.kinds.theme.short",
        desc_key: "contest.kinds.theme.desc",
        label: "主题企划",
        short: "企划",
        desc: "围绕一套给定设定召集创作，出版社公开设定集与世界观。",
    },
    ContestKindMeta {
        label_key: "contest.kinds.edit",
        short_key: "contest.kinds.edit.short",
        desc_key: "contest.kinds.edit.desc",
        label: "编辑约稿",
        short: "约稿",
        desc: "点名邀稿，面向特定题材与篇幅，稿酬按千字结算。",
    },
];

pub fn kind_meta(kind: ContestKind) -> &'static ContestKindMeta {
    let idx = match kind {
        ContestKind::CallForWriting => 0,
        ContestKind::Battle => 1,
        ContestKind::Theme => 2,
        ContestKind::Edit => 3,
    };
    &CONTEST_KIND_META[idx]
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContestStatus {
    Open,
    Judging,
    Finished,
}

impl ContestStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            ContestStatus::Open => "open",
            ContestStatus::Judging => "judging",
            ContestStatus::Finished => "finished",
        }
    }
    /// 状态标签的字典键（「征稿中 / 评审中 / 已结束」要在五种语言下显示）
    pub fn label_key(&self) -> String {
        format!("contest.status.{}", self.as_str())
    }
}

/// 赛事状态 —— **读取时派生**，不是记录里的字段。
///
/// 为什么不能存进 CRDT 记录：状态取决于「现在几点」，而现在几点不是 op log 的一部分。
/// 存进去就等于给收敛性加了一个外部输入 ——
/// 两个节点在不同时刻应用同一批操作会算出不同的 status，然后谁也说服不了谁。
///
/// 三段划分：截稿前征稿中 / 截稿后到公布前评审中 / 公布后已结束。
pub fn contest_status(deadline: &str, announce_at: &str, now_ms: u64) -> ContestStatus {
    let Some(end) = parse_iso_ms(deadline) else {
        return ContestStatus::Open;
    };
    if end > now_ms {
        return ContestStatus::Open;
    }
    if let Some(announce) = parse_iso_ms(announce_at) {
        if announce > now_ms {
            return ContestStatus::Judging;
        }
    }
    ContestStatus::Finished
}

/// 报名是否还开着
pub fn can_enter(status: ContestStatus) -> bool {
    status == ContestStatus::Open
}

/// 报名自检的结果。
///
/// 失败原因给的是**字典键 + 参数**，不是中文句子 ——
/// 这五句话要在五种语言下显示，写死中文等于锁死一种语言。
pub struct EntryCheck {
    pub ok: bool,
    /// 失败时的字典键，例如 `contest.check.wordsShort`
    pub reason_key: String,
    /// 需要多少 / 现在多少（界面插值用）
    pub need: i64,
    pub have: i64,
}

fn fail(key: &str) -> EntryCheck {
    EntryCheck { ok: false, reason_key: key.into(), need: 0, have: 0 }
}

/// 投稿前的规则自检。
///
/// 把「能不能参赛」写成纯函数，好处是提交前就能给出明确原因
/// （「需要至少 30,000 字，目前 206 字」），
/// 而不是让作者传上去之后才发现白忙一场 —— 后者对谁都不礼貌。
pub fn check_entry(
    status: ContestStatus,
    deadline: &str,
    min_words: u64,
    max_words: u64,
    allow_ongoing: bool,
    novel_words: u64,
    novel_status: &str,
    already_entered: bool,
    now_ms: u64,
) -> EntryCheck {
    if already_entered {
        return fail("contest.check.already");
    }
    if !can_enter(status) {
        return fail("contest.check.closed");
    }
    if days_left(deadline, now_ms) < 0 {
        return fail("contest.check.deadline");
    }
    if !allow_ongoing && novel_status != "completed" {
        return fail("contest.check.needCompleted");
    }
    if novel_words < min_words {
        return EntryCheck {
            ok: false,
            reason_key: "contest.check.wordsShort".into(),
            need: min_words as i64,
            have: novel_words as i64,
        };
    }
    if max_words > 0 && novel_words > max_words {
        return EntryCheck {
            ok: false,
            reason_key: "contest.check.wordsOver".into(),
            need: max_words as i64,
            have: novel_words as i64,
        };
    }
    EntryCheck { ok: true, reason_key: String::new(), need: 0, have: 0 }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::time::iso_of_ms;

    const DAY: u64 = 86_400_000;

    #[test]
    fn status_is_derived_from_time() {
        let now = 1_000 * DAY;
        assert_eq!(
            contest_status(&iso_of_ms(now + DAY), &iso_of_ms(now + 2 * DAY), now),
            ContestStatus::Open
        );
        assert_eq!(
            contest_status(&iso_of_ms(now - DAY), &iso_of_ms(now + DAY), now),
            ContestStatus::Judging
        );
        assert_eq!(
            contest_status(&iso_of_ms(now - 2 * DAY), &iso_of_ms(now - DAY), now),
            ContestStatus::Finished
        );
    }

    #[test]
    fn entry_check_reports_the_gap() {
        let now = 1_000 * DAY;
        let r = check_entry(
            ContestStatus::Open,
            &iso_of_ms(now + DAY),
            30_000,
            0,
            true,
            206,
            "ongoing",
            false,
            now,
        );
        assert!(!r.ok);
        assert_eq!(r.reason_key, "contest.check.wordsShort");
        assert_eq!((r.need, r.have), (30_000, 206));
    }

    #[test]
    fn ongoing_work_rejected_when_contest_demands_completed() {
        let now = 1_000 * DAY;
        let r = check_entry(
            ContestStatus::Open,
            &iso_of_ms(now + DAY),
            0,
            0,
            false,
            50_000,
            "ongoing",
            false,
            now,
        );
        assert!(!r.ok);
        assert_eq!(r.reason_key, "contest.check.needCompleted");
    }
}
