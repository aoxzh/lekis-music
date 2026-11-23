//! 注音歌词桥接（UIX-11）。
//!
//! 纯函数，同步返回：一行歌词的注音在本地几百微秒内算完（静态拼音表），
//! 走异步通道反而让 Dart 侧多一次 await 和一次帧延迟。
//!
//! 偏移是 **UTF-16**，Dart 侧可以直接拿去 `TextPainter.getBoxesForSelection`。

use flutter_rust_bridge::frb;
use lekis_enrich::ruby::{self, PinyinStyle};

/// 拼音写法。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PinyinStyleDto {
    /// 不带声调：`qing`。
    Plain,
    /// 带声调符号：`qíng`。
    Tone,
    /// 带声调数字：`qing2`。
    ToneNum,
}

impl From<PinyinStyleDto> for PinyinStyle {
    fn from(value: PinyinStyleDto) -> Self {
        match value {
            PinyinStyleDto::Plain => Self::Plain,
            PinyinStyleDto::Tone => Self::Tone,
            PinyinStyleDto::ToneNum => Self::ToneNum,
        }
    }
}

/// 一个注音区间：`line[start..end]` 的读音是 `ruby`（偏移按 UTF-16 计）。
#[derive(Debug, Clone)]
pub struct RubySpanDto {
    pub start: u32,
    pub end: u32,
    pub ruby: String,
}

/// 一行歌词的注音结果。没有汉字的行（英文 / 纯假名 / 空行）返回空 `spans`。
#[derive(Debug, Clone)]
pub struct RubyLineDto {
    pub spans: Vec<RubySpanDto>,
}

/// 给整首歌的歌词逐行注音。
///
/// `lines` 的顺序和返回值的顺序一一对应；调用方可以把结果按行号缓存，
/// 换行歌词时只需要重新算新增的行。
#[frb(sync)]
pub fn lyric_ruby_lines(lines: Vec<String>, style: PinyinStyleDto) -> Vec<RubyLineDto> {
    let style = PinyinStyle::from(style);
    ruby::annotate_lines(&lines, style)
        .into_iter()
        .map(|spans| RubyLineDto {
            spans: spans
                .into_iter()
                .map(|s| RubySpanDto {
                    start: u32::try_from(s.start).unwrap_or(u32::MAX),
                    end: u32::try_from(s.end).unwrap_or(u32::MAX),
                    ruby: s.ruby,
                })
                .collect(),
        })
        .collect()
}

/// 这段文本里有没有需要注音的汉字。
///
/// UI 侧用它先跳过纯英文 / 纯假名歌词行，避免为整首歌都请求一次注音。
#[frb(sync)]
pub fn lyric_has_han(text: String) -> bool {
    ruby::contains_han(&text)
}
