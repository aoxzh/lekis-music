//! 排版与绘制：Direct2D DC 渲染目标（软件）画进 DIB，`UpdateLayeredWindow` 送上屏幕。
//!
//! 每行歌词在换行时排版一次，连同描边 / 阴影栅格化成两张位图（未唱色、已唱色）缓存起来；
//! 每帧只是贴图 + 一个裁剪矩形做卡拉 OK 填充，所以按刷新率重绘也很便宜。
//!
//! 透明背景上不能用 ClearType（子像素抗锯齿需要不透明底），文字用灰度抗锯齿；
//! 靠描边 + 阴影保证在任何壁纸上都看得清。

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

use windows::core::{w, Result, HSTRING, PCWSTR};
use windows::Win32::Foundation::{COLORREF, D2DERR_RECREATE_TARGET, HWND, POINT, RECT, SIZE};
use windows::Win32::Graphics::Direct2D::Common::{
    D2D1_ALPHA_MODE_PREMULTIPLIED, D2D1_COLOR_F, D2D1_PIXEL_FORMAT, D2D_RECT_F, D2D_SIZE_U,
};
use windows::Win32::Graphics::Direct2D::*;
use windows::Win32::Graphics::DirectWrite::*;
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Gdi::{
    CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, SelectObject, AC_SRC_ALPHA,
    AC_SRC_OVER, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, BLENDFUNCTION, DIB_RGB_COLORS, HBITMAP, HDC,
    HGDIOBJ,
};
use windows::Win32::UI::WindowsAndMessaging::{UpdateLayeredWindow, ULW_ALPHA};
use windows_numerics::Vector2;

use crate::model::{Style, Word};
use crate::timeline::{Fill, PrimaryKind, View};

const DEFAULT_FAMILY: &str = "Microsoft YaHei UI";
/// 第二行相对主行的字号。
const SECONDARY_RATIO: f32 = 0.62;
/// 主行太长时最多缩到多小（相对设定字号）。
const MIN_SHRINK: f32 = 0.6;
const CACHE_LIMIT: usize = 8;

/// 工具栏按钮。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(super) enum Button {
    Previous,
    PlayPause,
    Next,
    Lock,
    Close,
}

const BUTTONS: [Button; 5] = [
    Button::Previous,
    Button::PlayPause,
    Button::Next,
    Button::Lock,
    Button::Close,
];

/// 和交互有关、影响画面的状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(super) struct Ui {
    pub(super) hovered: bool,
    pub(super) hover_button: Option<Button>,
    pub(super) pressed: Option<Button>,
    pub(super) locked: bool,
    pub(super) playing: bool,
}

/// 窗口各部分的位置（物理像素）。
pub(super) struct Layout {
    pub(super) scale: f32,
    pub(super) width: i32,
    pub(super) height: i32,
    font_px: f32,
    small_px: f32,
    pad_x: f32,
    button: f32,
    button_gap: f32,
    button_top: f32,
    line1_top: f32,
    line1_h: f32,
    line2_top: f32,
    line2_h: f32,
    two_line: bool,
}

impl Layout {
    pub(super) fn new(scale: f32, width: i32, style: &Style) -> Layout {
        let font_px = style.font_size * scale;
        let small_px = font_px * SECONDARY_RATIO;
        let toolbar_h = 44.0 * scale;
        let line1_h = (font_px * 1.5).ceil();
        let gap = 2.0 * scale;
        let line2_h = (small_px * 1.55).ceil();
        let bottom = 10.0 * scale;
        let line1_top = toolbar_h;
        let line2_top = line1_top + line1_h + gap;
        let height = if style.two_line {
            line2_top + line2_h + bottom
        } else {
            line1_top + line1_h + bottom
        };
        Layout {
            scale,
            width,
            height: height.ceil() as i32,
            font_px,
            small_px,
            pad_x: 18.0 * scale,
            button: 32.0 * scale,
            button_gap: 6.0 * scale,
            button_top: 6.0 * scale,
            line1_top,
            line1_h,
            line2_top,
            line2_h,
            two_line: style.two_line,
        }
    }

    fn avail_width(&self) -> f32 {
        (self.width as f32 - 2.0 * self.pad_x).max(40.0)
    }

    /// 按钮矩形：[上一首 播放 下一首]  [锁 关闭]，整体居中。
    fn button_rect(&self, b: Button) -> D2D_RECT_F {
        let i = BUTTONS.iter().position(|x| *x == b).unwrap_or(0) as f32;
        let group_gap = self.button * 0.75;
        let total = 5.0 * self.button + 4.0 * self.button_gap + group_gap;
        let mut left = (self.width as f32 - total) / 2.0 + i * (self.button + self.button_gap);
        if i >= 3.0 {
            left += group_gap;
        }
        D2D_RECT_F {
            left,
            top: self.button_top,
            right: left + self.button,
            bottom: self.button_top + self.button,
        }
    }

    /// 窗口坐标下点到了哪个按钮。锁定时只有锁按钮可点。
    pub(super) fn button_at(&self, x: f32, y: f32, locked: bool) -> Option<Button> {
        BUTTONS
            .iter()
            .copied()
            .filter(|b| !locked || *b == Button::Lock)
            .find(|b| {
                let r = self.button_rect(*b);
                x >= r.left && x < r.right && y >= r.top && y < r.bottom
            })
    }
}

/// 这一帧画面的指纹：没变就不重画。
pub(super) fn frame_key(
    view: &View<'_>,
    ui: &Ui,
    style: &Style,
    size: (i32, i32),
    dpi: u32,
) -> u64 {
    let mut h = DefaultHasher::new();
    view.kind.hash(&mut h);
    view.primary.hash(&mut h);
    view.secondary.hash(&mut h);
    match view.fill {
        Fill::Nothing => 0u32.hash(&mut h),
        Fill::All => 1u32.hash(&mut h),
        Fill::Partial { word, fraction } => {
            word.hash(&mut h);
            ((fraction * 1024.0) as u32).hash(&mut h);
        }
    }
    ui.hash(&mut h);
    style_hash(style).hash(&mut h);
    size.hash(&mut h);
    dpi.hash(&mut h);
    h.finish()
}

fn style_hash(style: &Style) -> u64 {
    let mut h = DefaultHasher::new();
    style.font_size.to_bits().hash(&mut h);
    style.font_family.hash(&mut h);
    style.bold.hash(&mut h);
    style.sung_color.hash(&mut h);
    style.unsung_color.hash(&mut h);
    style.outline_color.hash(&mut h);
    style.opacity.to_bits().hash(&mut h);
    style.two_line.hash(&mut h);
    h.finish()
}

fn color(argb: u32) -> D2D1_COLOR_F {
    D2D1_COLOR_F {
        r: ((argb >> 16) & 0xFF) as f32 / 255.0,
        g: ((argb >> 8) & 0xFF) as f32 / 255.0,
        b: (argb & 0xFF) as f32 / 255.0,
        a: ((argb >> 24) & 0xFF) as f32 / 255.0,
    }
}

fn rgba(r: f32, g: f32, b: f32, a: f32) -> D2D1_COLOR_F {
    D2D1_COLOR_F { r, g, b, a }
}

const TRANSPARENT: D2D1_COLOR_F = D2D1_COLOR_F {
    r: 0.0,
    g: 0.0,
    b: 0.0,
    a: 0.0,
};

/// 栅格化好的一行。
struct CachedLine {
    key: u64,
    used: u64,
    base: ID2D1Bitmap,
    fill: Option<ID2D1Bitmap>,
    w: f32,
    h: f32,
    /// 每个字在位图里的 [左, 右)。
    words_x: Vec<(f32, f32)>,
}

/// GDI 内存 DC + 32 位 top-down DIB。
struct Surface {
    w: i32,
    h: i32,
    dc: HDC,
    bitmap: HBITMAP,
    old: HGDIOBJ,
}

impl Surface {
    fn new(w: i32, h: i32) -> Result<Surface> {
        unsafe {
            let dc = CreateCompatibleDC(None);
            let info = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: w,
                    biHeight: -h,
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                },
                ..Default::default()
            };
            let mut bits = std::ptr::null_mut();
            let bitmap = match CreateDIBSection(Some(dc), &info, DIB_RGB_COLORS, &mut bits, None, 0)
            {
                Ok(b) => b,
                Err(e) => {
                    let _ = DeleteDC(dc);
                    return Err(e);
                }
            };
            let old = SelectObject(dc, bitmap.into());
            Ok(Surface {
                w,
                h,
                dc,
                bitmap,
                old,
            })
        }
    }
}

impl Drop for Surface {
    fn drop(&mut self) {
        unsafe {
            SelectObject(self.dc, self.old);
            let _ = DeleteObject(self.bitmap.into());
            let _ = DeleteDC(self.dc);
        }
    }
}

pub(super) struct Gfx {
    d2d: ID2D1Factory,
    dwrite: IDWriteFactory,
    icons: Option<&'static str>,
    rt: Option<ID2D1DCRenderTarget>,
    surface: Option<Surface>,
    cache: Vec<CachedLine>,
    tick: u64,
}

impl Gfx {
    pub(super) fn new() -> Result<Gfx> {
        unsafe {
            let d2d: ID2D1Factory = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None)?;
            let dwrite: IDWriteFactory = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)?;
            let icons = find_icon_font(&dwrite);
            Ok(Gfx {
                d2d,
                dwrite,
                icons,
                rt: None,
                surface: None,
                cache: Vec::new(),
                tick: 0,
            })
        }
    }

    pub(super) fn clear_cache(&mut self) {
        self.cache.clear();
    }

    /// 隐藏时释放位图和 DIB（下次显示再建）。
    pub(super) fn trim(&mut self) {
        self.cache.clear();
        self.rt = None;
        self.surface = None;
    }

    fn render_target(&mut self) -> Result<ID2D1DCRenderTarget> {
        if let Some(rt) = &self.rt {
            return Ok(rt.clone());
        }
        let props = D2D1_RENDER_TARGET_PROPERTIES {
            // 软件光栅化：不为一个小窗口拉起 D3D 设备（省内存，也不受驱动影响）。
            r#type: D2D1_RENDER_TARGET_TYPE_SOFTWARE,
            pixelFormat: D2D1_PIXEL_FORMAT {
                format: DXGI_FORMAT_B8G8R8A8_UNORM,
                alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED,
            },
            dpiX: 96.0,
            dpiY: 96.0,
            usage: D2D1_RENDER_TARGET_USAGE_NONE,
            minLevel: D2D1_FEATURE_LEVEL_DEFAULT,
        };
        let rt = unsafe { self.d2d.CreateDCRenderTarget(&props)? };
        self.cache.clear();
        self.rt = Some(rt.clone());
        Ok(rt)
    }

    pub(super) fn draw(
        &mut self,
        hwnd: HWND,
        size: (i32, i32),
        layout: &Layout,
        style: &Style,
        view: &View<'_>,
        ui: &Ui,
    ) -> Result<()> {
        let (w, h) = size;
        if self.surface.as_ref().map(|s| (s.w, s.h)) != Some((w, h)) {
            self.surface = None;
            self.surface = Some(Surface::new(w, h)?);
        }
        let rt = self.render_target()?;
        let dc = self.surface.as_ref().map(|s| s.dc).unwrap_or_default();
        let result = unsafe {
            rt.BindDC(
                dc,
                &RECT {
                    left: 0,
                    top: 0,
                    right: w,
                    bottom: h,
                },
            )?;
            rt.BeginDraw();
            rt.Clear(Some(&TRANSPARENT));
            let drawn = self.paint(&rt, layout, style, view, ui);
            let end = rt.EndDraw(None, None);
            drawn.and(end)
        };
        if let Err(e) = result {
            if e.code() == D2DERR_RECREATE_TARGET {
                self.rt = None;
                self.cache.clear();
            }
            return Err(e);
        }
        unsafe {
            let blend = BLENDFUNCTION {
                BlendOp: AC_SRC_OVER as u8,
                BlendFlags: 0,
                SourceConstantAlpha: 255,
                AlphaFormat: AC_SRC_ALPHA as u8,
            };
            UpdateLayeredWindow(
                hwnd,
                None,
                None,
                Some(&SIZE { cx: w, cy: h }),
                Some(dc),
                Some(&POINT { x: 0, y: 0 }),
                COLORREF(0),
                Some(&blend),
                ULW_ALPHA,
            )?;
        }
        Ok(())
    }

    unsafe fn paint(
        &mut self,
        rt: &ID2D1DCRenderTarget,
        layout: &Layout,
        style: &Style,
        view: &View<'_>,
        ui: &Ui,
    ) -> Result<()> {
        let brush = unsafe { rt.CreateSolidColorBrush(&TRANSPARENT, None)? };
        let full = D2D_RECT_F {
            left: 0.0,
            top: 0.0,
            right: layout.width as f32,
            bottom: layout.height as f32,
        };
        // 背景：解锁时整窗至少 alpha 3/255（分层窗口 alpha 为 0 的像素点不中）。
        unsafe {
            if !ui.locked && ui.hovered {
                brush.SetColor(&rgba(0.0, 0.0, 0.0, 0.42));
                let r = 10.0 * layout.scale;
                rt.FillRoundedRectangle(
                    &D2D1_ROUNDED_RECT {
                        rect: full,
                        radiusX: r,
                        radiusY: r,
                    },
                    &brush,
                );
            } else if !ui.locked {
                brush.SetColor(&rgba(0.0, 0.0, 0.0, 3.0 / 255.0));
                rt.FillRectangle(&full, &brush);
            }
        }

        let avail = layout.avail_width();
        // 主行。
        let sung = view.kind != PrimaryKind::Idle;
        let primary = self.line(
            rt,
            view.primary,
            layout.font_px,
            avail,
            style,
            sung,
            view.words,
        )?;
        let px = ((layout.width as f32 - primary.w) / 2.0).round();
        let py = (layout.line1_top + (layout.line1_h - primary.h) / 2.0).round();
        let dest = |x: f32, y: f32, l: &LineMetrics| D2D_RECT_F {
            left: x,
            top: y,
            right: x + l.w,
            bottom: y + l.h,
        };
        let d = dest(px, py, &primary);
        let nn = D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR;
        unsafe {
            match (view.fill, primary.fill.as_ref()) {
                (Fill::All, Some(fill)) => rt.DrawBitmap(fill, Some(&d), style.opacity, nn, None),
                (Fill::Partial { word, fraction }, Some(fill)) => {
                    rt.DrawBitmap(&primary.base, Some(&d), style.opacity, nn, None);
                    let x = primary
                        .words_x
                        .get(word)
                        .map(|(l, r)| l + (r - l) * fraction)
                        .unwrap_or(0.0);
                    let clip = D2D_RECT_F {
                        left: d.left,
                        top: d.top,
                        right: d.left + x,
                        bottom: d.bottom,
                    };
                    rt.PushAxisAlignedClip(&clip, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
                    rt.DrawBitmap(fill, Some(&d), style.opacity, nn, None);
                    rt.PopAxisAlignedClip();
                }
                _ => rt.DrawBitmap(&primary.base, Some(&d), style.opacity, nn, None),
            }
        }

        // 第二行。
        if layout.two_line {
            if let Some(text) = view.secondary {
                let second = self.line(rt, text, layout.small_px, avail, style, false, &[])?;
                let sx = ((layout.width as f32 - second.w) / 2.0).round();
                let sy = (layout.line2_top + (layout.line2_h - second.h) / 2.0).round();
                unsafe {
                    rt.DrawBitmap(
                        &second.base,
                        Some(&dest(sx, sy, &second)),
                        style.opacity * 0.9,
                        nn,
                        None,
                    )
                };
            }
        }

        // 工具栏。
        if ui.hovered {
            self.toolbar(rt, &brush, layout, ui)?;
        }
        Ok(())
    }

    unsafe fn toolbar(
        &self,
        rt: &ID2D1DCRenderTarget,
        brush: &ID2D1SolidColorBrush,
        layout: &Layout,
        ui: &Ui,
    ) -> Result<()> {
        let size = 15.0 * layout.scale;
        let family = self.icons.unwrap_or("Segoe UI Symbol");
        let format = unsafe {
            self.dwrite.CreateTextFormat(
                &HSTRING::from(family),
                None,
                DWRITE_FONT_WEIGHT_NORMAL,
                DWRITE_FONT_STYLE_NORMAL,
                DWRITE_FONT_STRETCH_NORMAL,
                size,
                w!("en-us"),
            )?
        };
        unsafe {
            format.SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER)?;
            format.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER)?;
        }
        for b in BUTTONS {
            if ui.locked && b != Button::Lock {
                continue;
            }
            let r = layout.button_rect(b);
            let radius = layout.button / 2.0;
            let bg = if ui.pressed == Some(b) {
                0.34
            } else if ui.hover_button == Some(b) {
                0.22
            } else if ui.locked {
                // 锁定时只露一个半透明的解锁按钮。
                0.0
            } else {
                0.0
            };
            unsafe {
                if ui.locked {
                    brush.SetColor(&rgba(0.0, 0.0, 0.0, 0.5));
                    rt.FillRoundedRectangle(
                        &D2D1_ROUNDED_RECT {
                            rect: r,
                            radiusX: radius,
                            radiusY: radius,
                        },
                        brush,
                    );
                }
                if bg > 0.0 {
                    brush.SetColor(&rgba(1.0, 1.0, 1.0, bg));
                    rt.FillRoundedRectangle(
                        &D2D1_ROUNDED_RECT {
                            rect: r,
                            radiusX: radius,
                            radiusY: radius,
                        },
                        brush,
                    );
                }
            }
            let glyph = icon_glyph(b, ui, self.icons.is_some());
            let text: Vec<u16> = glyph.encode_utf16().collect();
            let tl = unsafe {
                self.dwrite
                    .CreateTextLayout(&text, &format, r.right - r.left, r.bottom - r.top)?
            };
            unsafe {
                brush.SetColor(&rgba(1.0, 1.0, 1.0, 0.95));
                rt.DrawTextLayout(
                    Vector2 {
                        X: r.left,
                        Y: r.top,
                    },
                    &tl,
                    brush,
                    D2D1_DRAW_TEXT_OPTIONS_NONE,
                );
            }
        }
        Ok(())
    }

    /// 取（或栅格化）一行文字。
    #[allow(clippy::too_many_arguments)]
    unsafe fn line(
        &mut self,
        rt: &ID2D1DCRenderTarget,
        text: &str,
        font_px: f32,
        max_w: f32,
        style: &Style,
        with_fill: bool,
        words: &[Word],
    ) -> Result<LineMetrics> {
        let mut h = DefaultHasher::new();
        text.hash(&mut h);
        font_px.to_bits().hash(&mut h);
        (max_w as i32).hash(&mut h);
        with_fill.hash(&mut h);
        words.len().hash(&mut h);
        style_hash(style).hash(&mut h);
        let key = h.finish();
        self.tick += 1;
        let tick = self.tick;
        if let Some(c) = self.cache.iter_mut().find(|c| c.key == key) {
            c.used = tick;
            return Ok(LineMetrics::from(&*c));
        }
        let built = unsafe { self.build_line(rt, text, font_px, max_w, style, with_fill, words)? };
        let metrics = LineMetrics::from(&built);
        let built = CachedLine {
            key,
            used: tick,
            ..built
        };
        if self.cache.len() >= CACHE_LIMIT {
            if let Some(oldest) = self
                .cache
                .iter()
                .enumerate()
                .min_by_key(|(_, c)| c.used)
                .map(|(i, _)| i)
            {
                self.cache.swap_remove(oldest);
            }
        }
        self.cache.push(built);
        Ok(metrics)
    }

    unsafe fn text_layout(
        &self,
        utf16: &[u16],
        style: &Style,
        font_px: f32,
    ) -> Result<(IDWriteTextLayout, DWRITE_TEXT_METRICS)> {
        let family = if style.font_family.trim().is_empty() {
            DEFAULT_FAMILY
        } else {
            style.font_family.as_str()
        };
        let weight = if style.bold {
            DWRITE_FONT_WEIGHT_BOLD
        } else {
            DWRITE_FONT_WEIGHT_NORMAL
        };
        unsafe {
            let format = self.dwrite.CreateTextFormat(
                &HSTRING::from(family),
                None,
                weight,
                DWRITE_FONT_STYLE_NORMAL,
                DWRITE_FONT_STRETCH_NORMAL,
                font_px.max(1.0),
                w!("zh-cn"),
            )?;
            format.SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP)?;
            let layout = self
                .dwrite
                .CreateTextLayout(utf16, &format, 100_000.0, font_px * 3.0)?;
            let mut m = DWRITE_TEXT_METRICS::default();
            layout.GetMetrics(&mut m)?;
            Ok((layout, m))
        }
    }

    #[allow(clippy::too_many_arguments)]
    unsafe fn build_line(
        &self,
        rt: &ID2D1DCRenderTarget,
        text: &str,
        font_px: f32,
        max_w: f32,
        style: &Style,
        with_fill: bool,
        words: &[Word],
    ) -> Result<CachedLine> {
        let utf16: Vec<u16> = text.encode_utf16().collect();
        let (mut layout, mut m) = unsafe { self.text_layout(&utf16, style, font_px)? };
        let mut px = font_px;
        if m.widthIncludingTrailingWhitespace > max_w && m.widthIncludingTrailingWhitespace > 0.0 {
            px = (font_px * max_w / m.widthIncludingTrailingWhitespace).max(font_px * MIN_SHRINK);
            (layout, m) = unsafe { self.text_layout(&utf16, style, px)? };
        }
        let r = (px / 16.0).max(1.2);
        let pad = (r * 2.6).ceil();
        let tw = m.widthIncludingTrailingWhitespace.min(max_w);
        let bw = (tw + 2.0 * pad).ceil().max(1.0);
        let bh = (m.height + 2.0 * pad).ceil().max(1.0);
        let unsung = color(style.unsung_color);
        let base = unsafe {
            rasterize(
                rt,
                &layout,
                (bw, bh),
                pad,
                r,
                unsung,
                color(style.outline_color),
            )?
        };
        let fill = if with_fill {
            Some(unsafe {
                rasterize(
                    rt,
                    &layout,
                    (bw, bh),
                    pad,
                    r,
                    color(style.sung_color),
                    color(style.outline_color),
                )?
            })
        } else {
            None
        };

        // 每个字的横向范围（UTF-16 下标做命中测试）。
        let mut words_x = Vec::with_capacity(words.len());
        let len = utf16.len() as u32;
        let mut offset = 0u32;
        for word in words {
            let n = word.text.encode_utf16().count() as u32;
            let start = offset.min(len);
            let end = (offset + n).min(len);
            offset += n;
            let x0 = unsafe { hit_x(&layout, start, len, m.widthIncludingTrailingWhitespace)? };
            let x1 = unsafe { hit_x(&layout, end, len, m.widthIncludingTrailingWhitespace)? };
            words_x.push(((x0 + pad).min(bw), (x1 + pad).min(bw)));
        }
        Ok(CachedLine {
            key: 0,
            used: 0,
            base,
            fill,
            w: bw,
            h: bh,
            words_x,
        })
    }
}

/// 绘制时用到的一行的尺寸和位图（从缓存里拷出来的引用计数句柄）。
struct LineMetrics {
    base: ID2D1Bitmap,
    fill: Option<ID2D1Bitmap>,
    w: f32,
    h: f32,
    words_x: Vec<(f32, f32)>,
}

impl From<&CachedLine> for LineMetrics {
    fn from(c: &CachedLine) -> Self {
        LineMetrics {
            base: c.base.clone(),
            fill: c.fill.clone(),
            w: c.w,
            h: c.h,
            words_x: c.words_x.clone(),
        }
    }
}

unsafe fn hit_x(layout: &IDWriteTextLayout, pos: u32, len: u32, full: f32) -> Result<f32> {
    if pos >= len {
        return Ok(full);
    }
    let (mut x, mut y) = (0.0f32, 0.0f32);
    let mut m = DWRITE_HIT_TEST_METRICS::default();
    unsafe { layout.HitTestTextPosition(pos, false, &mut x, &mut y, &mut m)? };
    Ok(x)
}

/// 阴影 + 8 方向描边 + 正文，画进一张透明位图。
unsafe fn rasterize(
    rt: &ID2D1DCRenderTarget,
    layout: &IDWriteTextLayout,
    (bw, bh): (f32, f32),
    pad: f32,
    r: f32,
    fill: D2D1_COLOR_F,
    outline: D2D1_COLOR_F,
) -> Result<ID2D1Bitmap> {
    unsafe {
        let target = rt.CreateCompatibleRenderTarget(
            None,
            Some(&D2D_SIZE_U {
                width: bw as u32,
                height: bh as u32,
            }),
            None,
            D2D1_COMPATIBLE_RENDER_TARGET_OPTIONS_NONE,
        )?;
        target.BeginDraw();
        target.Clear(Some(&TRANSPARENT));
        target.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
        let brush = target.CreateSolidColorBrush(&outline, None)?;
        let at = |dx: f32, dy: f32| Vector2 {
            X: pad + dx,
            Y: pad + dy,
        };
        let opts = D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT;
        // 柔和的投影。
        brush.SetColor(&D2D1_COLOR_F {
            a: outline.a * 0.45,
            ..outline
        });
        target.DrawTextLayout(at(r * 0.7, r * 1.6), layout, &brush, opts);
        // 描边。
        brush.SetColor(&outline);
        let d = r * std::f32::consts::FRAC_1_SQRT_2;
        for (dx, dy) in [
            (r, 0.0),
            (-r, 0.0),
            (0.0, r),
            (0.0, -r),
            (d, d),
            (d, -d),
            (-d, d),
            (-d, -d),
        ] {
            target.DrawTextLayout(at(dx, dy), layout, &brush, opts);
        }
        brush.SetColor(&fill);
        target.DrawTextLayout(at(0.0, 0.0), layout, &brush, opts);
        target.EndDraw(None, None)?;
        target.GetBitmap()
    }
}

/// Segoe Fluent Icons（Win11）/ Segoe MDL2 Assets（Win10）。
fn find_icon_font(dwrite: &IDWriteFactory) -> Option<&'static str> {
    let mut collection = None;
    unsafe { dwrite.GetSystemFontCollection(&mut collection, false) }.ok()?;
    let collection = collection?;
    for family in ["Segoe Fluent Icons", "Segoe MDL2 Assets"] {
        let (mut index, mut exists) = (0u32, windows::core::BOOL(0));
        let name = HSTRING::from(family);
        if unsafe { collection.FindFamilyName(PCWSTR(name.as_ptr()), &mut index, &mut exists) }
            .is_ok()
            && exists.as_bool()
        {
            return Some(family);
        }
    }
    None
}

fn icon_glyph(b: Button, ui: &Ui, icon_font: bool) -> &'static str {
    if icon_font {
        match b {
            Button::Previous => "\u{E892}",
            Button::PlayPause if ui.playing => "\u{E769}",
            Button::PlayPause => "\u{E768}",
            Button::Next => "\u{E893}",
            // 锁定时按钮的作用是解锁，显示打开的锁。
            Button::Lock if ui.locked => "\u{E785}",
            Button::Lock => "\u{E72E}",
            Button::Close => "\u{E711}",
        }
    } else {
        match b {
            Button::Previous => "⏮",
            Button::PlayPause if ui.playing => "⏸",
            Button::PlayPause => "▶",
            Button::Next => "⏭",
            Button::Lock => "🔒",
            Button::Close => "✕",
        }
    }
}
