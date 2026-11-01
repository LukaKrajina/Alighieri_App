//! 勋章
//! ----
//! 勋章**由社区授予**，不再由系统按计数自动发。
//!
//! 三条原则：
//!  1. 纯装饰、无等级 —— 没有铜/银/金，不影响推荐、曝光与任何权利；
//!  2. 只保留不可重复获得的里程碑型（没有「十章 / 一百万字」这类计数勋章）；
//!  3. 授予记录是一条签名 op（`badge.grant`），全网一致；自授无效。
//!
//! 之前「算出条件 → 自动发」的问题：条件在**本机副本**上算，
//! 不同节点算出的结果可能不同，勋章就成了「你看到的和别人不一样」。

use crate::domain::state::ReplicaState;

pub struct BadgeDef {
    pub id: &'static str,
    pub title_key: &'static str,
    pub desc_key: &'static str,
    /// 判据说明（给授予者看的客观条件）
    pub criteria_key: &'static str,
}

/// 勋章目录 —— 只列**不可重复获得**的里程碑型。
pub const BADGES: [BadgeDef; 13] = [
    BadgeDef {
        id: "first-work",
        title_key: "badge.firstWork.title",
        desc_key: "badge.firstWork.desc",
        criteria_key: "badge.firstWork.criteria",
    },
    BadgeDef {
        id: "ongoing-year",
        title_key: "badge.ongoingYear.title",
        desc_key: "badge.ongoingYear.desc",
        criteria_key: "badge.ongoingYear.criteria",
    },
    BadgeDef {
        id: "ongoing-three-year",
        title_key: "badge.ongoingThreeYear.title",
        desc_key: "badge.ongoingThreeYear.desc",
        criteria_key: "badge.ongoingThreeYear.criteria",
    },
    BadgeDef {
        id: "reader",
        title_key: "badge.reader.title",
        desc_key: "badge.reader.desc",
        criteria_key: "badge.reader.criteria",
    },
    BadgeDef {
        id: "supported",
        title_key: "badge.supported.title",
        desc_key: "badge.supported.desc",
        criteria_key: "badge.supported.criteria",
    },
    BadgeDef {
        id: "licensed",
        title_key: "badge.licensed.title",
        desc_key: "badge.licensed.desc",
        criteria_key: "badge.licensed.criteria",
    },
    BadgeDef {
        id: "contest",
        title_key: "badge.contest.title",
        desc_key: "badge.contest.desc",
        criteria_key: "badge.contest.criteria",
    },
    BadgeDef {
        id: "translator",
        title_key: "badge.translator.title",
        desc_key: "badge.translator.desc",
        criteria_key: "badge.translator.criteria",
    },
    BadgeDef {
        id: "certificate",
        title_key: "badge.certificate.title",
        desc_key: "badge.certificate.desc",
        criteria_key: "badge.certificate.criteria",
    },
    BadgeDef {
        id: "contributor",
        title_key: "badge.contributor.title",
        desc_key: "badge.contributor.desc",
        criteria_key: "badge.contributor.criteria",
    },
    BadgeDef {
        id: "editor-group",
        title_key: "badge.editorGroup.title",
        desc_key: "badge.editorGroup.desc",
        criteria_key: "badge.editorGroup.criteria",
    },
    BadgeDef {
        id: "contest-winner",
        title_key: "badge.contestWinner.title",
        desc_key: "badge.contestWinner.desc",
        criteria_key: "badge.contestWinner.criteria",
    },
    BadgeDef {
        id: "adapted",
        title_key: "badge.adapted.title",
        desc_key: "badge.adapted.desc",
        criteria_key: "badge.adapted.criteria",
    },
];

pub fn badge_def(id: &str) -> Option<&'static BadgeDef> {
    BADGES.iter().find(|b| b.id == id)
}

/// 一枚已获得的勋章（由社区授予）
pub struct EarnedBadge {
    pub def: &'static BadgeDef,
    pub earned_at: String,
    /// 授予者 peerId（去重）
    pub granters: Vec<String>,
    /// 授予者写下的说明（可能有多条）
    pub notes: Vec<String>,
}

/// 一枚尚未获得的勋章（供授予者参考）
pub struct PendingBadge {
    pub def: &'static BadgeDef,
}

/// 某个身份已获得的勋章。
///
/// 同一枚勋章被多人授予 -> 只算一枚，但授予者与理由都保留 ——
/// 勋章会重复，夸你的话不会。
pub fn granted_badges(
    state: &ReplicaState,
    peer_id: &str,
) -> (Vec<EarnedBadge>, Vec<PendingBadge>) {
    use std::collections::BTreeMap;

    let mut by_badge: BTreeMap<&str, EarnedBadge> = BTreeMap::new();
    for g in state.badge_grants.values() {
        if g.target_peer != peer_id {
            continue;
        }
        let Some(def) = badge_def(&g.badge_id) else {
            continue;
        };
        if let Some(hit) = by_badge.get_mut(g.badge_id.as_str()) {
            if !hit.granters.contains(&g.granter) {
                hit.granters.push(g.granter.clone());
            }
            if let Some(note) = g.note.as_ref().filter(|n| !n.is_empty()) {
                hit.notes.push(note.clone());
            }
            if g.at < hit.earned_at {
                hit.earned_at = g.at.clone();
            }
        } else {
            by_badge.insert(
                g.badge_id.as_str(),
                EarnedBadge {
                    def,
                    earned_at: g.at.clone(),
                    granters: vec![g.granter.clone()],
                    notes: g.note.iter().filter(|n| !n.is_empty()).cloned().collect(),
                },
            );
        }
    }

    let mut earned: Vec<EarnedBadge> = by_badge.into_values().collect();
    // 最近获得的排前面
    earned.sort_by(|a, b| b.earned_at.cmp(&a.earned_at));
    let pending = BADGES
        .iter()
        .filter(|b| !earned.iter().any(|e| e.def.id == b.id))
        .map(|def| PendingBadge { def })
        .collect();
    (earned, pending)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::keys::badge_grant_key;
    use crate::domain::state::BadgeGrantRecord;

    fn grant(state: &mut ReplicaState, target: &str, badge: &str, granter: &str, at: &str) {
        let key = badge_grant_key(target, badge, granter);
        state.badge_grants.insert(
            key.clone(),
            BadgeGrantRecord {
                id: key,
                target_peer: target.into(),
                badge_id: badge.into(),
                granter: granter.into(),
                granter_name: String::new(),
                note: None,
                at: at.into(),
                received_at: at.into(),
            },
        );
    }

    #[test]
    fn multiple_grants_of_same_badge_count_once() {
        let mut s = ReplicaState::new();
        grant(&mut s, "peerA", "first-work", "peerB", "000000002:0:b");
        grant(&mut s, "peerA", "first-work", "peerC", "000000001:0:c");
        let (earned, pending) = granted_badges(&s, "peerA");
        assert_eq!(earned.len(), 1);
        assert_eq!(earned[0].granters.len(), 2);
        assert_eq!(earned[0].earned_at, "000000001:0:c");
        assert_eq!(pending.len(), 12);
    }

    #[test]
    fn unknown_badge_ids_are_ignored() {
        let mut s = ReplicaState::new();
        grant(&mut s, "peerA", "not-a-badge", "peerB", "000000001:0:b");
        let (earned, pending) = granted_badges(&s, "peerA");
        assert!(earned.is_empty());
        assert_eq!(pending.len(), 13);
    }
}