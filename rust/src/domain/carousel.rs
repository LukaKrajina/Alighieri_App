//! 首页轮播位的站点规则
//! ----------------------
//! 这些常量是**站点规则**，
//! 不是发布者可以自报的数字：记录里的 `fee` 由归约器按常量写入，
//! 同一批 op 在任何节点算出的余额都一样 —— 顺手也堵住了给自己打折这条路。

use crate::domain::model::CarouselKind;

/// 首页最多同时展示 6 条
pub const CAROUSEL_SLOTS: usize = 6;
/// 每条费用（奖励币）
pub const CAROUSEL_FEE: i64 = 100;
/// 展示时长：7 天
pub const CAROUSEL_WINDOW_MS: i64 = 7 * 24 * 60 * 60 * 1000;

pub const CAROUSEL_MAX_TITLE: usize = 48;
pub const CAROUSEL_MAX_SUBTITLE: usize = 80;
pub const CAROUSEL_MAX_NAME: usize = 40;

pub const CAROUSEL_KINDS: [CarouselKind; 4] = [
    CarouselKind::Novel,
    CarouselKind::Author,
    CarouselKind::Publisher,
    CarouselKind::Link,
];

pub fn truncate_chars(s: &str, max: usize) -> String {
    s.chars().take(max).collect()
}

/// 规整轮播位链接。
///
/// 只放行站内路径（`/` 开头）与 `https://` 外链：`javascript:` / `data:`
/// 之类的链接一旦被点到，就是在读者的应用里执行别人的脚本。
/// 反斜杠与 `//host` 一律拒绝 —— 它们在不同解析器里会被当成协议相对 URL，
/// 这种「各读各的」正是绕过白名单的老套路。
pub fn normalize_href(raw: &str) -> Option<String> {
    let href = raw.trim();
    if href.is_empty() || href.chars().count() > 300 {
        return None;
    }
    if href
        .chars()
        .any(|c| c <= '\u{1f}' || c == '\u{7f}' || c.is_whitespace())
    {
        return None;
    }
    if href.contains('\\') || href.starts_with("//") {
        return None;
    }
    if href.starts_with('/') {
        return Some(href.to_string());
    }
    let lower = href.to_ascii_lowercase();
    let rest = lower.strip_prefix("https://")?;
    // 主机名不能为空，也不能只有一个点。路径 / 查询 / 片段都允许。
    let host = rest
        .split(['/', '?', '#'])
        .next()
        .unwrap_or_default();
    if host.is_empty() || host == "." {
        return None;
    }
    Some(href.to_string())
}

/// 轮播位类型的字典键（界面按语言取词）
pub fn kind_label_key(kind: CarouselKind) -> &'static str {
    match kind {
        CarouselKind::Novel => "carousel.kind.novel",
        CarouselKind::Author => "carousel.kind.author",
        CarouselKind::Publisher => "carousel.kind.publisher",
        CarouselKind::Link => "carousel.kind.link",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn href_allows_internal_and_https_only() {
        assert_eq!(normalize_href(" /novel?id=n1 "), Some("/novel?id=n1".into()));
        assert_eq!(
            normalize_href("https://example.org/a?b=1"),
            Some("https://example.org/a?b=1".into())
        );
        assert_eq!(normalize_href("HTTPS://Example.org"), Some("HTTPS://Example.org".into()));
        assert_eq!(normalize_href("http://example.org"), None);
        assert_eq!(normalize_href("javascript:alert(1)"), None);
        assert_eq!(normalize_href("data:text/html,hi"), None);
        assert_eq!(normalize_href("//evil.example"), None);
        assert_eq!(normalize_href("/\\evil.example"), None);
        assert_eq!(normalize_href("https://"), None);
        assert_eq!(normalize_href("https://exa mple.org"), None);
    }
}