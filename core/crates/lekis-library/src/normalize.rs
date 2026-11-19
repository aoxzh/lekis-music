//! 文本规范化：去重键、排序键、搜索键（LIB-08、LIB-07）。
//!
//! 三层转换，逐层叠加：
//! 1. **简繁归一**：繁体转简体，这样"周杰倫"和"周杰伦"是同一个键（`zhconv`）；
//! 2. **拼音**：汉字转全拼和首字母，`zhoujielun`、`zjl` 都能搜到"周杰伦"（`pinyin`）；
//! 3. **折叠**：小写、折叠空白、去首尾空白。
//!
//! 索引时把"原文 / 简体 / 全拼 / 首字母"都写进 `search_index.keys`，查询时对用户输入做
//! 同样的转换，再按前缀匹配——这样中英文混排、简繁混用、拼音缩写都能命中。
//!
//! 日文假名 / 罗马字（LIB-07 的剩余部分）尚未实现，接口不用改。

use pinyin::ToPinyin;

/// 把繁体中文转成简体。非中文原样返回。
fn to_simplified(s: &str) -> String {
    // 纯 ASCII 不需要走转换表。
    if s.is_ascii() {
        return s.to_string();
    }
    zhconv::zhconv(s, zhconv::Variant::ZhHans)
}

/// 去重用的规范化名称：简繁归一、小写、折叠空白、去掉首尾空白。
pub fn norm_key(s: &str) -> String {
    to_simplified(s)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

/// 排序键。中文转成拼音，这样"阿"排在"B"前面。
pub fn sort_key(s: &str) -> String {
    let lower = norm_key(s);
    // 去掉英文的冠词前缀，和其他播放器保持一致。
    for prefix in ["the ", "a ", "an "] {
        if let Some(rest) = lower.strip_prefix(prefix) {
            return pinyin_of(rest).to_lowercase();
        }
    }
    pinyin_of(&lower).to_lowercase()
}

/// 汉字转全拼，非汉字原样保留。`周杰伦 - 晴天` → `zhoujielun - qingtian`。
pub fn pinyin_of(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 2);
    for c in s.chars() {
        match c.to_pinyin() {
            Some(p) => out.push_str(p.plain()),
            None => out.push(c),
        }
    }
    out
}

/// 汉字转拼音首字母，非汉字原样保留。`周杰伦` → `zjl`。
pub fn initials_of(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c.to_pinyin() {
            Some(p) => out.push_str(p.first_letter()),
            None => out.push(c),
        }
    }
    out
}

/// 写进全文索引 `keys` 列的搜索键（多个键用空格拼接）。
///
/// 每个部分都会贡献：原文（简体化后）、拼音全拼、拼音首字母。空串被丢弃，
/// 重复的键只保留一次（例如纯英文标题的原文和全拼是一样的）。
pub fn search_keys(parts: &[&str]) -> String {
    let mut keys: Vec<String> = Vec::with_capacity(parts.len() * 3);
    for part in parts {
        let text = norm_key(part);
        if text.is_empty() {
            continue;
        }
        let full = pinyin_of(&text).to_lowercase();
        let initials = initials_of(&text).to_lowercase();
        for key in [text, full, initials] {
            if !key.is_empty() && !keys.iter().any(|k| k == &key) {
                keys.push(key);
            }
        }
    }
    keys.join(" ")
}

/// 把用户输入展开成若干 FTS5 查询词。
///
/// 用户输入原文、简繁归一后的文字、全拼、首字母都会成为候选——任一命中即可，
/// 所以最后用 `OR` 连接。每个词做前缀匹配并转义引号。
///
/// 返回 `None` 表示输入里没有可搜索的字符（例如只有空白或标点）。
pub fn fts_query(input: &str) -> Option<String> {
    let text = norm_key(input);
    let mut groups: Vec<String> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for variant in [
        text.clone(),
        pinyin_of(&text).to_lowercase(),
        initials_of(&text).to_lowercase(),
    ] {
        if variant.is_empty() || seen.iter().any(|v| v == &variant) {
            continue;
        }
        seen.push(variant.clone());
        let terms: Vec<String> = variant
            .split(' ')
            .filter(|t| !t.is_empty() && t.chars().any(|c| c.is_alphanumeric()))
            .map(|t| format!("\"{}\"*", t.replace('"', "\"\"")))
            .collect();
        if !terms.is_empty() {
            groups.push(terms.join(" "));
        }
    }
    if groups.is_empty() {
        None
    } else if groups.len() == 1 {
        Some(groups.remove(0))
    } else {
        // 多个变体之间是"或"的关系，各自包一层括号再 OR 起来。
        Some(
            groups
                .into_iter()
                .map(|g| format!("({g})"))
                .collect::<Vec<_>>()
                .join(" OR "),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys() {
        assert_eq!(norm_key("  Jay   Chou "), "jay chou");
        assert_eq!(sort_key("The Beatles"), "beatles");
        assert_eq!(sort_key("周杰伦"), "zhoujielun");
        // 纯 ASCII 输入没有拼音变体，只展开成一组。
        assert_eq!(
            fts_query("jay \"chou"),
            Some("\"jay\"* \"\"\"chou\"*".to_string())
        );
        assert_eq!(fts_query("   "), None);
    }

    #[test]
    fn traditional_and_simplified_share_a_key() {
        assert_eq!(norm_key("周杰倫"), norm_key("周杰伦"));
        assert_eq!(norm_key("陳奕迅"), norm_key("陈奕迅"));
    }

    #[test]
    fn pinyin_variants_are_searchable() {
        let keys = search_keys(&["周杰伦", "晴天"]);
        // 原文、全拼、首字母都在里面。
        for expect in ["周杰伦", "zhoujielun", "zjl", "晴天", "qingtian", "qt"] {
            assert!(
                keys.split(' ').any(|k| k == expect),
                "缺少 {expect}: {keys}"
            );
        }
        // 纯英文只贡献一次，不重复。
        let keys = search_keys(&["Jay Chou"]);
        assert_eq!(keys.matches("jay chou").count(), 1);
    }

    #[test]
    fn query_expands_to_all_variants() {
        let q = fts_query("zjl").unwrap_or_default();
        assert!(q.contains("\"zjl\"*"), "{q}");
        // 简繁混着输入也能展开。
        let q = fts_query("周杰倫").unwrap_or_default();
        assert!(q.contains("周杰伦"), "{q}");
        assert!(q.contains("zhoujielun"), "{q}");
    }

    #[test]
    fn punctuation_only_input_yields_no_query() {
        assert_eq!(fts_query("..."), None);
        assert_eq!(fts_query("  ，。 "), None);
    }
}
