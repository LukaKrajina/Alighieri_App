//! op key 的构造与解析
//! --------------------
//! `apply_op` 靠 key 前缀取出实体 id，所以**每种操作的 key 必须带对前缀**。
//! 前缀写错不会报错，只会静默丢弃整条操作 —— 这个坑原站真实踩过一次
//! （`publisher.put` 一度用了裸 id，导致出版社永远不出现），所以这里集中定义、
//! 由单元测试盯着，不必再靠人眼。

/// 从带前缀的 op key 里取出实体 id，例如 `novel:abc` -> `abc`
pub fn entity_id_from_key<'a>(key: &'a str, prefix: &str) -> Option<&'a str> {
    key.strip_prefix(prefix)
}

pub fn novel_key(id: &str) -> String {
    format!("novel:{id}")
}
pub fn novel_id_from_key(key: &str) -> Option<&str> {
    entity_id_from_key(key, "novel:")
}

pub fn chapter_key(novel_id: &str, no: u32) -> String {
    format!("chapter:{novel_id}:{no}")
}
pub fn parse_chapter_key(key: &str) -> Option<(String, u32)> {
    let rest = key.strip_prefix("chapter:")?;
    let (novel_id, no) = rest.rsplit_once(':')?;
    let n: u32 = no.parse().ok()?;
    if novel_id.is_empty() {
        return None;
    }
    Some((novel_id.to_string(), n))
}

pub fn bookmark_key(actor: &str, novel_id: &str) -> String {
    format!("bookmark:{actor}:{novel_id}")
}

pub fn review_key(actor: &str, novel_id: &str, chapter_no: u32, nonce: &str) -> String {
    format!("review:{actor}:{novel_id}:{chapter_no}:{nonce}")
}

pub fn reaction_key(actor: &str, novel_id: &str, kind: &str) -> String {
    format!("reaction:{actor}:{novel_id}:{kind}")
}

pub fn profile_key(peer_id: &str) -> String {
    format!("profile:{peer_id}")
}

pub fn progress_key(actor: &str, novel_id: &str) -> String {
    format!("progress:{actor}:{novel_id}")
}

pub fn publisher_key(id: &str) -> String {
    format!("publisher:{id}")
}
pub fn publisher_id_from_key(key: &str) -> Option<&str> {
    entity_id_from_key(key, "publisher:")
}

pub fn contest_key(id: &str) -> String {
    format!("contest:{id}")
}
pub fn contest_id_from_key(key: &str) -> Option<&str> {
    entity_id_from_key(key, "contest:")
}

pub fn star_key(actor: &str, novel_id: &str) -> String {
    format!("star:{actor}:{novel_id}")
}

/// fork 的 key 用**新作品** id：一部衍生作品只有一条溯源记录
pub fn fork_key(novel_id: &str) -> String {
    format!("fork:{novel_id}")
}

pub fn issue_key(novel_id: &str, issue_id: &str) -> String {
    format!("issue:{novel_id}:{issue_id}")
}

pub fn patch_key(novel_id: &str, patch_id: &str) -> String {
    format!("patch:{novel_id}:{patch_id}")
}

pub fn merge_key(novel_id: &str, patch_id: &str) -> String {
    format!("merge:{novel_id}:{patch_id}")
}

pub fn group_key(novel_id: &str) -> String {
    format!("group:{novel_id}")
}

pub fn contest_result_key(contest_id: &str) -> String {
    format!("result:{contest_id}")
}

pub fn deal_key(deal_id: &str) -> String {
    format!("deal:{deal_id}")
}

/// 举报的 key 带**举报者**：同一举报者对同一作品只有一条记录（LWW）。
pub fn report_key(novel_id: &str, reporter: &str) -> String {
    format!("report:{novel_id}:{reporter}")
}

/// 作者申辩：每部作品一条
pub fn respond_key(novel_id: &str) -> String {
    format!("respond:{novel_id}")
}

/// 阅读事件（PV）：同一身份对同一话只计一次
pub fn view_key(actor: &str, novel_id: &str, chapter_no: u32) -> String {
    format!("view:{actor}:{novel_id}:{chapter_no}")
}

/// 零散贡献的 key：同一身份对同一作品只有一条（改内容是更新，不是刷贡献）
pub fn contrib_key(novel_id: &str, contributor: &str) -> String {
    format!("contrib:{novel_id}:{contributor}")
}

/// 勋章授予的 key：带授予者，所以多人可各自授予同一枚
pub fn badge_grant_key(target_peer: &str, badge_id: &str, granter: &str) -> String {
    format!("badge:{target_peer}:{badge_id}:{granter}")
}

/// 阅读时长事件的 key：带序号，所以同一秒可以多次记录而不互相覆盖
pub fn read_tick_key(actor: &str, novel_id: &str, chapter_no: u32, seq: &str) -> String {
    format!("read:{actor}:{novel_id}:{chapter_no}:{seq}")
}

/// 首页轮播位：key = `carousel:<id>`
pub fn carousel_key(id: &str) -> String {
    format!("carousel:{id}")
}
pub fn carousel_id_from_key(key: &str) -> Option<&str> {
    entity_id_from_key(key, "carousel:")
}

/// patch / merge 的复合 id（视图里用来互相引用）
pub fn patch_id_of(novel_id: &str, patch_id: &str) -> String {
    format!("{novel_id}|{patch_id}")
}

/// 译本在视图里的 id：`novelId|chapterNo|lang|actor`
pub fn translation_id(novel_id: &str, chapter_no: u32, lang: &str, actor: &str) -> String {
    format!("{novel_id}|{chapter_no}|{lang}|{actor}")
}

/// 证书 id：`cert:<被授予者>:<颁发者>`
pub fn certificate_id(target_peer: &str, issuer_peer: &str) -> String {
    format!("cert:{target_peer}:{issuer_peer}")
}

/// 信任背书：key = `attest:<actor>:<target>` —— 谁给谁背书由 key 决定。
pub fn attest_key(actor: &str, target: &str) -> String {
    format!("attest:{actor}:{target}")
}

/// 从 key 里拆出 (actor, target)。前缀不对或身份为空的，一律返回 None。
pub fn attest_actors_from_key(key: &str) -> Option<(&str, &str)> {
    let rest = key.strip_prefix("attest:")?;
    let (actor, target) = rest.split_once(':')?;
    if actor.is_empty() || target.is_empty() {
        return None;
    }
    Some((actor, target))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        assert_eq!(novel_id_from_key(&novel_key("abc")), Some("abc"));
        assert_eq!(parse_chapter_key(&chapter_key("n1", 12)), Some(("n1".into(), 12)));
        assert_eq!(publisher_id_from_key(&publisher_key("p1")), Some("p1"));
        assert_eq!(contest_id_from_key(&contest_key("c1")), Some("c1"));
        assert_eq!(carousel_id_from_key(&carousel_key("car-1")), Some("car-1"));
    }

    /// 原站踩过的坑：publisher.put 用了裸 id，导致出版社永远不出现。
    #[test]
    fn publisher_key_must_carry_prefix() {
        assert_eq!(publisher_id_from_key("p1"), None);
        assert_eq!(publisher_id_from_key("publisher:p1"), Some("p1"));
    }
}