//! 许可证登记表
//! ------------
//! 参照 GitHub 的做法：作者在发布时明确选择授权条款，读者能看到条款全文与要点 ——
//! 不用去猜「保留所有权利」到底保留了哪些。
//!
//! 分两类：
//!   A. 通用创作许可（CC 系列、公有领域）—— 直接对齐 SPDX / Creative Commons；
//!   B. 连载/轻小说专用许可 —— 「允许在站内连载，但禁止训练模型 / 禁止改编」
//!      这类通用 CC 无法表达、又确实有作者需要的条款。
//!
//! 哪部分能翻译、哪部分不能：
//!   - `text`（条款正文）**永远只有中文**。它是 CC / 授权条款的权威措辞，
//!     非官方译文可能造成法律上的误导 —— 界面上标注「以下为原文」。
//!     这条没有例外：法律文本不搞机翻。
//!   - `name` / `summary` 是界面文案，走 `lic.name.<key>` / `lic.summary.<key>` 键。
//!   - `allows/requires/forbids` 存的是 **i18n 键**（`@` 前缀），不是文案。

/// 默认许可证（作者不选时使用）
pub const DEFAULT_LICENSE: &str = "alighieri-serial";

/// 收益分池表：三个池子加起来应当是 1 —— 多出来的那部分没人有权拿。
#[derive(Debug, Clone, Copy)]
pub struct ShareTable {
    pub canon: f64,
    pub translation: f64,
    pub ancillary: f64,
}

/// 没有内置分池表的许可使用这张默认表（与 ANPL 2.0 一致）
pub const DEFAULT_SHARE_TABLE: ShareTable = ShareTable {
    canon: 0.8,
    translation: 0.15,
    ancillary: 0.05,
};

pub struct LicenseDef {
    /// 站内稳定标识，同时用作 slug
    pub id: &'static str,
    /// SPDX 标识；若不对应任何 SPDX 则为 None
    pub spdx: Option<&'static str>,
    /// i18n 键的后缀：有 SPDX 用 SPDX，否则用 id
    pub key: &'static str,
    /// 徽标用的短名（不带「（推荐）」这类括注）
    pub short_name: &'static str,
    pub name: &'static str,
    pub category: &'static str,
    pub summary: &'static str,
    pub allows: &'static [&'static str],
    pub requires: &'static [&'static str],
    pub forbids: &'static [&'static str],
    /// 是否允许商业化
    pub commercial: bool,
    /// 是否允许改编 / 二创
    pub derivatives: bool,
    pub recommended: bool,
    /// 收益分池表；None = 使用 DEFAULT_SHARE_TABLE
    pub share: Option<ShareTable>,
    /// 条款正文（Markdown 风格纯文本，只有中文）
    pub text: &'static str,
}

pub const LICENSES: [LicenseDef; 8] = [
    LicenseDef {
        id: "cc0-1.0",
        spdx: Some("CC0-1.0"),
        key: "CC0-1.0",
        short_name: "CC0 1.0",
        name: "CC0 1.0 公共领域贡献",
        category: "public-domain",
        summary: "完全放弃著作权，任何人可自由使用、修改、商用，无需署名。",
        allows: &["@free-modify", "@commercial", "@no-attribution"],
        requires: &[],
        forbids: &[],
        commercial: true,
        derivatives: true,
        recommended: false,
        share: None,
        text: "CC0 1.0 Universal（公共领域贡献）\n\n作者以完全公开的方式放弃与本作品相关的所有著作权与邻接权，\n任何人都可以复制、修改、发行与商业使用，无需署名。\n\n注意：部分法域不承认彻底放弃著作权，此处按「尽可能宽的授权」理解。",
    },
    LicenseDef {
        id: "cc-by-4.0",
        spdx: Some("CC-BY-4.0"),
        key: "CC-BY-4.0",
        short_name: "CC BY 4.0",
        name: "CC BY 4.0 署名",
        category: "cc",
        summary: "可自由使用与商用，须保留作者署名。",
        allows: &["@free-modify", "@commercial", "@redistribute"],
        requires: &["@attribution", "@license-link", "@indicate-changes"],
        forbids: &[],
        commercial: true,
        derivatives: true,
        recommended: false,
        share: None,
        text: "Creative Commons Attribution 4.0 International（署名 4.0）\n\n你可以自由地分享、改编、甚至用于商业目的，\n前提是：以恰当方式标注作者姓名、许可协议链接，并说明是否作过修改。\n\n完整条款：https://creativecommons.org/licenses/by/4.0/deed.zh-hans",
    },
    LicenseDef {
        id: "cc-by-sa-4.0",
        spdx: Some("CC-BY-SA-4.0"),
        key: "CC-BY-SA-4.0",
        short_name: "CC BY-SA 4.0",
        name: "CC BY-SA 4.0 署名-相同方式共享",
        category: "cc",
        summary: "可商用与改编，改编作品必须以相同协议发布。",
        allows: &["@free-modify", "@commercial", "@redistribute"],
        requires: &["@attribution", "@share-alike", "@indicate-changes"],
        forbids: &[],
        commercial: true,
        derivatives: true,
        recommended: false,
        share: None,
        text: "Creative Commons Attribution-ShareAlike 4.0 International（署名-相同方式共享 4.0）\n\n在 BY 的基础上增加「传染性」条款：若你基于本作品创作了衍生作品，\n该衍生作品必须以 CC BY-SA 4.0 或兼容协议发布。\n\n完整条款：https://creativecommons.org/licenses/by-sa/4.0/deed.zh-hans",
    },
    LicenseDef {
        id: "cc-by-nc-4.0",
        spdx: Some("CC-BY-NC-4.0"),
        key: "CC-BY-NC-4.0",
        short_name: "CC BY-NC 4.0",
        name: "CC BY-NC 4.0 署名-非商业",
        category: "cc",
        summary: "可改编与再分发（须署名），但禁止任何商业用途。",
        allows: &["@free-modify", "@redistribute"],
        requires: &["@attribution"],
        forbids: &["@commercial"],
        commercial: false,
        derivatives: true,
        recommended: false,
        share: None,
        text: "Creative Commons Attribution-NonCommercial 4.0 International（署名-非商业 4.0）\n\n允许个人与教育、研究等非商业场景的复制、改编与再分发，须署名；\n任何以获利为目的的使用（包括但不限于付费转载、广告、周边）均被禁止。\n\n完整条款：https://creativecommons.org/licenses/by-nc/4.0/deed.zh-hans",
    },
    LicenseDef {
        id: "cc-by-nd-4.0",
        spdx: Some("CC-BY-ND-4.0"),
        key: "CC-BY-ND-4.0",
        short_name: "CC BY-ND 4.0",
        name: "CC BY-ND 4.0 署名-禁止演绎",
        category: "cc",
        summary: "可转载与商用（须署名），但不允许改动原文。",
        allows: &["@reprint", "@commercial"],
        requires: &["@attribution"],
        forbids: &["@adapt"],
        commercial: true,
        derivatives: false,
        recommended: false,
        share: None,
        text: "Creative Commons Attribution-NoDerivatives 4.0 International（署名-禁止演绎 4.0）\n\n原文可以被转载甚至用于商业用途（须署名），\n但任何形式的内容改动（续写、改编、翻译）都不被允许。\n\n完整条款：https://creativecommons.org/licenses/by-nd/4.0/deed.zh-hans",
    },
    LicenseDef {
        id: "alighieri-2.0",
        spdx: None,
        key: "alighieri-2.0",
        short_name: "ANPL 2.0",
        name: "ANPL 2.0（推荐）",
        category: "novel",
        summary: "连载期禁止 AI 训练、改编与商用；完结后允许全文转载与 AI 训练。平台授权放宽，但不得外部因素改稿。对出版社或其他平台，作者与作者组可无条件终止授权",
        allows: &["@serialise-here", "@personal-noncommercial", "@quote-in-comments", "@platform-relaxed", "@reprint-after-final", "@ai-training-after-final"],
        requires: &["@attribution-peerid", "@keep-order", "@no-text-edit", "@terminate-right", "@share-by-graph"],
        forbids: &["@ai-training-during-serial", "@adaptation-during-serial", "@commercial-during-serial", "@no-bundle-sales"],
        commercial: true,
        derivatives: true,
        recommended: true,
        share: Some(ShareTable { canon: 0.8, translation: 0.15, ancillary: 0.05 }),
        text: "ANPL 2.0\n\n一、定义\n  「连载期」= 作者尚未将作品标记为完结的期间。\n  「完结」由作者通过 signed 操作声明，可由作者本人或作者组成员发起。\n  「作者组」= 依据本作品贡献图谱取得贡献者身份的人构成的编辑组。\n\n二、连载期（未完结）\n  1. 允许在 Alighieri 网络（或任何兼容节点）免费连载本作品。\n  2. 禁止将本作品全文或实质性片段用于训练任何机器学习 / 大语言模型，\n     亦不得投喂至以「训练」为目的的数据集。\n  3. 禁止任何改编（出版、漫画、动画、影视、商业游戏等），\n     除非获得作者与作者组的明确书面授权。\n  4. 禁止任何商业使用，包括但不限于付费连载、付费阅读、\n     整本或大规模打包售卖。\n  5. 允许个人非商业性引用片段、评论与讨论。\n\n三、完结后\n  1. 允许他人全文转载，须保留作者署名（含 peerId）与作品链接。\n  2. 允许用于 AI 模型训练（此条在连载期不适用）。\n  3. 商业化仍需单独授权，但平台获得的是**放宽**的授权：\n     出版社与其他小说平台可在不改稿的前提下连载 / 转载 / 商业分发。\n  4. 平台**不得因任何外部因素改稿**：不得修改文字、删改章节、调整结局，\n     也不得因外部压力、商业要求或「编辑」名义要求作者修改稿件或结局。\n  5. 对出版社或其他平台，作者与作者组可**无条件终止授权**，自发布终止声明之时起生效，\n     平台须停止新增分发；已发出副本的既有授权不追溯撤销\n     （这一点由 CRDT 的单调性决定，技术上无法做到「全网撤回」）。\n\n四、收益分配\n  本许可内置分池表（正典 80% / 翻译 15% / 零散贡献 5%）：\n  1. 正典池按**实际贡献字数**分配：原作者的原创章节与被整合进来的\n     续写章节，按各自字数占比分配。\n  2. 翻译池在译者之间**平分**（不按译文字数加权）。\n  3. 零散贡献池（校对、评审等）**平分**，池子占比刻意很小。\n  4. 分配由本作品当前副本中的**贡献图谱**计算得出，是确定性纯函数，\n     任何人都能独立复算；平台不得以人工裁定改变分配结果。\n  5. 零散贡献的**存在**由贡献者自行声明并签名，声明的真实性无法\n     由网络核验；因此该池占比被限制在很小的范围内。\n\n五、作者权利\n  作者可随时发布新的 license.put 操作变更许可，\n  新许可只对其后发布的内容生效。\n\n六、免责\n  本许可由作者通过 peerId 签名发布。许可文本与选择过程记录在\n  作品的 op log 中，任何人都可以独立验证。\n\n*本条款不是法律意见。若需正式授权，请咨询专业律师。*",
    },
    LicenseDef {
        id: "alighieri-serial",
        spdx: None,
        key: "alighieri-serial",
        short_name: "ANPL 1.0",
        name: "ANPL 1.0",
        category: "novel",
        summary: "允许在站内免费连载与转载全文，禁止 AI 训练与未经授权的商业改编。",
        allows: &["@serialise-here", "@personal-noncommercial", "@quote-in-comments"],
        requires: &["@attribution-peerid", "@keep-order"],
        forbids: &["@ai-training", "@unauthorised-adaptation", "@no-bundle-sales"],
        commercial: false,
        derivatives: false,
        recommended: false,
        share: None,
        text: "ANPL 1.0\n\n一、授权范围\n  1. 允许你在 Alighieri（或任一兼容的 P2P 节点）免费连载本作品，\n     内容以 CRDT 操作形式在网络中复制，每个节点各自保留一份副本。\n  2. 允许他人和个人博客非商业性地转载全文，须保留作者署名（含 peerId）\n     与作品链接。\n  3. 允许评论、讨论与引用片段。\n\n二、限制\n  1. 不得将本作品全文或实质性片段用于训练任何机器学习 / 大语言模型，\n     亦不得投喂至以「训练」为目的的数据集。\n  2. 未经作者书面授权，不得进行商业化的改编（出版、影视、动画、\n     商业游戏、付费周边等）。\n  3. 不得整本或大规模打包售卖。\n  4. 转载时不得改变章节顺序，也不得删除作者声明。\n\n三、作者权利\n  作者可随时发布新的 license.put 操作变更许可，\n  新许可只对其后发布的内容生效；已有副本的既有授权不追溯撤销\n  （这一点由 CRDT 的单调性决定，技术上无法做到「全网撤回」）。\n\n四、免责\n  本许可由作者通过 peerId 签名发布。许可文本与选择过程记录在\n  作品的 op log 中，任何人都可以独立验证。\n\n*本条款不是法律意见。若需正式授权，请咨询专业律师并考虑采用\n  上述 CC 系列条款中的一种。*",
    },
    LicenseDef {
        id: "alighieri-reserved",
        spdx: None,
        key: "alighieri-reserved",
        short_name: "保留所有权利",
        name: "保留所有权利（默认）",
        category: "novel",
        summary: "仅授权本站免费连载，其余权利全部保留。",
        allows: &["@serialise-here", "@personal-quotes"],
        requires: &["@attribution-peerid"],
        forbids: &["@no-full-reprint", "@no-adapt", "@commercial", "@no-ai"],
        commercial: false,
        derivatives: false,
        recommended: false,
        share: None,
        text: "保留所有权利\n\n除「允许在 Alighieri 网络中免费连载」外，作者保留全部权利。\n\n即：允许阅读与个人引用片段，不允许全文转载、不允许改编、\n不允许任何商业使用、不允许用于 AI 模型训练。\n\n任何超出上述范围的利用，请通过作品的 P2P 身份（peerId）联系作者协商。",
    },
];

pub fn get_license(id: Option<&str>) -> &'static LicenseDef {
    match id.and_then(|i| LICENSES.iter().find(|l| l.id == i)) {
        Some(l) => l,
        None => LICENSES
            .iter()
            .find(|l| l.id == DEFAULT_LICENSE)
            .expect("DEFAULT_LICENSE 必须在登记表里"),
    }
}

/// 作品当前许可的分池表；没有内置表的许可使用默认表。
pub fn share_table_of(id: Option<&str>) -> ShareTable {
    get_license(id).share.unwrap_or(DEFAULT_SHARE_TABLE)
}

/// 判断一个条目是不是 i18n 键（`@` 前缀）
pub fn is_term_key(s: &str) -> bool {
    s.starts_with('@')
}

/// 键 -> 字典键
pub fn term_key_to_dict_key(s: &str) -> String {
    format!("lic.term.{}", s.trim_start_matches('@'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_license_exists_and_is_flagged() {
        let d = get_license(None);
        assert_eq!(d.id, DEFAULT_LICENSE);
        assert!(LICENSES.iter().any(|l| l.recommended));
    }

    #[test]
    fn share_tables_sum_to_one() {
        for l in &LICENSES {
            let t = l.share.unwrap_or(DEFAULT_SHARE_TABLE);
            let sum = t.canon + t.translation + t.ancillary;
            assert!((sum - 1.0).abs() < 1e-9, "{} 分池表合计 {sum}", l.id);
        }
    }

    #[test]
    fn unknown_id_falls_back_to_default() {
        assert_eq!(get_license(Some("不存在的许可")).id, DEFAULT_LICENSE);
    }

    #[test]
    fn every_license_has_text_and_unique_id() {
        let mut seen = std::collections::BTreeSet::new();
        for l in &LICENSES {
            assert!(!l.text.is_empty(), "{} 缺条款正文", l.id);
            assert!(seen.insert(l.id), "{} 重复", l.id);
        }
    }
}