//! 原生 libp2p 节点
//! -----------------
//! Web 版跑在浏览器里，用的是 WebRTC + WebSocket + circuit relay v2。
//! App 不能复用那套 JS，但**必须能和 Web 节点互相发现、互相广播**，
//! 这里用 Rust 侧 libp2p 实现同一张网：
//!
//!   · TCP + DNS + WebSocket（App ↔ App，也能拨浏览器节点的 WSS 地址）
//!   · circuit relay v2（NAT 后面的节点也能被拨通，并主动预约中继）
//!   · dcutr（在已建立的中继连接上自动尝试打洞，成功后退化成直连）
//!   · Kademlia DHT（用 provider 记录发现同样跑本站的节点）
//!   · gossipsub（主题 `alighieri/ops/v1`，实时广播 op）
//!   · request-response 对账（App ↔ App 之间补齐断线期间错过的 op）
//!
//! 诚实地说浏览器节点的 WebRTC 传输无法从原生 App 主动拨号，
//! 但浏览器节点通常会同时预约公共中继，因此通过中继电路仍然可达。
//! 完全找不到任何节点时，节点保持在线但网络页会显示「0 同伴」，
//! 本地阅读 / 写作 / 账本不依赖网络 —— 写小说本来也不用先凑齐一桌人。
//!
//! 线程模型：引擎是同步的（FRB 调用、poll pump），网络是 Tokio 的。
//! 两者之间只有一条命令通道 + 一个状态快照，避免把 `&Engine` 跨线程。

use std::borrow::Cow;
use std::collections::{BTreeSet, HashMap, HashSet};
use std::net::IpAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use futures::StreamExt;
use libp2p::identity::Keypair;
use libp2p::multiaddr::Protocol;
use libp2p::swarm::dial_opts::DialOpts;
use libp2p::swarm::{NetworkBehaviour, SwarmEvent};
use libp2p::{
    autonat, dcutr, gossipsub, identify, kad, noise, ping, relay, request_response, tcp, yamux,
    Multiaddr, PeerId, StreamProtocol, Swarm, SwarmBuilder,
};
use sha2::{Digest, Sha256};
use tokio::sync::mpsc;

use crate::domain::hlc::compare_hlts;
use crate::domain::model::Op;

/* ------------------------- 与 Web 版共享的常量（别单方面改） ------------------------- */

pub const DEFAULT_PORT: u16 = 7788;
pub const NET_NAME: &str = "alighieri";
pub const PROTOCOL_VERSION: &str = "alighieri/1.0.0";
pub const TOPIC_OPS: &str = "alighieri/ops/v1";
/// App 之间专用的定向对账协议；Web 节点不认识它，会自然回退到 gossipsub ——
/// 不熟的人，走公共频道就好。
pub const SYNC_PROTOCOL: &str = "/alighieri/ops/1.0.0";
/// DHT provider 命名空间（与 Web 版一致）
pub const PEER_NAMESPACE: &str = "/alighieri/peers/v1";

/// 内置公共引导节点（兜底，可能被墙 / 限流，界面要如实说明）
pub const BOOTSTRAP_PEERS: &[&str] = &[
    "/dnsaddr/bootstrap.libp2p.io/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
    "/dnsaddr/bootstrap.libp2p.io/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
    "/dnsaddr/bootstrap.libp2p.io/p2p/QmcZf59bWwK5XFi76CZX8cbJ4BhTzzA3gU1ZjYZcYW3dwt",
    "/dnsaddr/va1.bootstrap.libp2p.io/p2p/12D3KooWKnDdG3iXw9eTFijk3EWSunZcFi54Zka4wmtqtt6rPxc8",
    "/ip4/104.131.131.82/tcp/4001/p2p/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
    "/dnsaddr/va2.bootstrap.libp2p.io/p2p/12D3KooWKnDdG3iXw9eTFijk3EWSunZcFi54Zka4wmtqtt6rPxc8",
];

/// 公共 Circuit Relay v2 中继
pub const RELAY_PEERS: &[&str] = &[
    "/dnsaddr/relay.libp2p.io/p2p/12D3KooWKnDdG3iXw9eTFijk3EWSunZcFi54Zka4wmtqtt6rPxc8",
    "/dnsaddr/relay.libp2p.io/p2p/12D3KooWGUaHeEzTfUZP4oX4nYagA1nrHi4JUjQ8eS3Z7YUJ5uyP",
];

/// WebSocket 引导（部分网络屏蔽 DNS TXT 时的兜底）
pub const WS_BOOTSTRAP_URLS: &[&str] = &[
    "wss://node.libp2p.io/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
    "wss://node.libp2p.io/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
    "wss://node.libp2p.io/p2p/QmcZf59bWwK5XFi76CZX8cbJ4BhTzzA3gU1ZjYZcYW3dwt",
];

const MAX_OPS_PER_MESSAGE: usize = 2000;
const MAX_IDS_PER_MESSAGE: usize = 20_000;
const DISCOVERY_INTERVAL: Duration = Duration::from_secs(30);
const RELAY_RETRY_INTERVAL: Duration = Duration::from_secs(5 * 60);
const PROVIDER_RETRY_INTERVAL: Duration = Duration::from_secs(5 * 60);
const AUTO_SYNC_INTERVAL: Duration = Duration::from_secs(30);
const SYNC_WAIT_TIMEOUT: Duration = Duration::from_secs(12);
const SITE_FETCH_TIMEOUT: Duration = Duration::from_millis(2500);

pub type OpsProvider = Arc<dyn Fn() -> Vec<Op> + Send + Sync>;
pub type OpsSink = Arc<dyn Fn(Vec<Op>) + Send + Sync>;

/* ------------------------- 对外状态 ------------------------- */

#[derive(Debug, Clone, Default)]
pub struct NetPeerStatus {
    pub peer_id: String,
    pub addr: String,
    pub direction: String,
    pub subscribed: bool,
    pub agent: String,
}

#[derive(Debug, Clone, Default)]
pub struct NetStatus {
    pub state: String,
    pub peers: Vec<NetPeerStatus>,
    pub dht_peers: u64,
    pub relay_reservations: u64,
    pub listen_addrs: Vec<String>,
    pub discovery_attempts: u64,
    pub providers_found: u64,
    pub providers_dialed: u64,
    pub last_net_error: String,
    pub net_source: String,
    pub site_fetched: bool,
    pub site_nodes: u64,
    pub ops_in: u64,
    pub ops_out: u64,
}

/* ------------------------- 配置 ------------------------- */

#[derive(Debug, Clone)]
pub struct NetConfig {
    pub port: u16,
    /// 手动 / settings 里追加的引导地址
    pub bootstrap: Vec<String>,
    /// 手动 / settings 里追加的中继地址
    pub relays: Vec<String>,
    /// 站点 URL，用来拉 `/.well-known/libp2p`
    pub site_url: String,
    /// 是否拨内置公共节点 / 中继。测试里关掉，免得 CI 去跟公网聊天。
    pub use_builtin_peers: bool,
}

impl Default for NetConfig {
    fn default() -> Self {
        NetConfig {
            port: DEFAULT_PORT,
            bootstrap: Vec::new(),
            relays: Vec::new(),
            site_url: String::new(),
            use_builtin_peers: true,
        }
    }
}

/* ------------------------- 共享消息 ------------------------- */

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct Envelope {
    v: String,
    net: String,
    ops: Vec<Op>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
struct SyncRequest {
    #[serde(default)]
    have: Vec<String>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
struct SyncResponse {
    #[serde(default)]
    ops: Vec<Op>,
}

#[derive(Debug, serde::Deserialize)]
struct SiteManifest {
    #[serde(default)]
    nodes: Vec<String>,
}

/* ------------------------- 命令与句柄 ------------------------- */

enum Command {
    Broadcast(Vec<Op>),
    AddPeer(String),
    RetryDiscovery,
    SyncWith {
        addr: String,
        reply: std::sync::mpsc::Sender<Result<usize, String>>,
    },
    SiteNodes {
        nodes: Vec<Multiaddr>,
        fetched: bool,
        error: String,
    },
    Shutdown,
}

pub struct Net {
    peer_id: String,
    seed: Vec<u8>,
    config: NetConfig,
    provide: OpsProvider,
    sink: OpsSink,
    cmd_tx: mpsc::UnboundedSender<Command>,
    cmd_rx: Option<mpsc::UnboundedReceiver<Command>>,
    status: Arc<Mutex<NetStatus>>,
    stopped: Arc<AtomicBool>,
    thread: Mutex<Option<thread::JoinHandle<()>>>,
}

impl Net {
    pub fn new(
        peer_id: String,
        seed: Vec<u8>,
        provide: OpsProvider,
        sink: OpsSink,
        config: NetConfig,
    ) -> Net {
        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
        Net {
            peer_id,
            seed,
            config,
            provide,
            sink,
            cmd_tx,
            cmd_rx: Some(cmd_rx),
            status: Arc::new(Mutex::new(NetStatus {
                state: "connecting".into(),
                ..Default::default()
            })),
            stopped: Arc::new(AtomicBool::new(false)),
            thread: Mutex::new(None),
        }
    }

    pub fn peer_id(&self) -> &str {
        &self.peer_id
    }

    pub fn status(&self) -> NetStatus {
        self.status.lock().unwrap().clone()
    }

    /// 后台启动 libp2p。返回实际监听端口（port = 0 时可用于确定系统分配的端口）。
    pub fn start(&mut self) -> Result<u16, String> {
        let cmd_rx = self.cmd_rx.take().ok_or_else(|| "网络已经启动".to_string())?;
        let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<u16, String>>();

        let peer_id = self.peer_id.clone();
        let seed = self.seed.clone();
        let config = self.config.clone();
        let provide = self.provide.clone();
        let sink = self.sink.clone();
        let status = self.status.clone();
        let stopped = self.stopped.clone();
        let site_cmd = self.cmd_tx.clone();

        {
            let mut s = self.status.lock().unwrap();
            s.state = "connecting".into();
            s.net_source = if config.bootstrap.is_empty() { "builtin".into() } else { "override".into() };
        }

        let handle = thread::Builder::new()
            .name("alighieri-p2p".into())
            .spawn(move || {
                let runtime = match tokio::runtime::Builder::new_multi_thread()
                    .worker_threads(2)
                    .enable_all()
                    .build()
                {
                    Ok(rt) => rt,
                    Err(e) => {
                        set_state(&status, "error", &format!("Tokio 运行时启动失败：{e}"));
                        let _ = ready_tx.send(Err(format!("Tokio 运行时启动失败：{e}")));
                        return;
                    }
                };
                let result = runtime.block_on(network_main(
                    peer_id,
                    seed,
                    provide,
                    sink,
                    config,
                    cmd_rx,
                    status.clone(),
                    stopped.clone(),
                    ready_tx,
                    site_cmd,
                ));
                if let Err(e) = result {
                    set_state(&status, "degraded", &e);
                }
            })
            .map_err(|e| format!("无法启动网络线程：{e}"))?;

        match ready_rx.recv_timeout(Duration::from_secs(25)) {
            Ok(Ok(port)) => {
                *self.thread.lock().unwrap() = Some(handle);
                Ok(port)
            }
            Ok(Err(e)) => {
                let _ = handle.join();
                Err(e)
            }
            Err(_) => {
                self.stopped.store(true, Ordering::Relaxed);
                let _ = self.cmd_tx.send(Command::Shutdown);
                let _ = handle.join();
                Err("网络启动超时（25 秒）".into())
            }
        }
    }

    pub fn stop(&self) {
        self.stopped.store(true, Ordering::Relaxed);
        let _ = self.cmd_tx.send(Command::Shutdown);
        if let Ok(mut guard) = self.thread.lock() {
            if let Some(handle) = guard.take() {
                let _ = handle.join();
            }
        }
        set_state(&self.status, "local", "");
    }

    pub fn is_stopped(&self) -> bool {
        self.stopped.load(Ordering::Relaxed)
    }

    /// 本机新写入的 op：投递给后台 gossipsub。无订阅者时静默丢弃，
    /// 断线期间错过的部分由连接后的定向对账补齐 —— 先存着，回头再补。
    pub fn broadcast(&self, ops: Vec<Op>) {
        if ops.is_empty() {
            return;
        }
        let _ = self.cmd_tx.send(Command::Broadcast(ops));
    }

    /// 手动拨号并做一轮定向对账。最多等 12 秒，返回对方补来的 op 条数。
    pub fn sync_with(&self, addr: &str) -> Result<usize, String> {
        let (tx, rx) = std::sync::mpsc::channel();
        self.cmd_tx
            .send(Command::SyncWith { addr: addr.trim().to_string(), reply: tx })
            .map_err(|_| "网络线程未运行".to_string())?;
        match rx.recv_timeout(SYNC_WAIT_TIMEOUT) {
            Ok(result) => result,
            Err(_) => Err("对账超时（12 秒）".into()),
        }
    }

    pub fn add_peer(&self, addr: &str) {
        let a = addr.trim();
        if !a.is_empty() {
            let _ = self.cmd_tx.send(Command::AddPeer(a.to_string()));
        }
    }

    pub fn retry_discovery(&self) {
        let _ = self.cmd_tx.send(Command::RetryDiscovery);
    }
}

impl Drop for Net {
    fn drop(&mut self) {
        self.stopped.store(true, Ordering::Relaxed);
        let _ = self.cmd_tx.send(Command::Shutdown);
    }
}

fn set_state(status: &Arc<Mutex<NetStatus>>, state: &str, error: &str) {
    if let Ok(mut s) = status.lock() {
        s.state = state.to_string();
        if !error.is_empty() {
            s.last_net_error = error.to_string();
        }
    }
}

/* ------------------------- libp2p behaviour（一堆零件，各干各的） ------------------------- */

#[derive(NetworkBehaviour)]
struct Behaviour {
    gossipsub: gossipsub::Behaviour,
    kad: kad::Behaviour<kad::store::MemoryStore>,
    identify: identify::Behaviour,
    ping: ping::Behaviour,
    relay: relay::client::Behaviour,
    dcutr: dcutr::Behaviour,
    autonat: autonat::Behaviour,
    sync: request_response::json::Behaviour<SyncRequest, SyncResponse>,
}

struct Node {
    swarm: Swarm<Behaviour>,
    provide: OpsProvider,
    sink: OpsSink,
    status: Arc<Mutex<NetStatus>>,
    provider_key: kad::RecordKey,

    bootstrap: Vec<Multiaddr>,
    relays: Vec<Multiaddr>,
    relay_attempt: HashMap<PeerId, Instant>,
    relay_active: HashSet<PeerId>,

    peers: HashMap<PeerId, PeerEntry>,
    conn_peers: HashMap<libp2p::swarm::ConnectionId, PeerId>,
    subscribed: HashSet<PeerId>,
    listen_addrs: Vec<String>,

    provider_last_dial: HashMap<PeerId, Instant>,
    provider_seen: HashSet<PeerId>,
    provider_pending: HashSet<PeerId>,
    /// provider 地址查询（等价 Web 版 `findPeer`），防止同一 peer 重复查询。
    provider_lookups: HashMap<kad::QueryId, PeerId>,
    providers_found: u64,
    providers_dialed: u64,

    manual_sync_dials: HashMap<libp2p::swarm::ConnectionId, PendingSync>,
    sync_waiters: HashMap<request_response::OutboundRequestId, std::sync::mpsc::Sender<Result<usize, String>>>,
    last_auto_sync: HashMap<PeerId, Instant>,

    discovery_attempts: u64,
    site_fetched: bool,
    site_nodes: u64,
    net_source: String,
}

struct PeerEntry {
    addr: String,
    direction: String,
    agent: String,
}

struct PendingSync {
    have: Vec<String>,
    reply: std::sync::mpsc::Sender<Result<usize, String>>,
}

/* ------------------------- 启动：先拿到端口，再谈理想 ------------------------- */

async fn network_main(
    peer_id: String,
    seed: Vec<u8>,
    provide: OpsProvider,
    sink: OpsSink,
    config: NetConfig,
    mut cmd_rx: mpsc::UnboundedReceiver<Command>,
    status: Arc<Mutex<NetStatus>>,
    stopped: Arc<AtomicBool>,
    ready_tx: std::sync::mpsc::Sender<Result<u16, String>>,
    site_cmd: mpsc::UnboundedSender<Command>,
) -> Result<(), String> {
    let mut swarm = match build_swarm(&peer_id, &seed).await {
        Ok(swarm) => swarm,
        Err(e) => {
            let _ = ready_tx.send(Err(e.clone()));
            return Err(e);
        }
    };

    let listen_addr: Multiaddr = format!("/ip4/0.0.0.0/tcp/{}", config.port)
        .parse()
        .map_err(|e| format!("监听地址无效：{e}"))?;
    if let Err(e) = swarm.listen_on(listen_addr) {
        let msg = format!("监听失败：{e}");
        let _ = ready_tx.send(Err(msg.clone()));
        return Err(msg);
    }

    // 等待系统分配 / 确认的 TCP 监听地址。只有拿到端口才回复引擎，
    // 否则界面会显示一个根本不存在的端口 —— 界面最擅长把错误放大展示。
    let actual = match wait_for_listen(&mut swarm).await {
        Ok(port) => port,
        Err(e) => {
            let _ = ready_tx.send(Err(e.clone()));
            return Err(e);
        }
    };

    let mut bootstrap = Vec::new();
    let mut relay_addrs = Vec::new();
    let mut errors = Vec::new();

    if config.use_builtin_peers {
        for raw in BOOTSTRAP_PEERS.iter().chain(WS_BOOTSTRAP_URLS.iter()) {
            push_unique_addr(&mut bootstrap, raw, &mut errors);
        }
    }
    for raw in config.bootstrap.iter() {
        push_unique_addr(&mut bootstrap, raw, &mut errors);
    }
    if config.use_builtin_peers {
        for raw in RELAY_PEERS.iter() {
            push_unique_addr(&mut relay_addrs, raw, &mut errors);
        }
    }
    for raw in config.relays.iter() {
        push_unique_addr(&mut relay_addrs, raw, &mut errors);
    }
    // 站点自己的域名作为 dnsaddr 引导项（部署者在 DNS 上发布 TXT）
    if let Some(host) = site_host(&config.site_url) {
        push_unique_addr(&mut bootstrap, &format!("/dnsaddr/{host}"), &mut errors);
    }

    let source = if !config.bootstrap.is_empty() {
        "override"
    } else {
        "builtin"
    };

    let mut node = Node {
        swarm,
        provide,
        sink,
        status: status.clone(),
        provider_key: provider_key(),
        bootstrap,
        relays: relay_addrs,
        relay_attempt: HashMap::new(),
        relay_active: HashSet::new(),
        peers: HashMap::new(),
        conn_peers: HashMap::new(),
        subscribed: HashSet::new(),
        listen_addrs: vec![format!("/ip4/0.0.0.0/tcp/{actual}")],
        provider_last_dial: HashMap::new(),
        provider_seen: HashSet::new(),
        provider_pending: HashSet::new(),
        provider_lookups: HashMap::new(),
        providers_found: 0,
        providers_dialed: 0,
        manual_sync_dials: HashMap::new(),
        sync_waiters: HashMap::new(),
        last_auto_sync: HashMap::new(),
        discovery_attempts: 0,
        site_fetched: false,
        site_nodes: 0,
        net_source: source.into(),
    };

    if !errors.is_empty() {
        node.note_error(&errors.join("；"));
    }

    {
        let mut s = status.lock().unwrap();
        s.state = "online".into();
        s.net_source = node.net_source.clone();
        s.listen_addrs = node.listen_addrs.clone();
        if let Some(first) = errors.first() {
            s.last_net_error = first.clone();
        }
    }

    let _ = ready_tx.send(Ok(actual));

    // 站点清单并行拉取：最多等 2.5 秒，不阻塞节点启动。
    if !config.site_url.trim().is_empty() {
        let site_url = config.site_url.clone();
        let tx = site_cmd.clone();
        thread::spawn(move || {
            let result = fetch_site_nodes(&site_url);
            let cmd = match result {
                Ok(nodes) => Command::SiteNodes { nodes, fetched: true, error: String::new() },
                Err(e) => Command::SiteNodes { nodes: Vec::new(), fetched: false, error: e },
            };
            let _ = tx.send(cmd);
        });
    }

    node.tick_discovery();
    let mut interval = tokio::time::interval(DISCOVERY_INTERVAL);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    interval.tick().await; // 第一次立即触发，上面已经跑过一轮

    loop {
        if stopped.load(Ordering::Relaxed) {
            break;
        }
        tokio::select! {
            cmd = cmd_rx.recv() => {
                match cmd {
                    Some(Command::Shutdown) | None => break,
                    Some(Command::Broadcast(ops)) => node.broadcast(ops),
                    Some(Command::AddPeer(addr)) => node.add_peer(&addr),
                    Some(Command::RetryDiscovery) => {
                        node.retry_discovery_now();
                    }
                    Some(Command::SyncWith { addr, reply }) => {
                        node.start_sync_with(&addr, reply);
                    }
                    Some(Command::SiteNodes { nodes, fetched, error }) => {
                        node.apply_site_nodes(nodes, fetched, error);
                    }
                }
            }
            event = node.swarm.select_next_some() => {
                node.handle_event(event);
            }
            _ = interval.tick() => {
                node.tick_discovery();
            }
        }
    }

    node.refresh_status();
    Ok(())
}

async fn build_swarm(peer_id: &str, seed: &[u8]) -> Result<Swarm<Behaviour>, String> {
    if seed.len() != 32 {
        return Err("身份种子必须是 32 字节".into());
    }
    let mut bytes = [0u8; 32];
    bytes.copy_from_slice(seed);
    let keypair = Keypair::ed25519_from_bytes(&mut bytes)
        .map_err(|e| format!("身份私钥无法转换为 libp2p 密钥：{e}"))?;
    let local_peer = keypair.public().to_peer_id();
    if local_peer.to_string() != peer_id {
        return Err(format!(
            "身份 peerId 与 libp2p 公钥不一致（引擎 {peer_id}，网络 {local_peer}）"
        ));
    }

    let gossipsub_config = gossipsub::ConfigBuilder::default()
        .max_transmit_size(2 * 1024 * 1024)
        .heartbeat_interval(Duration::from_secs(1))
        .mesh_n(6)
        .mesh_n_low(3)
        .mesh_n_high(12)
        .duplicate_cache_time(Duration::from_secs(120))
        .build()
        .map_err(|e| format!("gossipsub 配置无效：{e}"))?;

    let mut kad_config = kad::Config::new(StreamProtocol::new("/ipfs/kad/1.0.0"));
    kad_config.set_query_timeout(Duration::from_secs(10));

    let behaviour = move |key: &Keypair, relay: relay::client::Behaviour| -> Result<Behaviour, Box<dyn std::error::Error + Send + Sync>> {
        let mut gossipsub = gossipsub::Behaviour::new(
            gossipsub::MessageAuthenticity::Signed(key.clone()),
            gossipsub_config,
        )
        .map_err(|e| format!("gossipsub 初始化失败：{e}"))?;
        gossipsub
            .subscribe(&gossipsub::IdentTopic::new(TOPIC_OPS))
            .map_err(|e| format!("订阅 op 主题失败：{e}"))?;

        let local = key.public().to_peer_id();
        let mut kad = kad::Behaviour::with_config(
            local,
            kad::store::MemoryStore::new(local),
            kad_config,
        );
        kad.set_mode(Some(kad::Mode::Client));

        let identify = identify::Behaviour::new(
            identify::Config::new(PROTOCOL_VERSION.into(), key.public())
                .with_agent_version(format!("alighieri-app/{}", env!("CARGO_PKG_VERSION"))),
        );
        let ping = ping::Behaviour::new(ping::Config::new());
        let dcutr = dcutr::Behaviour::new(local);
        let autonat = autonat::Behaviour::new(local, autonat::Config::default());
        let sync = request_response::json::Behaviour::<SyncRequest, SyncResponse>::new(
            [(StreamProtocol::new(SYNC_PROTOCOL), request_response::ProtocolSupport::Full)],
            request_response::Config::default().with_request_timeout(Duration::from_secs(15)),
        );

        Ok(Behaviour { gossipsub, kad, identify, ping, relay, dcutr, autonat, sync })
    };

    let swarm = SwarmBuilder::with_existing_identity(keypair)
        .with_tokio()
        .with_tcp(
            tcp::Config::default().nodelay(true),
            noise::Config::new,
            yamux::Config::default,
        )
        .map_err(|e| format!("TCP 传输初始化失败：{e}"))?
        .with_dns()
        .map_err(|e| format!("DNS 传输初始化失败：{e}"))?
        .with_websocket(noise::Config::new, yamux::Config::default)
        .await
        .map_err(|e| format!("WebSocket 传输初始化失败：{e}"))?
        .with_relay_client(noise::Config::new, yamux::Config::default)
        .map_err(|e| format!("中继传输初始化失败：{e}"))?
        .with_behaviour(behaviour)
        .map_err(|e| format!("网络行为初始化失败：{e}"))?
        .with_swarm_config(|cfg| {
            cfg.with_idle_connection_timeout(Duration::from_secs(5 * 60))
        })
        .build();
    Ok(swarm)
}

async fn wait_for_listen(swarm: &mut Swarm<Behaviour>) -> Result<u16, String> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    loop {
        match tokio::time::timeout_at(deadline, swarm.select_next_some()).await {
            Ok(SwarmEvent::NewListenAddr { address, .. }) => {
                if let Some(port) = tcp_port(&address) {
                    return Ok(port);
                }
            }
            Ok(SwarmEvent::ListenerError { error, .. }) => {
                return Err(format!("监听失败：{error}"));
            }
            Ok(_) => {}
            Err(_) => return Err("等待监听地址超时（15 秒）".into()),
        }
    }
}

fn tcp_port(addr: &Multiaddr) -> Option<u16> {
    addr.iter().find_map(|p| match p {
        Protocol::Tcp(port) => Some(port),
        _ => None,
    })
}

/* ------------------------- 事件处理：能连就先连 ------------------------- */

impl Node {
    fn note_error(&mut self, msg: &str) {
        if msg.is_empty() {
            return;
        }
        if let Ok(mut s) = self.status.lock() {
            s.last_net_error = msg.to_string();
        }
    }

    fn refresh_status(&mut self) {
        let dht_peers = self
            .swarm
            .behaviour_mut()
            .kad
            .kbuckets()
            .map(|b| b.num_entries() as u64)
            .sum::<u64>();
        let mut peers: Vec<NetPeerStatus> = self
            .peers
            .iter()
            .map(|(peer, entry)| NetPeerStatus {
                peer_id: peer.to_string(),
                addr: entry.addr.clone(),
                direction: entry.direction.clone(),
                subscribed: self.subscribed.contains(peer),
                agent: entry.agent.clone(),
            })
            .collect();
        // HashMap 的迭代顺序每次刷新都可能变；界面每 2 秒读一次状态，
        // 不排序的话节点列表会一直跳，像在做布朗运动。
        peers.sort_by(|a, b| a.peer_id.cmp(&b.peer_id));
        let relay_reservations = self.relay_active.len() as u64;
        if let Ok(mut s) = self.status.lock() {
            s.peers = peers;
            s.dht_peers = dht_peers;
            s.relay_reservations = relay_reservations;
            s.listen_addrs = self.listen_addrs.clone();
            s.discovery_attempts = self.discovery_attempts;
            s.providers_found = self.providers_found;
            s.providers_dialed = self.providers_dialed;
            s.net_source = self.net_source.clone();
            s.site_fetched = self.site_fetched;
            s.site_nodes = self.site_nodes;
        }
    }

    fn broadcast(&mut self, ops: Vec<Op>) {
        let n = ops.len() as u64;
        let envelope = Envelope {
            v: PROTOCOL_VERSION.into(),
            net: NET_NAME.into(),
            ops,
        };
        let payload = match serde_json::to_vec(&envelope) {
            Ok(p) => p,
            Err(e) => {
                self.note_error(&format!("广播序列化失败：{e}"));
                return;
            }
        };
        let topic = gossipsub::IdentTopic::new(TOPIC_OPS);
        match self.swarm.behaviour_mut().gossipsub.publish(topic, payload) {
            Ok(_) | Err(gossipsub::PublishError::NoPeersSubscribedToTopic) => {
                if let Ok(mut s) = self.status.lock() {
                    s.ops_out += n;
                }
            }
            Err(e) => {
                // 已经落盘，联网后由定向对账补齐；这里只记录诊断。
                self.note_error(&format!("gossipsub 广播失败：{e}"));
                if let Ok(mut s) = self.status.lock() {
                    s.ops_out += n;
                }
            }
        }
    }

    fn add_peer(&mut self, raw: &str) {
        match parse_target(raw) {
            Ok((addr, _)) => {
                if !self.bootstrap.iter().any(|a| a == &addr) {
                    self.bootstrap.push(addr.clone());
                }
                if let Err(e) = self.swarm.dial(addr.clone()) {
                    self.note_error(&format!("拨号 {addr} 失败：{e}"));
                } else {
                    self.tick_discovery();
                }
            }
            Err(e) => self.note_error(&e),
        }
    }

    fn apply_site_nodes(&mut self, nodes: Vec<Multiaddr>, fetched: bool, error: String) {
        self.site_fetched = fetched;
        self.site_nodes = nodes.len() as u64;
        if !error.is_empty() {
            self.note_error(&format!("站点节点清单拉取失败：{error}"));
        }
        if !nodes.is_empty() {
            if self.net_source != "override" {
                self.net_source = "site".into();
            }
            for addr in &nodes {
                if !self.bootstrap.iter().any(|a| a == addr) {
                    self.bootstrap.push(addr.clone());
                }
                // 站点清单里的节点也可能提供中继：都试一遍。
                if !self.relays.iter().any(|a| a == addr) {
                    self.relays.push(addr.clone());
                }
            }
            self.tick_discovery();
        }
        self.refresh_status();
    }

    /// 用户点「重试发现」：清掉节流，让这次真的重查 / 重拨。
    fn retry_discovery_now(&mut self) {
        self.provider_last_dial.clear();
        self.relay_attempt.clear();
        self.tick_discovery();
    }

    fn tick_discovery(&mut self) {
        self.discovery_attempts += 1;

        // 周期性重拨引导节点：公共节点经常是暂时性不可达 —— 多敲几次门。
        let bootstrap: Vec<Multiaddr> = self.bootstrap.iter().take(12).cloned().collect();
        for addr in bootstrap {
            // 已经连上的 peer 不再重复拨号，否则每 30 秒会多开一条连接。
            if let Some(peer) = last_peer_id(&addr) {
                if self.swarm.is_connected(&peer) {
                    continue;
                }
            }
            let _ = self.swarm.dial(addr);
        }

        // 向中继预约：每个中继最多 5 分钟试一次。预约成功后由
        // relay client 自动续约，不需要每轮重听。
        let relays: Vec<Multiaddr> = self.relays.clone();
        let now = Instant::now();
        for relay in relays {
            let Some(relay_id) = last_peer_id(&relay) else {
                continue;
            };
            // 预约成功后由 relay client 自动续约，不必重复 listen。
            if self.relay_active.contains(&relay_id) {
                continue;
            }
            let retry = self
                .relay_attempt
                .get(&relay_id)
                .map(|t| now.duration_since(*t) >= RELAY_RETRY_INTERVAL)
                .unwrap_or(true);
            if !retry {
                continue;
            }
            self.relay_attempt.insert(relay_id, now);
            let mut circuit = relay.clone();
            circuit.push(Protocol::P2pCircuit);
            if let Err(e) = self.swarm.listen_on(circuit) {
                self.note_error(&format!("中继预约失败（{relay_id}）：{e}"));
            }
        }

        let dht_ready = self
            .swarm
            .behaviour_mut()
            .kad
            .kbuckets()
            .map(|b| b.num_entries())
            .sum::<usize>()
            > 0;
        if dht_ready {
            let key = self.provider_key.clone();
            let _ = self.swarm.behaviour_mut().kad.start_providing(key);
            let key = self.provider_key.clone();
            let _ = self.swarm.behaviour_mut().kad.get_providers(key);
            let _ = self.swarm.behaviour_mut().kad.bootstrap();
        }
        self.refresh_status();
    }

    fn start_sync_with(
        &mut self,
        raw: &str,
        reply: std::sync::mpsc::Sender<Result<usize, String>>,
    ) {
        let (addr, peer) = match parse_target(raw) {
            Ok(v) => v,
            Err(e) => {
                let _ = reply.send(Err(e));
                return;
            }
        };
        let have = self.have();
        if let Some(peer) = peer {
            if self.swarm.is_connected(&peer) {
                let rid = self
                    .swarm
                    .behaviour_mut()
                    .sync
                    .send_request(&peer, SyncRequest { have });
                self.sync_waiters.insert(rid, reply);
                return;
            }
            let opts = DialOpts::peer_id(peer).addresses(vec![addr]).build();
            let cid = opts.connection_id();
            self.manual_sync_dials.insert(cid, PendingSync { have, reply });
            if let Err(e) = self.swarm.dial(opts) {
                if let Some(p) = self.manual_sync_dials.remove(&cid) {
                    let _ = p.reply.send(Err(format!("拨号失败：{e}")));
                }
            }
            return;
        }
        let opts = DialOpts::unknown_peer_id().address(addr).build();
        let cid = opts.connection_id();
        self.manual_sync_dials.insert(cid, PendingSync { have, reply });
        if let Err(e) = self.swarm.dial(opts) {
            if let Some(p) = self.manual_sync_dials.remove(&cid) {
                let _ = p.reply.send(Err(format!("拨号失败：{e}")));
            }
        }
    }

    fn send_auto_sync(&mut self, peer: PeerId) {
        let now = Instant::now();
        if let Some(last) = self.last_auto_sync.get(&peer) {
            if now.duration_since(*last) < AUTO_SYNC_INTERVAL {
                return;
            }
        }
        self.last_auto_sync.insert(peer, now);
        let have = self.have();
        self.swarm
            .behaviour_mut()
            .sync
            .send_request(&peer, SyncRequest { have });
    }

    fn have(&self) -> Vec<String> {
        have_ids(&(self.provide)())
    }

    /// 从 Kademlia 路由表里收集 provider 的已知地址。
    fn known_provider_addrs(&mut self, provider: PeerId) -> Vec<Multiaddr> {
        let mut addrs = Vec::new();
        let kad = self.swarm.behaviour_mut().kad.kbuckets();
        for bucket in kad {
            for entry in bucket.iter() {
                if *entry.node.key.preimage() == provider {
                    addrs.extend(entry.node.value.iter().cloned());
                }
            }
        }
        addrs
    }

    /// 本次拨号可用的地址：路由表直连地址 + 自己配置的中继电路。
    fn provider_dial_addrs(&mut self, provider: PeerId) -> Vec<Multiaddr> {
        let mut addrs = Vec::new();
        for addr in self.known_provider_addrs(provider) {
            push_dial_addr(&mut addrs, &addr);
        }
        // 对方在 NAT 后面时只有中继电路能通。
        for relay in self.relays.clone().into_iter().take(3) {
            let mut circuit = relay;
            circuit.push(Protocol::P2pCircuit);
            circuit.push(Protocol::P2p(provider));
            push_dial_addr(&mut addrs, &circuit);
        }
        addrs
    }

    /// 等价 Web 版 `findPeer`：provider 记录只返回 peerId，地址要再查一次。
    /// 浏览器节点通常只在中继后面，这一步是 App 能主动拨通它们的关键。
    fn lookup_provider(&mut self, provider: PeerId) {
        if provider == *self.swarm.local_peer_id() {
            return;
        }
        if self.provider_lookups.values().any(|p| *p == provider) {
            return;
        }
        let id = self.swarm.behaviour_mut().kad.get_closest_peers(provider);
        self.provider_lookups.insert(id, provider);
    }

    /// 只负责拨号，不做节流；地址刚学到时需要立即重试。
    fn dial_provider_now(&mut self, provider: PeerId) {
        if provider == *self.swarm.local_peer_id()
            || self.swarm.is_connected(&provider)
            || self.provider_pending.contains(&provider)
        {
            return;
        }
        let addrs = self.provider_dial_addrs(provider);
        if addrs.is_empty() {
            return;
        }
        // 同一次拨号里带上所有候选地址：libp2p 会并发尝试，
        // 直连成功就不必再走中继，反之亦然。
        self.provider_pending.insert(provider);
        let opts = DialOpts::peer_id(provider).addresses(addrs).build();
        if self.swarm.dial(opts).is_err() {
            self.provider_pending.remove(&provider);
        }
    }

    fn dial_provider(&mut self, provider: PeerId) {
        if provider == *self.swarm.local_peer_id()
            || self.swarm.is_connected(&provider)
            || self.provider_pending.contains(&provider)
        {
            return;
        }
        let now = Instant::now();
        if let Some(last) = self.provider_last_dial.get(&provider) {
            if now.duration_since(*last) < PROVIDER_RETRY_INTERVAL {
                return;
            }
        }
        self.provider_last_dial.insert(provider, now);
        // 即使路由表里有地址也查一次：provider 记录里的地址不一定进了路由表，
        // 浏览器节点往往只在中继后面，必须靠 findPeer 才能拿到电路地址。
        self.lookup_provider(provider);
        self.dial_provider_now(provider);
    }

    /// DHT findPeer 返回后：记下地址，并绕过节流立即尝试。
    fn handle_provider_lookup(&mut self, provider: PeerId, peers: Vec<kad::PeerInfo>) {
        let mut learned = Vec::new();
        for info in peers {
            if info.peer_id == provider {
                learned.extend(info.addrs);
            }
        }
        for addr in &learned {
            self.swarm
                .behaviour_mut()
                .kad
                .add_address(&provider, addr.clone());
        }
        if learned.is_empty() {
            return;
        }
        self.dial_provider_now(provider);
    }

    fn handle_event(&mut self, event: SwarmEvent<BehaviourEvent>) {
        match event {
            SwarmEvent::NewListenAddr { address, .. } => {
                push_string_unique(&mut self.listen_addrs, address.to_string());
                self.refresh_status();
            }
            SwarmEvent::ExpiredListenAddr { address, .. } => {
                self.listen_addrs.retain(|a| a != &address.to_string());
                self.refresh_status();
            }
            SwarmEvent::ListenerClosed { addresses, .. } => {
                for a in addresses {
                    self.listen_addrs.retain(|x| x != &a.to_string());
                }
                self.refresh_status();
            }
            SwarmEvent::NewExternalAddrCandidate { address } => {
                self.swarm.add_external_address(address.clone());
                push_string_unique(&mut self.listen_addrs, address.to_string());
                self.refresh_status();
            }
            SwarmEvent::ExternalAddrConfirmed { address } => {
                push_string_unique(&mut self.listen_addrs, address.to_string());
                self.refresh_status();
            }
            SwarmEvent::ExternalAddrExpired { address } => {
                self.listen_addrs.retain(|a| a != &address.to_string());
                self.refresh_status();
            }
            SwarmEvent::ConnectionEstablished {
                peer_id,
                connection_id,
                endpoint,
                ..
            } => {
                let direction = if endpoint.is_dialer() { "outbound" } else { "inbound" };
                let addr = endpoint.get_remote_address().to_string();
                self.conn_peers.insert(connection_id, peer_id);
                self.peers.insert(
                    peer_id,
                    PeerEntry {
                        addr,
                        direction: direction.into(),
                        agent: self.peers.get(&peer_id).map(|p| p.agent.clone()).unwrap_or_default(),
                    },
                );
                let remote = endpoint.get_remote_address().clone();
                self.swarm.behaviour_mut().kad.add_address(&peer_id, remote);
                if self.provider_pending.remove(&peer_id) {
                    self.providers_dialed += 1;
                    if let Ok(mut s) = self.status.lock() {
                        s.providers_dialed = self.providers_dialed;
                    }
                }
                if let Some(pending) = self.manual_sync_dials.remove(&connection_id) {
                    let rid = self
                        .swarm
                        .behaviour_mut()
                        .sync
                        .send_request(&peer_id, SyncRequest { have: pending.have });
                    self.sync_waiters.insert(rid, pending.reply);
                } else {
                    self.send_auto_sync(peer_id);
                }
                self.refresh_status();
            }
            SwarmEvent::ConnectionClosed {
                peer_id,
                connection_id,
                ..
            } => {
                if self.conn_peers.remove(&connection_id).is_some() {
                    let still_connected = self.conn_peers.values().any(|p| *p == peer_id);
                    if !still_connected {
                        self.peers.remove(&peer_id);
                        self.subscribed.remove(&peer_id);
                        self.last_auto_sync.remove(&peer_id);
                        self.relay_active.remove(&peer_id);
                    }
                }
                self.refresh_status();
            }
            SwarmEvent::OutgoingConnectionError {
                connection_id,
                peer_id,
                error,
                ..
            } => {
                if let Some(pending) = self.manual_sync_dials.remove(&connection_id) {
                    let _ = pending.reply.send(Err(format!("拨号失败：{error}")));
                }
                if let Some(peer) = peer_id {
                    if !self.swarm.is_connected(&peer) {
                        self.provider_pending.remove(&peer);
                    }
                }
                self.note_error(&format!("拨号失败：{error}"));
            }
            SwarmEvent::Behaviour(event) => self.handle_behaviour(event),
            _ => {}
        }
    }

    fn handle_behaviour(&mut self, event: BehaviourEvent) {
        match event {
            BehaviourEvent::Gossipsub(event) => self.handle_gossipsub(event),
            BehaviourEvent::Kad(event) => self.handle_kad(event),
            BehaviourEvent::Identify(event) => self.handle_identify(event),
            BehaviourEvent::Relay(event) => self.handle_relay(event),
            BehaviourEvent::Dcutr(event) => {
                if event.result.is_ok() {
                    eprintln!("[alighieri] 与 {} 打洞成功", event.remote_peer_id);
                }
                self.refresh_status();
            }
            BehaviourEvent::Autonat(event) => {
                if let autonat::Event::StatusChanged { new, .. } = event {
                    if let autonat::NatStatus::Public(addr) = new {
                        self.swarm.add_external_address(addr.clone());
                        push_string_unique(&mut self.listen_addrs, addr.to_string());
                    }
                }
                self.refresh_status();
            }
            BehaviourEvent::Sync(event) => self.handle_sync(event),
            BehaviourEvent::Ping(_) => {}
        }
    }

    fn handle_gossipsub(&mut self, event: gossipsub::Event) {
        match event {
            gossipsub::Event::Message { message, .. } => {
                if message.topic.as_str() != TOPIC_OPS {
                    return;
                }
                let envelope: Envelope = match serde_json::from_slice(&message.data) {
                    Ok(e) => e,
                    Err(e) => {
                        self.note_error(&format!("收到无法解析的广播：{e}"));
                        return;
                    }
                };
                if envelope.net != NET_NAME || envelope.ops.is_empty() {
                    return;
                }
                let n = envelope.ops.len() as u64;
                (self.sink)(envelope.ops);
                if let Ok(mut s) = self.status.lock() {
                    s.ops_in += n;
                }
            }
            gossipsub::Event::Subscribed { peer_id, topic } => {
                if topic.as_str() == TOPIC_OPS {
                    self.subscribed.insert(peer_id);
                    self.refresh_status();
                }
            }
            gossipsub::Event::Unsubscribed { peer_id, topic } => {
                if topic.as_str() == TOPIC_OPS {
                    self.subscribed.remove(&peer_id);
                    self.refresh_status();
                }
            }
            gossipsub::Event::GossipsubNotSupported { peer_id } => {
                self.subscribed.remove(&peer_id);
                self.refresh_status();
            }
            _ => {}
        }
    }

    fn handle_kad(&mut self, event: kad::Event) {
        match event {
            kad::Event::OutboundQueryProgressed { id, result, .. } => match result {
                kad::QueryResult::GetProviders(Ok(kad::GetProvidersOk::FoundProviders { providers, .. })) => {
                    for provider in providers {
                        if provider == *self.swarm.local_peer_id() {
                            continue;
                        }
                        if self.provider_seen.insert(provider) {
                            self.providers_found += 1;
                        }
                        self.dial_provider(provider);
                    }
                    self.refresh_status();
                }
                kad::QueryResult::GetProviders(Err(e)) => {
                    self.note_error(&format!("DHT 查询失败：{e}"));
                }
                kad::QueryResult::GetClosestPeers(Ok(kad::GetClosestPeersOk { peers, .. })) => {
                    if let Some(provider) = self.provider_lookups.remove(&id) {
                        self.handle_provider_lookup(provider, peers);
                    }
                }
                kad::QueryResult::GetClosestPeers(Err(kad::GetClosestPeersError::Timeout {
                    peers,
                    ..
                })) => {
                    // 超时也可能已经拿到了对方地址，能连就先连。
                    if let Some(provider) = self.provider_lookups.remove(&id) {
                        self.handle_provider_lookup(provider, peers);
                    }
                }
                kad::QueryResult::StartProviding(Err(e)) => {
                    self.note_error(&format!("DHT announce 失败：{e}"));
                }
                _ => {}
            },
            kad::Event::RoutingUpdated { .. } | kad::Event::ModeChanged { .. } => {
                self.refresh_status();
            }
            kad::Event::RoutablePeer { peer, address } => {
                self.swarm.behaviour_mut().kad.add_address(&peer, address);
                self.refresh_status();
            }
            _ => {}
        }
    }

    fn handle_identify(&mut self, event: identify::Event) {
        if let identify::Event::Received { peer_id, info, .. } = event {
            if let Some(entry) = self.peers.get_mut(&peer_id) {
                entry.agent = info.agent_version.clone();
            }
            for addr in info.listen_addrs {
                self.swarm.behaviour_mut().kad.add_address(&peer_id, addr);
            }
            let _ = self.swarm.behaviour_mut().kad.bootstrap();
            self.refresh_status();
        }
    }

    fn handle_relay(&mut self, event: relay::client::Event) {
        match event {
            relay::client::Event::ReservationReqAccepted { relay_peer_id, .. } => {
                self.relay_active.insert(relay_peer_id);
                self.note_error("");
                self.refresh_status();
            }
            relay::client::Event::OutboundCircuitEstablished { .. }
            | relay::client::Event::InboundCircuitEstablished { .. } => {
                self.refresh_status();
            }
        }
    }

    fn handle_sync(&mut self, event: request_response::Event<SyncRequest, SyncResponse>) {
        match event {
            request_response::Event::Message { peer, message, .. } => match message {
                request_response::Message::Request { request, channel, .. } => {
                    let ops = missing_ops(&(self.provide)(), &request.have);
                    let response = SyncResponse { ops };
                    if self
                        .swarm
                        .behaviour_mut()
                        .sync
                        .send_response(channel, response)
                        .is_err()
                    {
                        self.note_error(&format!("回应 {peer} 的对账请求失败"));
                    }
                }
                request_response::Message::Response { request_id, response } => {
                    let n = response.ops.len();
                    if n > 0 {
                        (self.sink)(response.ops);
                        if let Ok(mut s) = self.status.lock() {
                            s.ops_in += n as u64;
                        }
                    }
                    if let Some(reply) = self.sync_waiters.remove(&request_id) {
                        let _ = reply.send(Ok(n));
                    }
                }
            },
            request_response::Event::OutboundFailure { peer, request_id, error, .. } => {
                if let Some(reply) = self.sync_waiters.remove(&request_id) {
                    let _ = reply.send(Err(format!("与 {peer} 对账失败：{error}")));
                }
            }
            request_response::Event::InboundFailure { error, .. } => {
                self.note_error(&format!("对账入站失败：{error}"));
            }
            _ => {}
        }
    }
}

/* ------------------------- 工具函数 ------------------------- */

pub fn missing_ops(ops: &[Op], have: &[String]) -> Vec<Op> {
    let known: BTreeSet<&str> = have.iter().map(|s| s.as_str()).collect();
    let mut out: Vec<Op> = ops
        .iter()
        .filter(|o| !known.contains(o.id.as_str()))
        .cloned()
        .collect();
    out.sort_by(|a, b| compare_hlts(&a.hlts, &b.hlts));
    out.truncate(MAX_OPS_PER_MESSAGE);
    out
}

fn have_ids(ops: &[Op]) -> Vec<String> {
    let mut ops: Vec<&Op> = ops.iter().collect();
    ops.sort_by(|a, b| compare_hlts(&a.hlts, &b.hlts));
    ops.iter()
        .rev()
        .take(MAX_IDS_PER_MESSAGE)
        .map(|o| o.id.clone())
        .collect()
}

fn provider_key() -> kad::RecordKey {
    let digest = Sha256::digest(PEER_NAMESPACE.as_bytes());
    let mut bytes = Vec::with_capacity(34);
    // multihash sha2-256：0x12 0x20 + 32 字节摘要
    bytes.push(0x12);
    bytes.push(0x20);
    bytes.extend_from_slice(&digest);
    kad::RecordKey::from(bytes)
}

fn push_unique_addr(out: &mut Vec<Multiaddr>, raw: &str, errors: &mut Vec<String>) {
    match parse_multiaddr(raw) {
        Ok(addr) => {
            if !out.iter().any(|a| a == &addr) {
                out.push(addr);
            }
        }
        Err(e) => errors.push(format!("节点地址 {raw:?} 无法解析：{e}")),
    }
}

fn push_string_unique(out: &mut Vec<String>, value: String) {
    if !out.contains(&value) {
        out.push(value);
    }
}

fn push_dial_addr(out: &mut Vec<Multiaddr>, addr: &Multiaddr) {
    if let Some(addr) = dialable_provider_addr(addr) {
        if !out.contains(&addr) {
            out.push(addr);
        }
    }
}

/// 只保留原生端真的能拨的 provider 地址：
///   · 普通地址必须是 TCP / DNS —— 浏览器给出的 WebRTC、QUIC 地址直接跳过；
///   · 中继电路地址截断到 `p2p-circuit` —— 后面的 `/webrtc` 是浏览器侧的传输，
///     原生端不需要；拨号时 libp2p 会自动补上目标 peer id。
fn dialable_provider_addr(addr: &Multiaddr) -> Option<Multiaddr> {
    let mut out = Multiaddr::empty();
    let mut tcp = false;
    let mut dns = false;
    for p in addr.iter() {
        let circuit = matches!(p, Protocol::P2pCircuit);
        match &p {
            Protocol::Tcp(_) => tcp = true,
            Protocol::Dns(_) | Protocol::Dns4(_) | Protocol::Dns6(_) | Protocol::Dnsaddr(_) => {
                dns = true
            }
            _ => {}
        }
        out.push(p);
        if circuit {
            return (tcp || dns).then_some(out);
        }
    }
    (tcp || dns).then_some(out)
}

fn last_peer_id(addr: &Multiaddr) -> Option<PeerId> {
    addr.iter().filter_map(|p| match p {
        Protocol::P2p(id) => Some(id),
        _ => None,
    }).last()
}

/// 把用户输入的 `IP:端口` / `host:端口` / multiaddr / wss URL 统一成 multiaddr。
fn parse_target(raw: &str) -> Result<(Multiaddr, Option<PeerId>), String> {
    let addr = parse_multiaddr(raw)?;
    let peer = last_peer_id(&addr);
    Ok((addr, peer))
}

pub fn parse_multiaddr(raw: &str) -> Result<Multiaddr, String> {
    let s = raw.trim();
    if s.is_empty() {
        return Err("地址为空".into());
    }
    if s.starts_with('/') {
        return s.parse::<Multiaddr>().map_err(|e| format!("multiaddr 无效：{e}"));
    }
    if s.contains("://") {
        return parse_url_multiaddr(s);
    }
    parse_host_port_multiaddr(s, DEFAULT_PORT)
}

fn parse_url_multiaddr(s: &str) -> Result<Multiaddr, String> {
    let (scheme, rest) = s.split_once("://").ok_or_else(|| "URL 缺少协议".to_string())?;
    let secure = match scheme.to_ascii_lowercase().as_str() {
        "wss" | "https" => true,
        "ws" | "http" => false,
        _ => return Err(format!("不支持的 URL 协议：{scheme}")),
    };
    let (authority, path) = match rest.split_once('/') {
        Some((a, p)) => (a, p),
        None => (rest, ""),
    };
    let path_port = path
        .split('/')
        .collect::<Vec<_>>()
        .windows(2)
        .find_map(|w| (w[0] == "tcp").then(|| w[1].parse::<u16>().ok()).flatten());
    let (host, port) = split_host_port(authority, if secure { 443 } else { 80 })?;
    let port = path_port.unwrap_or(port);
    let peer = path
        .split('/')
        .collect::<Vec<_>>()
        .windows(2)
        .find_map(|w| (w[0] == "p2p").then(|| w[1].parse::<PeerId>().ok()).flatten());

    let mut ma = Multiaddr::empty();
    push_host(&mut ma, &host)?;
    ma.push(Protocol::Tcp(port));
    if secure {
        ma.push(Protocol::Tls);
        ma.push(Protocol::Sni(Cow::Owned(host.clone())));
    }
    ma.push(if secure { Protocol::Wss(Cow::Borrowed("/")) } else { Protocol::Ws(Cow::Borrowed("/")) });
    if let Some(peer) = peer {
        ma.push(Protocol::P2p(peer));
    }
    Ok(ma)
}

fn parse_host_port_multiaddr(s: &str, default_port: u16) -> Result<Multiaddr, String> {
    let (host, port) = split_host_port(s, default_port)?;
    let mut ma = Multiaddr::empty();
    push_host(&mut ma, &host)?;
    ma.push(Protocol::Tcp(port));
    Ok(ma)
}

fn push_host(ma: &mut Multiaddr, host: &str) -> Result<(), String> {
    if let Ok(ip) = host.parse::<IpAddr>() {
        match ip {
            IpAddr::V4(v4) => ma.push(Protocol::Ip4(v4)),
            IpAddr::V6(v6) => ma.push(Protocol::Ip6(v6)),
        }
    } else {
        if host.is_empty() {
            return Err("主机名为空".into());
        }
        ma.push(Protocol::Dns(Cow::Owned(host.to_string())));
    }
    Ok(())
}

fn split_host_port(s: &str, default_port: u16) -> Result<(String, u16), String> {
    let s = s.trim();
    if s.is_empty() {
        return Err("地址为空".into());
    }
    // [::1]:4001
    if let Some(rest) = s.strip_prefix('[') {
        if let Some((host, tail)) = rest.split_once(']') {
            let port = tail
                .strip_prefix(':')
                .and_then(|p| p.parse::<u16>().ok())
                .unwrap_or(default_port);
            return Ok((host.to_string(), port));
}
    }
    match s.rsplit_once(':') {
        Some((host, port)) if !host.contains(':') => {
            let port = port.parse::<u16>().map_err(|_| format!("端口无效：{port}"))?;
            Ok((host.to_string(), port))
        }
        // IPv6 字面量（没有方括号）或没有端口
        _ => Ok((s.to_string(), default_port)),
    }
}

fn site_host(site_url: &str) -> Option<String> {
    let raw = site_url.trim();
    if raw.is_empty() {
        return None;
    }
    let rest = raw
        .strip_prefix("https://")
        .or_else(|| raw.strip_prefix("http://"))
        .unwrap_or(raw);
    let authority = rest.split('/').next()?.split('?').next()?;
    let host = if let Some(rest) = authority.strip_prefix('[') {
        rest.split(']').next()?.to_string()
    } else {
        authority.rsplit_once(':').map(|(h, _)| h).unwrap_or(authority).to_string()
    };
    if host.is_empty() || host == "localhost" || host == "127.0.0.1" || host == "::1" {
        return None;
    }
    Some(host)
}

fn well_known_url(site_url: &str) -> String {
    let base = site_url.trim().trim_end_matches('/');
    if base.starts_with("http://") || base.starts_with("https://") {
        format!("{base}/.well-known/libp2p")
    } else {
        format!("https://{base}/.well-known/libp2p")
    }
}

fn fetch_site_nodes(site_url: &str) -> Result<Vec<Multiaddr>, String> {
    let url = well_known_url(site_url);
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(SITE_FETCH_TIMEOUT))
        .build()
        .into();
    let mut res = agent
        .get(&url)
        .header("accept", "application/json")
        .call()
        .map_err(|e| format!("{e}"))?;
    let text = res
        .body_mut()
        .read_to_string()
        .map_err(|e| format!("读取节点清单失败：{e}"))?;
    let manifest: SiteManifest =
        serde_json::from_str(&text).map_err(|e| format!("节点清单不是合法 JSON：{e}"))?;
    let mut out = Vec::new();
    for raw in manifest.nodes.into_iter().take(64) {
        if let Ok(addr) = parse_multiaddr(&raw) {
            if !out.contains(&addr) {
                out.push(addr);
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::model::OpKind;

    fn op(id: &str, hlts: &str) -> Op {
        Op {
            id: id.into(),
            actor: "peerA".into(),
            hlts: hlts.into(),
            kind: OpKind::NovelPut,
            key: format!("novel:{id}"),
            body: serde_json::json!({}),
            cid: None,
            v: 1,
            sig: None,
        }
    }

    #[test]
    fn missing_ops_is_a_set_difference() {
        let ops = vec![op("a", "000000001:0:x"), op("b", "000000002:0:x"), op("c", "000000003:0:x")];
        let out = missing_ops(&ops, &["b".to_string()]);
        assert_eq!(out.iter().map(|o| o.id.clone()).collect::<Vec<_>>(), vec!["a", "c"]);
    }

    /// 迟到的旧 op 也必须被补过去 —— 用 HLC 游标截断的话，迟到者就永远进不了门
    #[test]
    fn late_old_op_is_still_transferred() {
        let mine = vec![op("late", "000000001:0:x")];
        let have = vec!["newer".to_string()];
        assert_eq!(missing_ops(&mine, &have).len(), 1);
    }

    #[test]
    fn plain_addresses_become_multiaddrs() {
        assert_eq!(parse_multiaddr("1.2.3.4:9000").unwrap().to_string(), "/ip4/1.2.3.4/tcp/9000");
        assert_eq!(parse_multiaddr("example.org").unwrap().to_string(), "/dns/example.org/tcp/7788");
        assert_eq!(
            parse_multiaddr("wss://node.libp2p.io/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN")
                .unwrap()
                .to_string(),
            "/dns/node.libp2p.io/tcp/443/tls/sni/node.libp2p.io/wss/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN"
        );
    }

    /// 浏览器节点会同时公布 WebRTC 与中继地址；原生端只能拨 TCP/WS
    /// 以及中继电路（电路后面的 `/webrtc` 要截掉）。
    #[test]
    fn provider_addresses_are_filtered_for_native_transports() {
        let relay = "12D3KooWKnDdG3iXw9eTFijk3EWSunZcFi54Zka4wmtqtt6rPxc8";
        let circuit: Multiaddr = format!(
            "/ip4/203.0.113.7/tcp/4001/p2p/{relay}/p2p-circuit/webrtc"
        )
        .parse()
        .unwrap();
        assert_eq!(
            dialable_provider_addr(&circuit).unwrap().to_string(),
            format!("/ip4/203.0.113.7/tcp/4001/p2p/{relay}/p2p-circuit")
        );

        let direct: Multiaddr = "/ip4/198.51.100.5/tcp/7788".parse().unwrap();
        assert_eq!(dialable_provider_addr(&direct).unwrap(), direct);

        let quic: Multiaddr = format!(
            "/ip4/203.0.113.8/udp/4001/quic-v1/p2p/{relay}/p2p-circuit"
        )
        .parse()
        .unwrap();
        assert!(dialable_provider_addr(&quic).is_none(), "QUIC 中继不可拨");

        let webrtc: Multiaddr = "/ip4/198.51.100.6/udp/4001/webrtc".parse().unwrap();
        assert!(dialable_provider_addr(&webrtc).is_none(), "WebRTC 直连不可拨");
    }

    /// 两个真实 libp2p 节点：B 通过 A 的地址拨通，连接后自动对账拿到
    /// A 已有的 op；随后 A 广播的新 op 由 gossipsub 实时送达。
    ///
    /// 关掉内置公共节点，确保这条测试只走 loopback，不依赖外网 ——
    /// 测试不该先问公网今天心情如何。
    #[test]
    fn two_nodes_sync_and_gossip_over_loopback() {
        use crate::domain::identity::Identity;

        let a_id = Identity::from_seed(&[1u8; 32], 0);
        let b_id = Identity::from_seed(&[2u8; 32], 0);

        let ops_a = Arc::new(Mutex::new(vec![op("sync-a", "000000001:0:a")]));
        let got_b: Arc<Mutex<Vec<Op>>> = Arc::new(Mutex::new(Vec::new()));

        let provide_a = {
            let ops = ops_a.clone();
            Arc::new(move || ops.lock().unwrap().clone()) as OpsProvider
        };
        let mut a = Net::new(
            a_id.peer_id.clone(),
            a_id.seed.clone(),
            provide_a,
            Arc::new(|_: Vec<Op>| {}),
            NetConfig {
                port: 0,
                use_builtin_peers: false,
                ..Default::default()
            },
        );
        let port_a = a.start().expect("启动节点 A");
        let a_addr = format!("/ip4/127.0.0.1/tcp/{port_a}/p2p/{}", a_id.peer_id);

        let sink_b = {
            let got = got_b.clone();
            Arc::new(move |ops: Vec<Op>| got.lock().unwrap().extend(ops)) as OpsSink
        };
        let mut b = Net::new(
            b_id.peer_id.clone(),
            b_id.seed.clone(),
            Arc::new(|| Vec::<Op>::new()),
            sink_b,
            NetConfig {
                port: 0,
                bootstrap: vec![a_addr],
                use_builtin_peers: false,
                ..Default::default()
            },
        );
        b.start().expect("启动节点 B");

        let deadline = Instant::now() + Duration::from_secs(20);
        let (mut synced, mut subscribed) = (false, false);
        while Instant::now() < deadline {
            synced = got_b.lock().unwrap().iter().any(|o| o.id == "sync-a");
            subscribed = a.status().peers.iter().any(|p| p.subscribed);
            if synced && subscribed {
                break;
            }
            thread::sleep(Duration::from_millis(100));
        }
        assert!(synced, "B 连接后没有通过对账收到 A 已有的 op");
        assert!(subscribed, "A 看不到 B 订阅了 op 主题");
        assert!(
            b.status().peers.iter().any(|p| p.peer_id == a_id.peer_id),
            "B 的连接列表里没有 A"
        );

        a.broadcast(vec![op("gossip-a", "000000002:0:a")]);
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            if got_b.lock().unwrap().iter().any(|o| o.id == "gossip-a") {
                break;
            }
            thread::sleep(Duration::from_millis(100));
        }
        assert!(
            got_b.lock().unwrap().iter().any(|o| o.id == "gossip-a"),
            "B 没有通过 gossipsub 收到 A 的新广播"
        );

        a.stop();
        b.stop();
    }

    #[test]
    fn provider_key_matches_web_multihash_bytes() {
        let key = provider_key();
        let bytes = key.to_vec();
        assert_eq!(&bytes[..2], &[0x12, 0x20]);
        assert_eq!(bytes.len(), 34);
        let digest = Sha256::digest(PEER_NAMESPACE.as_bytes());
        assert_eq!(&bytes[2..], digest.as_slice());
    }
}