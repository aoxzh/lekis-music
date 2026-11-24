use std::fmt::Write;

pub(super) fn to_ttml(input: &str) -> Option<String> {
    let normalized = input.replace("\r\n", "\n").replace('\r', "\n");
    let mut lines = normalized.lines();
    let header = lines.next()?.strip_prefix("WEBVTT")?;
    if !(header.is_empty() || header.starts_with([' ', '\t'])) || header.contains("-->") {
        return None;
    }
    lines.find(|line| line.trim().is_empty())?;
    let mut paragraphs = String::new();
    while let Some(first) = lines.find(|line| !line.trim().is_empty()) {
        let mut block = lines.by_ref().take_while(|line| !line.trim().is_empty());
        write_cue(first.trim(), &mut block, &mut paragraphs);
        block.for_each(drop);
    }
    if paragraphs.is_empty() {
        return None;
    }
    Some(format!(
        "<tt xmlns=\"http://www.w3.org/ns/ttml\"><body><div>{paragraphs}</div></body></tt>"
    ))
}

fn write_cue<'a>(first: &str, block: &mut impl Iterator<Item = &'a str>, output: &mut String) {
    if matches!(first, "STYLE" | "REGION") || first.split_ascii_whitespace().next() == Some("NOTE")
    {
        return;
    }
    let timing = if first.contains("-->") {
        first
    } else if let Some(line) = block.next() {
        line
    } else {
        return;
    };
    let Some((start, rest)) = timing.split_once("-->") else {
        return;
    };
    let Some(start) = timestamp(start.trim()) else {
        return;
    };
    let Some(end) = rest.split_ascii_whitespace().next().and_then(timestamp) else {
        return;
    };
    if end <= start {
        return;
    }
    let mut payload = String::new();
    for line in block {
        let plain = cue_text(line);
        let plain = plain.trim();
        if !plain.is_empty() {
            if !payload.is_empty() {
                payload.push_str("<br/>");
            }
            payload.push_str(&quick_xml::escape::partial_escape(plain));
        }
    }
    if !payload.is_empty() {
        let _ = write!(
            output,
            "<p begin=\"{start}ms\" end=\"{end}ms\">{payload}</p>"
        );
    }
}

fn timestamp(value: &str) -> Option<u64> {
    let (clock, millis) = value.split_once('.')?;
    let mut parts = clock.rsplit(':');
    let seconds = parts.next()?;
    let minutes = parts.next()?;
    let hours = parts.next().unwrap_or("00");
    if parts.next().is_some()
        || hours.len() < 2
        || minutes.len() != 2
        || seconds.len() != 2
        || millis.len() != 3
        || ![hours, minutes, seconds, millis]
            .iter()
            .all(|part| part.bytes().all(|byte| byte.is_ascii_digit()))
    {
        return None;
    }
    let minutes: u64 = minutes.parse().ok()?;
    let seconds: u64 = seconds.parse().ok()?;
    if minutes >= 60 || seconds >= 60 {
        return None;
    }
    hours
        .parse::<u64>()
        .ok()?
        .checked_mul(3_600_000)?
        .checked_add(minutes * 60_000 + seconds * 1000 + millis.parse::<u64>().ok()?)
}

fn cue_text(mut line: &str) -> String {
    let mut plain = String::new();
    while let Some(ch) = line.chars().next() {
        line = &line[ch.len_utf8()..];
        if ch == '<' {
            if let Some(end) = line.find(['<', '>']) {
                let tag = &line[..end];
                let name = tag.trim_start_matches('/').split(['.', ' ', '\t']).next();
                if line.as_bytes()[end] == b'>'
                    && (matches!(
                        name,
                        Some("c" | "i" | "b" | "u" | "v" | "lang" | "ruby" | "rt")
                    ) || timestamp(tag).is_some())
                {
                    line = &line[end + 1..];
                    continue;
                }
            }
        } else if ch == '&' {
            if let Some((entity, decoded)) = [
                ("amp;", '&'),
                ("lt;", '<'),
                ("gt;", '>'),
                ("nbsp;", '\u{a0}'),
                ("lrm;", '\u{200e}'),
                ("rlm;", '\u{200f}'),
            ]
            .into_iter()
            .find(|(entity, _)| line.starts_with(entity))
            {
                plain.push(decoded);
                line = &line[entity.len()..];
                continue;
            }
        }
        if matches!(ch, '\t' | '\u{20}'..='\u{d7ff}' | '\u{e000}'..='\u{fffd}' | '\u{10000}'..='\u{10ffff}')
        {
            plain.push(ch);
        }
    }
    plain
}
