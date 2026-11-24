//! 日语注音歌词：给汉字标振假名（平假名），或者给整行标罗马音。
//!
//! 解决的是「日语歌词没有罗马音，看不懂 / 唱不出来」这件事。读音来自编译进
//! 二进制的常用汉字表（[`crate::ruby_ja_data`]，由 Unicode Unihan 的
//! `kJapanese` 字段生成），不联网、不加词典包。
//!
//! 和拼音注音一样，输出用 **UTF-16 偏移**，Dart 侧可以直接交给
//! `TextPainter.getBoxesForSelection`。
//!
//! 多音字按「送假名匹配 → 单字常用读音 → 音读」的保守顺序近似选择，
//! 再叠一张常见词 / 活用的小表。它是给「认字」用的提示，不是词典级
//! 分词：多音字和专有名词仍可能读错。

use crate::ruby::{is_han, RubySpan};
use crate::ruby_ja_data::{KanjiReadings, KANJI_READINGS};
use wana_kana::ConvertJapanese;

/// 日语注音写法。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum JapaneseRubyStyle {
    /// 汉字上方标平假名（振假名）。
    #[default]
    Kana,
    /// 汉字和假名上方标 Hepburn 罗马音。
    Romaji,
}

/// 是否为平假名（含假名扩展）。
#[must_use]
pub fn is_hiragana(ch: char) -> bool {
    matches!(ch as u32, 0x3041..=0x309F | 0x1B001..=0x1B11F)
}

/// 是否为片假名（含半角与假名扩展）。
#[must_use]
pub fn is_katakana(ch: char) -> bool {
    matches!(
        ch as u32,
        0x30A0..=0x30FF | 0x31F0..=0x31FF | 0xFF66..=0xFF9F
    )
}

/// 是否为假名（平假名或片假名）。
#[must_use]
pub fn is_kana(ch: char) -> bool {
    is_hiragana(ch) || is_katakana(ch)
}

/// 这段文本里有没有假名。给调用方判断「这是不是一行日语歌词」。
#[must_use]
pub fn contains_kana(text: &str) -> bool {
    text.chars().any(is_kana)
}

/// 给一行日语歌词生成注音区间。
///
/// 偏移是 **UTF-16**，可以直接给 Dart 用。没有假名的行（纯汉字 / 英文 /
/// 空行）返回空 `Vec`：只看一行无法判断纯汉字行是中文还是日文，宁可不动。
#[must_use]
pub fn annotate_line(line: &str, style: JapaneseRubyStyle) -> Vec<RubySpan> {
    if !contains_kana(line) {
        return Vec::new();
    }
    let mut spans = Vec::new();
    let mut byte = 0usize;
    let mut utf16 = 0usize;
    while byte < line.len() {
        let ch = next_char(line, byte);
        if is_han(ch) {
            let start_byte = byte;
            let start_utf16 = utf16;
            while byte < line.len() && is_han(next_char(line, byte)) {
                advance(line, &mut byte, &mut utf16);
            }
            let run = &line[start_byte..byte];
            let following = &line[byte..];
            if let Some(reading) = run_reading(run, following) {
                let ruby = match style {
                    JapaneseRubyStyle::Kana => reading,
                    // 汉字读音里可能正好是「は / へ / を」，不能按助词转写。
                    JapaneseRubyStyle::Romaji => reading.to_romaji(),
                };
                if !ruby.is_empty() {
                    spans.push(RubySpan {
                        start: start_utf16,
                        end: utf16,
                        ruby,
                    });
                }
            }
        } else if is_kana(ch) {
            let start_byte = byte;
            let start_utf16 = utf16;
            while byte < line.len() && is_kana(next_char(line, byte)) {
                advance(line, &mut byte, &mut utf16);
            }
            if style == JapaneseRubyStyle::Romaji {
                let ruby = kana_to_romaji(&line[start_byte..byte]);
                if !ruby.is_empty() {
                    spans.push(RubySpan {
                        start: start_utf16,
                        end: utf16,
                        ruby,
                    });
                }
            }
        } else {
            advance(line, &mut byte, &mut utf16);
        }
    }
    spans
}

/// 批量版本：一次把整首歌的歌词都注好音。
#[must_use]
pub fn annotate_lines<S: AsRef<str>>(lines: &[S], style: JapaneseRubyStyle) -> Vec<Vec<RubySpan>> {
    lines
        .iter()
        .map(|line| annotate_line(line.as_ref(), style))
        .collect()
}

fn next_char(text: &str, byte: usize) -> char {
    // 调用方只在 `byte < text.len()` 且停在字符边界时调用；兜底值只是
    // 为了让 clippy 的 `expect_used` 闭嘴，正常路径不会走到。
    text[byte..].chars().next().unwrap_or('\u{FFFD}')
}

fn advance(text: &str, byte: &mut usize, utf16: &mut usize) {
    let ch = next_char(text, *byte);
    *byte += ch.len_utf8();
    *utf16 += ch.len_utf16();
}

/// 表层假名转罗马音。单独的助词按发音转写（は → wa、へ → e、を → o）；
/// 汉字读音不走这里，否则「葉（は）」会被读成 wa。
fn kana_to_romaji(kana: &str) -> String {
    match kana {
        "は" | "ハ" => return "wa".to_owned(),
        "へ" | "ヘ" => return "e".to_owned(),
        "を" | "ヲ" => return "o".to_owned(),
        _ => {}
    }
    kana.to_romaji()
}

/// 一个汉字块的读音：先看活用 / 固定词，再按字逐个取音。
fn run_reading(run: &str, following: &str) -> Option<String> {
    if let Some(reading) = contextual_reading(run, following) {
        return Some(reading.to_owned());
    }
    let chars: Vec<char> = run.chars().collect();
    if chars.len() > 1 {
        if let Some(reading) = compound_reading(run) {
            return Some(reading.to_owned());
        }
    }
    let single = chars.len() == 1;
    let mut out = String::new();
    for (index, &ch) in chars.iter().enumerate() {
        let entry = readings_for(ch)?;
        let is_last = index + 1 == chars.len();
        let reading = if is_last {
            last_reading(ch, entry, following, single)?
        } else {
            first_reading(entry.on)
                .or_else(|| first_reading(entry.kun))?
                .to_owned()
        };
        out.push_str(&reading);
    }
    Some(out)
}

/// 汉字块最后一个字的读音。
fn last_reading(ch: char, entry: &KanjiReadings, following: &str, single: bool) -> Option<String> {
    if let Some(stem) = match_okurigana(entry.kun, following) {
        return Some(stem);
    }
    if single {
        let one = ch.to_string();
        if let Some(reading) = standalone_reading(&one) {
            return Some(reading.to_owned());
        }
        if let Some(reading) = first_reading(entry.kun) {
            return Some(reading.to_owned());
        }
    }
    first_reading(entry.on)
        .or_else(|| first_reading(entry.kun))
        .map(str::to_owned)
}

fn readings_for(ch: char) -> Option<&'static KanjiReadings> {
    KANJI_READINGS
        .binary_search_by_key(&ch, |entry| entry.ch)
        .ok()
        .map(|index| &KANJI_READINGS[index])
}

fn first_reading(readings: &str) -> Option<&str> {
    readings.split_whitespace().next()
}

/// 把汉字后面的送假名 / 活用词尾和读音表里的训读对上。
///
/// 读音表里的训读是辞书形（`たべる`、`はなす`、`うつくしい`），所以这里
/// 既接受「整个后缀就是送假名」（`食べる` → `た` + `べる`），也接受常见
/// 活用的词尾（`食べて` → `た`、`話して` → `はな`、`美しく` → `うつく`）。
fn match_okurigana(kun: &str, following: &str) -> Option<String> {
    let visible: Vec<char> = following.chars().take_while(|ch| is_kana(*ch)).collect();
    if visible.is_empty() {
        return None;
    }
    let first = visible[0];
    let mut best_matched = 0usize;
    let mut best_stem = None;
    for reading in kun.split_whitespace() {
        let chars: Vec<char> = reading.chars().collect();
        if chars.len() < 2 {
            continue;
        }
        for split in 1..chars.len() {
            let suffix: String = chars[split..].iter().collect();
            // 送假名可能被下一个汉字截断（食べ物 → べ），所以这里比对
            // 最长公共前缀，而不是要求整个后缀都出现。
            let shared = visible
                .iter()
                .zip(chars[split..].iter())
                .take_while(|(a, b)| a == b)
                .count();
            if shared > best_matched {
                best_matched = shared;
                best_stem = Some(chars[..split].iter().collect::<String>());
            }
            for form in inflections(&suffix, first) {
                let form: Vec<char> = form.chars().collect();
                if form.is_empty() || form.len() > visible.len() {
                    continue;
                }
                if visible[..form.len()] == form[..] && form.len() > best_matched {
                    best_matched = form.len();
                    best_stem = Some(chars[..split].iter().collect::<String>());
                }
            }
        }
    }
    best_stem
}

/// 从送假名后缀生成常见活用后的可见假名。
///
/// 只求覆盖歌词里最常见的动词 / 形容词活用，不追求语法完备；多生成几个
/// 候选比漏掉好，匹配时取最长的那个。
fn inflections(suffix: &str, first: char) -> Vec<String> {
    let chars: Vec<char> = suffix.chars().collect();
    let Some(&last) = chars.last() else {
        return Vec::new();
    };
    let stem: String = chars[..chars.len() - 1].iter().collect();
    // 可见假名的首字必须和词尾首字一致，否则这条后缀不可能匹配。
    let has_stem = !stem.is_empty();
    if has_stem && !stem.starts_with(first) {
        return Vec::new();
    }
    let endings: &[&str] = match last {
        'い' => &[
            "く",
            "くて",
            "かった",
            "くない",
            "くなかった",
            "ければ",
            "さ",
            "そう",
            "すぎる",
        ],
        'う' => &[
            "って",
            "った",
            "っている",
            "っていた",
            "っています",
            "います",
            "いました",
            "いません",
            "わない",
            "わなかった",
            "わなければ",
            "おう",
            "える",
            "えない",
            "えなかった",
            "えなく",
            "えなくて",
            "えなければ",
            "えた",
            "えれば",
            "わせる",
            "わせた",
            "わせて",
            "わせない",
            "いそう",
            "いたい",
            "いたくない",
            "いたかった",
            "いながら",
            "いなさい",
            "いましょう",
            "え",
            // 连用形
            "い",
        ],
        'く' => &[
            "いて",
            "いた",
            "いている",
            "いていた",
            "いています",
            "きます",
            "きました",
            "きません",
            "かない",
            "かなかった",
            "かなければ",
            "こう",
            "ける",
            "けない",
            "けなかった",
            "けなく",
            "けなくて",
            "けなければ",
            "けた",
            "けば",
            "かせる",
            "かせた",
            "かせて",
            "かせない",
            "きそう",
            "きたい",
            "きたくない",
            "きたかった",
            "きながら",
            "きなさい",
            "きましょう",
            "け",
            // 行って / 行った 的不规则促音便。
            "って",
            "った",
            "っている",
            "っていた",
            "っています",
            // 连用形（書き方）
            "き",
        ],
        'ぐ' => &[
            "いで",
            "いだ",
            "いでいる",
            "いでいた",
            "ぎます",
            "ぎました",
            "がない",
            "がなかった",
            "がなければ",
            "ごう",
            "げる",
            "げない",
            "げなかった",
            "げなく",
            "げなくて",
            "げなければ",
            "げた",
            "げば",
            "がせる",
            "がせた",
            "がせて",
            "がせない",
            "ぎそう",
            "ぎたい",
            "ぎたくない",
            "ぎたかった",
            "ぎながら",
            "ぎなさい",
            "ぎましょう",
            "げ",
            "ぎ",
        ],
        'す' => &[
            "して",
            "した",
            "している",
            "していた",
            "しています",
            "します",
            "しました",
            "しません",
            "さない",
            "さなかった",
            "さなければ",
            "そう",
            "せる",
            "せない",
            "せなかった",
            "せなく",
            "せなくて",
            "せなければ",
            "せた",
            "せば",
            "させる",
            "させた",
            "させて",
            "させない",
            "しそう",
            "したい",
            "したくない",
            "したかった",
            "しながら",
            "しなさい",
            "しましょう",
            "しすぎる",
            "しやすい",
            "しにくい",
            "せ",
            "せよ",
            "し",
        ],
        'つ' => &[
            "って",
            "った",
            "っている",
            "っていた",
            "っています",
            "ちます",
            "ちました",
            "たない",
            "たなかった",
            "たなければ",
            "とう",
            "てる",
            "てない",
            "てなかった",
            "てなく",
            "てなくて",
            "てなければ",
            "てた",
            "てば",
            "たせる",
            "たせた",
            "たせて",
            "たせない",
            "ちそう",
            "ちたい",
            "ちたくない",
            "ちたかった",
            "ちながら",
            "ちなさい",
            "ちましょう",
            "て",
            "ち",
        ],
        'ぬ' => &[
            "んで",
            "んだ",
            "んでいる",
            "んでいた",
            "にます",
            "にました",
            "なない",
            "ななかった",
            "ななければ",
            "のう",
            "ねる",
            "ねない",
            "ねなかった",
            "ねなく",
            "ねなくて",
            "ねなければ",
            "ねた",
            "ねば",
            "なせる",
            "なせた",
            "なせて",
            "なせない",
            "にそう",
            "にたい",
            "にたくない",
            "にたかった",
            "にながら",
            "になさい",
            "にましょう",
            "ね",
            "に",
        ],
        'ぶ' => &[
            "んで",
            "んだ",
            "んでいる",
            "んでいた",
            "びます",
            "びました",
            "ばない",
            "ばなかった",
            "ばなければ",
            "ぼう",
            "べる",
            "べない",
            "べなかった",
            "べなく",
            "べなくて",
            "べなければ",
            "べた",
            "べば",
            "ばせる",
            "ばせた",
            "ばせて",
            "ばせない",
            "びそう",
            "びたい",
            "びたくない",
            "びたかった",
            "びながら",
            "びなさい",
            "びましょう",
            "べ",
            "び",
        ],
        'む' => &[
            "んで",
            "んだ",
            "んでいる",
            "んでいた",
            "みます",
            "みました",
            "まない",
            "まなかった",
            "まなければ",
            "もう",
            "める",
            "めない",
            "めなかった",
            "めなく",
            "めなくて",
            "めなければ",
            "めた",
            "めば",
            "ませる",
            "ませた",
            "ませて",
            "ませない",
            "みそう",
            "みたい",
            "みたくない",
            "みたかった",
            "みながら",
            "みなさい",
            "みましょう",
            "め",
            // 连用形（飲み物）
            "み",
        ],
        'る' => &[
            // 一段动词
            "て",
            "た",
            "ている",
            "ていた",
            "ています",
            "ます",
            "ました",
            "ません",
            "たい",
            "たくない",
            "たかった",
            "ながら",
            "なさい",
            "ましょう",
            "ない",
            "なかった",
            "なければ",
            "よう",
            "れば",
            "られる",
            "られない",
            "られなかった",
            "られなく",
            "られなくて",
            "られなければ",
            "られた",
            "させる",
            "させた",
            "させて",
            "させない",
            "すぎる",
            "やすい",
            "にくい",
            "そう",
            "ろ",
            // 五段动词
            "って",
            "った",
            "っている",
            "っていた",
            "っています",
            "ります",
            "りました",
            "らない",
            "らなかった",
            "らなければ",
            "ろう",
            "れる",
            "れない",
            "れなかった",
            "れなく",
            "れなくて",
            "れなければ",
            "れた",
            "れば",
            "らせる",
            "らせた",
            "らせて",
            "らせない",
            "りそう",
            "りたい",
            "りたくない",
            "りたかった",
            "りながら",
            "りなさい",
            "りましょう",
            "れ",
            "り",
        ],
        _ => &[],
    };
    endings
        .iter()
        .filter(|ending| has_stem || ending.starts_with(first))
        .map(|ending| format!("{stem}{ending}"))
        .collect()
}

/// 单字在独立出现时的常用读音（优先于「训读第一个」的默认规则）。
fn standalone_reading(run: &str) -> Option<&'static str> {
    Some(match run {
        "光" => "ひかり",
        "夜" => "よる",
        "愛" => "あい",
        "影" => "かげ",
        "姿" => "すがた",
        "瞳" => "ひとみ",
        "涙" => "なみだ",
        "声" => "こえ",
        "夢" => "ゆめ",
        "星" => "ほし",
        "月" => "つき",
        "雪" => "ゆき",
        "風" => "かぜ",
        "空" => "そら",
        "海" => "うみ",
        "花" => "はな",
        "雨" => "あめ",
        "心" => "こころ",
        "命" => "いのち",
        "恋" => "こい",
        "手" => "て",
        "目" => "め",
        "唇" => "くちびる",
        "髪" => "かみ",
        "顔" => "かお",
        "背" => "せ",
        "朝" => "あさ",
        "夏" => "なつ",
        "冬" => "ふゆ",
        "春" => "はる",
        "秋" => "あき",
        "生" => "せい",
        "分" => "ぶん",
        "縁" => "えん",
        "後" => "あと",
        "回" => "かい",
        "番" => "ばん",
        "号" => "ごう",
        "円" => "えん",
        "本" => "ほん",
        "敵" => "てき",
        "一" => "いち",
        "二" => "に",
        "三" => "さん",
        "四" => "よん",
        "五" => "ご",
        "六" => "ろく",
        "八" => "はち",
        "九" => "きゅう",
        "十" => "じゅう",
        "百" => "ひゃく",
        "千" => "せん",
        "万" => "まん",
        _ => return None,
    })
}

/// 常见词的整体读音（只用于多字汉字块）。
fn compound_reading(run: &str) -> Option<&'static str> {
    Some(match run {
        "今日" => "きょう",
        "明日" => "あした",
        "昨日" => "きのう",
        "今年" => "ことし",
        "一昨日" => "おととい",
        "一人" => "ひとり",
        "二人" => "ふたり",
        "大人" => "おとな",
        "一緒" => "いっしょ",
        "上手" => "じょうず",
        "下手" => "へた",
        "大丈夫" => "だいじょうぶ",
        "大人気" => "だいにんき",
        "大和" => "やまと",
        "一生" => "いっしょう",
        "一瞬" => "いっしゅん",
        "一体" => "いったい",
        "一回" => "いっかい",
        "一杯" => "いっぱい",
        "一般" => "いっぱん",
        "一方" => "いっぽう",
        "一本" => "いっぽん",
        "一歩" => "いっぽ",
        "一匹" => "いっぴき",
        "唯一" => "ゆいいつ",
        "祖父" => "そふ",
        "祖母" => "そぼ",
        "兄弟" => "きょうだい",
        "姉妹" => "しまい",
        "土産" => "みやげ",
        "洒落" => "しゃれ",
        "手洗" => "てあら",
        "本音" => "ほんね",
        "本屋" => "ほんや",
        "本棚" => "ほんだな",
        "名前" => "なまえ",
        "何度" => "なんど",
        "何回" => "なんかい",
        "何人" => "なんにん",
        "何年" => "なんねん",
        "何月" => "なんがつ",
        "何日" => "なんにち",
        "何時" => "なんじ",
        "何分" => "なんぷん",
        "何色" => "なにいろ",
        "何処" => "どこ",
        "世界中" => "せかいじゅう",
        "日本中" => "にほんじゅう",
        "一日中" => "いちにちじゅう",
        "今日中" => "きょうじゅう",
        "今年中" => "ことしじゅう",
        "可愛" => "かわい",
        "素敵" => "すてき",
        "無理" => "むり",
        "迷惑" => "めいわく",
        "田舎" => "いなか",
        "眼鏡" => "めがね",
        "美味" => "おい",
        "面白" => "おもしろ",
        "気持" => "きも",
        "大好" => "だいす",
        "大嫌" => "だいきら",
        "彼女" => "かのじょ",
        "何故" => "なぜ",
        "俺達" => "おれたち",
        "僕等" => "ぼくら",
        "君等" => "きみら",
        "俺等" => "おれら",
        "子供" => "こども",
        "夜空" => "よぞら",
        "星空" => "ほしぞら",
        "景色" => "けしき",
        "笑顔" => "えがお",
        "素直" => "すなお",
        "素顔" => "すがお",
        "初恋" => "はつこい",
        "恋心" => "こいごころ",
        "三日月" => "みかづき",
        "木漏" => "こも",
        "陽射" => "ひざ",
        "黄昏" => "たそがれ",
        "花見" => "はなみ",
        "月見" => "つきみ",
        "花火" => "はなび",
        "花束" => "はなたば",
        "花言葉" => "はなことば",
        "手紙" => "てがみ",
        "足跡" => "あしあと",
        "山道" => "やまみち",
        "雨降" => "あめふ",
        "雪降" => "ゆきふ",
        "雨上" => "あめあ",
        "雨粒" => "あまつぶ",
        "見方" => "みかた",
        "見本" => "みほん",
        "見事" => "みごと",
        "夕日" => "ゆうひ",
        "夕焼" => "ゆうや",
        "朝日" => "あさひ",
        "朝焼" => "あさや",
        "大声" => "おおごえ",
        "大雨" => "おおあめ",
        "大雪" => "おおゆき",
        "大空" => "おおぞら",
        "小鳥" => "ことり",
        "小川" => "おがわ",
        "小雨" => "こさめ",
        "小声" => "こごえ",
        "一晩" => "ひとばん",
        "今朝" => "けさ",
        "音色" => "ねいろ",
        "声色" => "こわいろ",
        "水音" => "みずおと",
        "水色" => "みずいろ",
        "風向" => "かざむ",
        "風車" => "かざぐるま",
        "涙声" => "なみだごえ",
        "木陰" => "こかげ",
        "木立" => "こだち",
        "日本" => "にほん",
        "日本語" => "にほんご",
        "東京" => "とうきょう",
        "大阪" => "おおさか",
        "京都" => "きょうと",
        "微笑" => "ほほえ",
        "歌声" => "うたごえ",
        "雨音" => "あまおと",
        "足音" => "あしおと",
        "物音" => "ものおと",
        "今宵" => "こよい",
        "未来" => "みらい",
        "運命" => "うんめい",
        "奇跡" => "きせき",
        "約束" => "やくそく",
        "時間" => "じかん",
        "瞬間" => "しゅんかん",
        "全部" => "ぜんぶ",
        "本当" => "ほんとう",
        "世界" => "せかい",
        _ => return None,
    })
}

/// 活用 / 固定搭配的读音（优先于逐字规则）。
const CONTEXT_READING: &[(&str, &str, &str)] = &[
    ("来", "て", "き"),
    ("来", "た", "き"),
    ("来", "ます", "き"),
    ("来", "ました", "き"),
    ("来", "ません", "き"),
    ("来", "られ", "こ"),
    ("来", "ない", "こ"),
    ("来", "なか", "こ"),
    ("来", "る", "く"),
    ("来", "れ", "こ"),
    ("来", "よう", "こ"),
    ("来", "たい", "き"),
    ("来", "い", "こ"),
    ("好", "き", "す"),
    ("嫌", "だ", "いや"),
    ("生", "まれ", "う"),
    ("母", "さん", "かあ"),
    ("母", "ちゃん", "かあ"),
    ("父", "さん", "とう"),
    ("父", "ちゃん", "とう"),
    ("兄", "さん", "にい"),
    ("兄", "ちゃん", "にい"),
    ("姉", "さん", "ねえ"),
    ("姉", "ちゃん", "ねえ"),
    ("祖父", "さん", "じい"),
    ("祖父", "ちゃん", "じい"),
    ("祖母", "さん", "ばあ"),
    ("祖母", "ちゃん", "ばあ"),
    ("巡", "り", "まわ"),
    ("待", "たせ", "ま"),
    ("何", "でも", "なん"),
    ("何", "にも", "なん"),
    ("想", "い", "おも"),
    ("願", "い", "ねが"),
    ("祈", "り", "いの"),
    ("誓", "い", "ちか"),
    ("叫", "び", "さけ"),
    ("違", "い", "ちが"),
    ("望", "み", "のぞ"),
    ("頼", "み", "たの"),
    ("頼", "り", "たよ"),
    ("眠", "り", "ねむ"),
    ("笑", "み", "え"),
    ("喜", "び", "よろこ"),
    ("悲", "しみ", "かな"),
    ("苦", "しみ", "くる"),
    ("楽", "しみ", "たの"),
    ("愛", "して", "あい"),
    ("愛", "した", "あい"),
    ("愛", "する", "あい"),
    ("愛", "され", "あい"),
    ("愛", "せる", "あい"),
];

fn contextual_reading(run: &str, following: &str) -> Option<&'static str> {
    let mut best = None;
    for &(key, after, reading) in CONTEXT_READING {
        if run != key || !following.starts_with(after) {
            continue;
        }
        let len = after.chars().count();
        if best.is_none_or(|(_, best_len)| len > best_len) {
            best = Some((reading, len));
        }
    }
    best.map(|(reading, _)| reading)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rubies(line: &str, style: JapaneseRubyStyle) -> Vec<String> {
        annotate_line(line, style)
            .into_iter()
            .map(|span| span.ruby)
            .collect()
    }

    fn kana(line: &str) -> Vec<String> {
        rubies(line, JapaneseRubyStyle::Kana)
    }

    #[test]
    fn kana_detection() {
        assert!(contains_kana("君の名は"));
        assert!(contains_kana("カタカナ"));
        assert!(!contains_kana("晴天"));
        assert!(!contains_kana("Hello"));
    }

    #[test]
    fn furigana_uses_okurigana_and_kun_readings() {
        assert_eq!(kana("君の名は"), ["きみ", "な"]);
        assert_eq!(kana("食べる"), ["た"]);
        assert_eq!(kana("食べて"), ["た"]);
        assert_eq!(kana("話して"), ["はな"]);
        assert_eq!(kana("美しく"), ["うつく"]);
        assert_eq!(kana("少し"), ["すこ"]);
        assert_eq!(kana("光り"), ["ひか"]);
        assert_eq!(kana("食べ物"), ["た", "もの"]);
        assert_eq!(kana("飲み物"), ["の", "もの"]);
        assert_eq!(kana("話し手"), ["はな", "て"]);
        assert_eq!(kana("帰って"), ["かえ"]);
        assert_eq!(kana("高かった"), ["たか"]);
        assert_eq!(kana("分かり"), ["わ"]);
    }

    #[test]
    fn compound_and_irregular_readings() {
        assert_eq!(kana("東京の夜"), ["とうきょう", "よる"]);
        assert_eq!(kana("今日は"), ["きょう"]);
        assert_eq!(kana("大人しい"), ["おとな"]);
        assert_eq!(kana("来て"), ["き"]);
        assert_eq!(kana("行って"), ["い"]);
        assert_eq!(kana("愛して"), ["あい"]);
        assert_eq!(kana("咲いた"), ["さ"]);
        assert_eq!(kana("お母さん"), ["かあ"]);
        assert_eq!(kana("何度も"), ["なんど"]);
        assert_eq!(kana("一生を"), ["いっしょう"]);
        assert_eq!(kana("本音で"), ["ほんね"]);
        assert_eq!(kana("世界中で"), ["せかいじゅう"]);
        assert_eq!(kana("本の"), ["ほん"]);
        assert_eq!(kana("後ろ"), ["うし"]);
        assert_eq!(kana("後で"), ["あと"]);
        assert_eq!(kana("会いたい"), ["あ"]);
        assert_eq!(kana("好き"), ["す"]);
        assert_eq!(kana("名前を"), ["なまえ"]);
        assert_eq!(kana("歌いながら"), ["うた"]);
        assert_eq!(kana("食べられない"), ["た"]);
        assert_eq!(kana("帰りたい"), ["かえ"]);
        assert_eq!(kana("会えなくて"), ["あ"]);
        assert_eq!(kana("聞かせて"), ["き"]);
        assert_eq!(kana("走り出せ"), ["はし", "だ"]);
    }

    #[test]
    fn romaji_covers_kanji_and_kana() {
        assert_eq!(
            rubies("君の名は", JapaneseRubyStyle::Romaji),
            ["kimi", "no", "na", "wa"]
        );
        assert_eq!(
            rubies("東京", JapaneseRubyStyle::Romaji),
            Vec::<String>::new()
        );
        assert_eq!(
            rubies("東京へ", JapaneseRubyStyle::Romaji),
            ["toukyou", "e"]
        );
        // 汉字读音「は」保持 ha，只有表层助词转成 wa。
        assert_eq!(rubies("葉は", JapaneseRubyStyle::Romaji), ["ha", "wa"]);
    }

    #[test]
    fn no_kana_means_no_spans() {
        assert!(kana("晴天").is_empty());
        assert!(kana("Hello world").is_empty());
    }

    #[test]
    fn offsets_are_utf16_units() {
        let spans = annotate_line("🎵君の名は", JapaneseRubyStyle::Kana);
        assert_eq!(spans[0].start, 2);
        assert_eq!(spans[0].end, 3);
        assert_eq!(spans[1].start, 4);
        assert_eq!(spans[1].end, 5);
    }

    #[test]
    fn batch_matches_single() {
        let lines = ["君の名は", "きょうのあめ", ""];
        let batch = annotate_lines(&lines, JapaneseRubyStyle::Kana);
        assert_eq!(batch.len(), 3);
        assert_eq!(batch[0], annotate_line(lines[0], JapaneseRubyStyle::Kana));
        assert!(batch[1].is_empty());
        assert!(batch[2].is_empty());
    }
}
