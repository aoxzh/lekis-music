//! 和操作系统无关的路径。

use std::fmt;

/// 相对于音源根目录的路径，用 `/` 分隔，不以 `/` 开头或结尾。根目录是空字符串。
///
/// 构造时会规范化：去掉 `.`、多余的 `/`，并拒绝 `..`（防止跳出根目录）。
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Default)]
pub struct VfsPath(String);

impl VfsPath {
    /// 根目录。
    pub fn root() -> Self {
        Self(String::new())
    }

    /// 从字符串解析。包含 `..` 时返回 `None`。
    pub fn parse(s: &str) -> Option<Self> {
        let mut parts = Vec::new();
        for part in s.split(['/', '\\']) {
            match part {
                "" | "." => continue,
                ".." => return None,
                p => parts.push(p),
            }
        }
        Some(Self(parts.join("/")))
    }

    /// 拼接一个子项名称。
    pub fn join(&self, name: &str) -> Self {
        if self.0.is_empty() {
            Self(name.to_string())
        } else {
            Self(format!("{}/{}", self.0, name))
        }
    }

    /// 字符串形式。
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// 是否是根目录。
    pub fn is_root(&self) -> bool {
        self.0.is_empty()
    }

    /// 最后一段（文件名）。
    pub fn file_name(&self) -> Option<&str> {
        self.0.rsplit('/').next().filter(|s| !s.is_empty())
    }

    /// 扩展名（不含点）。
    pub fn extension(&self) -> Option<&str> {
        let name = self.file_name()?;
        let (stem, ext) = name.rsplit_once('.')?;
        if stem.is_empty() {
            None
        } else {
            Some(ext)
        }
    }

    /// 父目录。根目录没有父目录。
    pub fn parent(&self) -> Option<Self> {
        if self.0.is_empty() {
            return None;
        }
        Some(match self.0.rsplit_once('/') {
            Some((parent, _)) => Self(parent.to_string()),
            None => Self::root(),
        })
    }
}

impl fmt::Display for VfsPath {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "/{}", self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_and_rejects_parent_dirs() {
        assert_eq!(
            VfsPath::parse("/a//b/./c/").map(|p| p.0),
            Some("a/b/c".into())
        );
        assert_eq!(VfsPath::parse("a\\b").map(|p| p.0), Some("a/b".into()));
        assert!(VfsPath::parse("a/../b").is_none());
    }

    #[test]
    fn file_name_extension_parent() {
        let p = VfsPath::parse("Music/周杰伦/晴天.flac").unwrap_or_default();
        assert_eq!(p.file_name(), Some("晴天.flac"));
        assert_eq!(p.extension(), Some("flac"));
        assert_eq!(p.parent().map(|x| x.0), Some("Music/周杰伦".into()));
        assert_eq!(
            VfsPath::parse(".hidden").unwrap_or_default().extension(),
            None
        );
    }
}
