//! 10 段均衡器的持久化模型与预设目录（PLY-04）。
//!
//! 设置值存在资料库的通用设置表里，键名由 [`crate::settings`] 定义：
//! - `playback.eq.enabled`：`true` / `false`
//! - `playback.eq.preamp`：dB 数字
//! - `playback.eq.bands`：10 个 dB 数字的 JSON 数组
//! - `playback.eq.preset`：预设 ID（可选，空字符串表示自定义）
//!
//! 内置预设是 **AutoEQ 风格的近似补偿曲线**，不是官方测量数据，也不代表厂商推荐值。

use lekis_playback::{EqPreset, EqSettings, BAND_COUNT, MAX_GAIN_DB, MIN_GAIN_DB};

/// 均衡器设置（给 UI / FFI 用的可序列化模型）。
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct EqualizerSettings {
    /// 是否启用。
    pub enabled: bool,
    /// 全局前级增益（dB，-12..=+12）。
    pub preamp_db: f32,
    /// 10 段增益（dB，顺序见 [`lekis_playback::BAND_FREQUENCIES_HZ`]）。
    pub bands_db: Vec<f32>,
    /// 当前选择的预设 ID；`None` 表示自定义 / 平直。
    pub preset: Option<String>,
}

impl Default for EqualizerSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            preamp_db: 0.0,
            bands_db: vec![0.0; BAND_COUNT],
            preset: None,
        }
    }
}

impl EqualizerSettings {
    /// 钳制所有增益和 preamp，保证频段数正好是 10，并清理空预设 ID。
    pub fn sanitized(mut self) -> Self {
        self.preamp_db = clamp_db(self.preamp_db);
        if !self.preamp_db.is_finite() {
            self.preamp_db = 0.0;
        }
        if self.bands_db.len() > BAND_COUNT {
            self.bands_db.truncate(BAND_COUNT);
        }
        while self.bands_db.len() < BAND_COUNT {
            self.bands_db.push(0.0);
        }
        for gain in &mut self.bands_db {
            *gain = clamp_db(*gain);
        }
        if self
            .preset
            .as_deref()
            .map(|id| id.trim().is_empty())
            .unwrap_or(true)
        {
            self.preset = None;
        } else if let Some(id) = self.preset.as_mut() {
            *id = id.trim().to_string();
        }
        self
    }

    /// 转成播放引擎的 DSP 参数。
    pub fn to_playback(&self) -> EqSettings {
        EqSettings::new(self.enabled, self.preamp_db, &self.bands_db)
    }

    /// 从播放引擎参数构造（诊断 / 回读用）。
    pub fn from_playback(settings: EqSettings, preset: Option<String>) -> Self {
        Self {
            enabled: settings.enabled,
            preamp_db: settings.preamp_db,
            bands_db: settings.bands_db.to_vec(),
            preset,
        }
    }
}

fn clamp_db(value: f32) -> f32 {
    if value.is_finite() {
        value.clamp(MIN_GAIN_DB, MAX_GAIN_DB)
    } else {
        0.0
    }
}

/// 内置预设（AutoEQ 风格近似曲线）。
pub fn presets() -> &'static [EqPreset] {
    lekis_playback::EQ_PRESETS
}

/// 按 ID 查找预设。
pub fn preset(id: &str) -> Option<&'static EqPreset> {
    lekis_playback::eq_preset(id)
}

/// 从资料库的三个原始设置值构造一份安全设置。
pub fn from_values(
    enabled: Option<&str>,
    preamp: Option<&str>,
    bands_json: Option<&str>,
    preset: Option<&str>,
) -> EqualizerSettings {
    let enabled = enabled
        .map(|value| value.trim() != "false" && value.trim() != "0")
        .unwrap_or(false);
    let preamp_db = preamp
        .and_then(|value| value.trim().parse::<f32>().ok())
        .unwrap_or(0.0);
    let bands_db = bands_json
        .and_then(|value| serde_json::from_str::<Vec<f32>>(value).ok())
        .unwrap_or_else(|| vec![0.0; BAND_COUNT]);
    EqualizerSettings {
        enabled,
        preamp_db,
        bands_db,
        preset: preset.map(str::to_string),
    }
    .sanitized()
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_clamps_and_fixes_band_count() {
        let settings = EqualizerSettings {
            enabled: true,
            preamp_db: 40.0,
            bands_db: vec![-40.0, 40.0, f32::NAN, f32::INFINITY],
            preset: Some("  ".into()),
        }
        .sanitized();
        assert_eq!(settings.preamp_db, MAX_GAIN_DB);
        assert_eq!(settings.bands_db.len(), BAND_COUNT);
        assert_eq!(settings.bands_db[0], MIN_GAIN_DB);
        assert_eq!(settings.bands_db[1], MAX_GAIN_DB);
        assert_eq!(settings.bands_db[2], 0.0);
        assert_eq!(settings.bands_db[3], 0.0);
        assert_eq!(settings.bands_db[4], 0.0);
        assert_eq!(settings.preset, None);
    }

    #[test]
    fn from_values_is_tolerant_of_bad_json_and_numbers() {
        let settings = from_values(
            Some("true"),
            Some("not-a-number"),
            Some("[1, 2, 3]"),
            Some("sennheiser-hd-600"),
        );
        assert!(settings.enabled);
        assert_eq!(settings.preamp_db, 0.0);
        assert_eq!(
            settings.bands_db,
            vec![1.0, 2.0, 3.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        );
        assert_eq!(settings.preset.as_deref(), Some("sennheiser-hd-600"));
    }

    #[test]
    fn at_least_eight_presets_are_available() {
        assert!(presets().len() >= 8);
        assert!(preset("apple-airpods-pro-2").is_some());
        assert!(preset("does-not-exist").is_none());
    }
}
