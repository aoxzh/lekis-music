//! Normalize local karaoke sidecars to the TTML word, translation and agent model.

use super::{sidecar_bytes, MAX_SIDECAR_BYTES};
use base64::{engine::general_purpose::STANDARD, Engine};
use lekis_vfs::{Vfs, VfsPath};
use quick_xml::{escape::partial_escape, events::Event, Reader};
use regex::Regex;
use serde_json::Value;
use std::{borrow::Cow, collections::BTreeMap, fmt::Write, sync::LazyLock};

mod qrc_container;
#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests;

#[derive(Clone, Copy, PartialEq)]
pub(super) enum Format {
    Qrc,
    Yrc,
    Krc,
}

impl Format {
    pub(super) fn from_ext(ext: &str) -> Option<Self> {
        match ext {
            "qrc" | "QRC" => Some(Self::Qrc),
            "yrc" | "YRC" => Some(Self::Yrc),
            "krc" | "KRC" => Some(Self::Krc),
            _ => None,
        }
    }
}

fn inflate(bytes: &[u8]) -> Option<Vec<u8>> {
    miniz_oxide::inflate::decompress_to_vec_zlib_with_limit(bytes, MAX_SIDECAR_BYTES as usize).ok()
}

fn text(format: Format, bytes: &[u8]) -> Option<String> {
    let unpacked;
    let data = if format == Format::Qrc
        && (bytes.starts_with(qrc_container::MAGIC)
            || bytes
                .iter()
                .find(|byte| !byte.is_ascii_whitespace())
                .is_some_and(u8::is_ascii_hexdigit))
    {
        unpacked = qrc_container::unpack(bytes)?;
        unpacked.as_slice()
    } else if let Some(payload) = bytes
        .strip_prefix(b"krc1")
        .filter(|_| format == Format::Krc)
    {
        let mask = b"@Gaw^2tGQ61-\xce\xd2ni";
        let compressed: Vec<_> = payload
            .iter()
            .enumerate()
            .map(|(index, byte)| byte ^ mask[index % 16])
            .collect();
        unpacked = inflate(&compressed)?;
        unpacked.as_slice()
    } else {
        bytes
    };
    let decoded = if let Some((encoding, skip)) = encoding_rs::Encoding::for_bom(data) {
        encoding.decode_without_bom_handling_and_without_replacement(&data[skip..])?
    } else if let Ok(utf8) = std::str::from_utf8(data) {
        Cow::Borrowed(utf8)
    } else {
        encoding_rs::GB18030.decode_without_bom_handling_and_without_replacement(data)?
    };
    xml_text(&decoded).then(|| decoded.into_owned())
}

fn xml_text(text: &str) -> bool {
    text.chars().all(|ch| matches!(ch, '\n' | '\r' | '\t' | '\u{20}'..='\u{d7ff}' | '\u{e000}'..='\u{fffd}' | '\u{10000}'..='\u{10ffff}'))
}

fn qrc_content(text: &str) -> Option<Cow<'_, str>> {
    if !text.trim_start().starts_with('<') {
        return Some(Cow::Borrowed(text));
    }
    let mut reader = Reader::from_str(text);
    let mut content = None;
    loop {
        match reader.read_event().ok()? {
            Event::Start(tag) | Event::Empty(tag) if tag.name().as_ref() == "Lyric_1" => {
                let value = tag.try_get_attribute("LyricContent").ok()??;
                content = Some(Cow::Owned(
                    quick_xml::escape::unescape(&value.value).ok()?.into_owned(),
                ));
            }
            Event::Eof => return content,
            _ => {}
        }
    }
}

#[derive(Default)]
struct Line {
    start: u32,
    end: u32,
    words: Vec<(u32, u32, String)>,
    translation: String,
    roman: String,
    voice: Option<String>,
}

static Q_WORD: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"\(([0-9]+),([0-9]+)\)").ok());
static Y_WORD: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"\(([0-9]+),([0-9]+),[0-9]+\)").ok());
static K_WORD: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"<([0-9]+),([0-9]+),[0-9]+>").ok());
static VOICE: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(concat!(
        r"(?i)^\s*(?:\[(合唱|齐唱|合|男声?|女声?|A|B|All|Both|Male|Female|Voice [12])\]",
        r"|(合唱|齐唱|合|男声?|女声?|A|B|All|Both|Male|Female|Voice [12])\s*[:：]",
        r"|\[(?:演唱|Vocal)\s*[:：]\s*([^\]\n]{1,100})\])\s*"
    ))
    .ok()
});

fn parse_line(format: Format, raw: &str) -> Option<Line> {
    let (header, body) = raw.trim_start().strip_prefix('[')?.split_once(']')?;
    let (start, duration) = header.split_once(',')?;
    let start: u32 = start.parse().ok()?;
    let mut line = Line {
        start,
        end: start.checked_add(duration.parse().ok()?)?,
        ..Line::default()
    };
    let markers = match format {
        Format::Qrc => &*Q_WORD,
        Format::Yrc => &*Y_WORD,
        Format::Krc => &*K_WORD,
    };
    let mut matches = markers.as_ref()?.captures_iter(body).peekable();
    let mut cursor = 0;
    while let Some(marker) = matches.next() {
        let token = marker.get(0)?;
        let start = marker[1]
            .parse::<u32>()
            .ok()?
            .checked_add(if format == Format::Krc { line.start } else { 0 })?;
        let end = start.checked_add(marker[2].parse().ok()?)?;
        let value = if format == Format::Qrc {
            let word = &body[cursor..token.start()];
            cursor = token.end();
            word
        } else {
            if cursor == 0 && token.start() > 0 {
                line.words
                    .push((line.start, line.start, body[..token.start()].into()));
            }
            cursor = matches
                .peek()
                .and_then(|next| next.get(0))
                .map_or(body.len(), |next| next.start());
            &body[token.end()..cursor]
        };
        if !value.is_empty() {
            line.words.push((start, end, value.into()));
        }
    }
    if cursor < body.len() {
        let start = line.words.last().map_or(line.start, |word| word.1);
        line.words
            .push((start, line.end.max(start), body[cursor..].into()));
    }
    Some(line)
}

fn extract_voice(line: &mut Line) {
    let joined: String = line.words.iter().map(|word| word.2.as_str()).collect();
    let Some(label) = VOICE.as_ref().and_then(|prefix| prefix.captures(&joined)) else {
        return;
    };
    line.voice = label
        .iter()
        .skip(1)
        .flatten()
        .next()
        .map(|part| part.as_str().trim().to_owned());
    let mut remaining = label[0].len();
    for (_, _, word) in &mut line.words {
        let count = remaining.min(word.len());
        word.drain(..count);
        remaining -= count;
        if remaining == 0 {
            break;
        }
    }
    line.words.retain(|word| !word.2.is_empty());
}

fn krc_languages(lines: &mut [Line], data: &str) -> Option<()> {
    let decoded = STANDARD.decode(data.trim()).ok()?;
    let languages = serde_json::from_slice::<Value>(&decoded).ok()?;
    for language in languages["content"].as_array()? {
        let (Some(kind @ (0 | 1)), Some(rows)) = (
            language["type"].as_u64(),
            language["lyricContent"].as_array(),
        ) else {
            continue;
        };
        let mut rows = rows.iter();
        for line in &mut *lines {
            if kind == 0 && line.words.is_empty() {
                continue;
            }
            let Some(row) = rows.next() else { break };
            if let Some(parts) = row.as_array() {
                let text: String = parts.iter().filter_map(Value::as_str).collect();
                if text.trim() == "//" || !xml_text(&text) {
                    continue;
                }
                if kind == 1 {
                    line.translation = text;
                } else {
                    line.roman = text;
                }
            }
        }
    }
    Some(())
}

static LRC_STAMP: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"^\[([0-9]+):([0-5][0-9])(?:[.:]([0-9]{1,3}))?\]").ok());

fn lrc_millis(stamp: &regex::Captures<'_>) -> Option<u32> {
    let minutes = stamp[1].parse::<u32>().ok()?;
    let seconds = stamp[2].parse::<u32>().ok()?;
    let fraction = match stamp.get(3) {
        Some(digits) => digits.as_str().parse::<u32>().ok()? * 10u32.pow(3 - digits.len() as u32),
        None => 0,
    };
    minutes
        .checked_mul(60_000)?
        .checked_add(seconds * 1000 + fraction)
}

fn add_timed_text(lines: &mut [Line], content: &str, roman: bool, format: Format) {
    let Some(pattern) = LRC_STAMP.as_ref() else {
        return;
    };
    let mut by_start = BTreeMap::new();
    for raw in content.lines() {
        let mut rest = raw.trim();
        let mut times = Vec::new();
        while let Some(stamp) = pattern.captures(rest) {
            if let Some(at) = lrc_millis(&stamp) {
                times.push(at);
            }
            rest = &rest[stamp[0].len()..];
        }
        if !times.is_empty() && !rest.is_empty() {
            let rest = std::sync::Arc::<str>::from(rest);
            for time in times {
                by_start.insert(time, rest.clone());
            }
        } else if let Some(line) = parse_line(format, raw) {
            let text: String = line.words.iter().map(|word| word.2.as_str()).collect();
            by_start.insert(line.start, text.into());
        }
    }
    let mut budget = MAX_SIDECAR_BYTES as usize;
    for line in lines {
        // QQ exports round or truncate companion clocks to centiseconds.
        let candidate = if format == Format::Qrc {
            by_start
                .range(line.start.saturating_sub(9)..=line.start.saturating_add(9))
                .min_by_key(|(time, _)| time.abs_diff(line.start))
                .map(|(time, _)| *time)
        } else {
            Some(line.start)
        };
        if let Some(text) = candidate.and_then(|time| by_start.remove(&time)) {
            if text.len() > budget {
                break;
            }
            budget -= text.len();
            if roman {
                line.roman = text.to_string();
            } else {
                line.translation = text.to_string();
            }
        }
    }
}

fn render(mut lines: Vec<Line>, offset: i32) -> Option<String> {
    let shift =
        |time: u32| (i64::from(time) - i64::from(offset)).clamp(0, i64::from(u32::MAX)) as u32;
    let mut agents = BTreeMap::new();
    for line in &mut lines {
        extract_voice(line);
        // The player compares concatenated spans with the trimmed paragraph text.
        for (_, _, word) in &mut line.words {
            word.drain(..word.len() - word.trim_start().len());
            if !word.is_empty() {
                break;
            }
        }
        for (_, _, word) in line.words.iter_mut().rev() {
            word.truncate(word.trim_end().len());
            if !word.is_empty() {
                break;
            }
        }
        line.words.retain(|word| !word.2.is_empty());
        if let Some(name) = &line.voice {
            let id = agents.len() + 1;
            agents.entry(name.clone()).or_insert(id);
        }
    }
    lines.retain(|line| line.words.iter().any(|word| !word.2.trim().is_empty()));
    if lines.is_empty() {
        return None;
    }
    let mut xml = String::from("<tt xmlns=\"http://www.w3.org/ns/ttml\" xmlns:ttm=\"http://www.w3.org/ns/ttml#metadata\" xml:space=\"preserve\">");
    if !agents.is_empty() {
        xml.push_str("<head><metadata>");
        for (name, id) in &agents {
            let kind = if matches!(
                name.to_ascii_lowercase().as_str(),
                "合" | "合唱" | "齐唱" | "all" | "both"
            ) {
                "group"
            } else {
                "person"
            };
            write!(
                xml,
                "<ttm:agent xml:id=\"v{id}\" type=\"{kind}\"><ttm:name>{}</ttm:name></ttm:agent>",
                partial_escape(name)
            )
            .ok()?;
        }
        xml.push_str("</metadata></head>");
    }
    xml.push_str("<body><div>");
    for line in lines {
        write!(
            xml,
            "<p begin=\"{}ms\" end=\"{}ms\"",
            shift(line.start),
            shift(line.end)
        )
        .ok()?;
        if let Some(id) = line.voice.as_ref().and_then(|name| agents.get(name)) {
            write!(xml, " ttm:agent=\"v{id}\"").ok()?;
        }
        xml.push('>');
        for (start, end, word) in line.words {
            write!(
                xml,
                "<span begin=\"{}ms\" end=\"{}ms\">{}</span>",
                shift(start),
                shift(end),
                partial_escape(&word)
            )
            .ok()?;
        }
        for (role, value) in [("x-translation", line.translation), ("x-roman", line.roman)] {
            if !value.trim().is_empty() && xml_text(&value) {
                write!(
                    xml,
                    "<span ttm:role=\"{role}\">{}</span>",
                    partial_escape(&value)
                )
                .ok()?;
            }
        }
        xml.push_str("</p>");
    }
    xml.push_str("</div></body></tt>");
    Some(xml)
}

pub(super) async fn read(
    format: Format,
    bytes: &[u8],
    vfs: &dyn Vfs,
    stem: &str,
    ext: &str,
) -> Option<String> {
    let decoded = text(format, bytes)?;
    let mut content = if format == Format::Qrc {
        qrc_content(&decoded)?
    } else {
        Cow::Borrowed(decoded.as_str())
    };
    let json = (format == Format::Yrc && content.trim_start().starts_with('{'))
        .then(|| serde_json::from_str::<Value>(&content).ok())
        .flatten();
    if let Some(envelope) = &json {
        content = Cow::Borrowed(envelope.pointer("/yrc/lyric")?.as_str()?);
    }
    if !xml_text(&content) {
        return None;
    }
    let mut lines: Vec<_> = content
        .lines()
        .filter_map(|raw| parse_line(format, raw))
        .collect();
    if lines.is_empty() {
        return None;
    }
    if format == Format::Krc {
        if let Some(tag) = content
            .lines()
            .find_map(|raw| raw.trim().strip_prefix("[language:")?.strip_suffix(']'))
        {
            krc_languages(&mut lines, tag);
        }
    } else if let Some(envelope) = &json {
        for (roman, names) in [
            (false, ["ytlrc", "tlyric"]),
            (true, ["yromalrc", "romalrc"]),
        ] {
            if let Some(value) = names.iter().find_map(|name| {
                envelope[name]["lyric"]
                    .as_str()
                    .filter(|s| !s.trim().is_empty())
            }) {
                add_timed_text(&mut lines, value, roman, format);
            }
        }
    } else if format == Format::Qrc {
        let base = stem.strip_suffix("_qm").unwrap_or(stem);
        for (roman, suffix) in [(false, "_qmts"), (true, "_qmRoma")] {
            let path = VfsPath::parse(&format!("{base}{suffix}.{ext}"))?;
            if let Some(data) = sidecar_bytes(vfs, &path).await {
                if let Some(decoded) = text(format, &data) {
                    if let Some(content) = qrc_content(&decoded) {
                        add_timed_text(&mut lines, &content, roman, format);
                    }
                }
            }
        }
    }
    let offset = content
        .lines()
        .find_map(|line| {
            line.trim()
                .strip_prefix("[offset:")?
                .strip_suffix(']')?
                .trim()
                .parse::<i32>()
                .ok()
        })
        .unwrap_or(0);
    render(lines, offset)
}
