//! 艺人头像检索（免 Key）：网易云 `type=100` 艺人搜索 + Deezer `/search/artist`。
//!
//! 只认名字完全一致（由调用方的规范化函数判断）的艺人：先比正名，正名都对不上
//! 才看网易云别名（别名里常有山寨号"蹭"大牌，所以放在第二轮）。
//! 名字含 CJK 时先查网易云，否则先查 Deezer。

use crate::http;
use crate::throttle::RateLimiter;
use lekis_types::{ErrorCode, LekisError, Result};
use serde::Deserialize;
use std::time::Duration;

const NETEASE_HEADERS: &[(&str, &str)] = &[("Referer", "https://music.163.com/")];
/// 网易云"无头像"默认图的图片 ID。
const NETEASE_DEFAULT_AVATAR: &str = "5639395138885805";

/// 一条检索结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArtistImage {
    /// 图片地址（https）。
    pub url: String,
    /// 来源：`netease` / `deezer`。
    pub source: &'static str,
}

#[derive(Debug, Clone)]
struct Hit {
    name: String,
    aliases: Vec<String>,
    url: String,
}

/// 艺人头像检索器。内部有连接池和限速器，整个进程共用一个。
pub struct ArtistImages {
    client: reqwest::Client,
    deezer_base: String,
    netease_base: String,
    deezer_limiter: RateLimiter,
    netease_limiter: RateLimiter,
}

impl ArtistImages {
    /// 用官方地址创建。
    pub fn new() -> Result<Self> {
        Self::with_base_urls("https://api.deezer.com", "https://music.163.com")
    }

    /// 用自定义地址创建（测试 / 镜像）。
    pub fn with_base_urls(deezer: &str, netease: &str) -> Result<Self> {
        Ok(Self {
            client: http::client()?,
            deezer_base: deezer.trim_end_matches('/').to_string(),
            netease_base: netease.trim_end_matches('/').to_string(),
            deezer_limiter: RateLimiter::new(Duration::from_millis(500)),
            netease_limiter: RateLimiter::new(Duration::from_millis(800)),
        })
    }

    /// 找 `name` 的头像。`same(a, b)` 判断两个名字是否算同一个艺人（调用方传规范化比较）。
    ///
    /// 两个来源都没有可靠匹配时返回 `Ok(None)`；全部来源都请求失败才返回错误。
    pub async fn find(
        &self,
        name: &str,
        same: impl Fn(&str, &str) -> bool,
    ) -> Result<Option<ArtistImage>> {
        let name = name.trim();
        if name.is_empty() {
            return Ok(None);
        }
        let netease_first = name.chars().any(is_cjk);
        let order: [&'static str; 2] = if netease_first {
            ["netease", "deezer"]
        } else {
            ["deezer", "netease"]
        };
        let mut last_error = None;
        let mut any_ok = false;
        for source in order {
            let hits = match source {
                "netease" => self.netease(name).await,
                _ => self.deezer(name).await,
            };
            match hits {
                Ok(hits) => {
                    any_ok = true;
                    if let Some(url) = pick(name, &hits, &same) {
                        return Ok(Some(ArtistImage { url, source }));
                    }
                }
                Err(error) => {
                    tracing::debug!(target: "lekis_enrich::artist_image", source, code = %error.code.as_str(), "艺人头像来源不可用");
                    last_error = Some(error);
                }
            }
        }
        match (any_ok, last_error) {
            (false, Some(error)) => Err(error),
            _ => Ok(None),
        }
    }

    async fn deezer(&self, name: &str) -> Result<Vec<Hit>> {
        let mut url = http::join(&self.deezer_base, "/search/artist")?;
        url.query_pairs_mut()
            .append_pair("q", name)
            .append_pair("limit", "5");
        self.deezer_limiter.acquire().await;
        let Some(body) = http::get_text(&self.client, url, "Deezer /search/artist").await? else {
            return Ok(Vec::new());
        };
        parse_deezer(&body)
    }

    async fn netease(&self, name: &str) -> Result<Vec<Hit>> {
        let mut url = http::join(&self.netease_base, "/api/search/get")?;
        url.query_pairs_mut()
            .append_pair("s", name)
            .append_pair("type", "100")
            .append_pair("limit", "5");
        self.netease_limiter.acquire().await;
        let Some(body) = http::get_text_with_headers(
            &self.client,
            url,
            NETEASE_HEADERS,
            "NetEase /api/search/get (artist)",
        )
        .await?
        else {
            return Ok(Vec::new());
        };
        parse_netease(&body)
    }
}

/// 先按正名找，再按别名找；都不中返回 `None`。
fn pick(name: &str, hits: &[Hit], same: &impl Fn(&str, &str) -> bool) -> Option<String> {
    hits.iter()
        .find(|h| same(name, &h.name))
        .or_else(|| {
            hits.iter()
                .find(|h| h.aliases.iter().any(|a| same(name, a)))
        })
        .map(|h| h.url.clone())
}

fn is_cjk(c: char) -> bool {
    matches!(c as u32,
        0x3040..=0x30FF   // 平假名 / 片假名
        | 0x3400..=0x4DBF // CJK 扩展 A
        | 0x4E00..=0x9FFF // CJK 统一汉字
        | 0xAC00..=0xD7AF // 韩文音节
        | 0xF900..=0xFAFF)
}

fn decode(e: serde_json::Error) -> LekisError {
    LekisError::new(ErrorCode::Decode, format!("艺人检索响应解析失败：{e}"))
}

fn to_https(url: &str) -> String {
    match url.strip_prefix("http://") {
        Some(rest) => format!("https://{rest}"),
        None => url.to_string(),
    }
}

fn parse_deezer(body: &str) -> Result<Vec<Hit>> {
    #[derive(Deserialize)]
    struct Resp {
        #[serde(default)]
        data: Vec<Item>,
    }
    #[derive(Deserialize)]
    struct Item {
        #[serde(default)]
        name: String,
        #[serde(default)]
        picture_xl: Option<String>,
        #[serde(default)]
        picture_big: Option<String>,
    }
    let resp: Resp = serde_json::from_str(body).map_err(decode)?;
    Ok(resp
        .data
        .into_iter()
        .filter_map(|item| {
            let url = item
                .picture_xl
                .or(item.picture_big)
                .filter(|u| !u.is_empty())?;
            // 没有头像的艺人图片路径是 `/images/artist//...`（空哈希）。
            if url.contains("/artist//") {
                return None;
            }
            Some(Hit {
                name: item.name,
                aliases: Vec::new(),
                url: to_https(&url),
            })
        })
        .collect())
}

fn parse_netease(body: &str) -> Result<Vec<Hit>> {
    #[derive(Deserialize)]
    struct Resp {
        #[serde(default)]
        result: Option<Res>,
    }
    #[derive(Deserialize)]
    struct Res {
        #[serde(default)]
        artists: Vec<Item>,
    }
    #[derive(Deserialize)]
    struct Item {
        #[serde(default)]
        name: String,
        #[serde(default)]
        alias: Option<Vec<String>>,
        #[serde(default)]
        trans: Option<String>,
        #[serde(rename = "img1v1Url", default)]
        img1v1_url: Option<String>,
        #[serde(rename = "picUrl", default)]
        pic_url: Option<String>,
    }
    let resp: Resp = serde_json::from_str(body).map_err(decode)?;
    let Some(res) = resp.result else {
        return Ok(Vec::new());
    };
    let usable = |u: &String| !u.trim().is_empty() && !u.contains(NETEASE_DEFAULT_AVATAR);
    Ok(res
        .artists
        .into_iter()
        .filter_map(|item| {
            // 方形头像优先，没有再用横幅照。
            let url = item
                .img1v1_url
                .filter(usable)
                .or(item.pic_url.filter(usable))?;
            let mut aliases = item.alias.unwrap_or_default();
            aliases.extend(item.trans.filter(|t| !t.trim().is_empty()));
            Some(Hit {
                name: item.name,
                aliases,
                url: to_https(&url),
            })
        })
        .collect())
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    fn eq(a: &str, b: &str) -> bool {
        a.trim().to_lowercase() == b.trim().to_lowercase()
    }

    #[test]
    fn netease_prefers_real_name_over_squatter_alias() {
        let body = r#"{"result":{"artists":[
            {"name":"Jay","alias":["周杰伦"],"img1v1Url":"https://p1.music.126.net/a/1.jpg"},
            {"name":"周杰伦","alias":["Jay Chou"],"img1v1Url":"http://p1.music.126.net/b/2.jpg"}
        ]}}"#;
        let hits = parse_netease(body).unwrap();
        assert_eq!(
            pick("周杰伦", &hits, &eq).as_deref(),
            Some("https://p1.music.126.net/b/2.jpg")
        );
        assert_eq!(
            pick("jay chou", &hits, &eq).as_deref(),
            Some("https://p1.music.126.net/b/2.jpg")
        );
    }

    #[test]
    fn netease_skips_default_avatar() {
        let body = r#"{"result":{"artists":[
            {"name":"X","img1v1Url":"https://p1.music.126.net/6y-UleORITEDbvrOLV0Q8A==/5639395138885805.jpg","picUrl":null}
        ]}}"#;
        assert!(parse_netease(body).unwrap().is_empty());
    }

    #[test]
    fn deezer_skips_placeholder_and_requires_name_match() {
        let body = r#"{"data":[
            {"name":"Nobody","picture_xl":"https://cdn-images.dzcdn.net/images/artist//1000x1000-000000-80-0-0.jpg"},
            {"name":"Taylor Swift","picture_xl":"https://cdn-images.dzcdn.net/images/artist/cc24/1000x1000.jpg"}
        ]}"#;
        let hits = parse_deezer(body).unwrap();
        assert_eq!(hits.len(), 1);
        assert!(pick("taylor swift", &hits, &eq).is_some());
        assert!(pick("Olivia Rodrigo", &hits, &eq).is_none());
    }

    #[test]
    fn cjk_detection() {
        assert!("周杰伦".chars().any(is_cjk));
        assert!("ヨルシカ".chars().any(is_cjk));
        assert!(!"Taylor Swift".chars().any(is_cjk));
    }
}
