//! 标签读取。
//!
//! [`TagReader`] 是同步接口（CPU 密集），扫描器在 `spawn_blocking` 里调用它。

use std::io::{self, Read, Seek, SeekFrom};

use lekis_library::ScannedTags;
use lekis_types::{AudioProps, Codec, ErrorCode, LekisError, ReplayGain, Result};
use lekis_vfs::partial::PartialFile;
use lekis_vfs::VfsPath;
use lofty::config::ParseOptions;
use lofty::error::FileParseError;
use lofty::file::{AudioFile, FileType, TaggedFile, TaggedFileExt};
use lofty::probe::Probe;
use lofty::properties::FileProperties;
use lofty::tag::{ItemKey, Tag, TagType};

/// 标签解析器。
pub trait TagReader: Send + Sync {
    /// 从文件头尾数据里解析标签。数据不够时返回 `Err`，扫描器会用文件名兜底
    /// （以后改成：返回"需要补读的范围"，由扫描器补读后重试）。
    fn read(&self, path: &VfsPath, data: &PartialFile) -> Result<ScannedTags>;
}

/// 把 [`PartialFile`] 的两段字节伪装成一个完整的可读文件（LIB-02）。
///
/// `lofty` 需要一个 `Read + Seek` 的文件，但我们只拿到了头部和尾部。中间没读过的区域
/// 在读的时候返回 [`io::ErrorKind::UnexpectedEof`]：这样 lofty 会走"只读头尾"的路径
/// （ID3v2 / FLAC metadata block / MP3 首帧在头部，ID3v1 / APEv2 / 末帧在尾部），
/// 而不会试图把整个文件读进内存，也不会把缺口当成 0 字节数据去解析。
///
/// `Seek` 允许跳到任意位置（包括还没读过的区域和文件末尾），只有真正 `Read` 到缺口才报错。
#[derive(Debug)]
pub struct SparseReader<'a> {
    /// 文件总长度。
    size: u64,
    /// 头部数据（从偏移 0 开始）。
    head: &'a [u8],
    /// 尾部数据（到文件末尾结束）。
    tail: &'a [u8],
    /// 尾部数据在文件中的起始偏移。
    tail_start: u64,
    /// 当前读位置。
    pos: u64,
}

impl<'a> SparseReader<'a> {
    /// 用头尾数据构造。
    pub fn new(data: &'a PartialFile) -> Self {
        Self {
            size: data.size,
            head: data.head.as_ref(),
            tail: data.tail.as_ref(),
            tail_start: data.size.saturating_sub(data.tail.len() as u64),
            pos: 0,
        }
    }

    /// 文件总长度。
    pub fn len(&self) -> u64 {
        self.size
    }

    /// 是否是个空文件。
    pub fn is_empty(&self) -> bool {
        self.size == 0
    }
}

impl Read for SparseReader<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() || self.pos >= self.size {
            return Ok(0);
        }

        // 本次最多能读多少（不越过文件末尾）。
        let want = usize::try_from(self.size - self.pos)
            .unwrap_or(usize::MAX)
            .min(buf.len());

        // 头部区间。
        if self.pos < self.head.len() as u64 {
            let offset = usize::try_from(self.pos).unwrap_or(usize::MAX);
            let n = want.min(self.head.len() - offset);
            buf[..n].copy_from_slice(&self.head[offset..offset + n]);
            self.pos += n as u64;
            return Ok(n);
        }

        // 尾部区间。
        if self.pos >= self.tail_start {
            let offset = usize::try_from(self.pos - self.tail_start).unwrap_or(usize::MAX);
            let n = want.min(self.tail.len().saturating_sub(offset));
            if n == 0 {
                return Ok(0);
            }
            buf[..n].copy_from_slice(&self.tail[offset..offset + n]);
            self.pos += n as u64;
            return Ok(n);
        }

        // 中间的缺口：我们从来没读过这段数据。
        Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            format!(
                "文件偏移 {} 处的数据没有读取过（只缓存了头 {} 字节和尾部 {} 字节）",
                self.pos,
                self.head.len(),
                self.tail.len()
            ),
        ))
    }
}

impl Seek for SparseReader<'_> {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        // 用 i128 算，避免 u64 加减溢出；负数位置报错（lofty 探测 ID3v1 时依赖这个）。
        let target = match pos {
            SeekFrom::Start(n) => i128::from(n),
            SeekFrom::Current(n) => i128::from(self.pos) + i128::from(n),
            SeekFrom::End(n) => i128::from(self.size) + i128::from(n),
        };
        let new_pos = u64::try_from(target).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("seek 到了负的文件偏移：{target}"),
            )
        })?;
        self.pos = new_pos;
        Ok(new_pos)
    }
}

/// 基于 lofty 的实现（LIB-02）。
///
/// 支持的标签：ID3v1 / ID3v2.3 / ID3v2.4、Vorbis Comment（FLAC、Ogg）、MP4 `ilst`
/// atoms、APEv2、RIFF INFO。格式由 lofty 按文件魔数自己判断，判断不出来时退回扩展名。
///
/// 只读头尾：音频属性取 lofty 解析出的流信息；拿不到时长时才用
/// `文件大小 / 码率` 估算。标签完全读不出来时用 [`tags_from_file_name`] 补齐标题和专辑，
/// 但文件根本不是音频（或标签损坏到 lofty 报错）时返回 [`ErrorCode::Decode`] 错误，
/// 由扫描器决定怎么兜底。
pub struct LoftyTagReader;

impl TagReader for LoftyTagReader {
    fn read(&self, path: &VfsPath, data: &PartialFile) -> Result<ScannedTags> {
        if is_apple_double(data) {
            return Err(LekisError::new(
                ErrorCode::Unsupported,
                format!("macOS AppleDouble resource fork, not audio: {path}"),
            ));
        }
        let tagged = read_tagged_file(path, data, false)?;

        let mut tags = ScannedTags::default();
        if let Some(tag) = pick_tag(&tagged) {
            apply_tag(&mut tags, tag);
        }

        // 音频属性 + 时长：优先用 lofty 从流信息里算出来的值。
        let properties = tagged.properties();
        let audio = audio_props(tagged.file_type(), properties, data);
        let mut duration_ms = u64::try_from(properties.duration().as_millis()).unwrap_or(u64::MAX);
        if duration_ms == 0 {
            // lofty 没算出时长（例如 MP3 的末帧找不到）：拿码率估算一个。
            // 用的是整个文件大小（含标签），只用于列表展示，误差可以接受。
            if let Some(kbps) = audio
                .as_ref()
                .and_then(|a| a.bitrate_kbps)
                .filter(|v| *v > 0)
            {
                duration_ms = data.size.saturating_mul(8) / u64::from(kbps);
            }
        }
        tags.audio = audio;
        tags.duration_ms = duration_ms;

        // 标签里什么都没有时，用文件名兜底（和扫描器挂在 `Err` 上的兜底不冲突）。
        fallback_from_file_name(&mut tags, path);

        Ok(tags)
    }
}

/// 读取文件里第一张内嵌封面（ENR-01 的本地部分）。
///
/// 扫描阶段为了速度不解析封面；封面补填阶段用更大的头尾窗口调用这里。
/// 一张图都没有时返回 `Ok(None)`；文件不是音频 / 标签损坏时返回错误，由调用方跳过。
pub fn read_cover_art(path: &VfsPath, data: &PartialFile) -> Result<Option<Vec<u8>>> {
    let tagged = read_tagged_file(path, data, true)?;
    for tag in tagged.tags() {
        if let Some(picture) = tag.pictures().first() {
            if !picture.data().is_empty() {
                return Ok(Some(picture.data().to_vec()));
            }
        }
    }
    Ok(None)
}

/// 读内嵌歌词（ID3 USLT / Vorbis LYRICS / MP4 ©lyr）。没有时返回 `None`。
pub fn read_lyrics(path: &VfsPath, data: &PartialFile) -> Result<Option<String>> {
    let tagged = read_tagged_file(path, data, false)?;
    for tag in tagged.tags() {
        if let Some(text) = tag.get_string(ItemKey::Lyrics) {
            let text = text.trim();
            if !text.is_empty() {
                return Ok(Some(text.to_string()));
            }
        }
    }
    Ok(None)
}

/// 用 lofty 打开文件并读出标签 + 流信息。
///
/// 先按文件内容猜格式（`fLaC`、MP3 帧同步、MP4 `ftyp`……），猜不出来再按扩展名。
fn read_tagged_file(
    path: &VfsPath,
    data: &PartialFile,
    read_cover_art: bool,
) -> Result<TaggedFile> {
    // 扫描阶段只要标签和流信息，不需要封面（封面可能几百 KB，而且我们只缓存了头尾）。
    // 封面补填阶段会显式传 true，并用更大的头尾窗口。
    let options = ParseOptions::new().read_cover_art(read_cover_art);

    let guessed = Probe::new(SparseReader::new(data))
        .options(options)
        .guess_file_type();
    match guessed {
        Ok(probe) => {
            // `FileType::Custom` 没有注册 resolver，lofty 会在 read 里 panic，必须避开。
            let usable = probe
                .file_type()
                .filter(|file_type| !matches!(file_type, FileType::Custom(_)));
            if usable.is_some() {
                return to_leks_result(probe.read(), path);
            }
        }
        Err(e) => {
            tracing::debug!(
                target: "scanner",
                path = %path,
                error = %e,
                "content sniff failed, falling back to file extension"
            );
        }
    }

    // 内容猜不出来（例如头部被写坏了）：用扩展名再试一次。
    let Some(file_type) = path
        .extension()
        .and_then(FileType::from_ext)
        .filter(|file_type| !matches!(file_type, FileType::Custom(_)))
    else {
        return Err(LekisError::new(
            ErrorCode::Decode,
            format!("无法识别音频格式：{path}"),
        ));
    };

    let probe = Probe::with_file_type(SparseReader::new(data), file_type).options(options);
    to_leks_result(probe.read(), path)
}

/// 头部窗口最多扩到多大。再大的文件（巨型封面的 hi-res 专辑）就放弃，用文件名兜底。
pub const MAX_HEAD: u64 = 48 * 1024 * 1024;

/// 读完标签之后还要多读的音频数据（MP3 要连上几帧、FLAC 之后就是帧数据）。
const AUDIO_SLACK: u64 = 64 * 1024;

/// macOS 的 AppleDouble 资源分叉（`._歌名.mp3`，拷贝时点号丢了就成了
/// `_歌名.mp3`）：魔数 `00 05 16 07`，不是音频。
pub fn is_apple_double(data: &PartialFile) -> bool {
    data.head.starts_with(&[0x00, 0x05, 0x16, 0x07])
}

/// 头尾窗口要扩到多大（[`wanted_window`] 的结果）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WantedWindow {
    /// 头部至少读这么多字节。
    pub head: u64,
    /// 尾部至少读这么多字节。
    pub tail: u64,
}

/// 第一次只读了头尾、标签却解析失败时：沿着容器结构（ID3v2、FLAC 元数据块、
/// RIFF/WAVE、AIFF、MP4 atom）算出头尾窗口至少要多大，才能把音频数据以外的
/// 部分读全。不认识的格式、或者窗口已经够大时返回 `None`。
///
/// 常见原因是内嵌了大封面：ID3v2 的 APIC、FLAC 的 PICTURE 块、WAV 末尾的
/// `id3 ` 块、MP4 的 `moov` 动辄几 MB，远超默认窗口，lofty 读到缺口就报错。
pub fn wanted_window(data: &PartialFile) -> Option<WantedWindow> {
    if data.is_complete() {
        return None;
    }
    let mut want = WantedWindow {
        head: data.head.len() as u64,
        tail: data.tail.len() as u64,
    };
    let view = View { data };
    let mut pos = 0u64;

    // ID3v2 前缀（MP3 / AAC，有些 FLAC 也挂一个）：10 字节头 + syncsafe 长度。
    if let Some(h) = view.bytes(0, 10).filter(|h| &h[..3] == b"ID3") {
        let size = h[6..10]
            .iter()
            .fold(0u64, |acc, b| (acc << 7) | u64::from(b & 0x7F));
        let footer = if h[5] & 0x10 != 0 { 10 } else { 0 };
        pos = 10 + size + footer;
        want.head = want.head.max(pos + AUDIO_SLACK);
    }

    match view.bytes(pos, 4) {
        Some(b"fLaC") => walk_flac(&view, pos + 4, &mut want),
        Some(b"RIFF") if view.bytes(pos + 8, 4) == Some(b"WAVE") => {
            walk_chunks(&view, pos + 12, Endian::Little, b"data", &mut want);
        }
        Some(b"FORM") if matches!(view.bytes(pos + 8, 4), Some(b"AIFF" | b"AIFC")) => {
            walk_chunks(&view, pos + 12, Endian::Big, b"SSND", &mut want);
        }
        _ if view.bytes(pos + 4, 4) == Some(b"ftyp") => walk_mp4(&view, pos, &mut want),
        _ => {}
    }

    want.head = want.head.min(data.size).min(MAX_HEAD);
    want.tail = want.tail.min(data.size).min(MAX_HEAD);
    let grew = want.head > data.head.len() as u64 || want.tail > data.tail.len() as u64;
    grew.then_some(want)
}

/// 只读视图：按文件偏移取头部或尾部里已经读到的字节。
struct View<'a> {
    data: &'a PartialFile,
}

impl View<'_> {
    fn bytes(&self, at: u64, len: u64) -> Option<&[u8]> {
        let end = at.checked_add(len)?;
        if end <= self.data.head.len() as u64 {
            return self.data.head.get(at as usize..end as usize);
        }
        let tail_at = self.data.tail_offset();
        if !self.data.tail.is_empty() && at >= tail_at && end <= self.data.size {
            return self
                .data
                .tail
                .get((at - tail_at) as usize..(end - tail_at) as usize);
        }
        None
    }

    /// `[at, end)` 不在已读窗口里时，把窗口扩到能覆盖它。
    fn need(&self, at: u64, end: u64, want: &mut WantedWindow) {
        let head = self.data.head.len() as u64;
        let tail_at = self.data.tail_offset();
        if end <= head || (!self.data.tail.is_empty() && at >= tail_at) {
            return;
        }
        // 离头近就扩头部，否则扩尾部（WAV / MP4 的元数据常在音频数据之后）。
        if at < self.data.size / 2 {
            want.head = want.head.max(end + AUDIO_SLACK);
        } else {
            want.tail = want.tail.max(self.data.size - at);
        }
    }
}

#[derive(Clone, Copy)]
enum Endian {
    Little,
    Big,
}

fn read_u32(b: &[u8], endian: Endian) -> u64 {
    let arr = [b[0], b[1], b[2], b[3]];
    u64::from(match endian {
        Endian::Little => u32::from_le_bytes(arr),
        Endian::Big => u32::from_be_bytes(arr),
    })
}

/// FLAC：`fLaC` 之后一串 metadata block，每块 4 字节头（最后一块的标志位 + 24 位长度）。
fn walk_flac(view: &View<'_>, mut pos: u64, want: &mut WantedWindow) {
    for _ in 0..128 {
        let Some(block) = view.bytes(pos, 4) else {
            // 下一个块头还没读到：先扩到这里，调用方会再来一轮。
            view.need(pos, pos + 4, want);
            return;
        };
        let last = block[0] & 0x80 != 0;
        let len = (u64::from(block[1]) << 16) | (u64::from(block[2]) << 8) | u64::from(block[3]);
        view.need(pos, pos + 4 + len, want);
        pos += 4 + len;
        if last {
            return;
        }
    }
}

/// RIFF / AIFF：`[4 字节 ID][4 字节长度][内容]`，奇数长度补一个字节。
/// `audio` 块（音频数据）不用读内容。
fn walk_chunks(
    view: &View<'_>,
    mut pos: u64,
    endian: Endian,
    audio: &[u8; 4],
    want: &mut WantedWindow,
) {
    let size = view.data.size;
    for _ in 0..64 {
        if pos + 8 > size {
            return;
        }
        let Some(header) = view.bytes(pos, 8) else {
            view.need(pos, pos + 8, want);
            return;
        };
        let len = read_u32(&header[4..8], endian);
        let end = (pos + 8 + len + (len & 1)).min(size);
        if &header[..4] != audio {
            view.need(pos, end, want);
        }
        pos = end;
    }
}

/// MP4：`[4 字节长度][4 字节类型]`，长度 1 表示后面跟 64 位长度，0 表示到文件末尾。
/// 只有 `mdat`（音频数据）不用读。
fn walk_mp4(view: &View<'_>, mut pos: u64, want: &mut WantedWindow) {
    let size = view.data.size;
    for _ in 0..64 {
        if pos + 8 > size {
            return;
        }
        let Some(header) = view.bytes(pos, 8) else {
            view.need(pos, pos + 8, want);
            return;
        };
        let mut len = read_u32(&header[..4], Endian::Big);
        let is_mdat = &header[4..8] == b"mdat";
        if len == 1 {
            let Some(ext) = view.bytes(pos + 8, 8) else {
                view.need(pos, pos + 16, want);
                return;
            };
            len = u64::from_be_bytes([
                ext[0], ext[1], ext[2], ext[3], ext[4], ext[5], ext[6], ext[7],
            ]);
        } else if len == 0 {
            len = size - pos;
        }
        if len < 8 {
            return;
        }
        let end = (pos + len).min(size);
        if !is_mdat {
            view.need(pos, end, want);
        }
        pos = end;
    }
}

/// lofty 的错误转成 [`LekisError`]。音频文件损坏 / 不是音频都算 [`ErrorCode::Decode`]。
fn to_leks_result(
    result: std::result::Result<TaggedFile, FileParseError>,
    path: &VfsPath,
) -> Result<TaggedFile> {
    result.map_err(|e| {
        LekisError::new(
            ErrorCode::Decode,
            format!("解析音频标签失败（{path}）：{e}"),
        )
    })
}

/// 选一个信息最多的标签。
///
/// 一个文件可能同时带 ID3v2 + ID3v1（MP3）、ID3v2 + Vorbis Comment（FLAC）。
/// 优先用信息更全的现代标签，只有旧标签当备份。
fn pick_tag(tagged: &TaggedFile) -> Option<&Tag> {
    tagged
        .tags()
        .iter()
        .filter(|tag| tag.item_count() > 0)
        .max_by_key(|tag| (tag_rank(tag.tag_type()), tag.item_count()))
}

/// 标签类型的可信度排序（越高越可信）。
fn tag_rank(tag_type: TagType) -> u8 {
    match tag_type {
        TagType::Id3v2 => 7,
        TagType::VorbisComments => 6,
        TagType::Mp4Ilst => 5,
        TagType::Ape => 4,
        TagType::RiffInfo => 3,
        TagType::AiffText => 2,
        TagType::Id3v1 => 1,
        // `TagType` 是 `#[non_exhaustive]`，以后 lofty 加新格式时排在最后。
        _ => 0,
    }
}

/// 把一个标签映射到 [`ScannedTags`]。
fn apply_tag(tags: &mut ScannedTags, tag: &Tag) {
    if let Some(title) = text(tag, ItemKey::TrackTitle) {
        tags.title = title;
    }
    tags.artists = split_artists(&collect_strings(
        tag,
        &[ItemKey::TrackArtist, ItemKey::TrackArtists],
    ));
    if let Some(album) = text(tag, ItemKey::AlbumTitle) {
        tags.album = Some(album);
    }
    tags.album_artists = split_artists(&collect_strings(
        tag,
        &[ItemKey::AlbumArtist, ItemKey::AlbumArtists],
    ));
    tags.track_no = number(tag, ItemKey::TrackNumber);
    tags.disc_no = number(tag, ItemKey::DiscNumber);
    tags.year = year(tag);
    tags.genres = genres(tag);
    tags.mbid_recording = music_brainz_recording_id(tag);
    tags.replaygain = replay_gain(tag);
}

/// 取一个文本项，去掉首尾空白，空字符串当没有。
fn text(tag: &Tag, key: ItemKey) -> Option<String> {
    tag.get_string(key)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

/// 取多个键的所有文本值（多值标签用）。
fn collect_strings(tag: &Tag, keys: &[ItemKey]) -> Vec<String> {
    let mut out = Vec::new();
    for key in keys {
        for value in tag.get_strings(*key) {
            let value = value.trim();
            if !value.is_empty() {
                out.push(value.to_owned());
            }
        }
    }
    out
}

/// 艺人拆分。
///
/// 取舍说明：
/// - 多值标签（Vorbis `ARTIST` 多条、MP4 `ARTISTS`、ID3v2.4 的 `\0` 分隔）由 lofty 拆好了，
///   这里只做去空去重。
/// - 单个字符串里的分隔符只认 `;`（无歧义）和带空格的 ` / `、` & `、` feat. `、` ft. `。
///   这样 `AC/DC`、`Simon&Garfunkel` 这种名字不会被拆坏（"AC / DC" 仍会被拆，属于已知代价：
///   宁可少拆，也不要把一个艺人拆成两个库里查不到的记录）。
fn split_artists(values: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for value in values {
        for chunk in value.split(';') {
            for part in split_artist_value(chunk) {
                push_unique(&mut out, part);
            }
        }
    }
    out
}

/// 按带空格的连接符把一段艺人字符串切开（保留原字符串的切片，不复制）。
fn split_artist_value(value: &str) -> Vec<&str> {
    // 长模式在前，避免 `" feat "` 先把 `" feat. "` 吃掉半个。
    const SEPARATORS: [&str; 6] = [" / ", " & ", " feat. ", " feat ", " ft. ", " ft "];

    let mut out = Vec::new();
    let mut start = 0;
    let mut i = 0;
    while i < value.len() {
        let tail = &value[i..];
        let mut hit = 0;
        for separator in SEPARATORS {
            if tail.len() >= separator.len()
                && tail.as_bytes()[..separator.len()].eq_ignore_ascii_case(separator.as_bytes())
            {
                hit = separator.len();
                break;
            }
        }
        if hit > 0 {
            out.push(&value[start..i]);
            i += hit;
            start = i;
        } else {
            // 按 char 前进，保证切片永远落在 UTF-8 边界上。
            i += tail.chars().next().map_or(1, char::len_utf8);
        }
    }
    out.push(&value[start..]);
    out
}

/// 去空白、去空串、去重后追加。
fn push_unique(out: &mut Vec<String>, value: &str) {
    let value = value.trim();
    if value.is_empty() || out.iter().any(|existing| existing == value) {
        return;
    }
    out.push(value.to_owned());
}

/// 取一个数字标签。`TRCK`/`TRACKNUMBER` 可能是 `"3/12"` 这种"编号/总数"写法，只取前者。
fn number(tag: &Tag, key: ItemKey) -> Option<u32> {
    let raw = tag.get_string(key)?;
    first_u32(raw)
}

/// 从 `"3/12"`、`"3; 12"`、`"3"` 里取第一个能解析的数字。
fn first_u32(raw: &str) -> Option<u32> {
    raw.split(['/', ';', ','])
        .map(str::trim)
        .find_map(|part| part.parse::<u32>().ok())
}

/// 年份：先看 `DATE`/`TDRC`（`RecordingDate`），再看 `YEAR`。
fn year(tag: &Tag) -> Option<i32> {
    for key in [ItemKey::RecordingDate, ItemKey::Year] {
        if let Some(raw) = tag.get_string(key) {
            if let Some(year) = parse_year(raw) {
                return Some(year);
            }
        }
    }
    None
}

/// 从 `"2003"`、`"2003-07-31"` 里取年份；两位数（`"03"`）不当成年份。
fn parse_year(raw: &str) -> Option<i32> {
    let digits: String = raw
        .trim()
        .chars()
        .take_while(char::is_ascii_digit)
        .collect();
    if digits.len() < 4 {
        return None;
    }
    let year = digits.get(..4)?.parse::<i32>().ok()?;
    (1000..=9999).contains(&year).then_some(year)
}

/// 流派：多值标签每条都收，单条里的 `;` 也拆开（`"Rock; Pop"` 在 ID3v2 里很常见）。
fn genres(tag: &Tag) -> Vec<String> {
    let mut out = Vec::new();
    for raw in tag.get_strings(ItemKey::Genre) {
        for part in raw.split(';') {
            push_unique(&mut out, part);
        }
    }
    out
}

/// MusicBrainz 录音 ID。多数格式是文本（Vorbis `MUSICBRAINZ_TRACKID`、
/// ID3v2 `TXXX`），ID3v2 的 `UFID` 帧会被 lofty 解成文本；兜底再从二进制里转一次。
fn music_brainz_recording_id(tag: &Tag) -> Option<String> {
    if let Some(id) = text(tag, ItemKey::MusicBrainzRecordingId) {
        return Some(id);
    }
    tag.get_binary(ItemKey::MusicBrainzRecordingId, true)
        .and_then(|bytes| std::str::from_utf8(bytes).ok())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

/// ReplayGain。
fn replay_gain(tag: &Tag) -> ReplayGain {
    ReplayGain {
        track_gain_db: db_value(tag, ItemKey::ReplayGainTrackGain),
        track_peak: db_value(tag, ItemKey::ReplayGainTrackPeak),
        album_gain_db: db_value(tag, ItemKey::ReplayGainAlbumGain),
        album_peak: db_value(tag, ItemKey::ReplayGainAlbumPeak),
    }
}

/// 读一个 dB 值。标签里通常写成 `"-7.53 dB"`，也可能只有数字。
fn db_value(tag: &Tag, key: ItemKey) -> Option<f32> {
    let raw = tag.get_string(key)?;
    parse_db(raw)
}

/// 解析标签里的 dB 数值（去掉 `dB` / `db` 后缀和空白）。
fn parse_db(raw: &str) -> Option<f32> {
    let trimmed = raw
        .trim()
        .trim_end_matches(|c: char| c.is_ascii_alphabetic() || c.is_whitespace());
    trimmed
        .parse::<f32>()
        .ok()
        .filter(|value| value.is_finite())
}

/// 组装音频属性。拿不到采样率也拿不到码率时返回 `None`（界面上不显示音质标签）。
fn audio_props(
    file_type: FileType,
    properties: &FileProperties,
    data: &PartialFile,
) -> Option<AudioProps> {
    let sample_rate = properties.sample_rate().unwrap_or(0);
    // lofty 的码率单位就是 kbps；0 表示"没算出来"，当没有。
    let bitrate_kbps = properties
        .audio_bitrate()
        .or_else(|| properties.overall_bitrate())
        .filter(|kbps| *kbps > 0);
    if sample_rate == 0 && bitrate_kbps.is_none() {
        return None;
    }
    Some(AudioProps {
        codec: codec_for(file_type, data),
        sample_rate,
        bit_depth: properties.bit_depth(),
        // `AudioProps.channels` 不是 `Option`：未知时填 0。
        channels: properties.channels().unwrap_or(0),
        bitrate_kbps,
    })
}

/// lofty 的 [`FileType`] 映射到我们自己的 [`Codec`]。
fn codec_for(file_type: FileType, data: &PartialFile) -> Codec {
    match file_type {
        FileType::Aac => Codec::Aac,
        FileType::Aiff => Codec::Aiff,
        FileType::Ape => Codec::Ape,
        FileType::Flac => Codec::Flac,
        FileType::Mpeg => Codec::Mp3,
        FileType::Mp4 => mp4_codec(data),
        FileType::Mpc => Codec::Other("Musepack".to_owned()),
        FileType::Opus => Codec::Opus,
        FileType::Speex => Codec::Other("Speex".to_owned()),
        FileType::Vorbis => Codec::Vorbis,
        FileType::Wav => Codec::Wav,
        FileType::WavPack => Codec::WavPack,
        // `FileType` 是 `#[non_exhaustive]`（还有 `Custom`），认不出来的留个占位。
        _ => Codec::Other("unknown".to_owned()),
    }
}

/// MP4 的编解码器。
///
/// lofty 的通用 [`FileProperties`] 只有采样率 / 位深 / 声道，`Mp4Codec`
/// （AAC / ALAC / MP3 / FLAC）藏在 `Mp4Properties` 里，`TaggedFile` 取不到。
/// 所以退一步：在头尾数据里找编解码器 atom（`alac` / `mp4a`）。找不到就按 AAC 算
/// （`.m4a` 绝大多数是 AAC）；内嵌封面的数据里碰巧出现 `alac` 会误判，属于已知代价。
fn mp4_codec(data: &PartialFile) -> Codec {
    let head = data.head.as_ref();
    let tail = data.tail.as_ref();
    if contains_bytes(head, b"alac") || contains_bytes(tail, b"alac") {
        return Codec::Alac;
    }
    Codec::Aac
}

/// 在字节串里找一个子串。
fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty()
        && haystack
            .windows(needle.len())
            .any(|window| window == needle)
}

/// 标签里没有标题 / 艺人 / 专辑时，用文件名补齐（不覆盖已有的值）。
fn fallback_from_file_name(tags: &mut ScannedTags, path: &VfsPath) {
    let fallback = tags_from_file_name(path);
    if tags.title.trim().is_empty() {
        tags.title = fallback.title;
    }
    if tags.artists.is_empty() {
        tags.artists = fallback.artists;
    }
    if tags
        .album
        .as_deref()
        .is_none_or(|album| album.trim().is_empty())
    {
        tags.album = fallback.album;
    }
}

/// 没有标签时，用文件名兜底：支持 `艺人 - 标题.flac` 和 `01. 标题.flac` 两种常见格式。
pub fn tags_from_file_name(path: &VfsPath) -> ScannedTags {
    let name = path.file_name().unwrap_or_default();
    let stem = name.rsplit_once('.').map(|(s, _)| s).unwrap_or(name);
    let stem = stem
        .trim_start_matches(|c: char| c.is_ascii_digit())
        .trim_start_matches(['.', ' ', '-', '_'])
        .trim();
    let (artists, title) = match stem.split_once(" - ") {
        Some((artist, title)) => (vec![artist.trim().to_string()], title.trim().to_string()),
        None => (Vec::new(), stem.to_string()),
    };
    // 上级目录名当作专辑名（"艺人/专辑/01 歌名.flac" 是最常见的整理方式）。
    let album = path.parent().and_then(|p| p.file_name().map(str::to_owned));
    ScannedTags {
        title,
        artists,
        album,
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    // 测试里用 unwrap 断言前提成立，这是仓库约定（库代码才禁用）。
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;
    use bytes::Bytes;
    use lofty::config::WriteOptions;
    use lofty::prelude::TagExt;
    use lofty::tag::Tag;

    /// 造一个"小文件"的 [`PartialFile`]：头部覆盖全文件，尾部为空
    /// （和 `partial::read_head_tail` 对小文件的处理一致）。
    fn whole_file(bytes: Vec<u8>) -> PartialFile {
        let size = bytes.len() as u64;
        PartialFile {
            size,
            head: Bytes::from(bytes),
            tail: Bytes::new(),
        }
    }

    fn path(text: &str) -> VfsPath {
        VfsPath::parse(text).unwrap()
    }

    // ---- SparseReader ----

    #[test]
    fn sparse_reader_serves_head_tail_and_rejects_gap() {
        let data = PartialFile {
            size: 10_000,
            head: Bytes::from((0..100u8).collect::<Vec<u8>>()),
            tail: Bytes::from(vec![7u8; 50]),
        };
        let mut reader = SparseReader::new(&data);

        // 头部。
        let mut buf = [0u8; 8];
        reader.read_exact(&mut buf).unwrap();
        assert_eq!(buf, [0, 1, 2, 3, 4, 5, 6, 7]);

        // 尾部（偏移 9950 起）。
        reader.seek(SeekFrom::Start(9_950)).unwrap();
        reader.read_exact(&mut buf).unwrap();
        assert_eq!(buf, [7u8; 8]);

        // 尾部边界：读到文件末尾为止，再读是 EOF。
        reader.seek(SeekFrom::Start(9_990)).unwrap();
        let mut rest = vec![0u8; 32];
        assert_eq!(reader.read(&mut rest).unwrap(), 10);
        assert_eq!(reader.read(&mut rest).unwrap(), 0);

        // 中间的缺口：明确报错，而不是返回 0（返回 0 会被当成文件结束）。
        reader.seek(SeekFrom::Start(500)).unwrap();
        let err = reader.read(&mut buf).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::UnexpectedEof);

        // 头部末尾只返回能读到的那部分，不越界。
        reader.seek(SeekFrom::Start(96)).unwrap();
        assert_eq!(reader.read(&mut buf).unwrap(), 4);

        // Seek 语义。
        assert_eq!(reader.seek(SeekFrom::End(0)).unwrap(), 10_000);
        assert_eq!(reader.seek(SeekFrom::Current(-10)).unwrap(), 9_990);
        assert_eq!(reader.len(), 10_000);
        assert!(!reader.is_empty());
        // 负数位置报错（lofty 靠这个判断"文件太小，没有 ID3v1"）。
        assert!(reader.seek(SeekFrom::End(-10_001)).is_err());
    }

    // ---- MP3 + ID3v2 ----

    /// 一个合法的 MPEG1 Layer3 128kbps 44.1kHz 立体声帧（417 字节）。
    /// 帧头 `FF FB 90 00` 是这组参数的标准取值。
    fn mp3_frame() -> Vec<u8> {
        let mut frame = vec![0u8; 417];
        frame[..4].copy_from_slice(&[0xFF, 0xFB, 0x90, 0x00]);
        frame
    }

    /// 用 lofty 的写入 API 生成一段合法的 ID3v2 标签字节。
    fn id3v2_bytes(tag: &Tag) -> Vec<u8> {
        let mut out = Vec::new();
        tag.dump_to(&mut out, WriteOptions::new()).unwrap();
        out
    }

    #[test]
    fn mp3_id3v2_tags() {
        let mut tag = Tag::new(TagType::Id3v2);
        assert!(tag.insert_text(ItemKey::TrackTitle, "晴天".to_owned()));
        assert!(tag.insert_text(ItemKey::TrackArtist, "周杰伦".to_owned()));
        assert!(tag.insert_text(ItemKey::AlbumTitle, "叶惠美".to_owned()));
        assert!(tag.insert_text(ItemKey::TrackNumber, "3".to_owned()));
        assert!(tag.insert_text(ItemKey::DiscNumber, "1".to_owned()));
        assert!(tag.insert_text(ItemKey::RecordingDate, "2003-07-31".to_owned()));
        assert!(tag.insert_text(ItemKey::Genre, "Pop".to_owned()));

        // 文件 = ID3v2 标签 + 三个音频帧（lofty 要求至少能连上两帧才算找到帧同步）。
        let mut file = id3v2_bytes(&tag);
        for _ in 0..3 {
            file.extend_from_slice(&mp3_frame());
        }

        let tags = LoftyTagReader
            .read(&path("周杰伦/叶惠美/03. 晴天.mp3"), &whole_file(file))
            .unwrap();
        assert_eq!(tags.title, "晴天");
        assert_eq!(tags.artists, vec!["周杰伦".to_owned()]);
        assert_eq!(tags.album.as_deref(), Some("叶惠美"));
        assert_eq!(tags.track_no, Some(3));
        assert_eq!(tags.disc_no, Some(1));
        assert_eq!(tags.year, Some(2003));
        assert_eq!(tags.genres, vec!["Pop".to_owned()]);
        assert!(tags.duration_ms > 0, "MP3 应该能算出时长");

        let audio = tags.audio.expect("MP3 应该有音频属性");
        assert_eq!(audio.codec, Codec::Mp3);
        assert_eq!(audio.sample_rate, 44_100);
        assert_eq!(audio.channels, 2);
        assert_eq!(audio.bit_depth, None);
        assert_eq!(audio.bitrate_kbps, Some(128));
    }

    /// 把文件切成"头 + 尾"，模拟扫描器的部分读取。
    fn head_tail(bytes: &[u8], head: usize, tail: usize) -> PartialFile {
        PartialFile {
            size: bytes.len() as u64,
            head: Bytes::copy_from_slice(&bytes[..head]),
            tail: Bytes::copy_from_slice(&bytes[bytes.len() - tail..]),
        }
    }

    #[test]
    fn big_id3_tag_needs_a_bigger_head_and_then_parses() {
        let mut tag = Tag::new(TagType::Id3v2);
        assert!(tag.insert_text(ItemKey::TrackTitle, "白吃白喝".to_owned()));
        assert!(tag.insert_text(ItemKey::TrackArtist, "陈奕迅".to_owned()));
        // 600 KB 的注释，相当于一张内嵌大封面。
        assert!(tag.insert_text(ItemKey::Comment, "x".repeat(600 * 1024)));
        let mut file = id3v2_bytes(&tag);
        let tag_len = file.len() as u64;
        for _ in 0..400 {
            file.extend_from_slice(&mp3_frame());
        }
        let p = path("陈奕迅/1-04 白吃白喝.mp3");

        // 默认窗口：标签都没读全，解析失败（这就是列表里时长 0:00 的原因）。
        let first = head_tail(&file, 256 * 1024, 128 * 1024);
        assert!(LoftyTagReader.read(&p, &first).is_err());

        let wanted = wanted_window(&first).expect("should ask for more");
        assert!(
            wanted.head > tag_len,
            "must cover the whole tag: {wanted:?} <= {tag_len}"
        );

        let second = head_tail(&file, wanted.head as usize, wanted.tail as usize);
        let tags = LoftyTagReader.read(&p, &second).unwrap();
        assert_eq!(tags.title, "白吃白喝");
        assert_eq!(tags.artists, vec!["陈奕迅".to_owned()]);
        assert!(tags.duration_ms > 0);
        assert_eq!(wanted_window(&second), None);
    }

    #[test]
    fn big_flac_picture_block_is_measured_from_the_block_headers() {
        // fLaC + STREAMINFO(34) + 一个 1 MB 的 PADDING 块（相当于 PICTURE）。
        let mut file = b"fLaC".to_vec();
        file.extend_from_slice(&[0x00, 0x00, 0x00, 34]);
        file.extend_from_slice(&[0u8; 34]);
        let big = 1024 * 1024u32;
        file.extend_from_slice(&[0x81, (big >> 16) as u8, (big >> 8) as u8, big as u8]);
        file.extend(std::iter::repeat_n(0u8, big as usize));
        file.extend(std::iter::repeat_n(0u8, 512 * 1024));
        let data = head_tail(&file, 256 * 1024, 128 * 1024);
        let wanted = wanted_window(&data).unwrap();
        assert_eq!(wanted.head, 4 + 4 + 34 + 4 + u64::from(big) + 64 * 1024);
    }

    #[test]
    fn unknown_or_complete_files_ask_for_nothing() {
        assert_eq!(wanted_window(&whole_file(vec![0u8; 100])), None);
        let junk = vec![7u8; 1024 * 1024];
        assert_eq!(wanted_window(&head_tail(&junk, 1024, 1024)), None);
    }

    #[test]
    fn apple_double_forks_are_rejected_as_not_audio() {
        let mut fork = vec![0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00];
        fork.extend_from_slice(b"Mac OS X        ");
        fork.resize(4096, 0);
        let err = LoftyTagReader
            .read(&path("安溥/_1-04 白吃白喝.mp3"), &whole_file(fork))
            .unwrap_err();
        assert_eq!(err.code, ErrorCode::Unsupported);
    }

    /// 排查用：`LEKIS_TAG_FILE=<路径> cargo test -p lekis-scanner real_file -- --ignored --nocapture`
    /// 按扫描器的方式（先默认头尾窗口，失败再扩）读一个真实文件。
    #[test]
    #[ignore = "needs LEKIS_TAG_FILE"]
    fn real_file() {
        let Ok(file) = std::env::var("LEKIS_TAG_FILE") else {
            return;
        };
        let bytes = std::fs::read(&file).unwrap();
        let p = path("x/real.bin");
        let ext_path = path(&format!(
            "x/real.{}",
            file.rsplit('.').next().unwrap_or("bin")
        ));
        let p = if ext_path.extension().is_some() {
            ext_path
        } else {
            p
        };
        let (mut head, mut tail) = (256 * 1024usize, 128 * 1024usize);
        for round in 0..3 {
            let data = if head + tail >= bytes.len() {
                whole_file(bytes.clone())
            } else {
                head_tail(&bytes, head, tail)
            };
            match LoftyTagReader.read(&p, &data) {
                Ok(tags) => {
                    println!("round {round}: ok {tags:?}");
                    return;
                }
                Err(e) => {
                    println!("round {round}: {e}");
                    let Some(w) = wanted_window(&data) else {
                        println!("no bigger window");
                        break;
                    };
                    (head, tail) = (w.head as usize, w.tail as usize);
                }
            }
        }
        match LoftyTagReader.read(&p, &whole_file(bytes)) {
            Ok(tags) => println!("whole file: ok {tags:?}"),
            Err(e) => println!("whole file: {e}"),
        }
    }

    /// 最小的 16 位立体声 WAV：fmt + data，末尾挂一个大 `id3 ` 块（封面就在这里）。
    fn wav_with_trailing_id3(tag: &[u8], audio_bytes: usize) -> Vec<u8> {
        let mut fmt = Vec::new();
        fmt.extend_from_slice(&1u16.to_le_bytes()); // PCM
        fmt.extend_from_slice(&2u16.to_le_bytes());
        fmt.extend_from_slice(&44_100u32.to_le_bytes());
        fmt.extend_from_slice(&(44_100u32 * 4).to_le_bytes());
        fmt.extend_from_slice(&4u16.to_le_bytes());
        fmt.extend_from_slice(&16u16.to_le_bytes());
        let chunks: [(&[u8; 4], Vec<u8>); 3] = [
            (b"fmt ", fmt),
            (b"data", vec![0u8; audio_bytes]),
            (b"id3 ", tag.to_vec()),
        ];
        let mut body = b"WAVE".to_vec();
        for (id, content) in chunks {
            body.extend_from_slice(id);
            body.extend_from_slice(&(content.len() as u32).to_le_bytes());
            body.extend_from_slice(&content);
            if content.len() % 2 == 1 {
                body.push(0);
            }
        }
        let mut file = b"RIFF".to_vec();
        file.extend_from_slice(&(body.len() as u32).to_le_bytes());
        file.extend_from_slice(&body);
        file
    }

    #[test]
    fn wav_with_a_big_trailing_id3_chunk_needs_a_bigger_tail() {
        let mut tag = Tag::new(TagType::Id3v2);
        assert!(tag.insert_text(ItemKey::TrackTitle, "I wish".to_owned()));
        assert!(tag.insert_text(ItemKey::TrackArtist, "AiM".to_owned()));
        assert!(tag.insert_text(ItemKey::Comment, "x".repeat(400 * 1024)));
        let file = wav_with_trailing_id3(&id3v2_bytes(&tag), 2 * 1024 * 1024);
        let p = path("DISC 1/01_I wish.wav");

        let first = head_tail(&file, 256 * 1024, 128 * 1024);
        assert!(LoftyTagReader.read(&p, &first).is_err());

        let wanted = wanted_window(&first).expect("should ask for a bigger tail");
        assert!(wanted.tail > 400 * 1024, "{wanted:?}");
        let second = head_tail(&file, wanted.head as usize, wanted.tail as usize);
        let tags = LoftyTagReader.read(&p, &second).unwrap();
        assert_eq!(tags.title, "I wish");
        assert_eq!(tags.artists, vec!["AiM".to_owned()]);
        assert!(tags.duration_ms > 10_000, "{}", tags.duration_ms);
    }

    // ---- FLAC + Vorbis Comment ----

    /// 造一个最小的合法 FLAC：`fLaC` + STREAMINFO + VORBIS_COMMENT。
    ///
    /// STREAMINFO 内容必须是 34 字节（lofty 会读完整个结构）。
    fn flac_file(comments: &[(&str, &str)]) -> Vec<u8> {
        // STREAMINFO：min/max block size 各 16 位，min/max frame size 各 24 位，
        // 然后是 采样率(20)/声道-1(3)/位深-1(5)/总采样数高 4 位，再 32 位总采样数，最后 16 字节 MD5。
        let sample_rate = 44_100u32;
        let channels = 2u32;
        let bits = 16u32;
        let total_samples = 132_300u64; // 44100Hz × 3 秒
                                        // 总采样数 36 位：高 4 位塞进 STREAMINFO 的最后一个字节。
        let info = (sample_rate << 12)
            | ((channels - 1) << 9)
            | ((bits - 1) << 4)
            | ((total_samples >> 32) as u32 & 0xF);

        let mut stream_info = Vec::with_capacity(34);
        stream_info.extend_from_slice(&[0x10, 0x00, 0x10, 0x00]); // min/max block size
        stream_info.extend_from_slice(&[0x00, 0x00, 0x00, 0x00, 0x00, 0x00]); // min/max frame size
        stream_info.extend_from_slice(&info.to_be_bytes());
        stream_info.extend_from_slice(&(total_samples as u32).to_be_bytes());
        stream_info.extend_from_slice(&[0u8; 16]); // MD5

        // Vorbis Comment 内容：vendor 长度 + vendor，条目数 + 每条（长度 + KEY=VALUE）。
        let mut vorbis = Vec::new();
        vorbis.extend_from_slice(&0u32.to_le_bytes()); // vendor 为空
        vorbis.extend_from_slice(&(comments.len() as u32).to_le_bytes());
        for (key, value) in comments {
            let entry = format!("{key}={value}");
            vorbis.extend_from_slice(&(entry.len() as u32).to_le_bytes());
            vorbis.extend_from_slice(entry.as_bytes());
        }

        let mut file = Vec::new();
        file.extend_from_slice(b"fLaC");
        // STREAMINFO：last=0，type=0。
        file.push(0x00);
        file.extend_from_slice(&(stream_info.len() as u32).to_be_bytes()[1..]);
        file.extend_from_slice(&stream_info);
        // VORBIS_COMMENT：last=1，type=4。
        file.push(0x84);
        file.extend_from_slice(&(vorbis.len() as u32).to_be_bytes()[1..]);
        file.extend_from_slice(&vorbis);
        file
    }

    #[test]
    fn flac_vorbis_comment_tags() {
        let file = flac_file(&[
            ("TITLE", "晴天"),
            ("ARTIST", "周杰伦"),
            ("ARTIST", "费玉清"),
            // 注意：AC/DC 不能被拆成 "AC" 和 "DC"。
            ("ARTIST", "AC/DC"),
            ("ALBUM", "叶惠美"),
            ("ALBUMARTIST", "周杰伦"),
            ("TRACKNUMBER", "3"),
            ("DISCNUMBER", "1/2"),
            ("DATE", "2003-07-31"),
            ("GENRE", "Pop"),
            ("GENRE", "Mandopop"),
            ("REPLAYGAIN_TRACK_GAIN", "-7.53 dB"),
            ("REPLAYGAIN_TRACK_PEAK", "0.988431"),
            ("REPLAYGAIN_ALBUM_GAIN", "-6.20 dB"),
            (
                "MUSICBRAINZ_TRACKID",
                "c1f8f0a4-1b2c-4f83-9c7f-2f5b1d0f9a11",
            ),
        ]);

        let tags = LoftyTagReader
            .read(&path("周杰伦/叶惠美/03. 晴天.flac"), &whole_file(file))
            .unwrap();

        assert_eq!(tags.title, "晴天");
        assert_eq!(
            tags.artists,
            vec!["周杰伦".to_owned(), "费玉清".to_owned(), "AC/DC".to_owned()]
        );
        assert_eq!(tags.album.as_deref(), Some("叶惠美"));
        assert_eq!(tags.album_artists, vec!["周杰伦".to_owned()]);
        assert_eq!(tags.track_no, Some(3));
        // "1/2" 这种"碟号/总碟数"只取前面。
        assert_eq!(tags.disc_no, Some(1));
        assert_eq!(tags.year, Some(2003));
        assert_eq!(tags.genres, vec!["Pop".to_owned(), "Mandopop".to_owned()]);
        assert_eq!(
            tags.mbid_recording.as_deref(),
            Some("c1f8f0a4-1b2c-4f83-9c7f-2f5b1d0f9a11")
        );
        assert_eq!(tags.replaygain.track_gain_db, Some(-7.53));
        assert_eq!(tags.replaygain.track_peak, Some(0.988_431));
        assert_eq!(tags.replaygain.album_gain_db, Some(-6.20));
        // 时长来自 STREAMINFO（44100Hz × 3 秒），不是估算的。
        assert_eq!(tags.duration_ms, 3_000);

        let audio = tags.audio.expect("FLAC 应该有音频属性");
        assert_eq!(audio.codec, Codec::Flac);
        assert_eq!(audio.sample_rate, 44_100);
        assert_eq!(audio.bit_depth, Some(16));
        assert_eq!(audio.channels, 2);
    }

    // ---- 兜底和错误 ----

    #[test]
    fn falls_back_to_file_name_without_tags() {
        // 没有 ID3v2，只有三个音频帧：标签是空的，标题/艺人/专辑要用文件名补。
        let mut file = Vec::new();
        for _ in 0..3 {
            file.extend_from_slice(&mp3_frame());
        }
        let tags = LoftyTagReader
            .read(&path("周杰伦/叶惠美/周杰伦 - 晴天.mp3"), &whole_file(file))
            .unwrap();

        assert_eq!(tags.title, "晴天");
        assert_eq!(tags.artists, vec!["周杰伦".to_owned()]);
        assert_eq!(tags.album.as_deref(), Some("叶惠美"));
        // 音频属性仍然是真读出来的。
        assert_eq!(tags.audio.expect("应该有音频属性").codec, Codec::Mp3);
    }

    #[test]
    fn non_audio_file_returns_decode_error() {
        let err = LoftyTagReader
            .read(
                &path("misc/notes.mp3"),
                &whole_file(b"hello, not audio".to_vec()),
            )
            .unwrap_err();
        assert_eq!(err.code, ErrorCode::Decode);

        // 连扩展名都不认识的文件也应该报错，而不是 panic。
        let err = LoftyTagReader
            .read(
                &path("misc/notes.xyz"),
                &whole_file(b"hello, not audio".to_vec()),
            )
            .unwrap_err();
        assert_eq!(err.code, ErrorCode::Decode);
    }

    // ---- 纯函数 ----

    #[test]
    fn artist_splitting_is_conservative() {
        let cases: [(&str, Vec<&str>); 5] = [
            ("周杰伦", vec!["周杰伦"]),
            ("周杰伦 & 费玉清", vec!["周杰伦", "费玉清"]),
            ("Jay Chou feat. 费玉清", vec!["Jay Chou", "费玉清"]),
            ("A; B", vec!["A", "B"]),
            // 不带空格的斜杠不拆，保住 AC/DC。
            ("AC/DC", vec!["AC/DC"]),
        ];
        for (raw, expected) in cases {
            let got = split_artists(&[raw.to_owned()]);
            assert_eq!(got, expected, "拆分 {raw:?} 出错");
        }

        // 多值标签 + 去重 + 去空白。
        let got = split_artists(&[
            "周杰伦".to_owned(),
            " 周杰伦 ".to_owned(),
            "费玉清;周杰伦".to_owned(),
        ]);
        assert_eq!(got, vec!["周杰伦".to_owned(), "费玉清".to_owned()]);
    }

    #[test]
    fn number_year_and_db_parsing() {
        assert_eq!(first_u32("3/12"), Some(3));
        assert_eq!(first_u32(" 7 "), Some(7));
        assert_eq!(first_u32("total"), None);

        assert_eq!(parse_year("2003"), Some(2003));
        assert_eq!(parse_year("2003-07-31"), Some(2003));
        assert_eq!(parse_year("03"), None);
        assert_eq!(parse_year(""), None);

        assert_eq!(parse_db("-7.53 dB"), Some(-7.53));
        assert_eq!(parse_db("0.988431"), Some(0.988_431));
        assert_eq!(parse_db("+2.0 db"), Some(2.0));
        assert_eq!(parse_db("loud"), None);
    }

    #[test]
    fn file_name_fallback() {
        let p = VfsPath::parse("周杰伦/叶惠美/03. 晴天.flac").unwrap_or_default();
        let t = tags_from_file_name(&p);
        assert_eq!(t.title, "晴天");
        assert_eq!(t.album.as_deref(), Some("叶惠美"));

        let p = VfsPath::parse("misc/Jay Chou - 晴天.mp3").unwrap_or_default();
        let t = tags_from_file_name(&p);
        assert_eq!(t.title, "晴天");
        assert_eq!(t.artists, vec!["Jay Chou".to_string()]);
    }
}
