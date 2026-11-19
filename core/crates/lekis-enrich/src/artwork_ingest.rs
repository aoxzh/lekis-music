//! 封面的下载、解码、缩放、编码与主色提取（ENR-01、ENR-12）。
//!
//! 补全提供方只负责"告诉我们在哪能找到封面"（[`crate::ArtworkPayload::url`]），
//! 真正把图片拿回来、按档位缩放、算哈希、提主色是这一层的事：
//!
//! ```text
//! URL → 下载（限大小、限类型）→ 解码 → 缩放到目标边长 → 编码 WebP（无损）→ SHA-256 → 主色
//! ```
//!
//! 哈希用图片**原始字节**的 SHA-256，所以同一张封面从不同提供方拿到时能去重
//! （`artwork.hash` 上有唯一约束）。数据库只存元数据，字节按
//! `docs/ARCHITECTURE.md` 第 5 节放本机缓存目录，路径用
//! [`lekis_library::cache_relative_path`] 计算。
//!
//! 主色（ENR-12）用"按 5 bit 量化后统计出现次数"的简单做法：封面这种图通常只有几个
//! 主色调，量化后取前几名就足够让 UI 染色，不值得为它引入一整个 k-means 实现。

use crate::http;
use lekis_types::{ErrorCode, LekisError, Palette, Result};
use sha2::{Digest, Sha256};

/// 单张封面的下载上限（16 MiB）。超过这个大小的图基本不是专辑封面。
pub const MAX_IMAGE_BYTES: usize = 16 * 1024 * 1024;

/// 缩放用的滤波：Lanczos3 在缩小时不容易出摩尔纹，代价是慢一点，但补全是后台任务。
const FILTER: image::imageops::FilterType = image::imageops::FilterType::Lanczos3;

/// 处理好的封面：可以直接落盘 + 入库。
#[derive(Debug, Clone, PartialEq)]
pub struct ProcessedArtwork {
    /// 原始下载字节的 SHA-256（十六进制，小写）。
    pub hash: String,
    /// 输出图宽度。
    pub width: u32,
    /// 输出图高度。
    pub height: u32,
    /// 从图里提取的主色（ENR-12）。
    pub palette: Palette,
    /// 编码后的 WebP 字节。
    pub bytes: Vec<u8>,
}

/// 下载一张图，返回原始字节。
///
/// 只接受 `image/*` 类型（有些提供方在限流时返回 `text/html` 的错误页，直接拦掉比
/// 后面解码失败更容易定位）；`Content-Length` 超限时提前放弃。
pub async fn fetch_image(url: &str) -> Result<Vec<u8>> {
    let parsed = reqwest::Url::parse(url)
        .map_err(|e| LekisError::invalid(format!("封面地址无法解析：{e}")))?;
    let client = http::client()?;
    let response = client.get(parsed).send().await.map_err(http::network)?;
    let status = response.status();
    if !status.is_success() {
        return Err(http::status(status.as_u16(), "下载封面"));
    }
    if let Some(len) = response.content_length() {
        if len as usize > MAX_IMAGE_BYTES {
            return Err(LekisError::invalid(format!(
                "封面太大（{len} 字节），超过上限 {MAX_IMAGE_BYTES}"
            )));
        }
    }
    if let Some(kind) = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
    {
        if !kind.starts_with("image/") && !kind.starts_with("application/octet-stream") {
            return Err(LekisError::new(
                ErrorCode::Unsupported,
                format!("封面返回的不是图片：{kind}"),
            ));
        }
    }
    let bytes = response.bytes().await.map_err(http::network)?;
    if bytes.len() > MAX_IMAGE_BYTES {
        return Err(LekisError::invalid(format!(
            "封面太大（{} 字节），超过上限 {MAX_IMAGE_BYTES}",
            bytes.len()
        )));
    }
    if bytes.is_empty() {
        return Err(LekisError::new(ErrorCode::Decode, "封面响应为空"));
    }
    Ok(bytes.to_vec())
}

/// 计算原始图片字节的哈希（去重用）。
pub fn hash_bytes(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

/// 解码 → 等比缩放到目标边长 → 编码 WebP（无损）→ 提主色。
///
/// 目标边长是"长边不超过 `target_px`"：竖版、横版封面都按长边算，
/// 不会把一张 1400×1400 的方图拉成 1024×1024 以外的形状。
/// 原图小于目标边长时**不放大**（放大只会变糊，还会让缓存文件变大）。
pub fn process_image(bytes: &[u8], target_px: u32) -> Result<ProcessedArtwork> {
    if bytes.is_empty() {
        return Err(LekisError::invalid("封面字节为空"));
    }
    let target = target_px.clamp(96, 4096);
    let hash = hash_bytes(bytes);

    let image = image::load_from_memory(bytes)
        .map_err(|e| LekisError::new(ErrorCode::Decode, format!("解码封面失败：{e}")))?;
    let (src_w, src_h) = (image.width(), image.height());
    if src_w == 0 || src_h == 0 {
        return Err(LekisError::new(ErrorCode::Decode, "封面尺寸为 0"));
    }

    let longest = src_w.max(src_h);
    let scaled = if longest > target {
        // 长边压到 target，短边按比例（至少 1 像素）。
        let ratio = target as f64 / longest as f64;
        let w = ((src_w as f64 * ratio).round() as u32).max(1);
        let h = ((src_h as f64 * ratio).round() as u32).max(1);
        image.resize_exact(w, h, FILTER)
    } else {
        image
    };

    let (width, height) = (scaled.width(), scaled.height());
    let rgb = scaled.to_rgb8();
    let palette = palette_from_rgb(rgb.as_raw(), width, height);

    let mut out = Vec::with_capacity(64 * 1024);
    image::codecs::webp::WebPEncoder::new_lossless(&mut out)
        .encode(rgb.as_raw(), width, height, image::ExtendedColorType::Rgb8)
        .map_err(|e| LekisError::new(ErrorCode::Internal, format!("编码 WebP 失败：{e}")))?;

    Ok(ProcessedArtwork {
        hash,
        width,
        height,
        palette,
        bytes: out,
    })
}

/// 从 RGB8 像素里提取主色（ENR-12）。
pub fn palette_from_rgb(pixels: &[u8], width: u32, height: u32) -> Palette {
    // 大图先抽样：主色不需要逐像素精确，200×200 的采样点已经足够稳定。
    let total = (width as usize) * (height as usize);
    let stride = (total / 40_000).max(1);
    let mut buckets: std::collections::HashMap<u16, (u32, u64, u64, u64)> =
        std::collections::HashMap::with_capacity(512);
    let mut index = 0usize;
    while index + 2 < pixels.len() {
        let (r, g, b) = (
            pixels[index] as u64,
            pixels[index + 1] as u64,
            pixels[index + 2] as u64,
        );
        // 每通道保留高 5 bit：把 1677 万色压到 32768 个桶。
        let key = (((r >> 3) as u16) << 10) | (((g >> 3) as u16) << 5) | ((b >> 3) as u16);
        let entry = buckets.entry(key).or_insert((0, 0, 0, 0));
        entry.0 += 1;
        entry.1 += r;
        entry.2 += g;
        entry.3 += b;
        index += 3 * stride;
    }

    if buckets.is_empty() {
        return fallback_palette();
    }

    let mut ranked: Vec<(u32, u32)> = buckets
        .into_iter()
        .map(|(key, (count, r, g, b))| {
            let color = color_from_sum(r, g, b, count);
            (count, color_key(key, color))
        })
        .collect();
    ranked.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));

    let primary = ranked[0].1;
    // 辅色：和主色明显不同的第一个（避免整张图两个色几乎一样）。
    let secondary = ranked
        .iter()
        .map(|(_, c)| *c)
        .find(|c| color_distance(primary, *c) > 60)
        .unwrap_or_else(|| shift_lightness(primary));
    let on_primary = if luminance(primary) > 0.55 {
        0x00_00_00
    } else {
        0xFF_FF_FF
    };

    let mut gradient: Vec<u32> = Vec::with_capacity(4);
    for (_, color) in ranked.iter() {
        if gradient.len() >= 4 {
            break;
        }
        if gradient.iter().any(|c| color_distance(*c, *color) <= 24) {
            continue;
        }
        gradient.push(*color);
    }
    if gradient.is_empty() {
        gradient.push(primary);
    }

    Palette {
        primary,
        secondary,
        on_primary,
        gradient,
    }
}

/// 全黑图或解不出像素时的兜底配色（深灰蓝）。
fn fallback_palette() -> Palette {
    Palette {
        primary: 0x2A_2E_36,
        secondary: 0x4A_50_5C,
        on_primary: 0xFF_FF_FF,
        gradient: vec![0x2A_2E_36, 0x3A_40_4A, 0x4A_50_5C],
    }
}

/// 桶里累计的 RGB 求平均，得到这个桶的代表色。
fn color_from_sum(r: u64, g: u64, b: u64, count: u32) -> u32 {
    let n = u64::from(count.max(1));
    let avg_r = (r / n).min(255) as u32;
    let avg_g = (g / n).min(255) as u32;
    let avg_b = (b / n).min(255) as u32;
    (avg_r << 16) | (avg_g << 8) | avg_b
}

/// 桶键 → 颜色（只在四舍五入后越界时才会和均值差一点点，这里直接用均值）。
fn color_key(_bucket: u16, color: u32) -> u32 {
    color
}

/// 两个 0xRRGGBB 颜色之间的加权欧氏距离（人眼对绿色更敏感）。
pub fn color_distance(a: u32, b: u32) -> u32 {
    let (ar, ag, ab) = split(a);
    let (br, bg, bb) = split(b);
    let dr = ar as i32 - br as i32;
    let dg = ag as i32 - bg as i32;
    let db = ab as i32 - bb as i32;
    let d = 2 * dr * dr + 4 * dg * dg + 3 * db * db;
    ((d as f64).sqrt().round() as u32).min(1000)
}

/// 感知亮度（0..=1，Rec. 709 系数）。
pub fn luminance(color: u32) -> f32 {
    let (r, g, b) = split(color);
    (0.2126 * r as f32 + 0.7152 * g as f32 + 0.0722 * b as f32) / 255.0
}

/// 提亮或压暗一档，作为辅色兜底。
fn shift_lightness(color: u32) -> u32 {
    let (r, g, b) = split(color);
    if luminance(color) > 0.5 {
        let dim = |c: u32| (c as f32 * 0.55) as u32;
        (dim(r) << 16) | (dim(g) << 8) | dim(b)
    } else {
        let lift = |c: u32| (c as f32 + (255.0 - c as f32) * 0.45) as u32;
        (lift(r) << 16) | (lift(g) << 8) | lift(b)
    }
}

fn split(color: u32) -> (u32, u32, u32) {
    ((color >> 16) & 0xFF, (color >> 8) & 0xFF, color & 0xFF)
}

// ---------------------------------------------------------------------------
// 多档缩略图（ENR-12）与带节流 / 缓存的下载
// ---------------------------------------------------------------------------

/// 缓存里为每张封面生成的边长档位。UI 按显示尺寸取"不小于需要的最近一档"。
pub const THUMBNAIL_WIDTHS: [u32; 4] = [128, 256, 512, 1024];

/// 一张封面的全部档位。
#[derive(Debug, Clone, PartialEq)]
pub struct ArtworkTiers {
    /// 原始字节的 SHA-256。
    pub hash: String,
    /// 最大一档的实际宽度（入库用）。
    pub width: u32,
    /// 最大一档的实际高度（入库用）。
    pub height: u32,
    /// 主色（按最大一档计算）。
    pub palette: Palette,
    /// `(档位, WebP 字节)`。档位是**名义**边长（文件名用它），原图比档位小时内容不放大。
    pub files: Vec<(u32, Vec<u8>)>,
}

/// 把一张图缩放到长边不超过 `target`（不放大），编码成无损 WebP。
fn encode_scaled(image: &image::DynamicImage, target: u32) -> Result<(u32, u32, Vec<u8>, Vec<u8>)> {
    let (src_w, src_h) = (image.width(), image.height());
    let longest = src_w.max(src_h);
    let scaled = if longest > target {
        let ratio = target as f64 / longest as f64;
        let w = ((src_w as f64 * ratio).round() as u32).max(1);
        let h = ((src_h as f64 * ratio).round() as u32).max(1);
        image.resize_exact(w, h, FILTER)
    } else {
        image.clone()
    };
    let (width, height) = (scaled.width(), scaled.height());
    let rgb = scaled.to_rgb8();
    let mut out = Vec::with_capacity(32 * 1024);
    image::codecs::webp::WebPEncoder::new_lossless(&mut out)
        .encode(rgb.as_raw(), width, height, image::ExtendedColorType::Rgb8)
        .map_err(|e| LekisError::new(ErrorCode::Internal, format!("编码 WebP 失败：{e}")))?;
    Ok((width, height, rgb.into_raw(), out))
}

/// 解码一次，按 `tiers` 里的每个档位各出一份 WebP（ENR-12）。`tiers` 为空时用 [`THUMBNAIL_WIDTHS`]。
pub fn process_tiers(bytes: &[u8], tiers: &[u32]) -> Result<ArtworkTiers> {
    if bytes.is_empty() {
        return Err(LekisError::invalid("封面字节为空"));
    }
    let tiers: Vec<u32> = if tiers.is_empty() {
        THUMBNAIL_WIDTHS.to_vec()
    } else {
        let mut t: Vec<u32> = tiers.iter().map(|w| (*w).clamp(96, 4096)).collect();
        t.sort_unstable();
        t.dedup();
        t
    };
    let hash = hash_bytes(bytes);
    let image = image::load_from_memory(bytes)
        .map_err(|e| LekisError::new(ErrorCode::Decode, format!("解码封面失败：{e}")))?;
    if image.width() == 0 || image.height() == 0 {
        return Err(LekisError::new(ErrorCode::Decode, "封面尺寸为 0"));
    }

    let mut files = Vec::with_capacity(tiers.len());
    let mut largest = (0, 0, fallback_palette());
    for (i, tier) in tiers.iter().enumerate() {
        let (w, h, rgb, webp) = encode_scaled(&image, *tier)?;
        if i + 1 == tiers.len() {
            largest = (w, h, palette_from_rgb(&rgb, w, h));
        }
        files.push((*tier, webp));
    }
    Ok(ArtworkTiers {
        hash,
        width: largest.0,
        height: largest.1,
        palette: largest.2,
        files,
    })
}

/// 所有封面图片下载共用的最小间隔（ENR-09）。图片来自各提供方的 CDN，限额比 API 宽，
/// 但"全部接受"一次可能连下几十张，仍然要排队，不能并发打爆对方。
static IMAGE_LIMITER: crate::throttle::RateLimiter =
    crate::throttle::RateLimiter::new(std::time::Duration::from_millis(250));

/// 按 URL 缓存最近下载的原图字节（同一张专辑封面被多首歌的候选同时引用时只下载一次）。
fn image_cache() -> &'static crate::cache::TtlCache<std::sync::Arc<[u8]>> {
    static CACHE: std::sync::OnceLock<crate::cache::TtlCache<std::sync::Arc<[u8]>>> =
        std::sync::OnceLock::new();
    CACHE.get_or_init(|| crate::cache::TtlCache::with_policy(crate::cache::DEFAULT_TTL, 16))
}

/// [`fetch_image`] 加上进程内节流（[`crate::throttle::RateLimiter`]）和结果缓存
/// （[`crate::cache::TtlCache`]）。补全流水线和"接受候选"都应该走这个入口。
pub async fn fetch_image_cached(url: &str) -> Result<std::sync::Arc<[u8]>> {
    if let Some(hit) = image_cache().get(url) {
        return Ok(hit);
    }
    IMAGE_LIMITER.acquire().await;
    let bytes: std::sync::Arc<[u8]> = fetch_image(url).await?.into();
    image_cache().insert(url.to_string(), bytes.clone());
    Ok(bytes)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn tiers_are_generated_for_every_width_without_upscaling() {
        let png = solid_png(600, 300, [12, 200, 90]);
        let out = process_tiers(&png, &[]).unwrap();
        let widths: Vec<u32> = out.files.iter().map(|(w, _)| *w).collect();
        assert_eq!(widths, THUMBNAIL_WIDTHS.to_vec());
        // 最大一档按原图尺寸（不放大），主色正确。
        assert_eq!((out.width, out.height), (600, 300));
        let (_, g, _) = split(out.palette.primary);
        assert!((g as i32 - 200).abs() <= 6);
        for (_, bytes) in &out.files {
            assert_eq!(&bytes[8..12], b"WEBP");
        }
        // 128 档真的缩小了。
        let small = image::load_from_memory(&out.files[0].1).unwrap();
        assert_eq!((small.width(), small.height()), (128, 64));
        assert_eq!(out.hash, hash_bytes(&png));
        assert_eq!(
            process_tiers(b"", &[]).unwrap_err().code,
            ErrorCode::InvalidArgument
        );
    }

    /// 造一张纯色 PNG，测解码 + 缩放 + 编码 + 主色。
    fn solid_png(width: u32, height: u32, rgb: [u8; 3]) -> Vec<u8> {
        let mut buffer = std::io::Cursor::new(Vec::new());
        let image = image::RgbImage::from_pixel(width, height, image::Rgb(rgb));
        image::DynamicImage::ImageRgb8(image)
            .write_to(&mut buffer, image::ImageFormat::Png)
            .unwrap();
        buffer.into_inner()
    }

    #[test]
    fn processes_solid_image_and_extracts_primary_color() {
        let png = solid_png(800, 800, [200, 30, 40]);
        let out = process_image(&png, 320).unwrap();
        assert_eq!((out.width, out.height), (320, 320));
        assert_eq!(out.hash.len(), 64);
        assert!(!out.bytes.is_empty());
        // WebP 魔数 "RIFF" ... "WEBP"。
        assert_eq!(&out.bytes[0..4], b"RIFF");
        assert_eq!(&out.bytes[8..12], b"WEBP");
        // 主色应该接近 (200, 30, 40)。
        let (r, g, b) = split(out.palette.primary);
        assert!((r as i32 - 200).abs() <= 6, "r = {r}");
        assert!((g as i32 - 30).abs() <= 6, "g = {g}");
        assert!((b as i32 - 40).abs() <= 6, "b = {b}");
        // 深色底上的文字应该是白的。
        assert_eq!(out.palette.on_primary, 0xFF_FF_FF);
        assert!(!out.palette.gradient.is_empty());
    }

    #[test]
    fn keeps_aspect_ratio_and_does_not_upscale() {
        let wide = solid_png(1200, 600, [10, 120, 200]);
        let out = process_image(&wide, 300).unwrap();
        assert_eq!((out.width, out.height), (300, 150));

        let small = solid_png(100, 100, [10, 120, 200]);
        let out = process_image(&small, 1024).unwrap();
        assert_eq!((out.width, out.height), (100, 100), "小图不放大");
    }

    #[test]
    fn light_background_gets_dark_text() {
        let png = solid_png(64, 64, [240, 240, 238]);
        let out = process_image(&png, 96).unwrap();
        assert_eq!(out.palette.on_primary, 0x00_00_00);
    }

    #[test]
    fn rejects_garbage_without_panicking() {
        let err = process_image(b"not an image at all", 320).unwrap_err();
        assert_eq!(err.code, ErrorCode::Decode);
        assert_eq!(
            process_image(b"", 320).unwrap_err().code,
            ErrorCode::InvalidArgument
        );
    }

    #[test]
    fn hash_is_stable_and_distinguishes_images() {
        let a = solid_png(16, 16, [1, 2, 3]);
        let b = solid_png(16, 16, [1, 2, 4]);
        assert_eq!(hash_bytes(&a), hash_bytes(&a));
        assert_ne!(hash_bytes(&a), hash_bytes(&b));
    }

    #[test]
    fn distance_and_luminance_are_sane() {
        assert_eq!(color_distance(0x00_00_00, 0x00_00_00), 0);
        assert!(color_distance(0xFF_FF_FF, 0x00_00_00) > 400);
        assert!(luminance(0xFF_FF_FF) > 0.95);
        assert!(luminance(0x00_00_00) < 0.05);
        assert!(color_distance(shift_lightness(0x12_34_56), 0x12_34_56) > 10);
    }
}
