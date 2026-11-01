//! 本地存储
//! --------
//! op log 是**只追加**的：每条 op 一行 JSON，落盘即事实。
//! 视图不落盘 —— 它是 op log 的纯函数结果，重放一遍就回来了。
//! 这样「视图与日志不一致」这类 bug 连出现的机会都没有。
//!
//! 数据目录由宿主（Flutter）传入：三个平台各有各的规范位置，
//! 与其在 Rust 里猜，不如让平台侧给 —— 猜错了，数据就会跑去奇怪的地方。

use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

use crate::domain::model::Op;
use crate::vault::EncryptedIdentity;

const OPLOG_FILE: &str = "oplog.jsonl";
const IDENTITY_FILE: &str = "identity.json";
const SETTINGS_FILE: &str = "settings.json";
/// op log 的裁剪上限：保留最近这么多条
pub const DEFAULT_OPLOG_KEEP: usize = 2000;

/// 磁盘上身份文件的三种形态。明文与加密各自有独立的 JSON 形状，
/// 靠字段判断；旧的明文身份（无口令）仍然能读。
#[derive(Debug, Clone, PartialEq)]
pub enum IdentityFile {
    /// 身份文件不存在（或损坏到无法判断）
    Missing,
    /// 明文：`{seed, createdAtMs}`
    Plain { seed: String, created_ms: u64 },
    /// 口令加密：`{v, iters, salt, nonce, data}`
    Encrypted(EncryptedIdentity),
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, Default)]
pub struct Settings {
    pub locale: String,
    pub theme_mode: String,
    pub hue: i32,
    pub sat: i32,
    /// 0 = 纯色，1 = 最通透。刻度与系统偏好无关，纯色端保证对比度始终可达。
    pub glass_level: f64,
    pub reader_font_scale: f64,
    /// 阅读器背景：paper / white / dark
    #[serde(default = "default_reader_theme")]
    pub reader_theme: String,
    /// 行距倍数
    #[serde(default = "default_reader_line_height")]
    pub reader_line_height: f64,
    /// scroll = 上下滚动；page = 左右翻章
    #[serde(default = "default_reader_page_mode")]
    pub reader_page_mode: String,
    /// 滚动到章末自动进入下一章
    #[serde(default = "default_reader_auto_next")]
    pub reader_auto_next: bool,
    /// 联邦审查阈值：多少个不同身份举报后在本机屏蔽（默认 3）
    pub review_threshold: u64,
    /// 审查只统计「我的信任圈」内的举报票（默认关）。开了之后，
    /// 信任圈外身份的举报不计入本机阈值 —— 这是本机偏好的诚实选项。
    #[serde(default)]
    pub review_trust_only: bool,
    /// 自动整合无冲突的贡献提案（只在本机在线时生效）
    pub auto_merge: bool,
    /// 本机豁免（仍要查看）的作品
    pub exempt: Vec<String>,
    /// 手动指定的引导节点地址
    #[serde(default)]
    pub bootstrap: Vec<String>,
    /// 站点自己的地址（用于拉取 `/.well-known/libp2p` 节点清单，以及 DNS TXT 引导）
    #[serde(default)]
    pub site_url: String,
    /// 手动指定的中继节点（Circuit Relay v2）；为空时使用内置公共中继
    #[serde(default)]
    pub relays: Vec<String>,

    /* -------- 上链桥接（默认全空 = 不显示上链入口） -------- */
    /// 唯一桥接节点 peerId
    #[serde(default)]
    pub bridge_peer_id: String,
    /// 申领接口基址（必须是 https）
    #[serde(default)]
    pub bridge_api_url: String,
    /// 已部署的 ERC-20 合约地址
    #[serde(default)]
    pub bridge_contract: String,
    /// 链 id：1 = 以太坊主网，11155111 = Sepolia
    #[serde(default = "default_chain_id")]
    pub bridge_chain_id: u64,
    /// 链上代币符号
    #[serde(default = "default_bridge_symbol")]
    pub bridge_symbol: String,

    /* -------- 赞助收款方式（默认全空 = 页面显示待配置） -------- */
    /// 支付宝收款码里的文本（不是图片路径）
    #[serde(default)]
    pub sponsor_alipay: String,
    /// 微信收款码里的文本
    #[serde(default)]
    pub sponsor_wechat: String,
    /// USDT 收款地址（EVM）
    #[serde(default)]
    pub sponsor_usdt: String,
    /// ETH 收款地址
    #[serde(default)]
    pub sponsor_eth: String,
    /// 赞助页的一句说明
    #[serde(default)]
    pub sponsor_note: String,
}

fn default_reader_theme() -> String {
    "paper".into()
}

fn default_reader_line_height() -> f64 {
    1.9
}

fn default_reader_page_mode() -> String {
    "scroll".into()
}

fn default_reader_auto_next() -> bool {
    true
}

fn default_chain_id() -> u64 {
    1
}

fn default_bridge_symbol() -> String {
    "CALC".into()
}

impl Settings {
    pub fn defaults() -> Self {
        Settings {
            locale: "zh".into(),
            theme_mode: "light".into(),
            hue: 152,
            sat: 64,
            glass_level: 0.55,
            reader_font_scale: 1.0,
            reader_theme: default_reader_theme(),
            reader_line_height: default_reader_line_height(),
            reader_page_mode: default_reader_page_mode(),
            reader_auto_next: default_reader_auto_next(),
            review_threshold: 3,
            review_trust_only: false,
            auto_merge: false,
            exempt: Vec::new(),
            bootstrap: Vec::new(),
            site_url: String::new(),
            relays: Vec::new(),
            bridge_peer_id: String::new(),
            bridge_api_url: String::new(),
            bridge_contract: String::new(),
            bridge_chain_id: 1,
            bridge_symbol: "CALC".into(),
            sponsor_alipay: String::new(),
            sponsor_wechat: String::new(),
            sponsor_usdt: String::new(),
            sponsor_eth: String::new(),
            sponsor_note: String::new(),
        }
    }
}

pub struct Store {
    dir: PathBuf,
}

impl Store {
    pub fn open(dir: &str) -> Result<Store, String> {
        let path = if dir.is_empty() {
            PathBuf::from("alighieri-data")
        } else {
            PathBuf::from(dir)
        };
        fs::create_dir_all(&path).map_err(|e| format!("无法创建数据目录 {path:?}：{e}"))?;
        Ok(Store { dir: path })
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    fn oplog_path(&self) -> PathBuf {
        self.dir.join(OPLOG_FILE)
    }

    /// 追加一条 op（只追加，不改写既有行）
    pub fn append_op(&self, op: &Op) -> Result<(), String> {
        let line = serde_json::to_string(op).map_err(|e| format!("op 序列化失败：{e}"))?;
        let mut f = OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.oplog_path())
            .map_err(|e| format!("打开 op log 失败：{e}"))?;
        writeln!(f, "{line}").map_err(|e| format!("写入 op log 失败：{e}"))?;
        f.sync_all().map_err(|e| format!("刷盘失败：{e}"))?;
        Ok(())
    }

    pub fn append_ops(&self, ops: &[Op]) -> Result<(), String> {
        if ops.is_empty() {
            return Ok(());
        }
        let mut f = OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.oplog_path())
            .map_err(|e| format!("打开 op log 失败：{e}"))?;
        for op in ops {
            let line = serde_json::to_string(op).map_err(|e| format!("op 序列化失败：{e}"))?;
            writeln!(f, "{line}").map_err(|e| format!("写入 op log 失败：{e}"))?;
        }
        f.sync_all().map_err(|e| format!("刷盘失败：{e}"))?;
        Ok(())
    }

    /// 读出全部 op。坏行跳过而不是让整个副本起不来 ——
    /// 一条坏数据不该让设备上所有已收到的作品一起消失。
    pub fn load_ops(&self) -> Result<Vec<Op>, String> {
        let p = self.oplog_path();
        if !p.exists() {
            return Ok(Vec::new());
        }
        let f = File::open(&p).map_err(|e| format!("读取 op log 失败：{e}"))?;
        let mut out = Vec::new();
        let mut bad = 0usize;
        for line in BufReader::new(f).lines() {
            let line = match line {
                Ok(l) => l,
                Err(_) => {
                    bad += 1;
                    continue;
                }
            };
            if line.trim().is_empty() {
                continue;
            }
            match serde_json::from_str::<Op>(&line) {
                Ok(op) => out.push(op),
                Err(_) => bad += 1,
            }
        }
        if bad > 0 {
            eprintln!("[alighieri] op log 里跳过了 {bad} 条无法解析的行");
        }
        Ok(out)
    }

    /// 裁剪：只保留最近 keep 条。
    ///
    /// 裁掉的是**本机副本的历史**，不是别人的：别人设备上的 op log 不受影响，
    /// 而且内容块（章节正文）在 op 里是自包含的，所以裁剪不会让读者丢正文 ——
    /// 别人的日志轮不到你管。
    pub fn trim_ops(&self, keep: usize) -> Result<usize, String> {
        let all = self.load_ops()?;
        if all.len() <= keep {
            return Ok(0);
        }
        let removed = all.len() - keep;
        let kept = &all[removed..];
        let tmp = self.dir.join(format!("{OPLOG_FILE}.tmp"));
        {
            let mut f = File::create(&tmp).map_err(|e| format!("创建临时文件失败：{e}"))?;
            for op in kept {
                let line = serde_json::to_string(op).map_err(|e| format!("序列化失败：{e}"))?;
                writeln!(f, "{line}").map_err(|e| format!("写入失败：{e}"))?;
            }
            f.sync_all().map_err(|e| format!("刷盘失败：{e}"))?;
        }
        fs::rename(&tmp, self.oplog_path()).map_err(|e| format!("替换 op log 失败：{e}"))?;
        Ok(removed)
    }

    pub fn save_identity(&self, seed_hex: &str, created_at_ms: u64) -> Result<(), String> {
        let v = serde_json::json!({ "seed": seed_hex, "createdAtMs": created_at_ms });
        write_json(&self.dir.join(IDENTITY_FILE), &v)
    }

    /// 用口令信封覆盖身份文件。加密后明文当场消失：
    /// 这里写的是 `{v, iters, salt, nonce, data}`，不再含种子 ——
    /// 覆盖得很彻底，没有留备份。
    pub fn save_encrypted_identity(&self, boxed: &EncryptedIdentity) -> Result<(), String> {
        write_json(&self.dir.join(IDENTITY_FILE), boxed)
    }

    pub fn load_identity(&self) -> Result<IdentityFile, String> {
        let p = self.dir.join(IDENTITY_FILE);
        if !p.exists() {
            return Ok(IdentityFile::Missing);
        }
        let v = read_json(&p)?;
        // 加密信封的标志：带 salt/nonce/data
        if v.get("salt").and_then(|x| x.as_str()).is_some()
            && v.get("nonce").and_then(|x| x.as_str()).is_some()
            && v.get("data").and_then(|x| x.as_str()).is_some()
        {
            return match serde_json::from_value::<EncryptedIdentity>(v) {
                Ok(b) => Ok(IdentityFile::Encrypted(b)),
                Err(_) => Ok(IdentityFile::Missing),
            };
        }
        let seed = v.get("seed").and_then(|x| x.as_str()).unwrap_or("").to_string();
        let created = v.get("createdAtMs").and_then(|x| x.as_u64()).unwrap_or(0);
        if seed.is_empty() {
            return Ok(IdentityFile::Missing);
        }
        Ok(IdentityFile::Plain {
            seed,
            created_ms: created,
        })
    }

    pub fn save_settings(&self, s: &Settings) -> Result<(), String> {
        write_json(&self.dir.join(SETTINGS_FILE), s)
    }

    pub fn load_settings(&self) -> Result<Settings, String> {
        let p = self.dir.join(SETTINGS_FILE);
        if !p.exists() {
            return Ok(Settings::defaults());
        }
        let v = read_json(&p)?;
        Ok(serde_json::from_value(v).unwrap_or_else(|_| Settings::defaults()))
    }

    /// op log 的字节数（网络页的「本地存储」用）
    pub fn oplog_bytes(&self) -> u64 {
        fs::metadata(self.oplog_path()).map(|m| m.len()).unwrap_or(0)
    }

    /// 清空本机数据
    pub fn wipe(&self) -> Result<(), String> {
        for name in [OPLOG_FILE, IDENTITY_FILE, SETTINGS_FILE] {
            let p = self.dir.join(name);
            if p.exists() {
                fs::remove_file(p).map_err(|e| format!("删除 {name} 失败：{e}"))?;
            }
        }
        Ok(())
    }
}

fn write_json(p: &Path, v: &impl serde::Serialize) -> Result<(), String> {
    // 先写临时文件再改名：写一半崩掉不会留下一个损坏的身份文件
    let tmp = p.with_extension("tmp");
    let s = serde_json::to_string_pretty(v).map_err(|e| format!("序列化失败：{e}"))?;
    {
        let mut f = File::create(&tmp).map_err(|e| format!("创建 {p:?} 失败：{e}"))?;
        f.write_all(s.as_bytes()).map_err(|e| format!("写入失败：{e}"))?;
        f.sync_all().map_err(|e| format!("刷盘失败：{e}"))?;
    }
    fs::rename(&tmp, p).map_err(|e| format!("替换 {p:?} 失败：{e}"))?;
    Ok(())
}

fn read_json(p: &Path) -> Result<serde_json::Value, String> {
    let s = fs::read_to_string(p).map_err(|e| format!("读取 {p:?} 失败：{e}"))?;
    serde_json::from_str(&s).map_err(|e| format!("解析 {p:?} 失败：{e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::model::OpKind;

    fn tmpdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("alighieri-test-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        d
    }

    fn op(id: &str) -> Op {
        Op {
            id: id.into(),
            actor: "peerA".into(),
            hlts: "000000001:0:peerA".into(),
            kind: OpKind::NovelPut,
            key: format!("novel:{id}"),
            body: serde_json::json!({}),
            cid: None,
            v: 1,
            sig: None,
        }
    }

    #[test]
    fn identity_file_roundtrip_plain_and_encrypted() {
        let d = tmpdir("identity-vault");
        let s = Store::open(d.to_str().unwrap()).unwrap();
        // 明文（历史形态）
        s.save_identity("feedbeef012345", 123).unwrap();
        assert!(matches!(
            s.load_identity().unwrap(),
            IdentityFile::Plain { .. }
        ));
        // 加密信封
        let boxed = crate::vault::seal(
            b"{\"seed\":\"feedbeef012345\",\"createdAtMs\":123}",
            "a passphrase",
        )
        .unwrap();
        s.save_encrypted_identity(&boxed).unwrap();
        match s.load_identity().unwrap() {
            IdentityFile::Encrypted(b) => {
                assert_eq!(b.v, 1);
                let plain = crate::vault::open(&b, "a passphrase").unwrap();
                assert!(String::from_utf8_lossy(&plain).contains("feedbeef012345"));
                assert!(crate::vault::open(&b, "wrong passphrase").is_err());
            }
            other => panic!("期望加密信封，实际是 {other:?}"),
        }
        // 不存在的身份文件 = Missing
        let empty = tmpdir("identity-none");
        let s2 = Store::open(empty.to_str().unwrap()).unwrap();
        assert_eq!(s2.load_identity().unwrap(), IdentityFile::Missing);
        let _ = fs::remove_dir_all(&d);
        let _ = fs::remove_dir_all(&empty);
    }

    #[test]
    fn append_then_load_is_append_only() {
        let d = tmpdir("append");
        let s = Store::open(d.to_str().unwrap()).unwrap();
        s.append_ops(&[op("a"), op("b")]).unwrap();
        s.append_op(&op("c")).unwrap();
        let loaded = s.load_ops().unwrap();
        assert_eq!(loaded.len(), 3);
        assert_eq!(loaded[0].id, "a");
        assert_eq!(loaded[2].id, "c");
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn corrupt_lines_are_skipped_not_fatal() {
        let d = tmpdir("corrupt");
        let s = Store::open(d.to_str().unwrap()).unwrap();
        s.append_op(&op("a")).unwrap();
        {
            let mut f = OpenOptions::new().append(true).open(s.oplog_path()).unwrap();
            writeln!(f, "这不是 JSON").unwrap();
        }
        s.append_op(&op("b")).unwrap();
        assert_eq!(s.load_ops().unwrap().len(), 2, "坏行应当被跳过");
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn trim_keeps_the_newest() {
        let d = tmpdir("trim");
        let s = Store::open(d.to_str().unwrap()).unwrap();
        s.append_ops(&[op("a"), op("b"), op("c"), op("d")]).unwrap();
        assert_eq!(s.trim_ops(2).unwrap(), 2);
        let left = s.load_ops().unwrap();
        assert_eq!(left.iter().map(|o| o.id.clone()).collect::<Vec<_>>(), vec!["c", "d"]);
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn settings_roundtrip() {
        let d = tmpdir("settings");
        let s = Store::open(d.to_str().unwrap()).unwrap();
        let mut st = Settings::defaults();
        st.locale = "ja".into();
        st.review_threshold = 5;
        s.save_settings(&st).unwrap();
        let back = s.load_settings().unwrap();
        assert_eq!(back.locale, "ja");
        assert_eq!(back.review_threshold, 5);
        let _ = fs::remove_dir_all(&d);
    }
}