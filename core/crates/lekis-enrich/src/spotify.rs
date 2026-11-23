//! Spotify catalogue search. Callers must display Spotify attribution and a link
//! to each result; these transient results must not be persisted as local artwork.
use crate::http;
use lekis_types::{LekisError, Result};
use serde::Deserialize;

/// A transient Spotify album and its required attribution link.
#[derive(Debug, Clone, PartialEq)]
pub struct SpotifyAlbum {
    /// Spotify album ID.
    pub id: String,
    /// Album title.
    pub title: String,
    /// Album artists.
    pub artists: Vec<String>,
    /// ISO-formatted release date, with the precision supplied by Spotify.
    pub release_date: Option<String>,
    /// Original Spotify cover URL, if provided.
    pub image_url: Option<String>,
    /// Link to the album on Spotify; must accompany displayed content.
    pub spotify_url: String,
}

#[derive(Deserialize)]
struct SearchResponse {
    albums: AlbumPage,
}
#[derive(Deserialize)]
struct AlbumPage {
    items: Vec<Album>,
}
#[derive(Deserialize)]
struct Album {
    id: String,
    name: String,
    #[serde(default)]
    artists: Vec<Artist>,
    release_date: Option<String>,
    #[serde(default)]
    images: Vec<Image>,
    external_urls: ExternalUrls,
}
#[derive(Deserialize)]
struct Artist {
    name: String,
}
#[derive(Deserialize)]
struct Image {
    url: String,
}
#[derive(Deserialize)]
struct ExternalUrls {
    spotify: String,
}

/// Searches the Spotify Web API using a user-provided access token.
pub struct SpotifyCatalog {
    client: reqwest::Client,
    base_url: String,
}
impl SpotifyCatalog {
    /// Construct a client for the official endpoint.
    pub fn new() -> Result<Self> {
        Self::with_base_url("https://api.spotify.com")
    }
    /// Construct a client with an alternate endpoint, primarily for testing.
    pub fn with_base_url(base_url: &str) -> Result<Self> {
        let url = reqwest::Url::parse(base_url)
            .map_err(|_| LekisError::invalid("invalid Spotify endpoint"))?;
        if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
            return Err(LekisError::invalid("invalid Spotify endpoint"));
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
    /// Search at most ten albums. `token` must come from secure user configuration;
    /// it is sent only in the Authorization header and never stored or logged.
    pub async fn search_albums(
        &self,
        token: &str,
        album: &str,
        artist: &str,
        market: &str,
    ) -> Result<Vec<SpotifyAlbum>> {
        if token.trim().is_empty()
            || album.trim().is_empty()
            || artist.trim().is_empty()
            || market.len() != 2
            || !market.bytes().all(|c| c.is_ascii_alphabetic())
        {
            return Err(LekisError::invalid(
                "Spotify token, album, artist and two-letter market are required",
            ));
        }
        let mut url = http::join(&self.base_url, "/v1/search")?;
        let query = format!("album:{} artist:{}", album.trim(), artist.trim());
        url.query_pairs_mut()
            .append_pair("q", &query)
            .append_pair("type", "album")
            .append_pair("limit", "10")
            .append_pair("market", &market.to_ascii_uppercase());
        let response = self
            .client
            .get(url)
            .bearer_auth(token)
            .send()
            .await
            .map_err(http::network)?;
        if !response.status().is_success() {
            return Err(http::status(response.status().as_u16(), "Spotify search"));
        }
        let data: SearchResponse = response.json().await.map_err(http::network)?;
        Ok(data
            .albums
            .items
            .into_iter()
            .take(10)
            .filter_map(|a| {
                let link = reqwest::Url::parse(&a.external_urls.spotify).ok()?;
                if link.scheme() != "https" || link.host_str() != Some("open.spotify.com") {
                    return None;
                }
                let image_url = a.images.into_iter().map(|i| i.url).find(|u| {
                    reqwest::Url::parse(u)
                        .is_ok_and(|u| u.scheme() == "https" && u.host_str() == Some("i.scdn.co"))
                });
                Some(SpotifyAlbum {
                    id: a.id,
                    title: a.name,
                    artists: a.artists.into_iter().map(|x| x.name).collect(),
                    release_date: a.release_date,
                    image_url,
                    spotify_url: link.into(),
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
    use std::net::TcpListener;
    #[tokio::test]
    async fn authenticated_search_returns_attributed_album_without_persisting() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let task = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            let mut bytes = [0; 8192];
            let n = socket.read(&mut bytes).unwrap();
            let request = String::from_utf8_lossy(&bytes[..n]).to_lowercase();
            assert!(request.contains("/v1/search?q=album%3A".to_lowercase().as_str()));
            assert!(request.contains("type=album"));
            assert!(request.contains("market=sg"));
            assert!(request.contains("authorization: bearer test-token"));
            let body = r#"{"albums":{"items":[{"id":"abc","name":"Test album","artists":[{"name":"Test artist"}],"release_date":"2025","images":[{"url":"https://i.scdn.co/image/test"}],"external_urls":{"spotify":"https://open.spotify.com/album/abc"}}]}}"#;
            write!(
                socket,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            )
            .unwrap();
        });
        let albums = SpotifyCatalog::with_base_url(&base)
            .unwrap()
            .search_albums("test-token", "Test album", "Test artist", "sg")
            .await
            .unwrap();
        task.join().unwrap();
        assert_eq!(albums[0].spotify_url, "https://open.spotify.com/album/abc");
        assert_eq!(
            albums[0].image_url.as_deref(),
            Some("https://i.scdn.co/image/test")
        );
        assert_eq!(albums[0].artists, ["Test artist"]);
    }
}
