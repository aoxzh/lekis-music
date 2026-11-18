//! 文本规范化：去重键、排序键、搜索键。
//!
//! TODO(LIB-07)：
//! - 繁体 → 简体（OpenCC），让"周杰倫"和"周杰伦"互通；
//! - 中文 → 拼音全拼 + 首字母（pinyin crate），支持 `zjl`、`zhoujielun` 搜到"周杰伦"；
//! - 日文假名 → 罗马字。
//!
//! 现在只做了小写和空白折叠，接口已经固定，补实现时不需要改调用方。

/// 去重用的规范化名称：小写、折叠空白、去掉首尾空白。
pub fn norm_key(s: &str) -> String {
    s.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

/// 排序键。中文以后转成拼音，这样"阿"排在"B"前面。
pub fn sort_key(s: &str) -> String {
    let lower = norm_key(s);
    // 去掉英文的冠词前缀，和其他播放器保持一致。
    for prefix in ["the ", "a ", "an "] {
        if let Some(rest) = lower.strip_prefix(prefix) {
            return rest.to_string();
        }
    }
    lower
}

/// 写进全文索引 `keys` 列的搜索键（多个键用空格拼接）。
pub fn search_keys(parts: &[&str]) -> String {
    parts
        .iter()
        .map(|p| norm_key(p))
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// 把用户输入转成 FTS5 查询：每个词做前缀匹配，并转义引号。
pub fn fts_query(input: &str) -> Option<String> {
    let terms: Vec<String> = norm_key(input)
        .split(' ')
        .filter(|t| !t.is_empty())
        .map(|t| format!("\"{}\"*", t.replace('"', "\"\"")))
        .collect();
    if terms.is_empty() {
        None
    } else {
        Some(terms.join(" "))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys() {
        assert_eq!(norm_key("  Jay   Chou "), "jay chou");
        assert_eq!(sort_key("The Beatles"), "beatles");
        assert_eq!(
            fts_query("jay \"chou"),
            Some("\"jay\"* \"\"\"chou\"*".to_string())
        );
        assert_eq!(fts_query("   "), None);
    }
}
