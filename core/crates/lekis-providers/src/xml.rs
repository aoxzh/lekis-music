//! 极简 XML → 树解析器（给 Plex 用）。
//!
//! Plex 的行为是"永远只给 XML"（`Accept: application/xml`），响应结构固定为
//! `MediaContainer` 套 `Track` / `Media` / `Part`。用 serde 反序列化 XML 要引 `quick-xml` 的
//! `serialize` 特性并且和命名空间、混合内容打架，不如直接遍历事件流建一棵小树，
//! 然后按名字取值 —— 逻辑简单、可测试、对 Plex 的多余属性也宽容。
//!
//! 只支持实际用得到的部分：元素、属性、文本、CDATA。注释、处理指令、DTD 直接跳过。

use lekis_types::{LekisError, Result};
use quick_xml::events::Event;
use quick_xml::{Reader, XmlVersion};

/// XML 元素（够用就行，不做命名空间解析）。
#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct XmlElement {
    /// 元素名（含前缀，比较时用 [`XmlElement::local_name`]）。
    pub name: String,
    /// 属性（顺序保留）。
    pub attributes: Vec<(String, String)>,
    /// 直接文本内容（拼接所有文本节点）。
    pub text: String,
    /// 子元素。
    pub children: Vec<XmlElement>,
}

impl XmlElement {
    /// 取属性（不区分大小写，Plex 的历史字段大小写混用）。
    pub(crate) fn attr(&self, name: &str) -> Option<&str> {
        self.attributes
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }

    /// 取属性的数值形式（取不到或者不是数字都是 `None`）。
    pub(crate) fn attr_parse<T: std::str::FromStr>(&self, name: &str) -> Option<T> {
        self.attr(name).and_then(|value| value.trim().parse().ok())
    }

    /// 名字去掉命名空间前缀后的部分。
    pub(crate) fn local_name(&self) -> &str {
        match self.name.split_once(':') {
            Some((_, local)) => local,
            None => &self.name,
        }
    }

    /// 第一个同名子元素。
    pub(crate) fn child(&self, name: &str) -> Option<&XmlElement> {
        self.children
            .iter()
            .find(|child| child.local_name().eq_ignore_ascii_case(name))
    }

    /// 所有同名子元素。
    pub(crate) fn children_named<'a>(
        &'a self,
        name: &'a str,
    ) -> impl Iterator<Item = &'a XmlElement> {
        self.children
            .iter()
            .filter(move |child| child.local_name().eq_ignore_ascii_case(name))
    }
}

/// 解析 XML 文本，返回根元素。
pub(crate) fn parse(xml: &str) -> Result<XmlElement> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);

    // 用显式的栈代替递归：Plex 的嵌套最深也就 MediaContainer > Track > Media > Part。
    let mut stack: Vec<XmlElement> = Vec::new();
    let mut root: Option<XmlElement> = None;

    loop {
        let event = reader
            .read_event()
            .map_err(|e| LekisError::invalid(format!("XML 解析失败：{e}")))?;

        match event {
            Event::Start(start) => stack.push(element_from_tag(&start)?),
            Event::Empty(empty) => {
                let element = element_from_tag(&empty)?;
                attach(&mut stack, &mut root, element);
            }
            Event::End(_) => {
                // 栈顶就是刚结束的元素；没有栈说明 XML 不平衡（read_event 一般会先报错，
                // 这里只是保险，不让它 panic）。
                if let Some(element) = stack.pop() {
                    attach(&mut stack, &mut root, element);
                }
            }
            Event::Text(text) => {
                let raw = text.into_inner();
                let decoded = quick_xml::escape::unescape(&raw)
                    .map(|cow| cow.into_owned())
                    .unwrap_or_else(|_| raw.into_owned());
                if let Some(top) = stack.last_mut() {
                    top.text.push_str(&decoded);
                }
            }
            Event::CData(cdata) => {
                let raw = cdata.into_inner();
                if let Some(top) = stack.last_mut() {
                    top.text.push_str(&raw);
                }
            }
            Event::Eof => break,
            // 注释、声明、处理指令、DTD、未解析的实体引用都不影响取值。
            _ => {}
        }
    }

    if stack.is_empty() {
        root.ok_or_else(|| LekisError::invalid("XML 里没有根元素"))
    } else {
        Err(LekisError::invalid("XML 里有未闭合的元素"))
    }
}

/// 从开始标签造一个空元素。
fn element_from_tag(tag: &quick_xml::events::BytesStart<'_>) -> Result<XmlElement> {
    let mut element = XmlElement {
        // quick-xml 0.42 起文本一律按 UTF-8 处理，名字直接就是 `&str`。
        name: tag.name().as_ref().to_string(),
        ..XmlElement::default()
    };
    for attribute in tag.attributes().with_checks(false) {
        let attribute =
            attribute.map_err(|e| LekisError::invalid(format!("XML 属性解析失败：{e}")))?;
        let key = attribute.key.as_ref().to_string();
        let value = attribute
            .normalized_value(XmlVersion::Implicit1_0)
            .map_err(|e| LekisError::invalid(format!("XML 属性归一化失败：{e}")))?
            .into_owned();
        element.attributes.push((key, value));
    }
    Ok(element)
}

/// 把完成的元素挂到父元素上；栈空时它就是根元素。
fn attach(stack: &mut [XmlElement], root: &mut Option<XmlElement>, element: XmlElement) {
    match stack.last_mut() {
        Some(parent) => parent.children.push(element),
        None => {
            if root.is_none() {
                *root = Some(element);
            }
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn parses_nested_attributes_and_text() {
        let xml = r#"<?xml version="1.0" encoding="UTF-8"?>
            <MediaContainer size="1" title="Music">
              <Track ratingKey="42" title="Bohemian Rhapsody" duration="354000">
                <Media id="7"><Part id="9" key="part-9-file" /></Media>
              </Track>
            </MediaContainer>"#;
        let root = parse(xml).unwrap();
        assert_eq!(root.local_name(), "MediaContainer");
        assert_eq!(root.attr("title"), Some("Music"));
        let track = root.child("Track").unwrap();
        assert_eq!(track.attr_parse::<u64>("duration"), Some(354_000));
        let part = track.child("Media").unwrap().child("Part").unwrap();
        assert_eq!(part.attr("key"), Some("part-9-file"));
    }

    #[test]
    fn decodes_entities() {
        let root =
            parse(r#"<a t="Simon &amp; Garfunkel"><b>The Sound of Silence</b></a>"#).unwrap();
        assert_eq!(root.attr("t"), Some("Simon & Garfunkel"));
        assert_eq!(root.child("b").unwrap().text, "The Sound of Silence");
    }

    #[test]
    fn rejects_broken_xml() {
        assert!(parse("<a><b></a>").is_err());
        assert!(parse("").is_err());
    }
}
