//! 由 peerId 派生笔名
//! ------------------
//! 注册时不需要填笔名：身份是一把 Ed25519 私钥，peerId 是公钥的多重哈希，
//! 笔名直接由 peerId 哈希派生，保证「一个身份 ↔ 一个笔名」且同一语言环境下
//! 全网一致。
//!
//! 为什么要自动派生而不是让用户自填：
//!   - 笔名一旦允许自填，就必然出现冒充（冒用他人笔名）与重名纠纷；
//!   - 自动派生让「署名 = 身份」成为可验证的事实，而不是一句声明。
//!
//! 笔名是**显示名**，不是身份：同一 peerId 在中文界面显示中文笔名、
//! 在日语界面显示日文笔名、在俄语界面显示俄文笔名……由观察者的界面语言
//! 决定（`set_locale` 由引擎在每次调用前设置）。因此不同语言的设备
//! 显示同一身份的不同笔名是预期行为；peerId 永远是唯一准绳。
//!
//! 用户仍然可以显式改笔名（发 profile.put），但那会覆盖派生值，
//! 且作者页会标注「自定义笔名」，不会伪装成系统派生名。
//! 「是否为派生名」按**全部支持语言**的候选集判断，所以切换界面语言
//! 不会把系统名误标成自定义名。

use std::cell::RefCell;

/// FNV-1a 32 位。与 Web 版 `lib/utils.ts` 的 `hash()` 逐位一致：
/// 同一段 peerId 在浏览器与本程序里必须派生出同一个笔名。
pub fn fnv1a(s: &str) -> u32 {
    let mut h: u32 = 2166136261;
    for b in s.as_bytes() {
        h ^= *b as u32;
        h = h.wrapping_mul(16777619);
    }
    h
}

/* ------------------------- 中文 ------------------------- */

/// 前缀表（40 个单字 + 16 个双字 = 56）。
///
/// ⚠️ Web 版 `lib/p2p/penname.ts` 的注释写的是「68 种」，实际数组只有 56 项。
/// 派生只依赖数组内容（`pick` 用 `arr.length`），所以这里按**实际内容**照抄，
/// 笔名才会在两个客户端上一致；注释里的数目是那边的笔误 —— 以数组为准，
/// 不以注释为准。
const ZH_PREFIX: [&str; 56] = [
    // 单字
    "夜", "星", "雨", "雪", "风", "云", "月", "墨", "白", "青", "苍", "无", "有", "初", "未", "半",
    "孤", "千", "万", "一", "南", "北", "东", "西", "上", "下", "深", "浅", "长", "远", "清", "寂",
    "晓", "暮", "寒", "暖", "虚", "实", "明", "暗",
    // 双字
    "长夜", "白昼", "深海", "远山", "孤岛", "空城", "旧梦", "新雪", "黄昏", "子夜", "拂晓", "残月",
    "浮云", "流光", "星海", "山海",
];

/// 后缀表（30 个单字 + 8 个双字 = 38）。同上：Web 版注释写 68，数组里实际 38 ——
/// 又是同一个笔误。
const ZH_SUFFIX: [&str; 38] = [
    // 单字
    "行", "语", "声", "影", "舟", "客", "生", "记", "谭", "说", "手", "笔", "心", "梦", "书", "页",
    "章", "曲", "歌", "诗", "灯", "火", "砂", "海", "山", "川", "林", "空", "翼", "羽",
    // 双字
    "不眠", "未完", "将醒", "有终", "无声", "独行", "入梦", "临别",
];

const ZH_JOINER: [&str; 8] = ["", "", "", "", "·", "-", "_", "の"];

/* ------------------------- 日语（假名保证出现在每个名字里） ------------------------- */

const JA_PREFIX: [&str; 30] = [
    "星野", "夜桜", "雨宮", "月影", "風間", "雪村", "白夜", "蒼井", "千夜", "朝霧",
    "夕凪", "小春", "遠野", "清瀬", "暁", "暮", "ルナ", "ソラ", "ミナ", "ユキ",
    "カイ", "レン", "アキ", "ヒカリ", "ツキ", "ホシ", "ネオン", "アオ", "シオン", "ノア",
];

/// 后缀全是平假名 / 片假名：保证任何日语笔名都含有假名，而不是纯汉字。
const JA_SUFFIX: [&str; 26] = [
    "ひかり", "かなで", "ゆめ", "そら", "みな", "ゆき", "ルカ", "ノア", "ミライ", "キリ",
    "サクラ", "ナギ", "シオン", "アオイ", "コハル", "レイ", "トワ", "ツキ", "ホシ", "カナタ",
    "ミオ", "ユウ", "ハル", "ナツ", "フユ", "アキ",
];

const JA_JOINER: [&str; 6] = ["", "", "", "・", "の", "＝"];

/* ------------------------- 俄语 ------------------------- */

const RU_PREFIX: [&str; 34] = [
    "Луна", "Ветер", "Мороз", "Снег", "Ночь", "Заря", "Тень", "Свет", "Туман", "Река",
    "Гроза", "Звезда", "Пепел", "Иней", "Рассвет", "Закат", "Тишина", "Даль", "Волна", "Огонь",
    "Север", "Юг", "Восток", "Запад", "Небо", "Земля", "Полынь", "Мёд", "Сажа", "Ива",
    "Клён", "Ель", "Рожь", "Мгла",
];

const RU_SUFFIX: [&str; 34] = [
    "Ветров", "Лунов", "Морозов", "Снегов", "Ночёв", "Зорин", "Тенев", "Светов", "Туманов", "Речкин",
    "Грозин", "Звёздов", "Пепелин", "Инеев", "Рассветов", "Закатов", "Тишин", "Далёв", "Волнов", "Огнев",
    "Северов", "Югов", "Востоков", "Западов", "Небов", "Землин", "Полынин", "Медов", "Сажин", "Ивин",
    "Клёнов", "Елин", "Ржов", "Мглин",
];

const RU_JOINER: [&str; 7] = [" ", " ", "", "", "·", "-", "—"];

/* ------------------------- 英语 ------------------------- */

const EN_PREFIX: [&str; 32] = [
    "Luna", "Nova", "Rain", "Snow", "Wind", "Cloud", "Moon", "Ink", "Ash", "Sky",
    "Star", "Ember", "Echo", "Raven", "Willow", "Sage", "Night", "Dawn", "Dusk", "Frost",
    "Mist", "River", "Storm", "Vale", "Wren", "Reed", "Hollow", "Amber", "Ivy", "Juniper",
    "Cypress", "Rowan",
];

const EN_SUFFIX: [&str; 34] = [
    "Vale", "Night", "Song", "Page", "Wind", "Frost", "Moon", "Reed", "Hart", "Lane",
    "Brook", "Stone", "Field", "Skye", "Wren", "Cross", "Grey", "Black", "Bright", "Hale",
    "Rowe", "West", "North", "East", "South", "Ash", "Ember", "Rain", "Snow", "Star",
    "Lark", "Moss", "Fern", "Quill",
];

const EN_JOINER: [&str; 7] = [" ", " ", " ", "", ".", "-", ""];

/* ------------------------- 韩语 ------------------------- */

const KO_PREFIX: [&str; 30] = [
    "하늘", "달빛", "별빛", "비", "눈", "바람", "구름", "달", "먹", "새벽",
    "노을", "안개", "강", "바다", "산", "숲", "은하", "우주", "빛", "소리",
    "꿈", "페이지", "책", "노래", "겨울", "여름", "가을", "봄", "밤", "낮",
];

const KO_SUFFIX: [&str; 30] = [
    "하늘", "달", "빛", "소리", "노래", "이야기", "기록", "꿈", "페이지", "새벽",
    "밤", "별", "강", "산", "바다", "숲", "눈", "비", "바람", "구름",
    "마루", "재", "새", "길", "돌", "풀", "잎", "꽃", "안개", "노을",
];

const KO_JOINER: [&str; 5] = ["", "", " ", "·", "-"];

/* ------------------------- 语言选择 ------------------------- */

struct Bank {
    prefixes: &'static [&'static str],
    suffixes: &'static [&'static str],
    joiners: &'static [&'static str],
}

static ZH_BANK: Bank = Bank {
    prefixes: ZH_PREFIX.as_slice(),
    suffixes: ZH_SUFFIX.as_slice(),
    joiners: ZH_JOINER.as_slice(),
};
static JA_BANK: Bank = Bank {
    prefixes: JA_PREFIX.as_slice(),
    suffixes: JA_SUFFIX.as_slice(),
    joiners: JA_JOINER.as_slice(),
};
static RU_BANK: Bank = Bank {
    prefixes: RU_PREFIX.as_slice(),
    suffixes: RU_SUFFIX.as_slice(),
    joiners: RU_JOINER.as_slice(),
};
static EN_BANK: Bank = Bank {
    prefixes: EN_PREFIX.as_slice(),
    suffixes: EN_SUFFIX.as_slice(),
    joiners: EN_JOINER.as_slice(),
};
static KO_BANK: Bank = Bank {
    prefixes: KO_PREFIX.as_slice(),
    suffixes: KO_SUFFIX.as_slice(),
    joiners: KO_JOINER.as_slice(),
};

/// 支持的语言（判断「是否派生名」时逐一比对）。
pub const PEN_LOCALES: [&str; 5] = ["zh", "en", "ja", "ko", "ru"];

/// 把 `zh-CN` / `zh_TW` / `ja-JP` 这类 locale 归一到词库语言。
fn lang_of(locale: &str) -> &'static str {
    let l = locale.trim().to_ascii_lowercase();
    if l.starts_with("zh") {
        "zh"
    } else if l.starts_with("ja") {
        "ja"
    } else if l.starts_with("ko") {
        "ko"
    } else if l.starts_with("ru") {
        "ru"
    } else {
        "en"
    }
}

fn bank_for(locale: &str) -> &'static Bank {
    match lang_of(locale) {
        "zh" => &ZH_BANK,
        "ja" => &JA_BANK,
        "ko" => &KO_BANK,
        "ru" => &RU_BANK,
        _ => &EN_BANK,
    }
}

thread_local! {
    /// 当前线程的界面语言。引擎在每次跨 FFI 调用前设置；
    /// 直接用 `pen_name_from` 的测试/工具代码默认中文。
    static ACTIVE_LOCALE: RefCell<String> = const { RefCell::new(String::new()) };
}

pub fn set_locale(locale: &str) {
    ACTIVE_LOCALE.with(|l| {
        *l.borrow_mut() = locale.to_string();
    });
}

pub fn current_locale() -> String {
    ACTIVE_LOCALE.with(|l| {
        let s = l.borrow();
        if s.is_empty() {
            "zh".to_string()
        } else {
            s.clone()
        }
    })
}

fn pick(list: &[&'static str], r: f64) -> &'static str {
    let i = ((r * list.len() as f64).floor() as usize) % list.len();
    list[i]
}

/// 按指定语言生成笔名（同一 peerId + 同一语言 = 同一结果）。
///
/// 命名空间：前缀 × 后缀 × 连接符 ≈ 1.4 万–2 万，其中约一半落在
/// 2 段名字上。由于字库有限，全网规模下**必然**会出现同名 ——
/// 这是显示名，不是身份，撞名了也不代表是同一个人。身份永远是 peerId，
/// 作者页与作品页都会同时展示两者以消除歧义。
///
/// 注意：这些字是**内容**（作者的署名），不是界面标签，所以不走字典。
pub fn pen_name_from_locale(peer_id: &str, locale: &str) -> String {
    let bank = bank_for(locale);
    let h = fnv1a(&format!("pen:{peer_id}"));
    // 用不同比特段取样，避免各段取值高度相关
    let a = pick(bank.prefixes, (h & 0xff) as f64 / 256.0);
    let b = pick(bank.suffixes, ((h >> 8) & 0xff) as f64 / 256.0);
    let j = pick(bank.joiners, ((h >> 16) & 0x7) as f64 / 8.0);
    // 约 1/3 的概率追加第三段，进一步降低撞名。
    // 拉丁/西里尔词库用空格分隔，中日韩直接连写。
    if ((h >> 20) & 0xff) as f64 / 256.0 < 0.34 {
        let c = pick(bank.suffixes, ((h >> 28) & 0xff) as f64 / 256.0);
        let sep = match lang_of(locale) {
            "en" | "ru" => " ",
            _ => "",
        };
        return format!("{a}{j}{b}{sep}{c}");
    }
    format!("{a}{j}{b}")
}

/// 按当前线程的界面语言派生（引擎已设置；默认中文）。
pub fn pen_name_from(peer_id: &str) -> String {
    pen_name_from_locale(peer_id, &current_locale())
}

const BIO_LINES: [&str; 4] = [
    "在 P2P 网络上写东西。",
    "业余写手，更新看心情。",
    "相信文字应该属于作者，而不是平台。",
    "这里的每一本都在你自己的设备上存了一份。",
];

/// 简介区的默认自我介绍
pub fn default_bio(peer_id: &str) -> &'static str {
    let h = fnv1a(&format!("bio:{peer_id}"));
    let i = ((h % 1000) as usize * BIO_LINES.len()) / 1000;
    BIO_LINES[i.min(BIO_LINES.len() - 1)]
}

/// 判断某个笔名是否为系统派生名（作者页用来打标）。
///
/// 逐语言比对：用户在中文界面用系统名，切到日语界面后
/// 作者页不能把那条中文系统名标成「自定义」。
pub fn is_derived(peer_id: &str, name: &str) -> bool {
    PEN_LOCALES
        .iter()
        .any(|locale| name == pen_name_from_locale(peer_id, locale))
}

/// 该身份在**当前界面语言**下的派生名。
pub fn derived_name(peer_id: &str) -> String {
    pen_name_from(peer_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn has_any(s: &str, range: impl Fn(char) -> bool) -> bool {
        s.chars().any(range)
    }

    #[test]
    fn penname_is_deterministic_and_stable() {
        let a = pen_name_from("12D3KooWTEST");
        let b = pen_name_from("12D3KooWTEST");
        assert_eq!(a, b);
        assert!(!a.is_empty());
    }

    #[test]
    fn different_peers_usually_differ() {
        let set: std::collections::BTreeSet<String> = (0..200)
            .map(|i| pen_name_from_locale(&format!("12D3KooW{i}"), "zh"))
            .collect();
        // 200 个样本应当几乎不碰撞
        assert!(set.len() > 190, "撞名过多：{}", 200 - set.len());
    }

    #[test]
    fn derived_flag() {
        let p = "12D3KooWTEST";
        // 任意语言的系统名都算派生名
        for locale in PEN_LOCALES {
            assert!(is_derived(p, &pen_name_from_locale(p, locale)));
        }
        assert!(!is_derived(p, "我自己起的名字"));
    }

    #[test]
    fn locale_banks_use_the_expected_scripts() {
        let peers: Vec<String> = (0..40).map(|i| format!("12D3KooW{i}")).collect();

        let zh: Vec<String> = peers.iter().map(|p| pen_name_from_locale(p, "zh")).collect();
        assert!(
            zh.iter().all(|n| has_any(n, |c| ('\u{4e00}'..='\u{9fff}').contains(&c))),
            "中文笔名应含汉字：{zh:?}"
        );

        let ja: Vec<String> = peers.iter().map(|p| pen_name_from_locale(p, "ja")).collect();
        assert!(
            ja.iter().all(|n| has_any(n, |c| ('\u{3040}'..='\u{30ff}').contains(&c))),
            "日文笔名应含平假名/片假名：{ja:?}"
        );

        let ru: Vec<String> = peers.iter().map(|p| pen_name_from_locale(p, "ru")).collect();
        assert!(
            ru.iter().all(|n| has_any(n, |c| ('\u{0400}'..='\u{04ff}').contains(&c))),
            "俄文笔名应含西里尔字母：{ru:?}"
        );

        let ko: Vec<String> = peers.iter().map(|p| pen_name_from_locale(p, "ko")).collect();
        assert!(
            ko.iter().all(|n| has_any(n, |c| ('\u{ac00}'..='\u{d7af}').contains(&c))),
            "韩文笔名应含谚文：{ko:?}"
        );

        let en: Vec<String> = peers.iter().map(|p| pen_name_from_locale(p, "en")).collect();
        assert!(
            en.iter().all(|n| n.chars().all(|c| c.is_ascii())),
            "英文笔名应为 ASCII：{en:?}"
        );

        let same_peer = "12D3KooWfixed";
        assert_ne!(
            pen_name_from_locale(same_peer, "zh"),
            pen_name_from_locale(same_peer, "ja"),
            "同一身份在不同语言下应有不同笔名"
        );
    }

    #[test]
    fn locale_tags_fall_back_correctly() {
        assert_eq!(pen_name_from_locale("p", "zh-CN"), pen_name_from_locale("p", "zh"));
        assert_eq!(pen_name_from_locale("p", "ja-JP"), pen_name_from_locale("p", "ja"));
        assert_eq!(pen_name_from_locale("p", "de-DE"), pen_name_from_locale("p", "en"));
    }

    /// FNV-1a 与 Web 版一致：这几个值是 JS 侧手算可得的固定点
    #[test]
    fn fnv1a_matches_reference() {
        assert_eq!(fnv1a(""), 2166136261);
        assert_eq!(fnv1a("a"), 0xe40c292c);
        assert_eq!(fnv1a("foobar"), 0xbf9cf968);
    }
}
