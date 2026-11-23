//! Apple Music official catalogue album search.
use crate::http;
use lekis_types::{LekisError, Result};
use serde::Deserialize;

/// Temporary Apple Music album metadata and artwork link.
#[derive(Debug, Clone, PartialEq)]
pub struct AppleAlbum {
    /// Apple Music catalogue identifier.
    pub id: String,
    /// Localized album title.
    pub title: String,
    /// Album artist.
    pub artist: String,
    /// Release date when available.
    pub release_date: Option<String>,
    /// Original image URL at requested display size.
    pub image_url: Option<String>,
    /// Apple Music album link.
    pub external_url: String,
}
#[derive(Deserialize)]
struct Search {
    results: Results,
}
#[derive(Deserialize)]
struct Results {
    #[serde(default)]
    albums: Option<Page>,
}
#[derive(Deserialize)]
struct Page {
    data: Vec<Album>,
}
#[derive(Deserialize)]
struct Album {
    id: String,
    attributes: Attributes,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Attributes {
    name: String,
    artist_name: String,
    release_date: Option<String>,
    artwork: Option<Artwork>,
    url: String,
}
#[derive(Deserialize)]
struct Artwork {
    url: String,
}

/// Apple Music API catalogue client.
pub struct AppleMusicCatalog {
    client: reqwest::Client,
    base_url: String,
}
impl AppleMusicCatalog {
    /// Use Apple's official endpoint.
    pub fn new() -> Result<Self> {
        Self::with_base_url("https://api.music.apple.com")
    }
    /// Override the endpoint for tests.
    pub fn with_base_url(base_url: &str) -> Result<Self> {
        let url = reqwest::Url::parse(base_url)
            .map_err(|_| LekisError::invalid("invalid Apple Music endpoint"))?;
        if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
            return Err(LekisError::invalid("invalid Apple Music endpoint"));
        }
        let client = reqwest::Client::builder()
            .user_agent(http::USER_AGENT)
            .timeout(http::TIMEOUT)
            .connect_timeout(http::CONNECT_TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(http::network)?;
        Ok(Self {
            client,
            base_url: base_url.trim_end_matches('/').into(),
        })
    }
    /// Search the public catalogue using a caller-provided developer token.
    pub async fn search_albums(
        &self,
        token: &str,
        album: &str,
        artist: &str,
        storefront: &str,
    ) -> Result<Vec<AppleAlbum>> {
        if token.trim().is_empty()
            || album.trim().is_empty()
            || artist.trim().is_empty()
            || storefront.len() != 2
            || !storefront.bytes().all(|b| b.is_ascii_alphabetic())
        {
            return Err(LekisError::invalid(
                "Apple developer token, album, artist and storefront are required",
            ));
        }
        let mut url = http::join(
            &self.base_url,
            &format!("/v1/catalog/{}/search", storefront.to_ascii_lowercase()),
        )?;
        url.query_pairs_mut()
            .append_pair("term", &format!("{} {}", album.trim(), artist.trim()))
            .append_pair("types", "albums")
            .append_pair("limit", "10");
        let response = self
            .client
            .get(url)
            .bearer_auth(token)
            .send()
            .await
            .map_err(http::network)?;
        if !response.status().is_success() {
            return Err(http::status(
                response.status().as_u16(),
                "Apple Music search",
            ));
        }
        let response: Search = response.json().await.map_err(http::network)?;
        Ok(response
            .results
            .albums
            .map(|p| p.data)
            .unwrap_or_default()
            .into_iter()
            .take(10)
            .filter_map(|a| {
                let link = reqwest::Url::parse(&a.attributes.url).ok()?;
                if link.scheme() != "https" || link.host_str() != Some("music.apple.com") {
                    return None;
                }
                let image_url = a
                    .attributes
                    .artwork
                    .map(|x| x.url.replace("{w}", "300").replace("{h}", "300"))
                    .filter(|u| {
                        reqwest::Url::parse(u).is_ok_and(|url| {
                            url.scheme() == "https"
                                && url.host_str().is_some_and(|h| h.ends_with(".mzstatic.com"))
                        })
                    });
                Some(AppleAlbum {
                    id: a.id,
                    title: a.attributes.name,
                    artist: a.attributes.artist_name,
                    release_date: a.attributes.release_date,
                    image_url,
                    external_url: link.into(),
                })
            })
            .collect())
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::panic)]
    use super::*;
    use std::io::{Read, Write};
    #[tokio::test]
    async fn searches_catalogue_with_developer_token_and_storefront() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let worker = std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let mut b = [0; 4096];
            let n = s.read(&mut b).unwrap();
            let req = String::from_utf8_lossy(&b[..n]).to_lowercase();
            assert!(req.contains("/v1/catalog/sg/search?"));
            assert!(req.contains("types=albums"));
            assert!(req.contains("authorization: bearer test-token"));
            let body = r#"{"results":{"albums":{"data":[{"id":"1","attributes":{"name":"Album","artistName":"Artist","releaseDate":"2025","url":"https://music.apple.com/sg/album/test/1","artwork":{"url":"https://is1-ssl.mzstatic.com/image/{w}x{h}.jpg"}}}]}}}"#;
            write!(
                s,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            )
            .unwrap();
        });
        let rows = AppleMusicCatalog::with_base_url(&base)
            .unwrap()
            .search_albums("test-token", "Album", "Artist", "SG")
            .await
            .unwrap();
        worker.join().unwrap();
        assert_eq!(rows[0].artist, "Artist");
        assert!(rows[0].image_url.as_ref().unwrap().contains("300x300"));
    }
}
