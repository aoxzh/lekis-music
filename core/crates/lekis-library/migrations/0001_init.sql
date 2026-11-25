-- Lekis 资料库初始表结构。
-- 规则：迁移文件只增不改。时间统一用 Unix 毫秒（INTEGER），布尔用 0/1。

-- ---------------------------------------------------------------------------
-- 音源与文件
-- ---------------------------------------------------------------------------

CREATE TABLE source (
  id             INTEGER PRIMARY KEY,
  kind           TEXT    NOT NULL,              -- SourceKind（snake_case）
  name           TEXT    NOT NULL,
  addresses_json TEXT    NOT NULL DEFAULT '[]', -- 按优先级排列的地址
  root_path      TEXT    NOT NULL DEFAULT '',
  credential_ref TEXT,                          -- 系统钥匙串里的引用，不是密码
  options_json   TEXT    NOT NULL DEFAULT '{}',
  enabled        INTEGER NOT NULL DEFAULT 1,
  priority       INTEGER NOT NULL DEFAULT 0,    -- 统一资料库选源时的优先级
  last_scan_at   INTEGER,
  created_at     INTEGER NOT NULL
);

CREATE TABLE file (
  id           INTEGER PRIMARY KEY,
  source_id    INTEGER NOT NULL REFERENCES source(id) ON DELETE CASCADE,
  path         TEXT    NOT NULL,                -- VfsPath（相对源根目录）
  size         INTEGER NOT NULL,
  mtime_ms     INTEGER NOT NULL,
  tag_hash     TEXT,                            -- 标签内容哈希，判断标签是否变化
  scan_state   TEXT    NOT NULL DEFAULT 'pending', -- pending / tagged / error
  scan_error   TEXT,
  audio_json   TEXT,                            -- AudioProps
  last_seen_at INTEGER NOT NULL,
  UNIQUE (source_id, path)
);
CREATE INDEX idx_file_source_state ON file(source_id, scan_state);

-- ---------------------------------------------------------------------------
-- 曲目 / 专辑 / 艺人
-- ---------------------------------------------------------------------------

CREATE TABLE artwork (
  id           INTEGER PRIMARY KEY,
  hash         TEXT    NOT NULL UNIQUE,         -- 原图内容哈希，同一张图只存一份
  source       TEXT    NOT NULL,                -- embedded / sidecar / coverartarchive / itunes / plugin:<id> ...
  width        INTEGER,
  height       INTEGER,
  palette_json TEXT,                            -- Palette（动态背景用）
  created_at   INTEGER NOT NULL
);

CREATE TABLE artist (
  id           INTEGER PRIMARY KEY,
  name         TEXT    NOT NULL,
  sort_name    TEXT,
  name_norm    TEXT    NOT NULL,                -- 规范化名称（小写、简体、去空白），用于去重
  mbid         TEXT,
  aliases_json TEXT    NOT NULL DEFAULT '[]',
  artwork_id   INTEGER REFERENCES artwork(id) ON DELETE SET NULL,
  UNIQUE (name_norm)
);

CREATE TABLE album (
  id                 INTEGER PRIMARY KEY,
  title              TEXT    NOT NULL,
  sort_title         TEXT,
  title_norm         TEXT    NOT NULL,
  artist_line        TEXT    NOT NULL DEFAULT '', -- 专辑艺人显示文字（冗余）
  artist_norm        TEXT    NOT NULL DEFAULT '',
  year               INTEGER,
  mbid_release       TEXT,
  mbid_release_group TEXT,
  artwork_id         INTEGER REFERENCES artwork(id) ON DELETE SET NULL,
  created_at         INTEGER NOT NULL,
  UNIQUE (title_norm, artist_norm)
);

CREATE TABLE album_artist (
  album_id  INTEGER NOT NULL REFERENCES album(id) ON DELETE CASCADE,
  artist_id INTEGER NOT NULL REFERENCES artist(id) ON DELETE CASCADE,
  position  INTEGER NOT NULL,
  PRIMARY KEY (album_id, artist_id)
);

CREATE TABLE track (
  id              INTEGER PRIMARY KEY,
  uid             TEXT    NOT NULL UNIQUE,      -- TrackUid（跨设备稳定）
  title           TEXT    NOT NULL,
  sort_title      TEXT,
  title_sort_key  TEXT    NOT NULL DEFAULT '',  -- 排序键（中文转拼音后的结果）
  artist_line     TEXT    NOT NULL DEFAULT '',  -- 列表显示用（冗余）
  album_id        INTEGER REFERENCES album(id) ON DELETE SET NULL,
  track_no        INTEGER,
  disc_no         INTEGER,
  year            INTEGER,
  duration_ms     INTEGER NOT NULL DEFAULT 0,
  mbid_recording  TEXT,
  acoustid        TEXT,
  replaygain_json TEXT,
  quality_badge   TEXT,                         -- 最佳文件的音质标签（冗余）
  artwork_id      INTEGER REFERENCES artwork(id) ON DELETE SET NULL,
  bliss_vector    BLOB,                         -- 声学特征（以后）
  overlay_json    TEXT,                         -- 用户或补全结果的覆盖层（不改原文件）
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);
CREATE INDEX idx_track_album ON track(album_id, disc_no, track_no);
CREATE INDEX idx_track_sort ON track(title_sort_key);
CREATE INDEX idx_track_created ON track(created_at);

CREATE TABLE track_artist (
  track_id  INTEGER NOT NULL REFERENCES track(id) ON DELETE CASCADE,
  artist_id INTEGER NOT NULL REFERENCES artist(id) ON DELETE CASCADE,
  role      TEXT    NOT NULL,                   -- ArtistRole
  position  INTEGER NOT NULL,
  PRIMARY KEY (track_id, artist_id, role)
);
CREATE INDEX idx_track_artist_artist ON track_artist(artist_id);

-- 统一资料库（SRC-13）：一首歌可以对应多个文件 / 多个源
CREATE TABLE track_file (
  track_id      INTEGER NOT NULL REFERENCES track(id) ON DELETE CASCADE,
  file_id       INTEGER REFERENCES file(id) ON DELETE CASCADE,       -- 文件系统类源
  source_id     INTEGER NOT NULL REFERENCES source(id) ON DELETE CASCADE,
  external_id   TEXT,                                                -- 服务器 / 插件源里的 ID
  quality_score INTEGER NOT NULL DEFAULT 0,                          -- 选源用：越高越好
  PRIMARY KEY (track_id, source_id, file_id, external_id)
);
CREATE INDEX idx_track_file_file ON track_file(file_id);

CREATE TABLE genre (
  id   INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE
);

CREATE TABLE track_genre (
  track_id INTEGER NOT NULL REFERENCES track(id) ON DELETE CASCADE,
  genre_id INTEGER NOT NULL REFERENCES genre(id) ON DELETE CASCADE,
  PRIMARY KEY (track_id, genre_id)
);

-- ---------------------------------------------------------------------------
-- 歌词与补全
-- ---------------------------------------------------------------------------

CREATE TABLE lyrics (
  id         INTEGER PRIMARY KEY,
  track_id   INTEGER NOT NULL REFERENCES track(id) ON DELETE CASCADE,
  format     TEXT    NOT NULL,                  -- LyricsFormat
  content    TEXT    NOT NULL,
  source     TEXT    NOT NULL,
  offset_ms  INTEGER NOT NULL DEFAULT 0,
  confidence REAL    NOT NULL DEFAULT 1.0,
  is_active  INTEGER NOT NULL DEFAULT 1,        -- 一首歌可以有多份歌词，只有一份生效
  created_at INTEGER NOT NULL
);
CREATE INDEX idx_lyrics_track ON lyrics(track_id, is_active);

-- 待确认队列（ENR-06）
CREATE TABLE enrich_candidate (
  id           INTEGER PRIMARY KEY,
  track_id     INTEGER REFERENCES track(id) ON DELETE CASCADE,
  album_id     INTEGER REFERENCES album(id) ON DELETE CASCADE,
  kind         TEXT    NOT NULL,                -- artwork / lyrics / tags
  payload_json TEXT    NOT NULL,
  source       TEXT    NOT NULL,
  score        REAL    NOT NULL,
  state        TEXT    NOT NULL DEFAULT 'pending', -- pending / accepted / rejected / auto_applied
  created_at   INTEGER NOT NULL,
  decided_at   INTEGER
);
CREATE INDEX idx_enrich_state ON enrich_candidate(state, created_at);

-- ---------------------------------------------------------------------------
-- 用户数据（这些表由同步日志物化而来，见 lekis-sync）
-- ---------------------------------------------------------------------------

CREATE TABLE user_state (
  track_uid    TEXT    PRIMARY KEY,             -- 用 uid 而不是本机 track.id，方便跨设备
  loved        INTEGER NOT NULL DEFAULT 0,
  rating       INTEGER,                         -- 1~5
  play_count   INTEGER NOT NULL DEFAULT 0,
  last_played  INTEGER,
  updated_hlc  TEXT                             -- 最后一次修改的 HLC（同步合并用）
);

CREATE TABLE playlist (
  id          INTEGER PRIMARY KEY,
  uid         TEXT    NOT NULL UNIQUE,          -- 跨设备稳定 ID（UUIDv7）
  name        TEXT    NOT NULL,
  kind        TEXT    NOT NULL DEFAULT 'static',-- static / smart
  rules_json  TEXT,                             -- 智能歌单规则
  folder_uid  TEXT,
  artwork_id  INTEGER REFERENCES artwork(id) ON DELETE SET NULL,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  deleted     INTEGER NOT NULL DEFAULT 0        -- 墓碑（同步用）
);

CREATE TABLE playlist_item (
  playlist_id  INTEGER NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
  position_key TEXT    NOT NULL,                -- 序列 CRDT 的位置键（字典序排序）
  track_uid    TEXT    NOT NULL,                -- 找不到对应曲目时显示占位（PL-05）
  added_at     INTEGER NOT NULL,
  PRIMARY KEY (playlist_id, position_key)
);

CREATE TABLE play_event (
  id         INTEGER PRIMARY KEY,
  track_uid  TEXT    NOT NULL,
  device_id  TEXT    NOT NULL,
  started_at INTEGER NOT NULL,
  played_ms  INTEGER NOT NULL,
  completed  INTEGER NOT NULL DEFAULT 0,
  scrobbled  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_play_event_time ON play_event(started_at);
CREATE INDEX idx_play_event_scrobble ON play_event(scrobbled) WHERE scrobbled = 0;

-- ---------------------------------------------------------------------------
-- 同步与插件
-- ---------------------------------------------------------------------------

-- 本机产生、尚未推送的同步操作
CREATE TABLE sync_outbox (
  hlc        TEXT    PRIMARY KEY,
  op_json    TEXT    NOT NULL,
  created_at INTEGER NOT NULL
);

-- 每个同步通道 / 每个远端设备读到了哪里
CREATE TABLE sync_cursor (
  channel   TEXT NOT NULL,
  device_id TEXT NOT NULL,
  last_hlc  TEXT NOT NULL,
  PRIMARY KEY (channel, device_id)
);

CREATE TABLE plugin (
  id               TEXT    PRIMARY KEY,         -- 反向域名
  manifest_json    TEXT    NOT NULL,
  enabled          INTEGER NOT NULL DEFAULT 1,
  granted_json     TEXT    NOT NULL DEFAULT '{}', -- 用户实际授予的权限
  installed_from   TEXT,
  installed_at     INTEGER NOT NULL
);

CREATE TABLE kv (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- ---------------------------------------------------------------------------
-- 全文搜索（LIB-07）：拼音全拼 / 首字母 / 简体 都在入库时生成，存进 keys 列
-- ---------------------------------------------------------------------------

CREATE VIRTUAL TABLE search_index USING fts5(
  kind UNINDEXED,     -- track / album / artist
  ref_id UNINDEXED,   -- 对应表的 id
  title,
  subtitle,           -- 艺人 / 专辑
  keys,               -- 规范化后的搜索键（简体、拼音、首字母、罗马字）
  tokenize = 'unicode61 remove_diacritics 2'
);
