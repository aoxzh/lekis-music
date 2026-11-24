use crate::cache::{cache_key, TtlCache};
use crate::http;
use crate::providers::{has_lyric_timestamp, lyrics_matching};
use crate::throttle::RateLimiter;
use crate::{Candidate, LyricsPayload, LyricsProvider, TrackHint, AUTO_APPLY_THRESHOLD};
use async_trait::async_trait;
use lekis_types::{ErrorCode, LekisError, LyricsFormat, Result};
use serde::{de::DeserializeOwned, Deserialize};
use std::collections::HashSet;
use std::time::Duration;

const SEARCH: &str = "/soso/fcgi-bin/client_search_cp";
const LYRIC: &str = "/lyric/fcgi-bin/fcg_query_lyric_new.fcg";
const REVIEW: f32 = AUTO_APPLY_THRESHOLD - 0.01;
const MAX_BODY: usize = 1024 * 1024;

/// Anonymous QQ Music song search and LRC retrieval.
pub struct QqLyrics {
    base: String,
    client: reqwest::Client,
    limiter: RateLimiter,
    cache: TtlCache<Vec<Candidate<LyricsPayload>>>,
}

#[derive(Deserialize)]
struct Envelope<T> {
    code: i64,
    #[serde(flatten)]
    body: T,
}

#[derive(Deserialize)]
struct SearchResult {
    data: Option<SearchData>,
}

#[derive(Deserialize)]
struct SearchData {
    song: SongList,
}

#[derive(Deserialize)]
struct SongList {
    list: Vec<Song>,
}

#[derive(Deserialize)]
struct Song {
    #[serde(default)]
    songmid: String,
    #[serde(default)]
    songname: String,
    #[serde(default)]
    albumname: String,
    #[serde(default)]
    singer: Vec<Singer>,
    #[serde(default)]
    interval: u64,
}

#[derive(Deserialize)]
struct Singer {
    name: String,
}

#[derive(Deserialize)]
struct LyricResponse {
    lyric: Option<String>,
}

fn decode_lyrics(raw: &str) -> Option<LyricsPayload> {
    let mut text = String::with_capacity(raw.len());
    let mut rest = raw;
    while let Some((before, after)) = rest.split_once('&') {
        text.push_str(before);
        let end = after.bytes().take(12).position(|b| b == b';');
        let decoded = end.and_then(|end| match &after[..end] {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "apos" => Some('\''),
            "quot" => Some('"'),
            "nbsp" => Some(' '),
            entity => {
                let number = entity.strip_prefix('#')?;
                let value = match number.strip_prefix(['x', 'X']) {
                    Some(hex) => u32::from_str_radix(hex, 16).ok()?,
                    None => number.parse::<u32>().ok()?,
                };
                char::from_u32(value).filter(|c| !c.is_control() || c.is_whitespace())
            }
        });
        if let (Some(end), Some(ch)) = (end, decoded) {
            text.push(ch);
            rest = &after[end + 1..];
        } else {
            text.push('&');
            rest = after;
        }
    }
    text.push_str(rest);
    let content = text.trim();
    let has_words = content.lines().any(|line| {
        let mut body = line.trim();
        while let Some((tag, tail)) = body.strip_prefix('[').and_then(|s| s.split_once(']')) {
            if !tag.contains(':') {
                break;
            }
            body = tail.trim_start();
        }
        let compact: String = body
            .chars()
            .filter(|c| c.is_alphanumeric())
            .flat_map(char::to_lowercase)
            .collect();
        !matches!(
            compact.as_str(),
            "" | "纯音乐"
                | "纯音乐请欣赏"
                | "此歌曲为没有填词的纯音乐请您欣赏"
                | "此歌曲为没有填词的纯音乐请欣赏"
                | "此歌曲为没有填词的纯音乐"
                | "此歌曲为纯音乐请欣赏"
                | "此歌曲为纯音乐请您欣赏"
                | "暂无歌词"
                | "暂无该歌曲歌词"
                | "instrumental"
                | "nolyrics"
        )
    });
    has_words.then(|| LyricsPayload {
        format: if has_lyric_timestamp(content) {
            LyricsFormat::Lrc
        } else {
            LyricsFormat::Plain
        },
        content: content.into(),
    })
}

fn folded(value: &str) -> String {
    lyrics_matching::width_fold(value).to_lowercase()
}

fn singer_matches(name: &str, artist: &str) -> bool {
    let name = folded(name);
    let artist = folded(artist);
    if artist.is_empty() {
        return false;
    }
    if name == artist {
        return true;
    }
    let Some((primary, alias)) = name.strip_suffix(')').and_then(|s| s.rsplit_once(" (")) else {
        return false;
    };
    primary == artist && !alias.is_empty() && alias.chars().all(|ch| matches!(ch, 'ぁ'..='ヿ'))
}

fn caption_pair(title: &str) -> Option<(String, String)> {
    let title = lyrics_matching::width_fold(title);
    let (label, rest) = title.strip_prefix('【')?.split_once('】')?;
    let (song, artist) = match label {
        "官方MV" => {
            let (artist, song) = rest.trim().split_once(" - ")?;
            (song, artist)
        }
        _ => {
            let label = label.replace("𝐇𝐢-𝐑𝐞𝐬", "Hi-Res").to_lowercase();
            let quality = label.strip_prefix("hi-res")?.trim_start_matches('·');
            if !matches!(quality, "无损" | "无损音质") {
                return None;
            }
            let (song, tail) = rest
                .trim()
                .trim_start_matches('|')
                .trim()
                .strip_prefix('《')?
                .split_once('》')?;
            (
                song,
                tail.trim().strip_prefix('-')?.trim().strip_suffix('-')?,
            )
        }
    };
    let (song, artist) = (song.trim(), artist.trim());
    if [song, artist]
        .iter()
        .any(|s| s.is_empty() || s.contains(['《', '》', '【', '】', '|']))
    {
        return None;
    }
    Some((song.into(), artist.into()))
}

impl QqLyrics {
    /// Stable source identifier shared with core registration.
    pub const NAME: &'static str = "qqmusic";

    /// Connect to QQ Music's public endpoints.
    pub fn new() -> Result<Self> {
        Self::with_base_url("https://c.y.qq.com")
    }

    /// Override the origin for a compatible endpoint or offline fixture server.
    pub fn with_base_url(base: &str) -> Result<Self> {
        http::join(base, SEARCH)?;
        Ok(Self {
            base: base.trim_end_matches('/').into(),
            client: http::client()?,
            limiter: RateLimiter::new(Duration::from_secs(1)),
            cache: TtlCache::new(),
        })
    }

    async fn read<T: DeserializeOwned>(
        &self,
        url: reqwest::Url,
        action: &str,
    ) -> Result<Option<T>> {
        self.limiter.acquire().await;
        let mut response = self
            .client
            .get(url)
            .timeout(Duration::from_secs(5))
            .header(reqwest::header::REFERER, "https://y.qq.com/")
            .send()
            .await
            .map_err(http::network)?;
        let status = response.status();
        if status.as_u16() == 404 {
            return Ok(None);
        }
        if !status.is_success() {
            return Err(http::status(status.as_u16(), action));
        }
        let oversized = || {
            LekisError::new(
                ErrorCode::Decode,
                format!("{action}: response exceeds 1 MiB"),
            )
        };
        if response
            .content_length()
            .is_some_and(|len| len > MAX_BODY as u64)
        {
            return Err(oversized());
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(http::network)? {
            if chunk.len() > MAX_BODY - bytes.len() {
                return Err(oversized());
            }
            bytes.extend_from_slice(&chunk);
        }
        let envelope: Envelope<T> = serde_json::from_slice(&bytes).map_err(|_| {
            LekisError::new(
                ErrorCode::Decode,
                format!("{action}: invalid JSON response"),
            )
        })?;
        if envelope.code != 0 {
            return Err(LekisError::new(
                ErrorCode::Network,
                format!("{action}: QQ code {}", envelope.code),
            ));
        }
        Ok(Some(envelope.body))
    }
}

fn score(hint: &TrackHint, song: &Song, identities: &[(String, Option<String>)]) -> Option<f32> {
    let duration = song.interval.checked_mul(1000)?;
    let timed = duration > 0 && hint.duration_ms > 0;
    if timed && duration.abs_diff(hint.duration_ms) > 5000
        || lyrics_matching::versions(&hint.title) != lyrics_matching::versions(&song.songname)
    {
        return None;
    }
    let title = folded(&song.songname);
    if title == folded(&hint.title)
        && hint
            .artists
            .iter()
            .any(|artist| song.singer.iter().any(|s| singer_matches(&s.name, artist)))
    {
        return Some(if timed { 0.9 } else { REVIEW });
    }
    if timed
        && identities.iter().any(|(query, artist)| {
            folded(query) == title
                && artist.as_ref().is_some_and(|artist| {
                    song.singer.iter().any(|s| singer_matches(&s.name, artist))
                })
        })
    {
        return Some(REVIEW);
    }
    None
}

#[async_trait]
impl LyricsProvider for QqLyrics {
    fn name(&self) -> &str {
        Self::NAME
    }

    async fn find_lyrics(&self, hint: &TrackHint) -> Result<Vec<Candidate<LyricsPayload>>> {
        self.lookup(hint, false).await
    }

    async fn search_lyrics(&self, hint: &TrackHint) -> Result<Vec<Candidate<LyricsPayload>>> {
        self.lookup(hint, true).await
    }
}

fn review_match(hint: &TrackHint, song: &Song) -> bool {
    let title = folded(&song.songname);
    let query = folded(&hint.title);
    let matches_title = title == query
        || title.strip_prefix(&query).is_some_and(|suffix| {
            matches!(
                suffix.trim(),
                "(live)" | "(remix)" | "(acoustic)" | "(现场版)" | "- live" | "- remix"
            )
        });
    matches_title
        && (hint.artists.is_empty()
            || hint.artists.iter().any(|artist| {
                song.singer
                    .iter()
                    .any(|singer| singer_matches(&singer.name, artist))
            }))
}

impl QqLyrics {
    async fn lookup(
        &self,
        hint: &TrackHint,
        manual: bool,
    ) -> Result<Vec<Candidate<LyricsPayload>>> {
        if hint.title.trim().is_empty() {
            return Ok(Vec::new());
        }
        let key = format!("{manual}:{}", cache_key(&self.base, hint));
        if let Some(cached) = self.cache.get(&key) {
            return Ok(cached);
        }
        let mut queries = lyrics_matching::search_variants(hint);
        if let Some((song, artist)) = caption_pair(&hint.title) {
            queries.insert(1, (song, Some(artist)));
        }
        let mut searched = HashSet::new();
        let mut downloaded = HashSet::new();
        let mut candidates = Vec::new();
        for (title, artist) in &queries {
            if searched.len() == 3 || downloaded.len() == 2 {
                break;
            }
            let query = artist
                .as_ref()
                .map_or_else(|| title.clone(), |artist| format!("{title} {artist}"));
            if !searched.insert(query.to_lowercase()) {
                continue;
            }
            let mut url = http::join(&self.base, SEARCH)?;
            url.query_pairs_mut().extend_pairs([
                ("w", query.as_str()),
                ("format", "json"),
                ("n", "10"),
                ("p", "1"),
                ("aggr", "1"),
            ]);
            let Some(search) = self.read::<SearchResult>(url, "QQ search").await? else {
                continue;
            };
            let data = search
                .data
                .ok_or_else(|| LekisError::new(ErrorCode::Decode, "QQ search: missing data"))?;
            let mut matches: Vec<_> = data
                .song
                .list
                .into_iter()
                .take(10)
                .filter(|s| !s.songmid.trim().is_empty())
                .filter_map(|song| {
                    score(hint, &song, &queries)
                        .or_else(|| (manual && review_match(hint, &song)).then_some(REVIEW))
                        .map(|score| (score, song))
                })
                .collect();
            matches.sort_by(|a, b| b.0.total_cmp(&a.0));
            for (confidence, song) in matches {
                if downloaded.len() == 2 {
                    break;
                }
                if !downloaded.insert(song.songmid.clone()) {
                    continue;
                }
                let mut url = http::join(&self.base, LYRIC)?;
                url.query_pairs_mut().extend_pairs([
                    ("songmid", song.songmid.as_str()),
                    ("format", "json"),
                    ("nobase64", "1"),
                ]);
                let result = match self.read::<LyricResponse>(url, "QQ lyric").await {
                    Ok(Some(result)) => result,
                    Ok(None) => continue,
                    Err(_) if !candidates.is_empty() => break,
                    Err(error) => return Err(error),
                };
                let Some(payload) = result.lyric.as_deref().and_then(decode_lyrics) else {
                    continue;
                };
                candidates.push(Candidate {
                    payload,
                    source: self.name().into(),
                    matched: TrackHint {
                        title: song.songname,
                        artists: song.singer.into_iter().map(|s| s.name).collect(),
                        duration_ms: song.interval.checked_mul(1000).unwrap_or_default(),
                        album: Some(song.albumname).filter(|name| !name.trim().is_empty()),
                        ..Default::default()
                    },
                    provider_confidence: confidence,
                });
                if !manual {
                    break;
                }
            }
            if !candidates.is_empty() {
                self.cache.insert(key, candidates.clone());
                return Ok(candidates);
            }
        }
        Ok(Vec::new())
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::panic)]
mod tests {
    use super::*;
    use serde_json::json;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::net::TcpListener;

    #[test]
    fn reads_encoded_lrc_plain_text_and_skips_empty_tracks() {
        let parsed =
            decode_lyrics("&#91;00&#58;01.00&#93;One &amp; two&#13;&#10;[00:02]&#x661F;").unwrap();
        assert_eq!(parsed.format, LyricsFormat::Lrc);
        assert_eq!(parsed.content, "[00:01.00]One & two\r\n[00:02]星");
        let plain = decode_lyrics("A &amp; B &unknown;").unwrap();
        assert_eq!(plain.format, LyricsFormat::Plain);
        assert_eq!(plain.content, "A & B &unknown;");
        for raw in [
            "[ar:Artist]\n[ti:Track]\n[00:00.00]",
            "[00:00]此歌曲为没有填词的纯音乐，请您欣赏",
            "&#91;00:00&#93;纯音乐，请欣赏",
            "[Instrumental]",
            "暂无歌词",
        ] {
            assert!(decode_lyrics(raw).is_none());
        }
        assert!(decode_lyrics("[00:00][Instrumental]\n[00:10]First verse").is_some());
    }

    #[tokio::test]
    async fn rejects_oversized_length_and_chunked_responses_before_json() {
        for chunked in [false, true] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let provider =
                QqLyrics::with_base_url(&format!("http://{}", listener.local_addr().unwrap()))
                    .unwrap();
            let task = tokio::spawn(async move {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut request = String::new();
                let mut reader = BufReader::new(&mut stream);
                while !request.ends_with("\r\n\r\n") {
                    assert!(reader.read_line(&mut request).await.unwrap() > 0);
                }
                if chunked {
                    stream
                        .write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
                        .await
                        .unwrap();
                    let chunk = vec![b' '; MAX_BODY / 2];
                    for _ in 0..2 {
                        stream
                            .write_all(format!("{:x}\r\n", chunk.len()).as_bytes())
                            .await
                            .unwrap();
                        stream.write_all(&chunk).await.unwrap();
                        stream.write_all(b"\r\n").await.unwrap();
                    }
                    stream.write_all(b"1\r\nx\r\n0\r\n\r\n").await.unwrap();
                } else {
                    stream
                        .write_all(
                            format!(
                                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n",
                                MAX_BODY + 1
                            )
                            .as_bytes(),
                        )
                        .await
                        .unwrap();
                }
            });
            let error = provider
                .find_lyrics(&hint("Title", "Artist", 180000))
                .await
                .unwrap_err();
            assert_eq!(error.code, ErrorCode::Decode);
            assert!(error.to_string().contains("exceeds"));
            task.await.unwrap();
        }
    }

    fn hint(title: &str, artist: &str, duration: u64) -> TrackHint {
        TrackHint {
            title: title.into(),
            artists: vec![artist.into()],
            duration_ms: duration,
            ..Default::default()
        }
    }

    fn row(title: &str, artist: &str, seconds: u64) -> Song {
        Song {
            songname: title.into(),
            songmid: "id".into(),
            albumname: String::new(),
            singer: vec![Singer {
                name: artist.into(),
            }],
            interval: seconds,
        }
    }

    #[test]
    fn identity_requires_the_recording_and_a_real_artist() {
        let wanted = hint(
            "《动画》OP主题曲「勇者」YOASOBI【Hi-Res百万级录音棚试听】",
            "uploader",
            196000,
        );
        let queries = lyrics_matching::search_variants(&wanted);
        for wrong in [
            row("勇者 (Live)", "YOASOBI", 196),
            row("勇者 (Remix)", "YOASOBI", 196),
            row("勇者!", "YOASOBI", 196),
            row("勇者", "YOASOBI (feat. Guest)", 196),
            row("勇者", "YOASOBI Cover Band", 196),
            row("勇者", "YOASOBI", 190),
            row("勇者", "YOASOBI", 0),
        ] {
            assert_eq!(score(&wanted, &wrong, &queries), None);
        }
        assert_eq!(
            score(&wanted, &row("勇者", "YOASOBI (ヨアソビ)", 191), &queries),
            Some(REVIEW)
        );
        let direct = hint("勇者", "YOASOBI", 196000);
        assert!(score(&direct, &row("勇者", "YOASOBI", 196), &[]).unwrap() >= AUTO_APPLY_THRESHOLD);
        assert_eq!(
            score(&direct, &row("勇者", "YOASOBI", 0), &[]),
            Some(REVIEW)
        );
        let (title, artist) =
            caption_pair("【𝐇𝐢-𝐑𝐞𝐬无损音质】｜《The Spectre(渐入佳境)》- RZZRKT -").unwrap();
        assert_eq!(
            (title.as_str(), artist.as_str()),
            ("The Spectre(渐入佳境)", "RZZRKT")
        );
        let mv = hint("【官方MV】ZAYN - Let Me", "Uploader", 250000);
        assert_eq!(
            score(
                &mv,
                &row("Let Me", "ZAYN", 185),
                &[("Let Me".into(), Some("ZAYN".into()))]
            ),
            None
        );
    }

    async fn fixture(
        responses: Vec<(u16, serde_json::Value)>,
    ) -> (QqLyrics, tokio::task::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut provider =
            QqLyrics::with_base_url(&format!("http://{}", listener.local_addr().unwrap())).unwrap();
        provider.limiter = RateLimiter::new(Duration::ZERO);
        let task = tokio::spawn(async move {
            let mut requests = Vec::new();
            for (status, body) in responses {
                let (mut stream, _) =
                    tokio::time::timeout(Duration::from_secs(3), listener.accept())
                        .await
                        .unwrap()
                        .unwrap();
                let mut reader = BufReader::new(&mut stream);
                let mut request = String::new();
                while !request.ends_with("\r\n\r\n") {
                    assert!(reader.read_line(&mut request).await.unwrap() > 0);
                }
                requests.push(request);
                let body = body.to_string();
                stream.write_all(format!("HTTP/1.1 {status} Test\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
            }
            requests
        });
        (provider, task)
    }

    #[tokio::test]
    async fn original_first_then_mv_fallback_with_referer_and_cached_output() {
        let songs = json!({"code":0,"data":{"song":{"list":[
            {"songmid":"other","songname":"Let Me (Live)","singer":[{"name":"ZAYN"}],"interval":185},
            {"songmid":"right","songname":"Let Me","singer":[{"name":"ZAYN"}],"interval":185}
        ]}}});
        let (provider, requests) = fixture(vec![
            (200, json!({"code":0,"data":{"song":{"list":[]}}})),
            (200, songs),
            (200, json!({"code":0,"lyric":"[00:01.00]fixture"})),
        ])
        .await;
        let wanted = hint("【官方MV】ZAYN - Let Me", "Uploader", 185000);
        let found = provider.find_lyrics(&wanted).await.unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].source, QqLyrics::NAME);
        assert_eq!(QqLyrics::NAME, "qqmusic");
        assert_eq!(found[0].provider_confidence, REVIEW);
        assert_eq!(found[0].payload.format, LyricsFormat::Lrc);
        assert_eq!(found[0].matched.title, "Let Me");
        assert_eq!(provider.find_lyrics(&wanted).await.unwrap(), found);
        let captured = requests.await.unwrap();
        assert!(captured[0].contains(SEARCH) && captured[0].contains("Uploader"));
        assert!(captured[1].contains("w=Let+Me+ZAYN"));
        assert!(captured[2].contains(LYRIC) && captured[2].contains("songmid=right"));
        assert!(captured[2].contains("nobase64=1"));
        assert!(captured[2]
            .to_lowercase()
            .contains("referer: https://y.qq.com/"));
    }

    #[tokio::test]
    async fn manual_search_returns_distinct_recordings_and_keeps_automatic_cache_separate() {
        let songs = json!({"code":0,"data":{"song":{"list":[
            {"songmid":"wrong","songname":"Echo (Live)","singer":[{"name":"Other"}],"interval":185},
            {"songmid":"live","songname":"Echo (Live)","albumname":"Concert","singer":[{"name":"Band"}],"interval":215},
            {"songmid":"studio","songname":"Echo","singer":[{"name":"Band"}],"interval":185}
        ]}}});
        let lyric = json!({"code":0,"lyric":"[00:01.00]fixture"});
        let (provider, requests) = fixture(vec![
            (200, songs.clone()),
            (200, lyric.clone()),
            (200, lyric.clone()),
            (200, songs),
            (200, lyric),
        ])
        .await;
        let wanted = hint("Echo", "Band", 185000);
        let choices = provider.search_lyrics(&wanted).await.unwrap();
        assert_eq!(choices.len(), 2);
        assert_eq!(choices[1].matched.title, "Echo (Live)");
        assert_eq!(choices[1].matched.album.as_deref(), Some("Concert"));
        assert_eq!(choices[1].matched.duration_ms, 215000);
        assert_eq!(provider.search_lyrics(&wanted).await.unwrap(), choices);
        let automatic = provider.find_lyrics(&wanted).await.unwrap();
        assert_eq!(automatic.len(), 1);
        assert_eq!(automatic[0].matched.title, "Echo");
        assert!(!requests
            .await
            .unwrap()
            .iter()
            .any(|r| r.contains("songmid=wrong")));
    }

    #[tokio::test]
    async fn throttled_search_stops_without_downloading() {
        let (provider, requests) = fixture(vec![(429, json!({}))]).await;
        let error = provider
            .find_lyrics(&hint("Song", "Band", 120000))
            .await
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::RateLimited);
        assert_eq!(requests.await.unwrap().len(), 1);
    }
}
