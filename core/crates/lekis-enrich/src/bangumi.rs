//! Bangumi music subjects are a review-only fallback for ACG album artwork.
//! The public search response has no reliable performer credit, so a matching
//! album title must never be treated as enough evidence for automatic adoption.
use crate::{
    cache::{cache_key, TtlCache},
    http,
    throttle::RateLimiter,
    ArtworkPayload, ArtworkProvider, Candidate, TrackHint,
};
use async_trait::async_trait;
use lekis_types::{LekisError, Result};
use serde::Deserialize;
use std::time::Duration;

/// Music-only ACG album fallback; every result requires user confirmation.
pub struct BangumiArtwork {
    base_url: String,
    client: reqwest::Client,
    limiter: RateLimiter,
    cache: TtlCache<Vec<Candidate<ArtworkPayload>>>,
}

impl BangumiArtwork {
    /// Use the official public Bangumi API.
    pub fn new() -> Result<Self> {
        Self::with_base_url("https://api.bgm.tv")
    }
    /// Override the endpoint for protocol tests or a compatible proxy.
    pub fn with_base_url(base: &str) -> Result<Self> {
        let base_url =
            reqwest::Url::parse(base).map_err(|_| LekisError::invalid("Bangumi API 地址无效"))?;
        Ok(Self {
            base_url: base_url.as_str().trim_end_matches('/').to_owned(),
            client: http::client()?,
            limiter: RateLimiter::new(Duration::from_secs(1)),
            cache: TtlCache::new(),
        })
    }
}

#[async_trait]
impl ArtworkProvider for BangumiArtwork {
    fn name(&self) -> &str {
        "bangumi"
    }
    async fn find_artwork(&self, hint: &TrackHint) -> Result<Vec<Candidate<ArtworkPayload>>> {
        // Search music releases, not anime posters or a video's descriptive title.
        let Some(album) = hint
            .album
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        else {
            return Ok(Vec::new());
        };
        let key = cache_key(&self.base_url, hint);
        if let Some(cached) = self.cache.get(&key) {
            return Ok(cached);
        }
        self.limiter.acquire().await;
        let url = http::join(&self.base_url, "/v0/search/subjects?limit=5")?;
        let response = self
            .client
            .post(url)
            .json(&serde_json::json!({"keyword":album,"filter":{"type":[3],"nsfw":false}}))
            .send()
            .await
            .map_err(http::network)?;
        if response.status().as_u16() == 404 {
            return Ok(Vec::new());
        }
        if !response.status().is_success() {
            return Err(http::status(
                response.status().as_u16(),
                "Bangumi music search",
            ));
        }
        let body = response.text().await.map_err(http::network)?;
        let candidates = parse(hint, &body)?;
        self.cache.insert(key, candidates.clone());
        Ok(candidates)
    }
}

fn parse(hint: &TrackHint, body: &str) -> Result<Vec<Candidate<ArtworkPayload>>> {
    #[derive(Deserialize)]
    struct Response {
        #[serde(default)]
        data: Vec<Subject>,
    }
    #[derive(Deserialize)]
    struct Subject {
        #[serde(rename = "type")]
        kind: u8,
        name: String,
        #[serde(default)]
        name_cn: String,
        #[serde(default)]
        nsfw: bool,
        #[serde(default)]
        images: std::collections::BTreeMap<String, String>,
    }
    let response: Response =
        serde_json::from_str(body).map_err(|_| LekisError::invalid("Bangumi 封面响应无效"))?;
    let target = hint.album.as_deref().unwrap_or("");
    let mut out = Vec::new();
    for item in response.data.into_iter().take(5) {
        if item.kind != 3 || item.nsfw {
            continue;
        }
        let similarity =
            crate::similarity(target, &item.name).max(crate::similarity(target, &item.name_cn));
        if similarity < 0.8 {
            continue;
        }
        let Some(url) = ["large", "medium", "common"]
            .iter()
            .filter_map(|key| item.images.get(*key))
            .find(|raw| {
                reqwest::Url::parse(raw).is_ok_and(|u| {
                    u.scheme() == "https"
                        && u.host_str() == Some("lain.bgm.tv")
                        && u.username().is_empty()
                        && u.password().is_none()
                })
            })
        else {
            continue;
        };
        out.push(Candidate {
            payload: ArtworkPayload {
                url: url.clone(),
                width: None,
                height: None,
            },
            source: "bangumi".into(),
            matched: TrackHint {
                title: hint.title.clone(),
                album: Some(item.name),
                ..Default::default()
            },
            provider_confidence: (similarity * 0.79).min(0.79),
        });
    }
    out.sort_by(|a, b| b.provider_confidence.total_cmp(&a.provider_confidence));
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn music_album_is_review_only_and_unrelated_posters_are_rejected() -> Result<()> {
        let hint = TrackHint {
            title: "勇者".into(),
            album: Some("勇者".into()),
            artists: vec!["YOASOBI".into()],
            ..Default::default()
        };
        let body = r#"{"data":[{"type":3,"name":"勇者","images":{"large":"https://lain.bgm.tv/pic/cover/l/test.jpg"}},{"type":2,"name":"勇者","images":{"large":"https://lain.bgm.tv/poster.jpg"}},{"type":3,"name":"無関係","images":{"large":"https://lain.bgm.tv/other.jpg"}},{"type":3,"name":"勇者","images":{"large":"https://example.com/untrusted.jpg"}}]}"#;
        let result = parse(&hint, body)?;
        assert_eq!(result.len(), 1);
        assert_eq!(
            crate::decide(result[0].provider_confidence),
            crate::Decision::Review
        );
        assert!(result[0].matched.artists.is_empty());
        Ok(())
    }
}
