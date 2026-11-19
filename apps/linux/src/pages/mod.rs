//! 页面模块。
//!
//! 页面划分和 `apps/windows` / `apps/android` 一一对应（`docs/ARCHITECTURE.md`
//! 第 7 节）：首页、资料库、搜索、正在播放、音源、补全审核、设置。
//!
//! 每个页面只做三件事：摆控件、调 [`crate::app::App`] 暴露的核心 API、
//! 订阅核心事件刷新显示。**没有业务逻辑**。

pub mod enrich_review;
pub mod home;
pub mod library;
pub mod now_playing;
pub mod search;
pub mod settings;
pub mod sources;
