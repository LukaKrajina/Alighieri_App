//! 核心域层
//! --------
//! 与平台、UI、网络全部无关的纯逻辑。这一层有三条硬性约束，
//! 违反任何一条，两台设备就会开始各说各话：
//!
//!  1. **归约必须是纯函数** —— 不能读「当前时间」。
//!     赛事状态、改名冷却期、PV 时间窗都在读取侧派生。
//!  2. **定序必须完全确定** —— HLC 三元组比较（wall → counter → node 字节序），
//!     所有容器用 `BTreeMap` / `BTreeSet`，不依赖插入顺序。
//!  3. **门控未通过的 op 必须挂起重试**，不能丢弃 —— 丢弃最省事，
//!     也最伤收敛性。

pub mod badges;
pub mod bridge;
pub mod carousel;
pub mod catalog;
pub mod contest;
pub mod hlc;
pub mod identity;
pub mod keys;
pub mod licenses;
pub mod model;
pub mod penname;
pub mod reducer;
pub mod selectors;
pub mod signature;
pub mod state;
pub mod theme;
pub mod time;
pub mod view;
pub mod wallet;