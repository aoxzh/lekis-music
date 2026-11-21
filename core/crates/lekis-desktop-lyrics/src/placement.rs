//! 每个显示器记住一个位置 / 宽度，并保证窗口落在可见工作区内（纯计算，与平台无关）。

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// 屏幕坐标里的矩形（物理像素）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Rect {
    /// 左。
    pub left: i32,
    /// 上。
    pub top: i32,
    /// 右（不含）。
    pub right: i32,
    /// 下（不含）。
    pub bottom: i32,
}

impl Rect {
    /// 宽。
    pub fn width(&self) -> i32 {
        self.right - self.left
    }
    /// 高。
    pub fn height(&self) -> i32 {
        self.bottom - self.top
    }
    /// 中心点。
    pub fn center(&self) -> (i32, i32) {
        (self.left + self.width() / 2, self.top + self.height() / 2)
    }
    /// 是否包含点。
    pub fn contains(&self, x: i32, y: i32) -> bool {
        x >= self.left && x < self.right && y >= self.top && y < self.bottom
    }
}

/// 一个显示器。
#[derive(Debug, Clone, PartialEq)]
pub struct Monitor {
    /// 稳定的标识（设备名 + 分辨率）。
    pub key: String,
    /// 工作区（去掉任务栏）。
    pub work: Rect,
    /// DPI / 96。
    pub scale: f32,
    /// 主显示器。
    pub primary: bool,
}

/// 某个显示器上记住的位置，相对工作区左上角，单位 DIP（换 DPI 后仍然成立）。
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Spot {
    /// 距工作区左边。
    pub x: f32,
    /// 距工作区上边。
    pub y: f32,
    /// 宽度。
    pub width: f32,
}

/// 所有显示器上的位置记录（序列化成 JSON 交给宿主保存）。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Placements {
    /// 最后一次停在哪个显示器。
    #[serde(default)]
    pub last: Option<String>,
    /// 显示器 → 位置。
    #[serde(default)]
    pub monitors: BTreeMap<String, Spot>,
}

/// 默认宽度（DIP）。
pub const DEFAULT_WIDTH_DIP: f32 = 880.0;
/// 最小宽度（DIP）。
pub const MIN_WIDTH_DIP: f32 = 320.0;
/// 默认离工作区底边的距离（DIP）。
const DEFAULT_BOTTOM_MARGIN_DIP: f32 = 72.0;

impl Placements {
    /// 从 JSON 读；坏数据当作没有记录。
    pub fn from_json(json: &str) -> Self {
        serde_json::from_str(json).unwrap_or_default()
    }

    /// 序列化。
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| "{}".into())
    }

    /// 选显示器并算出窗口矩形。`height_px(scale)` 给出该缩放下的窗口高度。
    /// 返回所选显示器在 `monitors` 里的下标；`monitors` 为空时返回 `None`。
    pub fn resolve(
        &self,
        monitors: &[Monitor],
        height_px: impl Fn(f32) -> i32,
    ) -> Option<(usize, Rect)> {
        if monitors.is_empty() {
            return None;
        }
        let by_key = |k: &str| monitors.iter().position(|m| m.key == k);
        let primary = monitors.iter().position(|m| m.primary).unwrap_or(0);
        let index = self.last.as_deref().and_then(by_key).unwrap_or(primary);
        let m = &monitors[index];
        let h = height_px(m.scale);
        let rect = match self.monitors.get(&m.key) {
            Some(spot) => {
                let left = m.work.left + dip(spot.x, m.scale);
                let top = m.work.top + dip(spot.y, m.scale);
                let w = dip(spot.width.max(MIN_WIDTH_DIP), m.scale);
                Rect {
                    left,
                    top,
                    right: left + w,
                    bottom: top + h,
                }
            }
            None => default_rect(m, h),
        };
        Some((index, clamp(rect, m.work, dip(MIN_WIDTH_DIP, m.scale))))
    }

    /// 记下窗口当前停在 `monitor` 上的位置。
    pub fn record(&mut self, monitor: &Monitor, rect: Rect) {
        let s = monitor.scale.max(0.5);
        self.monitors.insert(
            monitor.key.clone(),
            Spot {
                x: (rect.left - monitor.work.left) as f32 / s,
                y: (rect.top - monitor.work.top) as f32 / s,
                width: rect.width() as f32 / s,
            },
        );
        self.last = Some(monitor.key.clone());
    }
}

fn dip(v: f32, scale: f32) -> i32 {
    (v * scale).round() as i32
}

/// 主显示器底部居中。
pub fn default_rect(m: &Monitor, height: i32) -> Rect {
    let w = dip(DEFAULT_WIDTH_DIP, m.scale).min((m.work.width() as f32 * 0.8) as i32);
    let left = m.work.left + (m.work.width() - w) / 2;
    let top = m.work.bottom - height - dip(DEFAULT_BOTTOM_MARGIN_DIP, m.scale);
    Rect {
        left,
        top,
        right: left + w,
        bottom: top + height,
    }
}

/// 把窗口整个挪进工作区（宽度过大时先缩到工作区宽度，但不小于 `min_width`）。
pub fn clamp(rect: Rect, work: Rect, min_width: i32) -> Rect {
    let w = rect
        .width()
        .min(work.width())
        .max(min_width.min(work.width()));
    let h = rect.height();
    let left = rect.left.clamp(work.left, (work.right - w).max(work.left));
    let top = rect.top.clamp(work.top, (work.bottom - h).max(work.top));
    Rect {
        left,
        top,
        right: left + w,
        bottom: top + h,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn monitor(key: &str, left: i32, scale: f32, primary: bool) -> Monitor {
        Monitor {
            key: key.into(),
            work: Rect {
                left,
                top: 0,
                right: left + 1920,
                bottom: 1040,
            },
            scale,
            primary,
        }
    }

    #[test]
    fn default_is_bottom_center_of_primary() {
        let ms = [monitor("B", 1920, 1.0, false), monitor("A", 0, 1.0, true)];
        let (i, r) = Placements::default()
            .resolve(&ms, |_| 100)
            .unwrap_or_default();
        assert_eq!(i, 1);
        assert_eq!(r.width(), 880);
        assert_eq!(r.left, (1920 - 880) / 2);
        assert_eq!(r.bottom, 1040 - 72);
    }

    #[test]
    fn remembers_per_monitor_in_dip() {
        let ms = [monitor("A", 0, 1.0, true), monitor("B", 1920, 1.5, false)];
        let mut p = Placements::default();
        p.record(
            &ms[1],
            Rect {
                left: 1920 + 300,
                top: 150,
                right: 1920 + 300 + 1200,
                bottom: 300,
            },
        );
        let p = Placements::from_json(&p.to_json());
        assert_eq!(p.last.as_deref(), Some("B"));
        let (i, r) = p.resolve(&ms, |s| (100.0 * s) as i32).unwrap_or_default();
        assert_eq!(i, 1);
        assert_eq!(r.left, 1920 + 300);
        assert_eq!(r.top, 150);
        assert_eq!(r.width(), 1200);
        assert_eq!(r.height(), 150);
    }

    #[test]
    fn falls_back_to_primary_when_monitor_is_gone() {
        let mut p = Placements::default();
        p.record(
            &monitor("GONE", 5000, 1.0, false),
            Rect {
                left: 5100,
                top: 10,
                right: 5600,
                bottom: 110,
            },
        );
        let ms = [monitor("A", 0, 1.0, true)];
        let (i, r) = p.resolve(&ms, |_| 100).unwrap_or_default();
        assert_eq!(i, 0);
        assert!(r.left >= 0 && r.right <= 1920);
    }

    #[test]
    fn clamps_into_work_area() {
        let work = Rect {
            left: 0,
            top: 0,
            right: 1000,
            bottom: 800,
        };
        let r = clamp(
            Rect {
                left: 900,
                top: 790,
                right: 1300,
                bottom: 890,
            },
            work,
            300,
        );
        assert_eq!(
            r,
            Rect {
                left: 600,
                top: 700,
                right: 1000,
                bottom: 800
            }
        );
        let wide = clamp(
            Rect {
                left: -50,
                top: -5,
                right: 2000,
                bottom: 95,
            },
            work,
            300,
        );
        assert_eq!(
            wide,
            Rect {
                left: 0,
                top: 0,
                right: 1000,
                bottom: 100
            }
        );
    }

    #[test]
    fn bad_json_is_empty() {
        assert_eq!(Placements::from_json("nope"), Placements::default());
    }
}
