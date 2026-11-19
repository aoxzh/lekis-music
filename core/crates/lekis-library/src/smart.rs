//! 智能歌单（DIS-01）：规则模型、JSON 解析和 SQL 求值。
//!
//! 智能歌单在 `playlist` 表里是 `kind = 'smart'` 的行，规则以 JSON 存在 `rules_json` 列
//! （[`SmartRules`]）。歌单的曲目不落 `playlist_item`，而是每次求值现算：
//! [`Library::smart_playlist_tracks`]、[`Library::evaluate_smart_rules`]。
//!
//! # 规则语义
//!
//! - [`RuleGroup::All`] 是 AND，[`RuleGroup::Any`] 是 OR，[`RuleGroup::Not`] 是 NOT，可以任意嵌套；
//!   空 `All` 恒真（等于"不过滤"），空 `Any` 恒假（匹配不到任何曲目）。
//! - 比较遵循 SQL 的三值逻辑，但有两处 NULL 归一，避免"字段缺失就永远不匹配"的反直觉行为：
//!   - `Not` 生成 `NOT (COALESCE((...), 0))`：字段缺失（NULL）视为"条件不成立"，所以否定组能把
//!     "没有评分 / 没有播放记录"的曲目算进去；
//!   - 文本的 `NotContains` / `NotIn` 用 `COALESCE(列, '')` 比较：缺字段等于空串。
//!   - 其余比较（`Eq` / `Lt` / `Between`……）遇到 NULL 一律不匹配。
//! - 文本比较是字面量比较：`Eq` 用 `=`，`Contains` 用 `LIKE`（ASCII 大小写不敏感，其它字符敏感）。
//!   `Codec` 字段统一转小写比较，并且额外认 `"lossless"` / `"lossy"` 两个伪值。
//! - `Between` 用两个数字表示闭区间；单个数字表示上下界相同的区间（等价于等值比较）。
//!
//! # 安全
//!
//! - 规则里的用户输入全部走 SQL 参数绑定，不拼进 SQL 文本；表名、列名、排序、LIMIT 都来自
//!   白名单枚举（`AllowedColumns`），未知字段直接返回 [`LekisError::invalid`]。
//! - `Contains` / `NotContains` 的 `%`、`_`、`\` 会被转义，并配 `ESCAPE '\'`，所以 `%` 只当字面量。
//! - 解析和校验都不会 panic：坏 JSON、未知字段名、类型不匹配都是 `invalid` 错误。
//!
//! # `.nsp`（Navidrome 智能歌单）兼容
//!
//! [`SmartRules::parse`] 除了本模块自己的 JSON，还接受 `.nsp` 风格的简化 JSON：
//! `{"all": [...]}` / `{"any": [...]}` / `{"not": {...}}`，条件写成 `{"is": {"loved": true}}`、
//! `{"gt": {"rating": 3}}`、`{"inTheRange": {"year": [1981, 1990]}}` 这类形式。
//! 暂不支持的操作符（`inTheLast`、`startsWith`、`inPlaylist`……）返回清晰的 `invalid` 错误；
//! `name` / `comment` / `public` / `sync` / `refreshDelay` 这些元数据会被忽略。

use crate::db::DbResultExt;
use crate::playlists::{check_limit, PlaylistKind};
use crate::tracks::{map_track_row, TRACK_ROW_COLUMNS};
use crate::Library;
use lekis_types::{now_ms, LekisError, PlaylistId, Result, TrackRow, TrackSort};
use rusqlite::types::Value;
use rusqlite::{params, params_from_iter, OptionalExtension};
use serde::ser::SerializeStruct;
use serde::{de, Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Map as JsonMap, Value as JsonValue};

/// 规则里 `limit` 的上限（歌单最多这么多首；单次分页另有 `TrackQuery::MAX_LIMIT`）。
const MAX_RULES_LIMIT: u32 = 5000;

/// 单个文本 / 列表元素的最大长度（字符数）。
const MAX_TEXT_LEN: usize = 512;

/// `In` / `NotIn` 列表的最大长度。
const MAX_LIST_LEN: usize = 100;

/// 规则最大嵌套层数（防止恶意 JSON 把递归栈打爆）。
const MAX_DEPTH: u32 = 32;

// ---------------------------------------------------------------------------
// 字段、操作符、值
// ---------------------------------------------------------------------------

/// 规则可以引用的字段。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuleField {
    /// 曲目标题。
    Title,
    /// 艺人显示文字。
    Artist,
    /// 专辑名。
    Album,
    /// 流派（一首歌的多个流派用空格拼起来参与匹配）。
    Genre,
    /// 发行年份。
    Year,
    /// 时长（毫秒）。
    DurationMs,
    /// 码率（kbps）。
    BitrateKbps,
    /// 采样率（Hz）。
    SampleRate,
    /// 位深。
    BitDepth,
    /// 编码格式（`flac` / `mp3`……，另见 `"lossless"` / `"lossy"`）。
    Codec,
    /// 是否已收藏。
    Loved,
    /// 评分（1~5，没评过是 NULL）。
    Rating,
    /// 播放次数。
    PlayCount,
    /// 入库时间（Unix 毫秒）。
    AddedAt,
    /// 最后一次播放时间（Unix 毫秒）。
    LastPlayed,
    /// 统一资料库的音质分（SRC-13）。
    QualityScore,
}

impl RuleField {
    /// JSON / 错误信息里用的名字（snake_case）。
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Title => "title",
            Self::Artist => "artist",
            Self::Album => "album",
            Self::Genre => "genre",
            Self::Year => "year",
            Self::DurationMs => "duration_ms",
            Self::BitrateKbps => "bitrate_kbps",
            Self::SampleRate => "sample_rate",
            Self::BitDepth => "bit_depth",
            Self::Codec => "codec",
            Self::Loved => "loved",
            Self::Rating => "rating",
            Self::PlayCount => "play_count",
            Self::AddedAt => "added_at",
            Self::LastPlayed => "last_played",
            Self::QualityScore => "quality_score",
        }
    }

    /// 字段的值类型（决定它能配哪些操作符和值）。
    fn kind(self) -> FieldKind {
        match self {
            Self::Title | Self::Artist | Self::Album | Self::Genre | Self::Codec => FieldKind::Text,
            Self::Loved => FieldKind::Bool,
            _ => FieldKind::Number,
        }
    }
}

/// 字段的值类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FieldKind {
    /// 文本。
    Text,
    /// 整数。
    Number,
    /// 布尔。
    Bool,
}

impl FieldKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Number => "number",
            Self::Bool => "boolean",
        }
    }
}

/// 比较操作符。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuleOp {
    /// 等于。
    Eq,
    /// 不等于。
    Ne,
    /// 小于。
    Lt,
    /// 小于等于。
    Le,
    /// 大于。
    Gt,
    /// 大于等于。
    Ge,
    /// 文本包含。
    Contains,
    /// 文本不包含。
    NotContains,
    /// 在列表里。
    In,
    /// 不在列表里。
    NotIn,
    /// 在闭区间内（`[低, 高]`）。
    Between,
}

impl RuleOp {
    /// JSON / 错误信息里用的名字（snake_case）。
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Eq => "eq",
            Self::Ne => "ne",
            Self::Lt => "lt",
            Self::Le => "le",
            Self::Gt => "gt",
            Self::Ge => "ge",
            Self::Contains => "contains",
            Self::NotContains => "not_contains",
            Self::In => "in",
            Self::NotIn => "not_in",
            Self::Between => "between",
        }
    }
}

/// 规则的值。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuleValue {
    /// 单个文本。
    Text(String),
    /// 单个整数。
    Number(i64),
    /// 布尔。
    Bool(bool),
    /// 多值（`In` / `NotIn`，`Between` 时是两个数字）。
    TextList(Vec<String>),
    /// 编码格式（`"flac"` / `"lossless"`……）。
    Codec(String),
}

impl RuleValue {
    /// 错误信息里用的类型名。
    fn kind_name(&self) -> &'static str {
        match self {
            Self::Text(_) => "text",
            Self::Number(_) => "number",
            Self::Bool(_) => "boolean",
            Self::TextList(_) => "text list",
            Self::Codec(_) => "codec",
        }
    }
}

/// 一条规则：`字段 操作符 值`，例如 `rating >= 4`。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Rule {
    /// 字段。
    pub field: RuleField,
    /// 操作符。
    pub op: RuleOp,
    /// 值。
    pub value: RuleValue,
}

// ---------------------------------------------------------------------------
// 规则组
// ---------------------------------------------------------------------------

/// 规则组：AND / OR / NOT 的树，叶子是 [`Rule`]。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RuleGroup {
    /// 全部满足（空表示不过滤）。
    All(Vec<RuleGroup>),
    /// 满足任意一个（空表示匹配不到任何曲目）。
    Any(Vec<RuleGroup>),
    /// 取反。
    Not(Box<RuleGroup>),
    /// 单条规则。
    Rule(Rule),
}

impl RuleGroup {
    /// 递归校验（类型、长度、嵌套深度）。
    fn validate(&self, depth: u32) -> Result<()> {
        if depth > MAX_DEPTH {
            return Err(LekisError::invalid(format!(
                "smart playlist rules nest deeper than {MAX_DEPTH} levels"
            )));
        }
        match self {
            Self::All(groups) | Self::Any(groups) => {
                for group in groups {
                    group.validate(depth + 1)?;
                }
                Ok(())
            }
            Self::Not(inner) => inner.validate(depth + 1),
            Self::Rule(rule) => validate_rule(rule),
        }
    }
}

impl Serialize for RuleGroup {
    fn serialize<S: Serializer>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error> {
        match self {
            Self::All(groups) => {
                let mut out = serializer.serialize_struct("RuleGroupAll", 2)?;
                out.serialize_field("kind", "all")?;
                out.serialize_field("rules", groups)?;
                out.end()
            }
            Self::Any(groups) => {
                let mut out = serializer.serialize_struct("RuleGroupAny", 2)?;
                out.serialize_field("kind", "any")?;
                out.serialize_field("rules", groups)?;
                out.end()
            }
            Self::Not(inner) => {
                let mut out = serializer.serialize_struct("RuleGroupNot", 2)?;
                out.serialize_field("kind", "not")?;
                out.serialize_field("rule", inner.as_ref())?;
                out.end()
            }
            Self::Rule(rule) => {
                let mut out = serializer.serialize_struct("RuleGroupRule", 4)?;
                out.serialize_field("kind", "rule")?;
                out.serialize_field("field", &rule.field)?;
                out.serialize_field("op", &rule.op)?;
                out.serialize_field("value", &rule.value)?;
                out.end()
            }
        }
    }
}

impl<'de> Deserialize<'de> for RuleGroup {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
        let value = JsonValue::deserialize(deserializer)?;
        group_from_json(&value).map_err(de::Error::custom)
    }
}

/// 从一个 JSON 值解析规则组（本模块的 `{"kind": ...}` 形式和 `.nsp` 形式都认）。
fn group_from_json(value: &JsonValue) -> Result<RuleGroup> {
    let obj = value
        .as_object()
        .ok_or_else(|| LekisError::invalid("a smart playlist rule group must be a JSON object"))?;
    if let Some(kind_value) = obj.get("kind") {
        let kind = kind_value
            .as_str()
            .ok_or_else(|| LekisError::invalid("smart playlist \"kind\" must be a string"))?;
        return match kind {
            "all" | "and" => {
                check_keys(obj, &["kind", "rules"])?;
                Ok(RuleGroup::All(group_list(obj, "rules", kind)?))
            }
            "any" | "or" => {
                check_keys(obj, &["kind", "rules"])?;
                Ok(RuleGroup::Any(group_list(obj, "rules", kind)?))
            }
            "not" => {
                check_keys(obj, &["kind", "rule"])?;
                let inner = obj.get("rule").ok_or_else(|| {
                    LekisError::invalid("smart playlist \"not\" group needs a \"rule\" field")
                })?;
                Ok(RuleGroup::Not(Box::new(group_from_json(inner)?)))
            }
            "rule" => {
                check_keys(obj, &["kind", "field", "op", "value"])?;
                Ok(RuleGroup::Rule(rule_from_json(obj)?))
            }
            other => Err(LekisError::invalid(format!(
                "unknown smart playlist rule kind {other:?}; expected \"all\", \"any\", \"not\" or \"rule\""
            ))),
        };
    }
    // `.nsp` 风格：没有 "kind"，键就是 "all" / "is" / "gt" ……
    nsp_group_from_map(obj)
}

/// 取子组数组（`{"kind":"all","rules":[...]}`）。
fn group_list(obj: &JsonMap<String, JsonValue>, key: &str, kind: &str) -> Result<Vec<RuleGroup>> {
    let items = obj
        .get(key)
        .ok_or_else(|| LekisError::invalid(format!("smart playlist {kind:?} group needs {key:?}")))?
        .as_array()
        .ok_or_else(|| LekisError::invalid(format!("smart playlist {key:?} must be an array")))?;
    items.iter().map(group_from_json).collect()
}

/// 从 `{"kind":"rule","field":...,"op":...,"value":...}` 解析一条规则。
fn rule_from_json(obj: &JsonMap<String, JsonValue>) -> Result<Rule> {
    let field_name = obj
        .get("field")
        .and_then(JsonValue::as_str)
        .ok_or_else(|| LekisError::invalid("smart playlist rule needs a \"field\" string"))?;
    let field = rule_field(field_name)?;
    let op_name = obj
        .get("op")
        .and_then(JsonValue::as_str)
        .ok_or_else(|| LekisError::invalid("smart playlist rule needs an \"op\" string"))?;
    let op = rule_op(op_name)?;
    let value = obj
        .get("value")
        .ok_or_else(|| LekisError::invalid("smart playlist rule needs a \"value\""))?;
    let value = serde_json::from_value::<RuleValue>(value.clone()).map_err(|e| {
        LekisError::invalid(format!(
            "smart playlist rule value {value} is not a valid value: {e}"
        ))
    })?;
    Ok(Rule { field, op, value })
}

/// 只允许出现 `allowed` 里的键，防止字段名写错被静默忽略。
fn check_keys(obj: &JsonMap<String, JsonValue>, allowed: &[&str]) -> Result<()> {
    for key in obj.keys() {
        if !allowed.contains(&key.as_str()) {
            return Err(LekisError::invalid(format!(
                "unknown key {key:?} in smart playlist rule; allowed keys: {allowed:?}"
            )));
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// SmartRules
// ---------------------------------------------------------------------------

/// 一个智能歌单的完整规则。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SmartRules {
    /// 规则树。
    pub root: RuleGroup,
    /// 歌单最多多少首（`1..=5000`，`None` 表示不限）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
    /// 排序方式（`None` 按标题）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sort: Option<TrackSort>,
    /// 是否倒序。
    #[serde(default)]
    pub sort_desc: bool,
}

impl SmartRules {
    /// 解析规则 JSON。
    ///
    /// 两种格式都接受：
    /// - 本模块自己的格式：`{"root": {"kind": "all", "rules": [...]}, "limit": 100, ...}`；
    /// - `.nsp`（Navidrome）风格：`{"all": [{"is": {"loved": true}}], "sort": "title", ...}`。
    ///
    /// JSON 语法错误、未知字段 / 操作符、类型不匹配都返回 [`LekisError::invalid`]，不 panic。
    pub fn parse(json: &str) -> Result<Self> {
        let value: JsonValue = serde_json::from_str(json)
            .map_err(|e| LekisError::invalid(format!("invalid smart playlist JSON: {e}")))?;
        let canonical = value
            .as_object()
            .map(|obj| obj.contains_key("root"))
            .unwrap_or(false);
        let rules = if canonical {
            serde_json::from_value::<Self>(value)
                .map_err(|e| LekisError::invalid(format!("invalid smart playlist rules: {e}")))?
        } else {
            Self::from_nsp_json(&value)?
        };
        rules.validate()?;
        Ok(rules)
    }

    /// 序列化成 JSON（存 `playlist.rules_json` 用）。
    pub fn to_json(&self) -> Result<String> {
        serde_json::to_string(self).map_err(|e| {
            LekisError::internal(format!("failed to serialize smart playlist rules: {e}"))
        })
    }

    /// 校验规则：`limit` 范围、文本长度、值类型与字段 / 操作符是否相容、嵌套深度。
    pub fn validate(&self) -> Result<()> {
        if let Some(limit) = self.limit {
            if limit == 0 || limit > MAX_RULES_LIMIT {
                return Err(LekisError::invalid(format!(
                    "smart playlist limit must be 1..={MAX_RULES_LIMIT}"
                )));
            }
        }
        self.root.validate(0)
    }

    /// 求值：把规则树转成 WHERE 片段和参数。
    ///
    /// 返回的 SQL 片段只用 `?1`、`?2`…… 占位符，参数从 1 开始顺次编号；调用方追加
    /// `LIMIT` / `OFFSET` 参数时从 `args.len() + 1` 开始数。
    pub fn to_sql(&self, allowed: &AllowedColumns) -> Result<(String, Vec<Value>)> {
        let mut fragment = SqlFragment::new();
        group_sql(&self.root, allowed, &mut fragment)?;
        Ok((fragment.sql, fragment.args))
    }

    /// `.nsp` 风格 JSON → [`SmartRules`]。
    fn from_nsp_json(value: &JsonValue) -> Result<Self> {
        let obj = value
            .as_object()
            .ok_or_else(|| LekisError::invalid("smart playlist JSON must be a JSON object"))?;
        let mut rule_map = JsonMap::new();
        let mut limit = None;
        let mut sort = None;
        let mut sort_desc = false;
        for (key, val) in obj {
            match key.as_str() {
                "limit" => limit = Some(nsp_u32(val, "limit")?),
                "limitPercent" => {
                    return Err(LekisError::invalid(
                        "smart playlist \"limitPercent\" is not supported yet; use \"limit\"",
                    ))
                }
                "sort" => sort = Some(nsp_sort(val)?),
                "order" => sort_desc = nsp_order(val)?,
                // `.nsp` 的元数据，对求值没有影响。
                "name" | "comment" | "public" | "sync" | "refreshDelay" => {}
                _ => {
                    rule_map.insert(key.clone(), val.clone());
                }
            }
        }
        let root = nsp_group_from_map(&rule_map)?;
        Ok(Self {
            root,
            limit,
            sort,
            sort_desc,
        })
    }
}

// ---------------------------------------------------------------------------
// `.nsp` / 字段名 / 操作符名
// ---------------------------------------------------------------------------

/// 把 JSON 里的字段名映射成 [`RuleField`]（大小写、下划线、空格都不敏感）。
fn rule_field(name: &str) -> Result<RuleField> {
    let key = normalize_name(name);
    let field = match key.as_str() {
        "title" | "sorttitle" => RuleField::Title,
        "artist" | "albumartist" | "sortartist" | "sortalbumartist" => RuleField::Artist,
        "album" | "sortalbum" => RuleField::Album,
        "genre" => RuleField::Genre,
        "year" | "originalyear" | "releaseyear" => RuleField::Year,
        "duration" | "durationms" => RuleField::DurationMs,
        "bitrate" | "bitratekbps" => RuleField::BitrateKbps,
        "samplerate" => RuleField::SampleRate,
        "bitdepth" => RuleField::BitDepth,
        "codec" | "filetype" => RuleField::Codec,
        "loved" | "albumloved" => RuleField::Loved,
        "rating" | "albumrating" | "averagerating" => RuleField::Rating,
        "playcount" | "albumplaycount" => RuleField::PlayCount,
        "dateadded" | "addedat" | "albumdateadded" => RuleField::AddedAt,
        "lastplayed" | "albumlastplayed" => RuleField::LastPlayed,
        "qualityscore" => RuleField::QualityScore,
        _ => {
            return Err(LekisError::invalid(format!(
                "unknown smart playlist field {name:?}; expected one of {}",
                ALL_FIELD_NAMES.join(", ")
            )))
        }
    };
    Ok(field)
}

/// 所有字段名（拼错误信息用）。
const ALL_FIELD_NAMES: &[&str] = &[
    "title",
    "artist",
    "album",
    "genre",
    "year",
    "duration_ms",
    "bitrate_kbps",
    "sample_rate",
    "bit_depth",
    "codec",
    "loved",
    "rating",
    "play_count",
    "added_at",
    "last_played",
    "quality_score",
];

/// 把 JSON 里的操作符名映射成 [`RuleOp`]（大小写、下划线都不敏感）。
fn rule_op(name: &str) -> Result<RuleOp> {
    let key = normalize_name(name);
    let op = match key.as_str() {
        "is" | "eq" => RuleOp::Eq,
        "isnot" | "ne" => RuleOp::Ne,
        "lt" => RuleOp::Lt,
        "le" | "lte" => RuleOp::Le,
        "gt" => RuleOp::Gt,
        "ge" | "gte" => RuleOp::Ge,
        "contains" => RuleOp::Contains,
        "notcontains" => RuleOp::NotContains,
        "in" => RuleOp::In,
        "notin" => RuleOp::NotIn,
        "between" | "intherange" => RuleOp::Between,
        _ => {
            if UNSUPPORTED_NSP_OPS.contains(&key.as_str()) {
                return Err(LekisError::invalid(format!(
                    "smart playlist operator {name:?} is not supported yet"
                )));
            }
            return Err(LekisError::invalid(format!(
                "unknown smart playlist operator {name:?}"
            )));
        }
    };
    Ok(op)
}

/// 认识但暂不支持的 `.nsp` 操作符（报"还不支持"而不是"不认识"）。
const UNSUPPORTED_NSP_OPS: &[&str] = &[
    "inthelast",
    "notinthelast",
    "startswith",
    "endswith",
    "inplaylist",
    "notinplaylist",
    "before",
    "after",
    "earlierthan",
];

/// 小写 + 去掉下划线和空格，用于字段名 / 操作符名的模糊对照。
fn normalize_name(name: &str) -> String {
    name.trim()
        .chars()
        .filter(|c| *c != '_' && *c != ' ' && *c != '-')
        .flat_map(char::to_lowercase)
        .collect()
}

/// `.nsp` 风格的规则组：`{"all": [...]}` / `{"is": {...}}` 等。
fn nsp_group_from_map(obj: &JsonMap<String, JsonValue>) -> Result<RuleGroup> {
    let mut logical: Option<RuleGroup> = None;
    let mut conditions: Vec<RuleGroup> = Vec::new();
    for (key, value) in obj {
        let normalized = normalize_name(key);
        let group = match normalized.as_str() {
            "all" | "and" => Some(RuleGroup::All(nsp_group_list(value, key)?)),
            "any" | "or" => Some(RuleGroup::Any(nsp_group_list(value, key)?)),
            "not" => Some(RuleGroup::Not(Box::new(group_from_json(value)?))),
            _ => None,
        };
        if let Some(group) = group {
            if logical.is_some() {
                return Err(LekisError::invalid(
                    "only one of \"all\" / \"any\" / \"not\" is allowed at the same level",
                ));
            }
            logical = Some(group);
            continue;
        }
        let op = rule_op(key)?;
        conditions.extend(nsp_rules_for_op(op, key, value)?);
    }
    match (logical, conditions.len()) {
        (Some(group), 0) => Ok(group),
        (None, 0) => Err(LekisError::invalid(
            "smart playlist rule group is empty; expected \"all\", \"any\" or a condition",
        )),
        (None, 1) => Ok(conditions.remove(0)),
        (None, _) => Ok(RuleGroup::All(conditions)),
        (Some(_), _) => Err(LekisError::invalid(
            "smart playlist conditions cannot be mixed with \"all\" / \"any\" / \"not\" at the same level",
        )),
    }
}

/// `.nsp` 里的子组数组。
fn nsp_group_list(value: &JsonValue, key: &str) -> Result<Vec<RuleGroup>> {
    let items = value
        .as_array()
        .ok_or_else(|| LekisError::invalid(format!("smart playlist {key:?} must be an array")))?;
    items.iter().map(group_from_json).collect()
}

/// `.nsp` 的 `{"<op>": {"<field>": <value>}}`，多字段时按 AND 组合。
fn nsp_rules_for_op(op: RuleOp, op_key: &str, value: &JsonValue) -> Result<Vec<RuleGroup>> {
    let obj = value.as_object().ok_or_else(|| {
        LekisError::invalid(format!(
            "smart playlist operator {op_key:?} needs an object of field → value"
        ))
    })?;
    let mut rules = Vec::with_capacity(obj.len());
    for (field_name, raw) in obj {
        let field = rule_field(field_name)?;
        let value = nsp_value(field, op, raw)?;
        rules.push(RuleGroup::Rule(Rule { field, op, value }));
    }
    if rules.is_empty() {
        return Err(LekisError::invalid(format!(
            "smart playlist operator {op_key:?} has no fields"
        )));
    }
    Ok(rules)
}

/// `.nsp` 的值 → [`RuleValue`]（按字段类型和操作符决定形状）。
fn nsp_value(field: RuleField, op: RuleOp, raw: &JsonValue) -> Result<RuleValue> {
    match field.kind() {
        FieldKind::Bool => match raw {
            JsonValue::Bool(value) => Ok(RuleValue::Bool(*value)),
            JsonValue::Number(number) => match number.as_i64() {
                Some(0) => Ok(RuleValue::Bool(false)),
                Some(1) => Ok(RuleValue::Bool(true)),
                _ => Err(LekisError::invalid(format!(
                    "smart playlist field {:?} needs a boolean, got {raw}",
                    field.as_str()
                ))),
            },
            _ => Err(LekisError::invalid(format!(
                "smart playlist field {:?} needs a boolean, got {raw}",
                field.as_str()
            ))),
        },
        FieldKind::Number => match op {
            RuleOp::Between => {
                let items = raw.as_array().ok_or_else(|| {
                    LekisError::invalid(format!(
                        "smart playlist field {:?} with \"inTheRange\" needs [low, high]",
                        field.as_str()
                    ))
                })?;
                let [low_raw, high_raw] = items.as_slice() else {
                    return Err(LekisError::invalid(format!(
                        "smart playlist field {:?} with \"inTheRange\" needs exactly two numbers",
                        field.as_str()
                    )));
                };
                let low = nsp_number(low_raw, field)?;
                let high = nsp_number(high_raw, field)?;
                Ok(RuleValue::TextList(vec![low.to_string(), high.to_string()]))
            }
            RuleOp::In | RuleOp::NotIn => {
                let items = raw.as_array().ok_or_else(|| {
                    LekisError::invalid(format!(
                        "smart playlist field {:?} with {:?} needs an array",
                        field.as_str(),
                        op.as_str()
                    ))
                })?;
                let mut values = Vec::with_capacity(items.len());
                for item in items {
                    values.push(nsp_number(item, field)?.to_string());
                }
                Ok(RuleValue::TextList(values))
            }
            _ => Ok(RuleValue::Number(nsp_number(raw, field)?)),
        },
        FieldKind::Text => match op {
            RuleOp::In | RuleOp::NotIn => {
                let items = raw.as_array().ok_or_else(|| {
                    LekisError::invalid(format!(
                        "smart playlist field {:?} with {:?} needs an array of strings",
                        field.as_str(),
                        op.as_str()
                    ))
                })?;
                let mut values = Vec::with_capacity(items.len());
                for item in items {
                    let text = item.as_str().ok_or_else(|| {
                        LekisError::invalid(format!(
                            "smart playlist field {:?} needs strings, got {item}",
                            field.as_str()
                        ))
                    })?;
                    values.push(text.to_string());
                }
                Ok(RuleValue::TextList(values))
            }
            RuleOp::Between => Err(LekisError::invalid(format!(
                "smart playlist field {:?} is text; \"inTheRange\" needs a numeric field",
                field.as_str()
            ))),
            _ => {
                let text = raw.as_str().ok_or_else(|| {
                    LekisError::invalid(format!(
                        "smart playlist field {:?} needs a string, got {raw}",
                        field.as_str()
                    ))
                })?;
                if field == RuleField::Codec {
                    Ok(RuleValue::Codec(text.to_string()))
                } else {
                    Ok(RuleValue::Text(text.to_string()))
                }
            }
        },
    }
}

/// `.nsp` 里的整数（JSON 数字或数字字符串）。
fn nsp_number(raw: &JsonValue, field: RuleField) -> Result<i64> {
    if let Some(number) = raw.as_i64() {
        return Ok(number);
    }
    if let Some(text) = raw.as_str() {
        if let Ok(number) = text.trim().parse::<i64>() {
            return Ok(number);
        }
    }
    Err(LekisError::invalid(format!(
        "smart playlist field {:?} needs a number, got {raw}",
        field.as_str()
    )))
}

/// `.nsp` 的 `limit`。
fn nsp_u32(raw: &JsonValue, key: &str) -> Result<u32> {
    let number = raw
        .as_u64()
        .ok_or_else(|| LekisError::invalid(format!("smart playlist {key:?} must be a number")))?;
    u32::try_from(number)
        .map_err(|_| LekisError::invalid(format!("smart playlist {key:?} is too large")))
}

/// `.nsp` 的 `sort` → [`TrackSort`]。
fn nsp_sort(raw: &JsonValue) -> Result<TrackSort> {
    let name = raw
        .as_str()
        .ok_or_else(|| LekisError::invalid("smart playlist \"sort\" must be a string"))?;
    let key = normalize_name(name);
    let sort = match key.as_str() {
        "title" => TrackSort::Title,
        "artist" | "albumartist" => TrackSort::Artist,
        "album" => TrackSort::Album,
        "dateadded" | "recentlyadded" | "albumdateadded" => TrackSort::RecentlyAdded,
        "playcount" | "mostplayed" => TrackSort::MostPlayed,
        _ => {
            return Err(LekisError::invalid(format!(
                "smart playlist sort {name:?} is not supported; expected title, artist, album, \
                 dateAdded, recentlyAdded, playCount or mostPlayed"
            )))
        }
    };
    Ok(sort)
}

/// `.nsp` 的 `order` → 是否倒序。
fn nsp_order(raw: &JsonValue) -> Result<bool> {
    let name = raw
        .as_str()
        .ok_or_else(|| LekisError::invalid("smart playlist \"order\" must be a string"))?;
    match normalize_name(name).as_str() {
        "desc" | "descending" => Ok(true),
        "asc" | "ascending" => Ok(false),
        _ => Err(LekisError::invalid(format!(
            "smart playlist order {name:?} is not supported; expected \"asc\" or \"desc\""
        ))),
    }
}

// ---------------------------------------------------------------------------
// 规则校验
// ---------------------------------------------------------------------------

/// 校验一条规则的值类型和长度。
fn validate_rule(rule: &Rule) -> Result<()> {
    match &rule.value {
        RuleValue::Text(text) | RuleValue::Codec(text) => validate_text(rule.field, text)?,
        RuleValue::TextList(items) => {
            if items.len() > MAX_LIST_LEN {
                return Err(LekisError::invalid(format!(
                    "smart playlist list for field {:?} has {} items; at most {MAX_LIST_LEN} allowed",
                    rule.field.as_str(),
                    items.len()
                )));
            }
            for item in items {
                validate_text(rule.field, item)?;
            }
        }
        RuleValue::Number(_) | RuleValue::Bool(_) => {}
    }

    let kind = rule.field.kind();
    let mismatch = || {
        Err(LekisError::invalid(format!(
            "smart playlist rule {:?} {} {} is not allowed",
            rule.field.as_str(),
            rule.op.as_str(),
            rule.value.kind_name()
        )))
    };
    match rule.op {
        RuleOp::Contains | RuleOp::NotContains => match &rule.value {
            RuleValue::Text(_) => Ok(()),
            _ => mismatch(),
        },
        RuleOp::In | RuleOp::NotIn => match &rule.value {
            RuleValue::TextList(_) => Ok(()),
            _ => mismatch(),
        },
        RuleOp::Between => {
            if kind != FieldKind::Number {
                return Err(LekisError::invalid(format!(
                    "smart playlist rule \"between\" needs a numeric field, {:?} is {}",
                    rule.field.as_str(),
                    kind.as_str()
                )));
            }
            match &rule.value {
                RuleValue::Number(_) => Ok(()),
                RuleValue::TextList(items) if items.len() == 2 => {
                    for item in items {
                        if item.trim().parse::<i64>().is_err() {
                            return Err(LekisError::invalid(format!(
                                "smart playlist rule \"between\" needs two numbers, got {item:?}"
                            )));
                        }
                    }
                    Ok(())
                }
                _ => mismatch(),
            }
        }
        RuleOp::Lt | RuleOp::Le | RuleOp::Gt | RuleOp::Ge => match &rule.value {
            RuleValue::Number(_) if kind == FieldKind::Number => Ok(()),
            _ => mismatch(),
        },
        RuleOp::Eq | RuleOp::Ne => match (kind, &rule.value) {
            (FieldKind::Bool, RuleValue::Bool(_)) => Ok(()),
            (FieldKind::Number, RuleValue::Number(_)) => Ok(()),
            (FieldKind::Text, RuleValue::Text(_)) => Ok(()),
            (FieldKind::Text, RuleValue::Codec(_)) if rule.field == RuleField::Codec => Ok(()),
            _ => mismatch(),
        },
    }
}

/// 文本长度校验（按字符数，不是字节数）。
fn validate_text(field: RuleField, text: &str) -> Result<()> {
    let len = text.chars().count();
    if len > MAX_TEXT_LEN {
        return Err(LekisError::invalid(format!(
            "smart playlist text for field {:?} is {len} characters; at most {MAX_TEXT_LEN} allowed",
            field.as_str()
        )));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// 白名单列
// ---------------------------------------------------------------------------

/// 规则可以引用的 SQL 表达式白名单。
///
/// 字段名永远只会映射成这里的常量表达式，不会变成用户提供的 SQL 片段。
/// [`SmartRules::to_sql`] 用它把规则翻译成 SQL：不在白名单里的字段直接返回
/// [`LekisError::invalid`]，所以即使以后规则里加了新字段，旧代码也不会拼出未知列。
#[derive(Debug, Clone)]
pub struct AllowedColumns {
    columns: Vec<(RuleField, &'static str)>,
}

impl AllowedColumns {
    /// 标准白名单（覆盖 [`RuleField`] 的全部字段）。
    pub fn standard() -> Self {
        Self {
            columns: vec![
                (RuleField::Title, "t.title"),
                (RuleField::Artist, "t.artist_line"),
                (RuleField::Album, "a.title"),
                (RuleField::Genre, GENRE_SQL),
                (RuleField::Year, "t.year"),
                (RuleField::DurationMs, "t.duration_ms"),
                (RuleField::BitrateKbps, BITRATE_SQL),
                (RuleField::SampleRate, SAMPLE_RATE_SQL),
                (RuleField::BitDepth, BIT_DEPTH_SQL),
                (RuleField::Codec, CODEC_SQL),
                (RuleField::Loved, "COALESCE(u.loved, 0)"),
                (RuleField::Rating, "u.rating"),
                (RuleField::PlayCount, "COALESCE(u.play_count, 0)"),
                (RuleField::AddedAt, "t.created_at"),
                (RuleField::LastPlayed, "u.last_played"),
                (RuleField::QualityScore, QUALITY_SCORE_SQL),
            ],
        }
    }

    /// 取字段对应的表达式；不在白名单里返回 `None`。
    pub(crate) fn get(&self, field: RuleField) -> Option<&'static str> {
        self.columns
            .iter()
            .find(|(candidate, _)| *candidate == field)
            .map(|(_, sql)| *sql)
    }

    /// 去掉一个字段（测试"未知字段"分支用）。
    pub fn without(mut self, field: RuleField) -> Self {
        self.columns.retain(|(candidate, _)| *candidate != field);
        self
    }
}

/// 生成"最佳文件"（`quality_score` 最高的那个文件）的相关子查询。
macro_rules! best_file_expr {
    ($body:literal) => {
        concat!(
            "(SELECT ",
            $body,
            " FROM track_file tf JOIN file f ON f.id = tf.file_id",
            " WHERE tf.track_id = t.id AND f.audio_json IS NOT NULL",
            " ORDER BY tf.quality_score DESC LIMIT 1)"
        )
    };
}

/// 一首歌的所有流派拼成一个空格分隔的文本（`Contains` 匹配"包含这个流派"）。
const GENRE_SQL: &str = "(SELECT group_concat(g.name, ' ') FROM track_genre tg \
     JOIN genre g ON g.id = tg.genre_id WHERE tg.track_id = t.id)";

/// 码率（kbps），取自最佳文件的 `audio_json`。
const BITRATE_SQL: &str = best_file_expr!(
    "CASE WHEN json_valid(f.audio_json) THEN json_extract(f.audio_json, '$.bitrate_kbps') END"
);

/// 采样率（Hz），取自最佳文件的 `audio_json`。
const SAMPLE_RATE_SQL: &str = best_file_expr!(
    "CASE WHEN json_valid(f.audio_json) THEN json_extract(f.audio_json, '$.sample_rate') END"
);

/// 位深，取自最佳文件的 `audio_json`。
const BIT_DEPTH_SQL: &str = best_file_expr!(
    "CASE WHEN json_valid(f.audio_json) THEN json_extract(f.audio_json, '$.bit_depth') END"
);

/// 编码格式，取自最佳文件的 `audio_json`（`Codec::Other` 序列化成 `{"other":"..."}`）。
const CODEC_SQL: &str = best_file_expr!(
    "CASE WHEN json_valid(f.audio_json) THEN
        COALESCE(json_extract(f.audio_json, '$.codec.other'), json_extract(f.audio_json, '$.codec'))
     END"
);

/// 音质分（最佳文件的 `track_file.quality_score`）。
const QUALITY_SCORE_SQL: &str =
    "(SELECT tf.quality_score FROM track_file tf WHERE tf.track_id = t.id
      ORDER BY tf.quality_score DESC LIMIT 1)";

/// 无损编码（`Codec::is_lossless` 对应的 snake_case 名字）。
const LOSSLESS_CODECS: &[&str] = &[
    "alac", "flac", "wav", "aiff", "ape", "wavpack", "tta", "dsd",
];

// ---------------------------------------------------------------------------
// SQL 生成
// ---------------------------------------------------------------------------

/// WHERE 片段 + 绑定参数。
struct SqlFragment {
    sql: String,
    args: Vec<Value>,
}

impl SqlFragment {
    fn new() -> Self {
        Self {
            sql: String::new(),
            args: Vec::new(),
        }
    }

    /// 绑定一个参数，返回 `?N` 占位符文本。
    fn bind(&mut self, value: Value) -> String {
        self.args.push(value);
        format!("?{}", self.args.len())
    }

    fn bind_i64(&mut self, value: i64) -> String {
        self.bind(Value::Integer(value))
    }

    fn bind_text(&mut self, value: &str) -> String {
        self.bind(Value::Text(value.to_string()))
    }
}

/// 规则组 → SQL（每个子句自己带括号，优先级不依赖外部上下文）。
fn group_sql(group: &RuleGroup, allowed: &AllowedColumns, out: &mut SqlFragment) -> Result<()> {
    match group {
        RuleGroup::All(groups) => {
            if groups.is_empty() {
                out.sql.push('1');
                return Ok(());
            }
            join_groups(groups, " AND ", allowed, out)
        }
        RuleGroup::Any(groups) => {
            if groups.is_empty() {
                out.sql.push('0');
                return Ok(());
            }
            join_groups(groups, " OR ", allowed, out)
        }
        RuleGroup::Not(inner) => {
            // COALESCE(..., 0)：子条件因为字段缺失而变成 NULL 时算"不成立"，取反后才算成立。
            out.sql.push_str("NOT (COALESCE((");
            group_sql(inner, allowed, out)?;
            out.sql.push_str("), 0))");
            Ok(())
        }
        RuleGroup::Rule(rule) => rule_sql(rule, allowed, out),
    }
}

/// 用 `joiner` 把子组连起来，整体加一对括号。
fn join_groups(
    groups: &[RuleGroup],
    joiner: &str,
    allowed: &AllowedColumns,
    out: &mut SqlFragment,
) -> Result<()> {
    out.sql.push('(');
    for (index, group) in groups.iter().enumerate() {
        if index > 0 {
            out.sql.push_str(joiner);
        }
        out.sql.push('(');
        group_sql(group, allowed, out)?;
        out.sql.push(')');
    }
    out.sql.push(')');
    Ok(())
}

/// 一条规则 → SQL。
fn rule_sql(rule: &Rule, allowed: &AllowedColumns, out: &mut SqlFragment) -> Result<()> {
    validate_rule(rule)?;
    let column = allowed.get(rule.field).ok_or_else(|| {
        LekisError::invalid(format!(
            "smart playlist field {:?} is not allowed in this query",
            rule.field.as_str()
        ))
    })?;
    match rule.op {
        RuleOp::Eq | RuleOp::Ne => eq_sql(rule, column, out),
        RuleOp::Lt | RuleOp::Le | RuleOp::Gt | RuleOp::Ge => cmp_sql(rule, column, out),
        RuleOp::Contains | RuleOp::NotContains => like_sql(rule, column, out),
        RuleOp::In | RuleOp::NotIn => in_sql(rule, column, out),
        RuleOp::Between => between_sql(rule, column, out),
    }
}

/// `Eq` / `Ne`。
fn eq_sql(rule: &Rule, column: &str, out: &mut SqlFragment) -> Result<()> {
    let negated = rule.op == RuleOp::Ne;
    let operator = if negated { "<>" } else { "=" };
    match &rule.value {
        RuleValue::Bool(value) => {
            let placeholder = out.bind_i64(i64::from(*value));
            out.sql
                .push_str(&format!("{column} {operator} {placeholder}"));
            Ok(())
        }
        RuleValue::Number(value) => {
            let placeholder = out.bind_i64(*value);
            out.sql
                .push_str(&format!("{column} {operator} {placeholder}"));
            Ok(())
        }
        RuleValue::Codec(codec) => codec_sql(column, codec, negated, out),
        RuleValue::Text(text) if rule.field == RuleField::Codec => {
            codec_sql(column, text, negated, out)
        }
        RuleValue::Text(text) => {
            let placeholder = out.bind_text(text);
            if negated {
                out.sql
                    .push_str(&format!("COALESCE({column}, '') <> {placeholder}"));
            } else {
                out.sql.push_str(&format!("{column} = {placeholder}"));
            }
            Ok(())
        }
        RuleValue::TextList(_) => Err(LekisError::invalid(
            "smart playlist rule eq/ne needs a single value; use in/not_in for lists",
        )),
    }
}

/// 编码格式比较：转小写，并支持 `"lossless"` / `"lossy"` 两个伪值。
fn codec_sql(column: &str, raw: &str, negated: bool, out: &mut SqlFragment) -> Result<()> {
    let name = raw.trim().to_lowercase();
    if name.is_empty() {
        return Err(LekisError::invalid(
            "smart playlist codec value must not be empty",
        ));
    }
    match name.as_str() {
        "lossless" | "lossy" => {
            let lossy = name == "lossy";
            let values = LOSSLESS_CODECS
                .iter()
                .map(|codec| Value::Text((*codec).to_string()))
                .collect::<Vec<_>>();
            let placeholders = bind_placeholders(out, values);
            // `positive` 始终表示"编码匹配这个名字"，`ne` 再整体取反。
            let positive = if lossy {
                format!("({column} IS NOT NULL AND LOWER({column}) NOT IN {placeholders})")
            } else {
                format!("(LOWER({column}) IN {placeholders})")
            };
            if negated {
                out.sql.push_str("NOT ");
            }
            out.sql.push_str(&positive);
            Ok(())
        }
        _ => {
            let placeholder = out.bind_text(&name);
            if negated {
                out.sql
                    .push_str(&format!("COALESCE(LOWER({column}), '') <> {placeholder}"));
            } else {
                out.sql
                    .push_str(&format!("LOWER({column}) = {placeholder}"));
            }
            Ok(())
        }
    }
}

/// `Lt` / `Le` / `Gt` / `Ge`。
fn cmp_sql(rule: &Rule, column: &str, out: &mut SqlFragment) -> Result<()> {
    let RuleValue::Number(value) = &rule.value else {
        return Err(LekisError::invalid(format!(
            "smart playlist rule {} needs a number",
            rule.op.as_str()
        )));
    };
    let symbol = match rule.op {
        RuleOp::Lt => "<",
        RuleOp::Le => "<=",
        RuleOp::Gt => ">",
        _ => ">=",
    };
    let placeholder = out.bind_i64(*value);
    out.sql
        .push_str(&format!("{column} {symbol} {placeholder}"));
    Ok(())
}

/// `Contains` / `NotContains`：`%`、`_`、`\` 转义后用 `ESCAPE '\'`。
fn like_sql(rule: &Rule, column: &str, out: &mut SqlFragment) -> Result<()> {
    let RuleValue::Text(text) = &rule.value else {
        return Err(LekisError::invalid(format!(
            "smart playlist rule {} needs a text value",
            rule.op.as_str()
        )));
    };
    let pattern = escape_like(text);
    let placeholder = out.bind_text(&pattern);
    if rule.op == RuleOp::NotContains {
        out.sql.push_str(&format!(
            "COALESCE({column}, '') NOT LIKE '%' || {placeholder} || '%' ESCAPE '\\'"
        ));
    } else {
        out.sql.push_str(&format!(
            "{column} LIKE '%' || {placeholder} || '%' ESCAPE '\\'"
        ));
    }
    Ok(())
}

/// 把 `LIKE` 的通配符转义成字面量。
fn escape_like(input: &str) -> String {
    let mut escaped = String::with_capacity(input.len());
    for ch in input.chars() {
        if matches!(ch, '\\' | '%' | '_') {
            escaped.push('\\');
        }
        escaped.push(ch);
    }
    escaped
}

/// `In` / `NotIn`。
fn in_sql(rule: &Rule, column: &str, out: &mut SqlFragment) -> Result<()> {
    let RuleValue::TextList(items) = &rule.value else {
        return Err(LekisError::invalid(format!(
            "smart playlist rule {} needs a list of values",
            rule.op.as_str()
        )));
    };
    let negated = rule.op == RuleOp::NotIn;
    if items.is_empty() {
        // 空列表：in 匹配不到任何曲目，not_in 匹配全部。
        out.sql.push(if negated { '1' } else { '0' });
        return Ok(());
    }
    let numeric = rule.field.kind() == FieldKind::Number;
    let mut values = Vec::with_capacity(items.len());
    for item in items {
        if numeric {
            let number = item.trim().parse::<i64>().map_err(|_| {
                LekisError::invalid(format!(
                    "smart playlist field {:?} needs numbers, got {item:?}",
                    rule.field.as_str()
                ))
            })?;
            values.push(Value::Integer(number));
        } else if rule.field == RuleField::Codec {
            values.push(Value::Text(item.trim().to_lowercase()));
        } else {
            values.push(Value::Text(item.clone()));
        }
    }
    let placeholders = bind_placeholders(out, values);
    let left = match rule.field {
        RuleField::Codec if negated => format!("LOWER(COALESCE({column}, ''))"),
        RuleField::Codec => format!("LOWER({column})"),
        _ if numeric => column.to_string(),
        _ if negated => format!("COALESCE({column}, '')"),
        _ => column.to_string(),
    };
    let operator = if negated { "NOT IN" } else { "IN" };
    out.sql
        .push_str(&format!("{left} {operator} {placeholders}"));
    Ok(())
}

/// `Between`。
fn between_sql(rule: &Rule, column: &str, out: &mut SqlFragment) -> Result<()> {
    let (low, high) = match &rule.value {
        RuleValue::Number(value) => (*value, *value),
        RuleValue::TextList(items) => match items.as_slice() {
            [low, high] => (bound_number(low)?, bound_number(high)?),
            _ => {
                return Err(LekisError::invalid(
                    "smart playlist rule \"between\" needs two numbers",
                ))
            }
        },
        _ => {
            return Err(LekisError::invalid(
                "smart playlist rule \"between\" needs two numbers",
            ))
        }
    };
    let low_placeholder = out.bind_i64(low);
    let high_placeholder = out.bind_i64(high);
    out.sql.push_str(&format!(
        "{column} BETWEEN {low_placeholder} AND {high_placeholder}"
    ));
    Ok(())
}

/// 把区间边界解析成整数（`Between` 的文本形式，例如 `.nsp` 的 `[1981, 1990]`）。
fn bound_number(raw: &str) -> Result<i64> {
    raw.trim().parse::<i64>().map_err(|_| {
        LekisError::invalid(format!(
            "smart playlist rule \"between\" needs two numbers, got {raw:?}"
        ))
    })
}

/// 绑定一组参数，返回 `(?1, ?2, ...)`。
fn bind_placeholders(out: &mut SqlFragment, values: Vec<Value>) -> String {
    let mut placeholders = String::from("(");
    for (index, value) in values.into_iter().enumerate() {
        if index > 0 {
            placeholders.push_str(", ");
        }
        placeholders.push_str(&out.bind(value));
    }
    placeholders.push(')');
    placeholders
}

/// 排序 SQL（和 `tracks.rs` 的 `list_track_rows` 用同一套排序键）。
fn order_sql(rules: &SmartRules) -> &'static str {
    match (rules.sort.unwrap_or_default(), rules.sort_desc) {
        (TrackSort::Title, false) => "t.title_sort_key, t.id",
        (TrackSort::Title, true) => "t.title_sort_key DESC, t.id DESC",
        (TrackSort::Artist, false) => "t.artist_line, a.title, t.disc_no, t.track_no",
        (TrackSort::Artist, true) => {
            "t.artist_line DESC, a.title DESC, t.disc_no DESC, t.track_no DESC"
        }
        (TrackSort::Album, false) => "a.title, t.disc_no, t.track_no",
        (TrackSort::Album, true) => "a.title DESC, t.disc_no DESC, t.track_no DESC",
        (TrackSort::RecentlyAdded, false) => "t.created_at, t.id",
        (TrackSort::RecentlyAdded, true) => "t.created_at DESC, t.id DESC",
        (TrackSort::MostPlayed, false) => "COALESCE(u.play_count, 0), t.id",
        (TrackSort::MostPlayed, true) => "COALESCE(u.play_count, 0) DESC, t.id DESC",
    }
}

// ---------------------------------------------------------------------------
// Library 方法
// ---------------------------------------------------------------------------

impl Library {
    /// 求值一个智能歌单，返回一页曲目。
    ///
    /// 规则从 `playlist.rules_json` 读；歌单不存在返回 [`LekisError::not_found`]，歌单没有规则
    /// （不是智能歌单，或者规则是坏的）返回 [`LekisError::invalid`]。
    /// `limit` 必须在 `1..=TrackQuery::MAX_LIMIT`。
    pub async fn smart_playlist_tracks(
        &self,
        id: PlaylistId,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<TrackRow>> {
        check_limit(limit)?;
        let rules = self.playlist_rules(id).await?.ok_or_else(|| {
            LekisError::invalid(format!("playlist {id} has no smart playlist rules"))
        })?;
        self.evaluate_smart_rules(&rules, offset, limit).await
    }

    /// 按规则求值一曲目（不落库，供预览 / 试算用）。
    ///
    /// `limit` 必须在 `1..=TrackQuery::MAX_LIMIT`；规则自己的 `limit` 是歌单总长上限，
    /// 两者取交集（`offset + limit` 超出规则上限时返回空）。
    pub async fn evaluate_smart_rules(
        &self,
        rules: &SmartRules,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<TrackRow>> {
        check_limit(limit)?;
        rules.validate()?;
        let (where_sql, mut args) = rules.to_sql(&AllowedColumns::standard())?;

        // 规则自己的 limit 是"歌单总共多少首"，分页不能越过它。
        let cap = rules.limit.map_or(u64::MAX, u64::from);
        let start = u64::from(offset);
        if start >= cap {
            return Ok(Vec::new());
        }
        let take = u64::from(limit).min(cap - start);

        let sql = format!(
            "SELECT {TRACK_ROW_COLUMNS}
             FROM track t
             LEFT JOIN album a ON a.id = t.album_id
             LEFT JOIN user_state u ON u.track_uid = t.uid
             WHERE {where_sql}
             ORDER BY {}
             LIMIT ?{} OFFSET ?{}",
            order_sql(rules),
            args.len() + 1,
            args.len() + 2
        );
        args.push(Value::Integer(take as i64));
        args.push(Value::Integer(i64::from(offset)));
        self.read(move |c| {
            let mut stmt = c.prepare_cached(&sql).db()?;
            let rows = stmt
                .query_map(params_from_iter(args.iter()), map_track_row)
                .db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 按规则统计匹配的曲目数（规则编辑器预览用）。
    ///
    /// 和 [`Self::evaluate_smart_rules`] 使用同一套 SQL / 校验，规则自己的 `limit` 也算进去：
    /// 预览数字就是"这个歌单最多会有多少首"。`limit` 参数不参与，调用方不需要分页。
    pub async fn count_smart_rules(&self, rules: &SmartRules) -> Result<u64> {
        rules.validate()?;
        let (where_sql, mut args) = rules.to_sql(&AllowedColumns::standard())?;
        let from = "FROM track t
             LEFT JOIN album a ON a.id = t.album_id
             LEFT JOIN user_state u ON u.track_uid = t.uid";
        let sql = match rules.limit {
            Some(limit) => {
                let placeholder = args.len() + 1;
                args.push(Value::Integer(i64::from(limit)));
                format!(
                    "SELECT COUNT(*) FROM (
                         SELECT 1 {from} WHERE {where_sql} LIMIT ?{placeholder}
                     )"
                )
            }
            None => format!("SELECT COUNT(*) {from} WHERE {where_sql}"),
        };
        self.read(move |c| {
            let count: i64 = c
                .query_row(&sql, params_from_iter(args.iter()), |r| r.get(0))
                .db()?;
            Ok(count.max(0) as u64)
        })
        .await
    }

    /// 读一个歌单的规则。
    ///
    /// 歌单不存在返回 [`LekisError::not_found`]；普通歌单（没有规则）返回 `Ok(None)`。
    pub async fn playlist_rules(&self, id: PlaylistId) -> Result<Option<SmartRules>> {
        self.read(move |c| {
            let row: Option<Option<String>> = c
                .query_row(
                    "SELECT rules_json FROM playlist WHERE id = ?1 AND deleted = 0",
                    params![id.0],
                    |r| r.get(0),
                )
                .optional()
                .db()?;
            match row {
                None => Err(LekisError::not_found(format!("playlist {id}"))),
                Some(None) => Ok(None),
                Some(Some(json)) => Ok(Some(SmartRules::parse(&json)?)),
            }
        })
        .await
    }

    /// 设置 / 清除歌单规则，同时把 `kind` 在 `smart` / `static` 之间切换。
    ///
    /// 规则会先 [`SmartRules::validate`]；歌单不存在（或已写墓碑）返回 [`LekisError::not_found`]。
    pub async fn set_playlist_rules(
        &self,
        id: PlaylistId,
        rules: Option<&SmartRules>,
    ) -> Result<()> {
        let (json, kind) = match rules {
            Some(rules) => {
                rules.validate()?;
                (Some(rules.to_json()?), PlaylistKind::Smart)
            }
            None => (None, PlaylistKind::Static),
        };
        self.write(move |conn| {
            let now = now_ms();
            let updated = conn
                .execute(
                    "UPDATE playlist SET rules_json = ?2, kind = ?3, updated_at = ?4
                     WHERE id = ?1 AND deleted = 0",
                    params![id.0, json, kind.as_str(), now],
                )
                .db()?;
            if updated == 0 {
                return Err(LekisError::not_found(format!("playlist {id}")));
            }
            Ok(())
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;
    use lekis_types::{AudioProps, ErrorCode, TrackQuery};
    use rusqlite::params;
    use std::collections::HashMap;

    const FLAC_JSON: &str =
        r#"{"codec":"flac","sample_rate":44100,"bit_depth":16,"channels":2,"bitrate_kbps":1411}"#;
    const MP3_JSON: &str =
        r#"{"codec":"mp3","sample_rate":44100,"bit_depth":null,"channels":2,"bitrate_kbps":320}"#;
    const WAV_JSON: &str =
        r#"{"codec":"wav","sample_rate":96000,"bit_depth":24,"channels":2,"bitrate_kbps":null}"#;

    /// 测试用曲目（builder 风格，写进数据库时展开成多张表）。
    #[derive(Clone)]
    struct Seed {
        uid: &'static str,
        title: &'static str,
        artist: &'static str,
        album: Option<(&'static str, i64)>,
        year: Option<i64>,
        duration_ms: i64,
        added_at: i64,
        loved: bool,
        rating: Option<i64>,
        play_count: i64,
        last_played: Option<i64>,
        genre: Option<&'static str>,
        audio: Option<(&'static str, i64)>,
    }

    fn seed(uid: &'static str, title: &'static str) -> Seed {
        Seed {
            uid,
            title,
            artist: "",
            album: None,
            year: None,
            duration_ms: 0,
            added_at: 0,
            loved: false,
            rating: None,
            play_count: 0,
            last_played: None,
            genre: None,
            audio: None,
        }
    }

    impl Seed {
        fn artist(mut self, artist: &'static str) -> Self {
            self.artist = artist;
            self
        }

        fn album(mut self, title: &'static str, year: i64) -> Self {
            self.album = Some((title, year));
            self
        }

        fn year(mut self, year: i64) -> Self {
            self.year = Some(year);
            self
        }

        fn duration(mut self, duration_ms: i64) -> Self {
            self.duration_ms = duration_ms;
            self
        }

        fn added(mut self, added_at: i64) -> Self {
            self.added_at = added_at;
            self
        }

        fn loved(mut self, loved: bool) -> Self {
            self.loved = loved;
            self
        }

        fn rating(mut self, rating: i64) -> Self {
            self.rating = Some(rating);
            self
        }

        fn plays(mut self, play_count: i64) -> Self {
            self.play_count = play_count;
            self
        }

        fn last_played(mut self, at: i64) -> Self {
            self.last_played = Some(at);
            self
        }

        fn genre(mut self, genre: &'static str) -> Self {
            self.genre = Some(genre);
            self
        }

        fn audio(mut self, audio_json: &'static str, quality_score: i64) -> Self {
            self.audio = Some((audio_json, quality_score));
            self
        }
    }

    /// 把种子数据写进临时库（曲目 / 专辑 / 流派 / 文件 / 用户数据）。
    async fn seed_library(lib: &Library, seeds: Vec<Seed>) -> Result<()> {
        lib.write(move |c| {
            let tx = c.transaction().db()?;
            tx.execute(
                "INSERT INTO source (id, kind, name, addresses_json, root_path, options_json,
                                     enabled, priority, created_at)
                 VALUES (1, 'local', 'Test', '[]', '', '{}', 1, 0, 0)",
                [],
            )
            .db()?;
            let mut albums: HashMap<&'static str, i64> = HashMap::new();
            let mut genres: HashMap<&'static str, i64> = HashMap::new();
            for (index, seed) in seeds.iter().enumerate() {
                let id = index as i64 + 1;
                let album_id = match seed.album {
                    Some((title, year)) => {
                        let next = albums.len() as i64 + 1;
                        let album_id = *albums.entry(title).or_insert(next);
                        if album_id == next {
                            tx.execute(
                                "INSERT INTO album (id, title, title_norm, artist_line, year, created_at)
                                 VALUES (?1, ?2, ?3, '', ?4, 0)",
                                params![album_id, title, title.to_lowercase(), year],
                            )
                            .db()?;
                        }
                        Some(album_id)
                    }
                    None => None,
                };
                tx.execute(
                    "INSERT INTO track (id, uid, title, artist_line, album_id, year, duration_ms,
                                        created_at, updated_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)",
                    params![
                        id,
                        seed.uid,
                        seed.title,
                        seed.artist,
                        album_id,
                        seed.year,
                        seed.duration_ms,
                        seed.added_at,
                    ],
                )
                .db()?;
                if let Some(name) = seed.genre {
                    let next = genres.len() as i64 + 1;
                    let genre_id = *genres.entry(name).or_insert(next);
                    if genre_id == next {
                        tx.execute(
                            "INSERT INTO genre (id, name) VALUES (?1, ?2)",
                            params![genre_id, name],
                        )
                        .db()?;
                    }
                    tx.execute(
                        "INSERT INTO track_genre (track_id, genre_id) VALUES (?1, ?2)",
                        params![id, genre_id],
                    )
                    .db()?;
                }
                if let Some((audio_json, quality_score)) = seed.audio {
                    // `track.quality_badge` 是入库时算好的冗余列，这里照真实流程生成。
                    let badge = serde_json::from_str::<AudioProps>(audio_json)
                        .map(|audio| audio.quality_badge())
                        .ok();
                    tx.execute(
                        "INSERT INTO file (id, source_id, path, size, mtime_ms, scan_state,
                                           audio_json, last_seen_at)
                         VALUES (?1, 1, ?2, 0, 0, 'tagged', ?3, 0)",
                        params![id, format!("track-{id}.flac"), audio_json],
                    )
                    .db()?;
                    tx.execute(
                        "INSERT INTO track_file (track_id, file_id, source_id, external_id,
                                                 quality_score)
                         VALUES (?1, ?1, 1, NULL, ?2)",
                        params![id, quality_score],
                    )
                    .db()?;
                    tx.execute(
                        "UPDATE track SET quality_badge = ?2 WHERE id = ?1",
                        params![id, badge],
                    )
                    .db()?;
                }
                if seed.loved || seed.rating.is_some() || seed.play_count > 0
                    || seed.last_played.is_some()
                {
                    tx.execute(
                        "INSERT INTO user_state (track_uid, loved, rating, play_count, last_played)
                         VALUES (?1, ?2, ?3, ?4, ?5)",
                        params![
                            seed.uid,
                            i64::from(seed.loved),
                            seed.rating,
                            seed.play_count,
                            seed.last_played,
                        ],
                    )
                    .db()?;
                }
            }
            tx.commit().db()
        })
        .await
    }

    /// 默认测试数据（6 首，覆盖流派 / 年份 / 编码 / 用户数据 / 通配符标题）。
    fn fixture() -> Vec<Seed> {
        vec![
            seed("u-1", "Amazing Grace")
                .artist("A Band")
                .album("80s Album", 1985)
                .year(1985)
                .duration(200_000)
                .added(1_000)
                .loved(true)
                .rating(5)
                .plays(10)
                .last_played(50_000)
                .genre("Rock")
                .audio(FLAC_JSON, 100),
            seed("u-2", "Blue Notes")
                .artist("B Band")
                .album("80s Album", 1985)
                .year(1985)
                .duration(300_000)
                .added(2_000)
                .loved(true)
                .rating(2)
                .plays(1)
                .last_played(40_000)
                .genre("Jazz")
                .audio(MP3_JSON, 10),
            seed("u-3", "Crystal")
                .artist("C Band")
                .album("2000s Album", 2005)
                .year(2005)
                .duration(400_000)
                .added(3_000)
                .rating(5)
                .plays(20)
                .genre("古典")
                .audio(WAV_JSON, 90),
            seed("u-4", "100% Pure")
                .artist("D Band")
                .year(1990)
                .duration(100_000)
                .added(4_000),
            seed("u-5", "Under_score")
                .artist("E Band")
                .year(1995)
                .duration(150_000)
                .added(5_000),
            seed("u-6", "'; DROP TABLE track; --")
                .artist("F Band")
                .added(6_000),
        ]
    }

    fn rule(field: RuleField, op: RuleOp, value: RuleValue) -> RuleGroup {
        RuleGroup::Rule(Rule { field, op, value })
    }

    fn all(rules: Vec<RuleGroup>) -> RuleGroup {
        RuleGroup::All(rules)
    }

    fn any(rules: Vec<RuleGroup>) -> RuleGroup {
        RuleGroup::Any(rules)
    }

    fn not(inner: RuleGroup) -> RuleGroup {
        RuleGroup::Not(Box::new(inner))
    }

    fn text(value: &str) -> RuleValue {
        RuleValue::Text(value.to_string())
    }

    fn list(items: &[&str]) -> RuleValue {
        RuleValue::TextList(items.iter().map(|item| (*item).to_string()).collect())
    }

    fn rules(root: RuleGroup) -> SmartRules {
        SmartRules {
            root,
            limit: None,
            sort: None,
            sort_desc: false,
        }
    }

    /// 排序后的标题列表（默认排序键都一样，顺序取决于 id，测试里统一排序后比较）。
    fn titles(rows: &[TrackRow]) -> Vec<String> {
        let mut titles = rows.iter().map(|row| row.title.clone()).collect::<Vec<_>>();
        titles.sort();
        titles
    }

    fn err_code<T>(result: Result<T>) -> Option<ErrorCode> {
        result.err().map(|error| error.code)
    }

    #[tokio::test]
    async fn all_group_is_and() -> Result<()> {
        let lib = temp_library("smart-all")?;
        seed_library(&lib, fixture()).await?;
        let rules = rules(all(vec![
            rule(RuleField::Loved, RuleOp::Eq, RuleValue::Bool(true)),
            rule(RuleField::Rating, RuleOp::Ge, RuleValue::Number(5)),
        ]));
        let rows = lib.evaluate_smart_rules(&rules, 0, 50).await?;
        assert_eq!(titles(&rows), vec!["Amazing Grace"]);
        Ok(())
    }

    #[tokio::test]
    async fn any_group_is_or() -> Result<()> {
        let lib = temp_library("smart-any")?;
        seed_library(&lib, fixture()).await?;
        let rules = rules(any(vec![
            rule(RuleField::Loved, RuleOp::Eq, RuleValue::Bool(true)),
            rule(RuleField::Rating, RuleOp::Ge, RuleValue::Number(5)),
        ]));
        let rows = lib.evaluate_smart_rules(&rules, 0, 50).await?;
        assert_eq!(
            titles(&rows),
            vec!["Amazing Grace", "Blue Notes", "Crystal"]
        );
        Ok(())
    }

    #[tokio::test]
    async fn not_group_negates_including_missing_fields() -> Result<()> {
        let lib = temp_library("smart-not")?;
        seed_library(&lib, fixture()).await?;
        // 没有 user_state 行的曲目（u-3 ~ u-6 里的后三首）也应当匹配"没收藏"。
        let rules = rules(not(all(vec![rule(
            RuleField::Loved,
            RuleOp::Eq,
            RuleValue::Bool(true),
        )])));
        let rows = lib.evaluate_smart_rules(&rules, 0, 50).await?;
        assert_eq!(
            titles(&rows),
            vec![
                "'; DROP TABLE track; --",
                "100% Pure",
                "Crystal",
                "Under_score",
            ]
        );
        Ok(())
    }

    #[tokio::test]
    async fn contains_escapes_like_wildcards() -> Result<()> {
        let lib = temp_library("smart-like")?;
        seed_library(&lib, fixture()).await?;

        // `%` 只当字面量：不能匹配到所有曲目。
        let percent = rules(rule(RuleField::Title, RuleOp::Contains, text("%")));
        assert_eq!(
            titles(&lib.evaluate_smart_rules(&percent, 0, 50).await?),
            vec!["100% Pure"]
        );

        // `_` 只当字面量。
        let underscore = rules(rule(RuleField::Title, RuleOp::Contains, text("_")));
        assert_eq!(
            titles(&lib.evaluate_smart_rules(&underscore, 0, 50).await?),
            vec!["Under_score"]
        );

        // 反斜杠 + 通配符组合也不会破坏 SQL。
        let mixed = rules(rule(RuleField::Title, RuleOp::Contains, text("\\% _")));
        assert!(lib.evaluate_smart_rules(&mixed, 0, 50).await?.is_empty());

        // not_contains 把缺字段的曲目也算进去（COALESCE(列, '')）。
        let not_percent = rules(rule(RuleField::Title, RuleOp::NotContains, text("%")));
        let rows = lib.evaluate_smart_rules(&not_percent, 0, 50).await?;
        assert_eq!(rows.len(), 5);
        assert!(!titles(&rows).contains(&"100% Pure".to_string()));
        Ok(())
    }

    #[tokio::test]
    async fn between_filters_years() -> Result<()> {
        let lib = temp_library("smart-between")?;
        seed_library(&lib, fixture()).await?;
        let rules = rules(rule(
            RuleField::Year,
            RuleOp::Between,
            list(&["1985", "1990"]),
        ));
        let rows = lib.evaluate_smart_rules(&rules, 0, 50).await?;
        assert_eq!(
            titles(&rows),
            vec!["100% Pure", "Amazing Grace", "Blue Notes"]
        );
        Ok(())
    }

    #[tokio::test]
    async fn codec_matches_lossless_and_names() -> Result<()> {
        let lib = temp_library("smart-codec")?;
        seed_library(&lib, fixture()).await?;

        let lossless = rules(rule(
            RuleField::Codec,
            RuleOp::Eq,
            RuleValue::Codec("lossless".into()),
        ));
        assert_eq!(
            titles(&lib.evaluate_smart_rules(&lossless, 0, 50).await?),
            vec!["Amazing Grace", "Crystal"]
        );

        let flac = rules(rule(
            RuleField::Codec,
            RuleOp::Eq,
            RuleValue::Codec("flac".into()),
        ));
        assert_eq!(
            titles(&lib.evaluate_smart_rules(&flac, 0, 50).await?),
            vec!["Amazing Grace"]
        );

        let lossy = rules(rule(
            RuleField::Codec,
            RuleOp::Eq,
            RuleValue::Codec("lossy".into()),
        ));
        assert_eq!(
            titles(&lib.evaluate_smart_rules(&lossy, 0, 50).await?),
            vec!["Blue Notes"]
        );

        // 码率 / 采样率直接来自 audio_json。
        let high_res = rules(rule(
            RuleField::SampleRate,
            RuleOp::Ge,
            RuleValue::Number(96_000),
        ));
        assert_eq!(
            titles(&lib.evaluate_smart_rules(&high_res, 0, 50).await?),
            vec!["Crystal"]
        );
        let high_bitrate = rules(rule(
            RuleField::BitrateKbps,
            RuleOp::Gt,
            RuleValue::Number(320),
        ));
        assert_eq!(
            titles(&lib.evaluate_smart_rules(&high_bitrate, 0, 50).await?),
            vec!["Amazing Grace"]
        );
        let cd_depth = rules(rule(RuleField::BitDepth, RuleOp::Eq, RuleValue::Number(24)));
        assert_eq!(
            titles(&lib.evaluate_smart_rules(&cd_depth, 0, 50).await?),
            vec!["Crystal"]
        );
        Ok(())
    }

    #[tokio::test]
    async fn loved_rating_playcount_and_last_played() -> Result<()> {
        let lib = temp_library("smart-user-data")?;
        seed_library(&lib, fixture()).await?;

        let played = rules(rule(RuleField::PlayCount, RuleOp::Ge, RuleValue::Number(5)));
        assert_eq!(
            titles(&lib.evaluate_smart_rules(&played, 0, 50).await?),
            vec!["Amazing Grace", "Crystal"]
        );

        // 没评过分的曲目 rating 是 NULL，不参与 `ne` 比较。
        let not_top = rules(rule(RuleField::Rating, RuleOp::Ne, RuleValue::Number(5)));
        assert_eq!(
            titles(&lib.evaluate_smart_rules(&not_top, 0, 50).await?),
            vec!["Blue Notes"]
        );

        let recently_played = rules(rule(
            RuleField::LastPlayed,
            RuleOp::Ge,
            RuleValue::Number(45_000),
        ));
        assert_eq!(
            titles(&lib.evaluate_smart_rules(&recently_played, 0, 50).await?),
            vec!["Amazing Grace"]
        );

        let added = rules(rule(
            RuleField::AddedAt,
            RuleOp::Le,
            RuleValue::Number(2_000),
        ));
        assert_eq!(
            titles(&lib.evaluate_smart_rules(&added, 0, 50).await?),
            vec!["Amazing Grace", "Blue Notes"]
        );
        Ok(())
    }

    #[tokio::test]
    async fn limit_and_sort_are_applied() -> Result<()> {
        let lib = temp_library("smart-limit-sort")?;
        seed_library(&lib, fixture()).await?;

        let mut top = rules(all(Vec::new()));
        top.sort = Some(TrackSort::MostPlayed);
        top.sort_desc = true;
        top.limit = Some(2);

        let rows = lib.evaluate_smart_rules(&top, 0, 50).await?;
        assert_eq!(
            rows.iter()
                .map(|row| row.title.as_str())
                .collect::<Vec<_>>(),
            vec!["Crystal", "Amazing Grace"]
        );

        // 第二页：规则 limit=2 时只能再翻到第 2 首。
        let page = lib.evaluate_smart_rules(&top, 1, 50).await?;
        assert_eq!(page.len(), 1);
        assert_eq!(page[0].title, "Amazing Grace");
        // 越过规则上限就是空页。
        assert!(lib.evaluate_smart_rules(&top, 2, 50).await?.is_empty());

        // 没有规则 limit 时按曲目名倒序。
        let mut by_title = rules(all(Vec::new()));
        by_title.sort_desc = true;
        assert_eq!(lib.evaluate_smart_rules(&by_title, 0, 50).await?.len(), 6);

        // 分页参数越界是 invalid。
        assert_eq!(
            err_code(lib.evaluate_smart_rules(&top, 0, 0).await),
            Some(ErrorCode::InvalidArgument)
        );
        assert_eq!(
            err_code(
                lib.evaluate_smart_rules(&top, 0, TrackQuery::MAX_LIMIT + 1)
                    .await
            ),
            Some(ErrorCode::InvalidArgument)
        );
        Ok(())
    }

    #[tokio::test]
    async fn in_and_not_in_on_genre() -> Result<()> {
        let lib = temp_library("smart-in")?;
        seed_library(&lib, fixture()).await?;

        let in_rules = rules(rule(RuleField::Genre, RuleOp::In, list(&["Rock", "Jazz"])));
        assert_eq!(
            titles(&lib.evaluate_smart_rules(&in_rules, 0, 50).await?),
            vec!["Amazing Grace", "Blue Notes"]
        );

        let contains = rules(rule(RuleField::Genre, RuleOp::Contains, text("古典")));
        assert_eq!(
            titles(&lib.evaluate_smart_rules(&contains, 0, 50).await?),
            vec!["Crystal"]
        );

        // 没有流派的曲目按空串处理，所以会出现在 not_in 的结果里。
        let not_in = rules(rule(
            RuleField::Genre,
            RuleOp::NotIn,
            list(&["Rock", "Jazz"]),
        ));
        let rows = lib.evaluate_smart_rules(&not_in, 0, 50).await?;
        assert_eq!(rows.len(), 4);
        assert!(titles(&rows).contains(&"Crystal".to_string()));

        // 空列表：in 匹配不到，not_in 匹配全部。
        let empty_in = rules(rule(RuleField::Genre, RuleOp::In, list(&[])));
        assert!(lib.evaluate_smart_rules(&empty_in, 0, 50).await?.is_empty());
        let empty_not_in = rules(rule(RuleField::Genre, RuleOp::NotIn, list(&[])));
        assert_eq!(
            lib.evaluate_smart_rules(&empty_not_in, 0, 50).await?.len(),
            6
        );
        Ok(())
    }

    #[tokio::test]
    async fn invalid_json_reports_invalid_argument() -> Result<()> {
        // JSON 语法错误。
        assert_eq!(
            err_code(SmartRules::parse("{not json")),
            Some(ErrorCode::InvalidArgument)
        );
        // 未知规则类型。
        assert_eq!(
            err_code(SmartRules::parse(r#"{"root": {"kind": "nope"}}"#)),
            Some(ErrorCode::InvalidArgument)
        );
        // 未知字段名。
        assert_eq!(
            err_code(SmartRules::parse(
                r#"{"root": {"kind": "rule", "field": "vibe", "op": "eq", "value": {"number": 1}}}"#
            )),
            Some(ErrorCode::InvalidArgument)
        );
        // 未知操作符。
        assert_eq!(
            err_code(SmartRules::parse(
                r#"{"root": {"kind": "rule", "field": "title", "op": "smells_like", "value": {"text": "x"}}}"#
            )),
            Some(ErrorCode::InvalidArgument)
        );
        // 多余字段（拼错了不该被静默忽略）。
        assert_eq!(
            err_code(SmartRules::parse(
                r#"{"root": {"kind": "all", "rules": [], "rulez": []}}"#
            )),
            Some(ErrorCode::InvalidArgument)
        );
        // 值类型和字段不匹配。
        assert_eq!(
            err_code(SmartRules::parse(
                r#"{"root": {"kind": "rule", "field": "year", "op": "eq", "value": {"text": "1990"}}}"#
            )),
            Some(ErrorCode::InvalidArgument)
        );

        // 白名单外的字段：即使规则本身合法，也不允许生成 SQL。
        let lib = temp_library("smart-not-allowed")?;
        let allowed = AllowedColumns::standard().without(RuleField::Title);
        let rules = rules(rule(RuleField::Title, RuleOp::Contains, text("x")));
        assert_eq!(
            err_code(rules.to_sql(&allowed)),
            Some(ErrorCode::InvalidArgument)
        );
        assert!(rules.to_sql(&AllowedColumns::standard()).is_ok());
        let _ = &lib;
        Ok(())
    }

    #[tokio::test]
    async fn validate_rejects_bad_rules() -> Result<()> {
        // limit 越界。
        let mut too_small = rules(all(Vec::new()));
        too_small.limit = Some(0);
        assert_eq!(
            err_code(too_small.validate()),
            Some(ErrorCode::InvalidArgument)
        );
        let mut too_big = rules(all(Vec::new()));
        too_big.limit = Some(MAX_RULES_LIMIT + 1);
        assert_eq!(
            err_code(too_big.validate()),
            Some(ErrorCode::InvalidArgument)
        );

        // between 只能用在数字字段、只能配数字。
        assert_eq!(
            err_code(rules(rule(RuleField::Title, RuleOp::Between, list(&["1", "2"]))).validate()),
            Some(ErrorCode::InvalidArgument)
        );
        assert_eq!(
            err_code(
                rules(rule(
                    RuleField::Year,
                    RuleOp::Between,
                    RuleValue::Text("1990".into())
                ))
                .validate()
            ),
            Some(ErrorCode::InvalidArgument)
        );

        // contains 要文本。
        assert_eq!(
            err_code(
                rules(rule(
                    RuleField::Title,
                    RuleOp::Contains,
                    RuleValue::Number(1)
                ))
                .validate()
            ),
            Some(ErrorCode::InvalidArgument)
        );

        // 文本过长。
        let long = "x".repeat(MAX_TEXT_LEN + 1);
        assert_eq!(
            err_code(rules(rule(RuleField::Title, RuleOp::Contains, text(&long))).validate()),
            Some(ErrorCode::InvalidArgument)
        );

        // 嵌套过深。
        let mut deep = rule(RuleField::Title, RuleOp::Contains, text("x"));
        for _ in 0..(MAX_DEPTH + 1) {
            deep = not(deep);
        }
        assert_eq!(
            err_code(rules(deep).validate()),
            Some(ErrorCode::InvalidArgument)
        );

        // 合法规则通过。
        assert!(rules(all(vec![rule(
            RuleField::Year,
            RuleOp::Between,
            list(&["1980", "1989"])
        )]))
        .validate()
        .is_ok());
        Ok(())
    }

    #[tokio::test]
    async fn sql_injection_text_stays_literal() -> Result<()> {
        let lib = temp_library("smart-injection")?;
        seed_library(&lib, fixture()).await?;

        // 曲目标题本身就是注入串：只作为字面量匹配到它自己。
        let injected = "'; DROP TABLE track; --";
        let exact = rules(rule(RuleField::Title, RuleOp::Contains, text(injected)));
        let rows = lib.evaluate_smart_rules(&exact, 0, 50).await?;
        assert_eq!(titles(&rows), vec![injected]);

        let partial = rules(rule(RuleField::Title, RuleOp::Contains, text("DROP TABLE")));
        assert_eq!(
            titles(&lib.evaluate_smart_rules(&partial, 0, 50).await?),
            vec![injected]
        );

        // 常见的恒真注入串匹配不到任何曲目，也不会改变表结构。
        for payload in [
            "%' OR '1'='1",
            "') OR 1=1 --",
            "' UNION SELECT 1,2,3 --",
            "\\",
        ] {
            let rules = rules(all(vec![rule(
                RuleField::Title,
                RuleOp::Contains,
                text(payload),
            )]));
            assert!(
                lib.evaluate_smart_rules(&rules, 0, 50).await?.is_empty(),
                "注入串 {payload:?} 不应匹配任何曲目"
            );
        }

        // 表还在，行数没变。
        assert_eq!(lib.track_count().await?, 6);
        let artists = rules(rule(
            RuleField::Artist,
            RuleOp::Eq,
            text("F' OR '1'='1' --"),
        ));
        assert!(lib.evaluate_smart_rules(&artists, 0, 50).await?.is_empty());
        assert_eq!(lib.track_count().await?, 6);
        Ok(())
    }

    #[tokio::test]
    async fn nsp_style_json_parses() -> Result<()> {
        // Navidrome 文档里的 "80's Top Songs"，sort 换成我们支持的 title。
        let json = r#"{
            "name": "80s Top Songs",
            "comment": "top rated from the 80s",
            "all": [
                {"any": [{"is": {"loved": true}}, {"gt": {"rating": 3}}]},
                {"inTheRange": {"year": [1981, 1990]}}
            ],
            "sort": "title",
            "order": "desc",
            "limit": 25
        }"#;
        let rules = SmartRules::parse(json)?;
        assert_eq!(rules.limit, Some(25));
        assert_eq!(rules.sort, Some(TrackSort::Title));
        assert!(rules.sort_desc);
        let expected = all(vec![
            any(vec![
                rule(RuleField::Loved, RuleOp::Eq, RuleValue::Bool(true)),
                rule(RuleField::Rating, RuleOp::Gt, RuleValue::Number(3)),
            ]),
            rule(RuleField::Year, RuleOp::Between, list(&["1981", "1990"])),
        ]);
        assert_eq!(rules.root, expected);

        // 解析出来的规则真的能求值。
        let lib = temp_library("smart-nsp")?;
        seed_library(&lib, fixture()).await?;
        let rows = lib.evaluate_smart_rules(&rules, 0, 50).await?;
        // u-4（"100% Pure"）年份落在区间里，但没有 user_state 行：vintage 1985 的两首之外
        // 它的 `rating` 是 NULL，`any` 组因此是 NULL，AND 之后不成立——字段缺失不算匹配。
        assert_eq!(titles(&rows), vec!["Amazing Grace", "Blue Notes"]);

        // 其它 `.nsp` 写法：not + in + 多个字段。
        let more = SmartRules::parse(
            r#"{"not": {"is": {"genre": "Rock"}}, "sort": "dateAdded", "order": "asc"}"#,
        )?;
        assert_eq!(more.sort, Some(TrackSort::RecentlyAdded));
        assert!(!more.sort_desc);
        let more_rows = lib.evaluate_smart_rules(&more, 0, 50).await?;
        assert_eq!(more_rows.len(), 5);

        let multi = SmartRules::parse(r#"{"all": [{"in": {"genre": ["Rock", "Jazz"]}}]}"#)?;
        assert!(matches!(multi.root, RuleGroup::All(_)));
        assert_eq!(lib.evaluate_smart_rules(&multi, 0, 50).await?.len(), 2);
        Ok(())
    }

    #[tokio::test]
    async fn nsp_unsupported_parts_are_reported() -> Result<()> {
        // 认识但还不支持的 `.nsp` 操作符。
        let err = SmartRules::parse(r#"{"all": [{"inTheLast": {"lastPlayed": 30}}]}"#)
            .err()
            .map(|error| error.message)
            .unwrap_or_default();
        assert!(err.contains("inTheLast"), "错误信息应当点名操作符: {err}");

        // 不支持的排序字段。
        let err = SmartRules::parse(r#"{"all": [], "sort": "random"}"#)
            .err()
            .map(|error| error.message)
            .unwrap_or_default();
        assert!(err.contains("random"), "错误信息应当点名排序: {err}");

        // 未知字段名。
        let err = SmartRules::parse(r#"{"all": [{"is": {"vibe": "chill"}}]}"#)
            .err()
            .map(|error| error.message)
            .unwrap_or_default();
        assert!(err.contains("vibe"), "错误信息应当点名字段: {err}");

        // limitPercent 暂不支持。
        assert_eq!(
            err_code(SmartRules::parse(r#"{"all": [], "limitPercent": 10}"#)),
            Some(ErrorCode::InvalidArgument)
        );
        // 空的规则组。
        assert_eq!(
            err_code(SmartRules::parse("{}")),
            Some(ErrorCode::InvalidArgument)
        );
        Ok(())
    }

    #[tokio::test]
    async fn rules_round_trip_through_json() -> Result<()> {
        let original = SmartRules {
            root: all(vec![
                rule(RuleField::Genre, RuleOp::In, list(&["Rock", "Jazz"])),
                not(rule(RuleField::Title, RuleOp::Contains, text("live 50%"))),
                any(vec![
                    rule(RuleField::Loved, RuleOp::Eq, RuleValue::Bool(true)),
                    rule(
                        RuleField::Codec,
                        RuleOp::Eq,
                        RuleValue::Codec("lossless".into()),
                    ),
                ]),
            ]),
            limit: Some(120),
            sort: Some(TrackSort::RecentlyAdded),
            sort_desc: true,
        };
        let json = original.to_json()?;
        assert!(
            json.contains("\"kind\":\"all\""),
            "序列化后应当带 kind: {json}"
        );
        assert_eq!(SmartRules::parse(&json)?, original);

        // 大小写 / 下划线不敏感的操作符名与字段名。
        let lenient = SmartRules::parse(
            r#"{"root": {"kind": "rule", "field": "DurationMS", "op": "GreaterThanOrEqual", "value": {"number": 1}}}"#,
        );
        assert_eq!(err_code(lenient), Some(ErrorCode::InvalidArgument));
        let ok = SmartRules::parse(
            r#"{"root": {"kind": "rule", "field": "Duration_MS", "op": "GE", "value": {"number": 1}}}"#,
        )?;
        assert_eq!(
            ok.root,
            rule(RuleField::DurationMs, RuleOp::Ge, RuleValue::Number(1))
        );
        Ok(())
    }

    #[tokio::test]
    async fn set_and_clear_playlist_rules() -> Result<()> {
        let lib = temp_library("smart-playlist")?;
        seed_library(&lib, fixture()).await?;

        let id = lib.create_playlist("智能歌单", None).await?;
        assert_eq!(lib.get_playlist(id).await?.kind, PlaylistKind::Static);
        assert!(lib.playlist_rules(id).await?.is_none());

        let top_rated = rules(rule(RuleField::Rating, RuleOp::Ge, RuleValue::Number(5)));
        lib.set_playlist_rules(id, Some(&top_rated)).await?;
        assert_eq!(lib.get_playlist(id).await?.kind, PlaylistKind::Smart);
        assert_eq!(lib.playlist_rules(id).await?, Some(top_rated.clone()));

        let rows = lib.smart_playlist_tracks(id, 0, 50).await?;
        assert_eq!(titles(&rows), vec!["Amazing Grace", "Crystal"]);
        assert_eq!(lib.count_smart_rules(&top_rated).await?, 2);
        // 播放上下文也走规则求值，而不是空的 playlist_item。
        let context_ids = lib
            .context_track_ids(crate::TrackContext::Playlist(id))
            .await?;
        assert_eq!(context_ids.len(), 2);
        assert!(context_ids.iter().all(Option::is_some));

        // 改规则立刻生效（实时更新）。
        let by_codec = rules(rule(
            RuleField::Codec,
            RuleOp::Eq,
            RuleValue::Codec("mp3".into()),
        ));
        lib.set_playlist_rules(id, Some(&by_codec)).await?;
        assert_eq!(
            titles(&lib.smart_playlist_tracks(id, 0, 50).await?),
            vec!["Blue Notes"]
        );

        // 清除规则 → 退回普通歌单，求值报 invalid。
        lib.set_playlist_rules(id, None).await?;
        assert_eq!(lib.get_playlist(id).await?.kind, PlaylistKind::Static);
        assert!(lib.playlist_rules(id).await?.is_none());
        assert_eq!(
            err_code(lib.smart_playlist_tracks(id, 0, 50).await),
            Some(ErrorCode::InvalidArgument)
        );

        // 不存在的歌单：读写规则都是 not_found。
        let ghost = PlaylistId(9999);
        assert_eq!(
            err_code(lib.set_playlist_rules(ghost, Some(&top_rated)).await),
            Some(ErrorCode::NotFound)
        );
        assert_eq!(
            err_code(lib.playlist_rules(ghost).await),
            Some(ErrorCode::NotFound)
        );
        assert_eq!(
            err_code(lib.smart_playlist_tracks(ghost, 0, 50).await),
            Some(ErrorCode::NotFound)
        );

        // 规则里的 limit 生效在歌单层面。
        let mut limited = rules(all(Vec::new()));
        limited.limit = Some(3);
        lib.set_playlist_rules(id, Some(&limited)).await?;
        assert_eq!(lib.smart_playlist_tracks(id, 0, 50).await?.len(), 3);
        assert_eq!(
            lib.count_smart_rules(&limited).await?,
            3,
            "预览数也要遵守规则自己的 limit"
        );
        Ok(())
    }

    #[tokio::test]
    async fn playlist_items_are_not_materialized() -> Result<()> {
        let lib = temp_library("smart-no-items")?;
        seed_library(&lib, fixture()).await?;
        let id = lib.create_playlist("实时歌单", None).await?;
        lib.set_playlist_rules(
            id,
            Some(&rules(rule(
                RuleField::Loved,
                RuleOp::Eq,
                RuleValue::Bool(true),
            ))),
        )
        .await?;

        // 智能歌单不写 playlist_item：条目数是 0，但求值有 2 首。
        assert_eq!(lib.get_playlist(id).await?.track_count, 0);
        assert!(lib.playlist_items(id, 0, 10).await?.is_empty());
        assert_eq!(lib.smart_playlist_tracks(id, 0, 50).await?.len(), 2);

        // 也能把静态歌单的条目当普通曲目来求值（同一套 JOIN）。
        let rows = lib
            .evaluate_smart_rules(&rules(all(Vec::new())), 0, 50)
            .await?;
        assert_eq!(rows.len(), 6);
        assert!(rows.iter().all(|row| !row.title.is_empty()));
        assert!(rows.iter().any(|row| row.loved));
        Ok(())
    }

    #[tokio::test]
    async fn text_ops_are_case_insensitive_for_ascii() -> Result<()> {
        let lib = temp_library("smart-case")?;
        seed_library(&lib, fixture()).await?;

        // LIKE 默认对 ASCII 不区分大小写。
        let lower = rules(rule(RuleField::Title, RuleOp::Contains, text("amazing")));
        assert_eq!(
            titles(&lib.evaluate_smart_rules(&lower, 0, 50).await?),
            vec!["Amazing Grace"]
        );
        // `=` 区分大小写（字面量比较）。
        let upper = rules(rule(RuleField::Title, RuleOp::Eq, text("AMAZING GRACE")));
        assert!(lib.evaluate_smart_rules(&upper, 0, 50).await?.is_empty());
        let exact = rules(rule(RuleField::Title, RuleOp::Eq, text("Amazing Grace")));
        assert_eq!(
            titles(&lib.evaluate_smart_rules(&exact, 0, 50).await?),
            vec!["Amazing Grace"]
        );
        Ok(())
    }

    #[test]
    fn escape_like_is_idempotent_for_plain_text() {
        assert_eq!(escape_like("plain"), "plain");
        assert_eq!(escape_like("50%"), "50\\%");
        assert_eq!(escape_like("a_b"), "a\\_b");
        assert_eq!(escape_like("c:\\x"), "c:\\\\x");
        assert_eq!(escape_like(""), "");
    }

    #[test]
    fn field_and_op_names_are_stable() {
        // 这些名字会写进数据库和 FFI，不能无意中改掉。
        assert_eq!(RuleField::DurationMs.as_str(), "duration_ms");
        assert_eq!(RuleField::QualityScore.as_str(), "quality_score");
        assert_eq!(RuleOp::NotContains.as_str(), "not_contains");
        assert_eq!(RuleOp::Between.as_str(), "between");
        for field in [
            RuleField::Title,
            RuleField::Artist,
            RuleField::Album,
            RuleField::Genre,
            RuleField::Year,
            RuleField::DurationMs,
            RuleField::BitrateKbps,
            RuleField::SampleRate,
            RuleField::BitDepth,
            RuleField::Codec,
            RuleField::Loved,
            RuleField::Rating,
            RuleField::PlayCount,
            RuleField::AddedAt,
            RuleField::LastPlayed,
            RuleField::QualityScore,
        ] {
            assert_eq!(rule_field(field.as_str()).ok(), Some(field));
        }
        assert_eq!(
            rule_op("isNot").ok(),
            Some(RuleOp::Ne),
            "nsp 的 isNot 应当映射成 ne"
        );
    }
}
