//! AMLL TTML DB native API: https://amll.dev/reference/http-api/native.html
use super::*;
use std::collections::HashSet;

/// Public AMLL TTML database provider.
pub struct AmllLyrics {
    base_url: String,
    client: reqwest::Client,
    limiter: RateLimiter,
    backoff: Backoff,
    cache: TtlCache<Vec<Candidate<LyricsPayload>>>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Song {
    id: u64,
    #[serde(default)]
    music_names: Vec<String>,
    #[serde(default)]
    artist_names: Vec<String>,
    #[serde(default)]
    album_names: Vec<String>,
    lyrics: Option<String>,
}
#[derive(Deserialize)]
struct Envelope<T> {
    status: u16,
    data: T,
}
#[derive(Deserialize)]
struct Search {
    items: Vec<Song>,
}
impl AmllLyrics {
    /// Connect to the official service.
    pub fn new() -> Result<Self> {
        Self::with_base_url("https://api.amll.dev")
    }
    /// Override the endpoint for testing or independently hosted instances.
    pub fn with_base_url(base_url: &str) -> Result<Self> {
        let base_url = base_url.trim().trim_end_matches('/');
        if base_url.is_empty() {
            return Err(LekisError::invalid("AMLL 地址为空"));
        }
        Ok(Self {
            base_url: base_url.into(),
            client: http::client()?,
            limiter: RateLimiter::new(Duration::from_secs(1)),
            backoff: Backoff::new(Duration::from_secs(1), Duration::from_secs(60)),
            cache: TtlCache::new(),
        })
    }
    fn identity(hint: &TrackHint, song: &Song) -> Option<(TrackHint, f32)> {
        if song.artist_names.iter().all(|a| a.trim().is_empty()) {
            return None;
        }
        song.music_names
            .iter()
            .filter_map(|title| {
                let matched = TrackHint {
                    title: title.clone(),
                    artists: song.artist_names.clone(),
                    album: song.album_names.first().cloned(),
                    ..Default::default()
                };
                lyrics_matching::confidence(hint, &matched).map(|score| (matched, score))
            })
            .max_by(|a, b| a.1.total_cmp(&b.1))
    }
    async fn query(&self, hint: &TrackHint) -> Result<Vec<Candidate<LyricsPayload>>> {
        let mut seen = HashSet::new();
        let mut candidates = Vec::new();
        let mut fetched = 0;
        for (title, artist) in lyrics_matching::search_variants(hint).into_iter().take(4) {
            let mut url = http::join(&self.base_url, "/v1/lyrics/search")?;
            {
                let mut q = url.query_pairs_mut();
                q.append_pair("musicName", &title)
                    .append_pair("pageSize", "20");
                if let Some(artist) = artist {
                    q.append_pair("artistName", &artist);
                }
            }
            let Some(body) = fetch(
                &self.client,
                &self.limiter,
                &self.backoff,
                url,
                "AMLL search",
            )
            .await?
            else {
                continue;
            };
            let result: Envelope<Search> = serde_json::from_str(&body).map_err(decode)?;
            if result.status != 200 {
                return Err(LekisError::new(
                    ErrorCode::Decode,
                    "AMLL search response status",
                ));
            }
            for song in result.data.items.into_iter().take(20) {
                if !seen.insert(song.id) || Self::identity(hint, &song).is_none() {
                    continue;
                }
                if fetched >= 3 {
                    return Ok(candidates);
                }
                fetched += 1;
                let mut url = http::join(&self.base_url, "/v1/lyrics/get")?;
                url.query_pairs_mut()
                    .append_pair("id", &song.id.to_string());
                let Some(body) =
                    fetch(&self.client, &self.limiter, &self.backoff, url, "AMLL get").await?
                else {
                    continue;
                };
                let result: Envelope<Song> = serde_json::from_str(&body).map_err(decode)?;
                if result.status != 200 || result.data.id != song.id {
                    continue;
                }
                let Some((matched, score)) = Self::identity(hint, &result.data) else {
                    continue;
                };
                let Some(content) = result.data.lyrics else {
                    continue;
                };
                if content.len() > 1_000_000
                    || !content.contains("<tt")
                    || !content.contains("<p ")
                    || !content.contains("begin=")
                {
                    continue;
                }
                // No duration in this API: keep the candidate for review.
                candidates.push(Candidate {
                    payload: LyricsPayload {
                        format: LyricsFormat::Ttml,
                        content,
                    },
                    source: self.name().into(),
                    matched,
                    provider_confidence: score.min(crate::AUTO_APPLY_THRESHOLD - 0.01),
                });
            }
            if !candidates.is_empty() {
                break;
            }
        }
        lyrics_matching::sort(&mut candidates);
        Ok(candidates)
    }
}
#[async_trait]
impl LyricsProvider for AmllLyrics {
    fn name(&self) -> &str {
        "amll"
    }
    async fn find_lyrics(&self, hint: &TrackHint) -> Result<Vec<Candidate<LyricsPayload>>> {
        if hint.title.trim().is_empty() {
            return Ok(Vec::new());
        }
        let key = cache_key(&self.base_url, hint);
        if let Some(cached) = self.cache.get(&key) {
            return Ok(cached);
        }
        let result = tokio::time::timeout(Duration::from_secs(12), self.query(hint))
            .await
            .map_err(|_| LekisError::new(ErrorCode::Network, "AMLL 查询超时"))??;
        if !result.is_empty() {
            self.cache.insert(key, result.clone());
        }
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::panic)]
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    fn hint(title: &str, artist: &str) -> TrackHint {
        TrackHint {
            title: title.into(),
            artists: vec![artist.into()],
            duration_ms: 196_000,
            ..Default::default()
        }
    }
    fn song(title: &str, artist: &str) -> Song {
        Song {
            id: 7,
            music_names: vec![title.into()],
            artist_names: vec![artist.into()],
            album_names: vec![],
            lyrics: None,
        }
    }
    #[test]
    fn identity_rejects_wrong_artist_and_version() {
        let wanted = hint("勇者", "YOASOBI");
        assert!(AmllLyrics::identity(&wanted, &song("勇者", "YOASOBI")).is_some());
        assert!(AmllLyrics::identity(&wanted, &song("勇者 (Live)", "YOASOBI")).is_none());
        assert!(AmllLyrics::identity(&wanted, &song("勇者", "Other")).is_none());
        let upload = hint(
            "《葬送的芙莉莲》OP主题曲「勇者」YOASOBI【Hi-Res百万级录音棚试听】",
            "uploader",
        );
        assert!(
            AmllLyrics::identity(&upload, &song("勇者", "YOASOBI"))
                .unwrap()
                .1
                < crate::AUTO_APPLY_THRESHOLD
        );
    }
    #[tokio::test]
    async fn searches_then_fetches_ttml_for_review() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let thread = std::thread::spawn(move || {
            let responses = [
                serde_json::json!({"status":200,"data":{"items":[{"id":7,"musicNames":["勇者"],"artistNames":["YOASOBI"]}]}}).to_string(),
                serde_json::json!({"status":200,"data":{"id":7,"musicNames":["勇者"],"artistNames":["YOASOBI"],"lyrics":"<tt><body><p begin=\"00:01.00\">test</p></body></tt>"}}).to_string()
            ];
            for (index, body) in responses.iter().enumerate() {
                let (mut stream, _) = listener.accept().unwrap();
                let mut buf = [0; 4096];
                let n = stream.read(&mut buf).unwrap();
                let request = String::from_utf8_lossy(&buf[..n]);
                assert!(request.contains(if index == 0 {
                    "/v1/lyrics/search?"
                } else {
                    "/v1/lyrics/get?id=7"
                }));
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                )
                .unwrap();
            }
        });
        let result = AmllLyrics::with_base_url(&base)
            .unwrap()
            .find_lyrics(&hint("勇者", "YOASOBI"))
            .await
            .unwrap();
        thread.join().unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].payload.format, LyricsFormat::Ttml);
        assert!(result[0].provider_confidence < crate::AUTO_APPLY_THRESHOLD);
    }
}
