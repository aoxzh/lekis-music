//! 悬浮歌词窗口的输入数据：歌词行、样式、窗口发出的事件。

/// 一行里的一个字 / 词（增强 LRC 的逐字时间）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Word {
    /// 开始高亮的时间（毫秒，已套用偏移）。
    pub start_ms: u32,
    /// 高亮结束的时间（毫秒）。
    pub end_ms: u32,
    /// 文本。一行所有字拼起来等于 [`Line::text`]。
    pub text: String,
}

/// 一行歌词。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Line {
    /// 开始时间（毫秒，已套用偏移）。
    pub start_ms: u32,
    /// 正文。空串表示间奏。
    pub text: String,
    /// 与本行同一时间戳的翻译 / 罗马音（可选）。
    pub translation: Option<String>,
    /// 逐字时间；没有时为空。
    pub words: Vec<Word>,
}

/// 一首歌的歌词（由 UI 在换曲时推送一次）。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct LyricsDoc {
    /// 这份歌词属于哪首曲目；和播放时钟的曲目不一致时不显示（过期数据）。
    pub track_id: Option<i64>,
    /// 曲名：没有同步歌词时显示。
    pub title: String,
    /// 艺人：没有同步歌词时作为第二行显示。
    pub artist: String,
    /// 是否有时间戳。没有时只显示曲名。
    pub synced: bool,
    /// 按开始时间排好序的行。
    pub lines: Vec<Line>,
}

/// 外观设置。颜色都是 `0xAARRGGBB`。
#[derive(Debug, Clone, PartialEq)]
pub struct Style {
    /// 主行字号（DIP，按显示器 DPI 缩放）。
    pub font_size: f32,
    /// 字体族；空串用默认（Microsoft YaHei UI）。
    pub font_family: String,
    /// 粗体。
    pub bold: bool,
    /// 已唱部分 / 当前行（无逐字时间时整行）的颜色。
    pub sung_color: u32,
    /// 未唱部分和第二行的颜色。
    pub unsung_color: u32,
    /// 描边 / 阴影颜色。
    pub outline_color: u32,
    /// 歌词不透明度（0.2..=1）。工具栏和背景不受影响。
    pub opacity: f32,
    /// 显示第二行（有翻译时显示翻译，否则显示下一行）。
    pub two_line: bool,
}

impl Default for Style {
    fn default() -> Self {
        Self {
            font_size: 34.0,
            font_family: String::new(),
            bold: true,
            sung_color: 0xFF4F_C3F7,
            unsung_color: 0xFFFF_FFFF,
            outline_color: 0xB000_0000,
            opacity: 1.0,
            two_line: true,
        }
    }
}

impl Style {
    /// 把用户输入夹到合理范围。
    pub fn sanitized(mut self) -> Self {
        if !self.font_size.is_finite() {
            self.font_size = Style::default().font_size;
        }
        self.font_size = self.font_size.clamp(MIN_FONT_SIZE, MAX_FONT_SIZE);
        if !self.opacity.is_finite() {
            self.opacity = 1.0;
        }
        self.opacity = self.opacity.clamp(0.2, 1.0);
        self
    }
}

/// 允许的最小字号（DIP）。
pub const MIN_FONT_SIZE: f32 = 16.0;
/// 允许的最大字号（DIP）。
pub const MAX_FONT_SIZE: f32 = 72.0;

/// 悬浮窗工具栏上的播放控制。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Control {
    /// 上一首。
    Previous,
    /// 播放 / 暂停。
    PlayPause,
    /// 下一首。
    Next,
}

/// 悬浮窗发出的事件（在窗口线程上回调，处理函数不要阻塞）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// 用户点了悬浮窗上的关闭按钮（窗口已隐藏）。
    Closed,
    /// 用户在悬浮窗上锁定 / 解锁。
    LockChanged(bool),
    /// 工具栏上的播放控制。
    Control(Control),
    /// 拖动 / 调整宽度结束：新的位置记录（JSON，交给宿主持久化）。
    PlacementChanged(String),
}
