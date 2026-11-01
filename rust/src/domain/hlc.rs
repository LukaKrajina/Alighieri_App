//! 混合逻辑时钟（Hybrid Logical Clock）
//! ------------------------------------
//! CRDT 定序的核心。没有中心服务器来发号，而各设备本地时钟可能漂移、
//! 甚至被恶意回拨 —— 于是有了 HLC：本地时间加上一点记性。
//!
//! ```text
//! send():     l' = max(l, pt, c) + 1
//! receive(p): l' = max(l, pt, p.l, p.c + 1)
//! ```
//!
//! 序列化格式为 `"wall:counter:node"`，wall 为毫秒（base36），counter 吸收
//! 同毫秒内的并发，node 为 peerId 前 8 位 —— 冲突时它当裁判，判罚完全可复现。

use std::cmp::Ordering;

/// 解码后的 HLC 三元组
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DecodedHlts {
    pub wall: u64,
    pub counter: u64,
    pub node: [u8; 8],
}

impl DecodedHlts {
    /// node 分量以 UTF-8 字符串形式取出（尾部零填充被去掉）
    pub fn node_str(&self) -> String {
        let end = self.node.iter().position(|b| *b == 0).unwrap_or(8);
        String::from_utf8_lossy(&self.node[..end]).into_owned()
    }
}

fn to_base36(mut n: u64) -> String {
    if n == 0 {
        return "0".into();
    }
    let mut out = Vec::new();
    while n > 0 {
        let d = (n % 36) as u8;
        out.push(if d < 10 { b'0' + d } else { b'a' + (d - 10) });
        n /= 36;
    }
    out.reverse();
    String::from_utf8(out).unwrap_or_default()
}

fn from_base36(s: &str) -> u64 {
    s.chars()
        .try_fold(0u64, |acc, c| {
            let d = c.to_digit(36)? as u64;
            acc.checked_mul(36)?.checked_add(d)
        })
        .unwrap_or(0)
}

pub fn encode_hlts(wall: u64, counter: u64, node: &str) -> String {
    let padded = format!("{:0>9}", to_base36(wall));
    format!("{}:{}:{}", padded, to_base36(counter), node)
}

pub fn decode_hlts(s: &str) -> DecodedHlts {
    let mut it = s.split(':');
    let wall = from_base36(it.next().unwrap_or("0"));
    let counter = from_base36(it.next().unwrap_or("0"));
    let node_raw = it.next().unwrap_or("").as_bytes();
    let mut node = [0u8; 8];
    let n = node_raw.len().min(8);
    node[..n].copy_from_slice(&node_raw[..n]);
    DecodedHlts { wall, counter, node }
}

/// 比较两个 HLC。`Ordering::Greater` 表示 a 更新，平局由 node 字节序收场。
pub fn compare_hlts(a: &str, b: &str) -> Ordering {
    let x = decode_hlts(a);
    let y = decode_hlts(b);
    match x.wall.cmp(&y.wall) {
        Ordering::Equal => match x.counter.cmp(&y.counter) {
            // 同一逻辑时刻：以 node id 的字节序做确定性 tie-break
            Ordering::Equal => x.node.cmp(&y.node),
            o => o,
        },
        o => o,
    }
}

/// a 是否严格比 b 新
pub fn newer(a: &str, b: &str) -> bool {
    compare_hlts(a, b) == Ordering::Greater
}

pub fn max_hlts<'a>(a: &'a str, b: &'a str) -> &'a str {
    if compare_hlts(a, b) >= Ordering::Equal { a } else { b }
}

/// 取 HLC 里的物理时间分量（毫秒）
pub fn wall_of(h: &str) -> u64 {
    decode_hlts(h).wall
}

pub struct HybridClock {
    wall: u64,
    counter: u64,
    node: String,
}

impl HybridClock {
    pub fn new(node: &str, initial: Option<&str>) -> Self {
        let mut clock = HybridClock {
            wall: 0,
            counter: 0,
            node: node.chars().take(8).collect(),
        };
        if let Some(h) = initial {
            let d = decode_hlts(h);
            clock.wall = d.wall;
            clock.counter = d.counter;
        }
        clock
    }

    /// 本地产生一个事件
    pub fn now(&mut self, physical_ms: u64) -> String {
        if physical_ms > self.wall {
            self.wall = physical_ms;
            self.counter = 0;
        } else {
            self.counter += 1;
        }
        self.stamp()
    }

    /// 收到远端时间戳，推进本地时钟
    pub fn observe(&mut self, remote: &str, physical_ms: u64) -> String {
        let r = decode_hlts(remote);
        let max_wall = self.wall.max(physical_ms).max(r.wall);
        self.counter = if max_wall == self.wall && max_wall == r.wall {
            self.counter.max(r.counter) + 1
        } else if max_wall == self.wall {
            self.counter + 1
        } else if max_wall == r.wall {
            r.counter + 1
        } else {
            0
        };
        self.wall = max_wall;
        self.stamp()
    }

    fn stamp(&self) -> String {
        encode_hlts(self.wall, self.counter, &self.node)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base36_roundtrip() {
        for n in [0u64, 1, 35, 36, 1234567, u64::MAX / 3] {
            let s = to_base36(n);
            assert_eq!(from_base36(&s), n, "roundtrip failed for {n} -> {s}");
        }
    }

    #[test]
    fn order_by_wall_then_counter_then_node() {
        let a = encode_hlts(1000, 0, "aaaaaaaa");
        let b = encode_hlts(1000, 1, "aaaaaaaa");
        let c = encode_hlts(1000, 0, "bbbbbbbb");
        assert!(compare_hlts(&b, &a) == Ordering::Greater);
        assert!(compare_hlts(&c, &a) == Ordering::Greater);
        assert!(compare_hlts(&a, &a) == Ordering::Equal);
    }

    #[test]
    fn clock_monotonic_and_absorbs_remote() {
        let mut c = HybridClock::new("node1234", None);
        let t1 = c.now(1000);
        let t2 = c.now(1000); // 同一毫秒 -> counter 递增
        assert!(compare_hlts(&t2, &t1) == Ordering::Greater);
        // 远端时钟远在未来 -> 本地被推进
        let far = encode_hlts(999_999_999, 0, "zzzz");
        let t3 = c.observe(&far, 1000);
        assert!(compare_hlts(&t3, &far) == Ordering::Greater);
    }
}
