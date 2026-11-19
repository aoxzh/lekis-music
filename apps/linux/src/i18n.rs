//! 界面文案集中处。
//!
//! 按 `docs/CODING_GUIDELINES.md` 的要求，用户可见文字不能散落硬编码；
//! Linux 版先集中在这里，以后接入 gettext（`po/` + `.desktop` 本地化）时只替换本文件的实现。

use lekis_types::{
    ErrorCode, LekisError, PlaybackState, RepeatMode, ScanPhase, ShuffleMode, SourceKind, TrackSort,
};

// ---------------------------------------------------------------------------
// 通用
// ---------------------------------------------------------------------------

/// 应用名（窗口标题、关于页）。
pub const APP_NAME: &str = "Lekis 音乐";

/// 左侧导航：首页。
pub const NAV_HOME: &str = "首页";
/// 左侧导航：资料库。
pub const NAV_LIBRARY: &str = "资料库";
/// 左侧导航：搜索。
pub const NAV_SEARCH: &str = "搜索";
/// 左侧导航：正在播放。
pub const NAV_NOW_PLAYING: &str = "正在播放";
/// 左侧导航：音源。
pub const NAV_SOURCES: &str = "音源";
/// 左侧导航：补全审核。
pub const NAV_ENRICH: &str = "补全审核";
/// 左侧导航：设置。
pub const NAV_SETTINGS: &str = "设置";

// ---------------------------------------------------------------------------
// 首页
// ---------------------------------------------------------------------------

/// 首页标题。
pub const HOME_TITLE: &str = "首页";
/// 首页"最近添加"分组标题。
pub const HOME_RECENT: &str = "最近添加";
/// 首页空状态标题。
pub const HOME_EMPTY_TITLE: &str = "资料库还是空的";
/// 首页空状态说明。
pub const HOME_EMPTY_BODY: &str =
    "添加一个本地文件夹作为音源，扫描完成后这里会列出最近添加的曲目。";
/// 首页空状态按钮。
pub const HOME_EMPTY_ACTION: &str = "添加音源";

// ---------------------------------------------------------------------------
// 资料库
// ---------------------------------------------------------------------------

/// 资料库标题。
pub const LIBRARY_TITLE: &str = "资料库";
/// 资料库排序标签。
pub const LIBRARY_SORT: &str = "排序";
/// 资料库空状态。
pub const LIBRARY_EMPTY: &str = "资料库里还没有曲目。";

/// 排序方式：标题。
pub const SORT_TITLE: &str = "标题";
/// 排序方式：艺人。
pub const SORT_ARTIST: &str = "艺人";
/// 排序方式：专辑。
pub const SORT_ALBUM: &str = "专辑";
/// 排序方式：最近添加。
pub const SORT_RECENTLY_ADDED: &str = "最近添加";
/// 排序方式：最常播放。
pub const SORT_MOST_PLAYED: &str = "最常播放";

/// 排序下拉框的全部选项（顺序和 [`TrackSort`] 一一对应）。
pub const SORT_OPTIONS: [&str; 5] = [
    SORT_TITLE,
    SORT_ARTIST,
    SORT_ALBUM,
    SORT_RECENTLY_ADDED,
    SORT_MOST_PLAYED,
];

// ---------------------------------------------------------------------------
// 列表
// ---------------------------------------------------------------------------

/// 分页列表的"加载更多"按钮。
pub const LIST_LOAD_MORE: &str = "加载更多";
/// 分页列表已到末尾。
pub const LIST_ALL_LOADED: &str = "已加载全部";
/// 列表正在加载。
pub const LIST_LOADING: &str = "正在加载…";
/// 列表项：收藏按钮。
pub const TRACK_LOVE: &str = "收藏 / 取消收藏";

// ---------------------------------------------------------------------------
// 错误提示
// ---------------------------------------------------------------------------

/// 通用操作失败前缀。
pub const OP_FAILED: &str = "操作失败：";
/// 列表加载失败前缀。
pub const LOAD_FAILED: &str = "加载失败：";
/// 播放控制失败前缀。
pub const PLAY_FAILED: &str = "播放控制失败：";

// ---------------------------------------------------------------------------
// 搜索
// ---------------------------------------------------------------------------

/// 搜索页标题。
pub const SEARCH_TITLE: &str = "搜索";
/// 搜索框占位文字。
pub const SEARCH_PLACEHOLDER: &str = "搜索曲目、专辑、艺人";
/// 搜索页初始提示。
pub const SEARCH_EMPTY: &str = "输入关键词开始搜索。拼音、简繁和首字母匹配都在核心里完成。";
/// 搜索无结果。
pub const SEARCH_NO_RESULT: &str = "没有找到匹配的结果。";

// ---------------------------------------------------------------------------
// 正在播放 / 播放器
// ---------------------------------------------------------------------------

/// 正在播放页标题。
pub const NOW_PLAYING_TITLE: &str = "正在播放";
/// 没有曲目时的说明。
pub const NOW_PLAYING_NOTHING: &str = "还没有开始播放。在资料库里点一首歌试试。";
/// 播放条：没有曲目。
pub const PLAYER_NO_TRACK: &str = "未在播放";
/// 播放条：副标题占位。
pub const PLAYER_NO_TRACK_SUBTITLE: &str = "选择一首歌开始";
/// 播放按钮。
pub const PLAYER_PLAY: &str = "播放";
/// 暂停按钮。
pub const PLAYER_PAUSE: &str = "暂停";
/// 下一首。
pub const PLAYER_NEXT: &str = "下一首";
/// 上一首。
pub const PLAYER_PREVIOUS: &str = "上一首";
/// 音量。
pub const PLAYER_VOLUME: &str = "音量";
/// 循环模式（不循环）。
pub const PLAYER_REPEAT_OFF: &str = "循环：关闭";
/// 循环模式（列表循环）。
pub const PLAYER_REPEAT_ALL: &str = "循环：列表";
/// 循环模式（单曲循环）。
pub const PLAYER_REPEAT_ONE: &str = "循环：单曲";
/// 随机模式（关闭）。
pub const PLAYER_SHUFFLE_OFF: &str = "随机：关闭";
/// 随机模式（真随机）。
pub const PLAYER_SHUFFLE_RANDOM: &str = "随机：打开";
/// 随机模式（智能随机）。
pub const PLAYER_SHUFFLE_SMART: &str = "随机：智能";
/// 播放状态：加载中。
pub const STATE_LOADING: &str = "缓冲中…";
/// 播放状态：缓冲。
pub const STATE_BUFFERING: &str = "缓冲中…";
/// 播放状态：已暂停。
pub const STATE_PAUSED: &str = "已暂停";
/// 播放状态：队列播完。
pub const STATE_ENDED: &str = "播放结束";

// ---------------------------------------------------------------------------
// 音源
// ---------------------------------------------------------------------------

/// 音源页标题。
pub const SOURCES_TITLE: &str = "音源";
/// 添加本地文件夹按钮。
pub const SOURCES_ADD_LOCAL: &str = "添加本地文件夹";
/// 选择文件夹对话框标题。
pub const SOURCES_PICK_FOLDER: &str = "选择音乐文件夹";
/// 音源页空状态。
pub const SOURCES_EMPTY: &str = "还没有添加音源。添加一个本地音乐文件夹，扫描完全交给核心。";
/// 重新扫描按钮。
pub const SOURCES_RESCAN: &str = "重新扫描";
/// 添加成功。
pub const SOURCES_ADDED: &str = "已添加音源，正在后台扫描…";
/// 已取消添加。
pub const SOURCES_CANCELLED: &str = "已取消添加音源";
/// 扫描中。
pub const SOURCES_SCANNING: &str = "正在扫描：";
/// 扫描完成（`{}` 依次是新增 / 更新 / 移除）。
pub const SOURCES_SCAN_FINISHED: &str = "扫描完成：新增 {added} · 更新 {updated} · 移除 {removed}";
/// 音源里没有文件。
pub const SOURCES_RESCAN_STARTED: &str = "已重新开始扫描…";
/// 音源页脚注。
pub const SOURCES_FOOTNOTE: &str =
    "目前支持本地文件夹；SMB / WebDAV / NFS / SFTP 与服务器音源的添加界面还没做（TODO SRC-04~06）。";

// ---------------------------------------------------------------------------
// 补全审核
// ---------------------------------------------------------------------------

/// 补全审核页标题。
pub const ENRICH_TITLE: &str = "补全审核";
/// 待确认数量标签。
pub const ENRICH_PENDING: &str = "待确认";
/// 没有待确认项。
pub const ENRICH_EMPTY_TITLE: &str = "没有待确认的补全项";
/// 没有待确认项说明。
pub const ENRICH_EMPTY_BODY: &str = "核心在后台补全曲目信息，置信度不够的条目会在这里等你确认。";
/// 有候选项但接口未接通。
pub const ENRICH_UNAVAILABLE: &str =
    "核心已经发现需要人工确认的补全项，但列出候选的接口还没接通（TODO ENR-06：list_enrich_candidates / accept / reject）。";
/// 页脚说明。
pub const ENRICH_FOOTNOTE: &str = "这一页目前只显示队列长度；审核操作等核心的候选 API 就绪后再接。";

// ---------------------------------------------------------------------------
// 设置
// ---------------------------------------------------------------------------

/// 设置页标题。
pub const SETTINGS_TITLE: &str = "设置";
/// 应用版本。
pub const SETTINGS_APP_VERSION: &str = "应用版本";
/// 核心版本。
pub const SETTINGS_CORE_VERSION: &str = "核心版本";
/// 设备 ID。
pub const SETTINGS_DEVICE_ID: &str = "设备 ID";
/// 数据目录。
pub const SETTINGS_DATA_DIR: &str = "数据目录";
/// 缓存目录。
pub const SETTINGS_CACHE_DIR: &str = "缓存目录";
/// 运行平台。
pub const SETTINGS_PLATFORM: &str = "运行平台";
/// 深色主题。
pub const SETTINGS_DARK_THEME: &str = "深色主题";
/// 深色主题说明。
pub const SETTINGS_DARK_THEME_BODY: &str = "按 design/tokens.json 的 dark 色板生成 GTK 样式表。";
/// 设置页脚注。
pub const SETTINGS_FOOTNOTE: &str =
    "TODO(SET-01~04)：主题跟随系统、语言、音频输出（独占 / 比特完美）、ReplayGain、缓存上限、补全来源、插件、同步、隐私。\
设置项通过 lekis-core 的 kv 表读写，不放在 UI 里。";

// ---------------------------------------------------------------------------
// 迷你播放器 / 桌面歌词
// ---------------------------------------------------------------------------

/// 迷你播放器窗口标题。
pub const MINI_PLAYER_TITLE: &str = "迷你播放器";
/// 桌面歌词窗口标题。
pub const LYRICS_TITLE: &str = "桌面歌词";
/// 桌面歌词占位提示（核心还没有歌词 API）。
pub const LYRICS_PLACEHOLDER: &str = "核心还没有提供歌词（TODO ENR-04），这里先显示占位。";
/// 桌面歌词页脚。
pub const LYRICS_FOOTNOTE: &str =
    "UIX-07 骨架：窗口 + PositionTick 事件绑定 + LRC 解析/高亮都已就绪，等核心的歌词 API 接上即可显示。";
/// 打开迷你播放器（按钮提示）。
pub const OPEN_MINI_PLAYER: &str = "迷你播放器";
/// 打开桌面歌词（按钮提示）。
pub const OPEN_LYRICS: &str = "桌面歌词";

// ---------------------------------------------------------------------------
// 快捷键提示
// ---------------------------------------------------------------------------

/// 快捷键提示（设置页展示）。
pub const SHORTCUTS_HINT: &str =
    "快捷键：空格 播放/暂停 · ←/→ 快退/快进 5 秒 · Ctrl+O 添加音源 · Ctrl+F 搜索";

// ---------------------------------------------------------------------------
// 查询函数
// ---------------------------------------------------------------------------

/// 排序方式的中文名。
pub fn sort_text(sort: TrackSort) -> &'static str {
    match sort {
        TrackSort::Title => SORT_TITLE,
        TrackSort::Artist => SORT_ARTIST,
        TrackSort::Album => SORT_ALBUM,
        TrackSort::RecentlyAdded => SORT_RECENTLY_ADDED,
        TrackSort::MostPlayed => SORT_MOST_PLAYED,
    }
}

/// 排序方式在 [`SORT_OPTIONS`] 里的下标。
pub fn sort_index(sort: TrackSort) -> u32 {
    match sort {
        TrackSort::Title => 0,
        TrackSort::Artist => 1,
        TrackSort::Album => 2,
        TrackSort::RecentlyAdded => 3,
        TrackSort::MostPlayed => 4,
    }
}

/// 下拉框下标转排序方式。
pub fn sort_from_index(index: u32) -> TrackSort {
    match index {
        1 => TrackSort::Artist,
        2 => TrackSort::Album,
        3 => TrackSort::RecentlyAdded,
        4 => TrackSort::MostPlayed,
        _ => TrackSort::Title,
    }
}

/// 音源类型的中文名。
pub fn source_kind_text(kind: SourceKind) -> &'static str {
    match kind {
        SourceKind::Local => "本地文件夹",
        SourceKind::Smb => "SMB / Windows 共享",
        SourceKind::WebDav => "WebDAV",
        SourceKind::Nfs => "NFS",
        SourceKind::Sftp => "SFTP",
        SourceKind::OpenSubsonic => "OpenSubsonic",
        SourceKind::Jellyfin => "Jellyfin",
        SourceKind::Emby => "Emby",
        SourceKind::Plex => "Plex",
        SourceKind::Radio => "网络电台",
        SourceKind::Plugin => "插件音源",
    }
}

/// 扫描阶段的中文名。
pub fn scan_phase_text(phase: ScanPhase) -> &'static str {
    match phase {
        ScanPhase::Walking => "遍历目录",
        ScanPhase::ReadingTags => "读取标签",
        ScanPhase::Artwork => "生成缩略图",
        ScanPhase::WritingSharedIndex => "写共享索引",
    }
}

/// 播放状态的中文提示；正在播放返回 `None`（界面自己用图标表达）。
pub fn playback_state_text(state: PlaybackState) -> Option<&'static str> {
    match state {
        PlaybackState::Idle | PlaybackState::Playing => None,
        PlaybackState::Loading => Some(STATE_LOADING),
        PlaybackState::Paused => Some(STATE_PAUSED),
        PlaybackState::Buffering => Some(STATE_BUFFERING),
        PlaybackState::Ended => Some(STATE_ENDED),
    }
}

/// 循环模式的中文名。
pub fn repeat_text(mode: RepeatMode) -> &'static str {
    match mode {
        RepeatMode::Off => PLAYER_REPEAT_OFF,
        RepeatMode::All => PLAYER_REPEAT_ALL,
        RepeatMode::One => PLAYER_REPEAT_ONE,
    }
}

/// 循环模式按钮上的图标名（Adwaita 图标主题）。
pub fn repeat_icon(mode: RepeatMode) -> &'static str {
    match mode {
        // 单曲循环没有专门的 Adwaita 图标，用 1 标记的近似图标。
        RepeatMode::One => "media-playlist-repeat-song-symbolic",
        _ => "media-playlist-repeat-symbolic",
    }
}

/// 下一个循环模式（点击按钮时轮换 Off → All → One → Off）。
pub fn next_repeat(mode: RepeatMode) -> RepeatMode {
    match mode {
        RepeatMode::Off => RepeatMode::All,
        RepeatMode::All => RepeatMode::One,
        RepeatMode::One => RepeatMode::Off,
    }
}

/// 随机模式的中文名。
pub fn shuffle_text(mode: ShuffleMode) -> &'static str {
    match mode {
        ShuffleMode::Off => PLAYER_SHUFFLE_OFF,
        ShuffleMode::Random => PLAYER_SHUFFLE_RANDOM,
        ShuffleMode::Smart => PLAYER_SHUFFLE_SMART,
    }
}

/// 随机模式按钮上的图标名。
pub fn shuffle_icon(mode: ShuffleMode) -> &'static str {
    match mode {
        ShuffleMode::Off => "media-playlist-shuffle-symbolic",
        // 智能随机和真随机共用图标，用 tooltip 区分。
        ShuffleMode::Random | ShuffleMode::Smart => "media-playlist-shuffle-symbolic",
    }
}

/// 下一个随机模式（点击按钮时轮换 Off → Random → Smart → Off）。
pub fn next_shuffle(mode: ShuffleMode) -> ShuffleMode {
    match mode {
        ShuffleMode::Off => ShuffleMode::Random,
        ShuffleMode::Random => ShuffleMode::Smart,
        ShuffleMode::Smart => ShuffleMode::Off,
    }
}

/// 毫秒时长格式化成 `m:ss`（超过 1 小时用 `h:mm:ss`），和 Windows 版 `Format.Duration` 一致。
pub fn format_duration(ms: u64) -> String {
    let total_seconds = ms / 1000;
    let seconds = total_seconds % 60;
    let minutes = (total_seconds / 60) % 60;
    let hours = total_seconds / 3600;
    if hours > 0 {
        format!("{hours}:{minutes:02}:{seconds:02}")
    } else {
        format!("{minutes}:{seconds:02}")
    }
}

/// 把核心错误翻译成给用户看的提示。
///
/// 按 `docs/CODING_GUIDELINES.md`：不要直接把 `LekisError::message` 展示给用户，
/// 技术细节只写日志。
pub fn error_text(error: &LekisError) -> String {
    let hint = match error.code {
        ErrorCode::NotFound => "找不到对应的内容",
        ErrorCode::InvalidArgument => "参数不合法",
        ErrorCode::Unsupported => "当前平台不支持这个操作",
        ErrorCode::NotImplemented => "这个功能还没有实现",
        ErrorCode::Io => "读写文件失败",
        ErrorCode::Network => "网络访问失败",
        ErrorCode::Auth => "认证失败",
        ErrorCode::Database => "本地数据库出错",
        ErrorCode::Decode => "音频解码失败",
        ErrorCode::Plugin => "插件出错",
        ErrorCode::PermissionDenied => "没有权限",
        ErrorCode::Cancelled => "操作已取消",
        ErrorCode::RateLimited => "操作太频繁，请稍后再试",
        ErrorCode::Internal => "内部错误",
    };
    format!("{hint}（{}）", error.code.as_str())
}
