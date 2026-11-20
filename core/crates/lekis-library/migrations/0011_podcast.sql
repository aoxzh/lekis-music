-- 播客（SRC-12）。
--
-- 打开过的节目都会缓存到 podcast；subscribed = 1 才算订阅。单集按 (podcast_id, guid)
-- 去重，刷新时只更新元数据，保留播放进度和已播放标记。
-- 播放时单集 ID 映射成 -(2^40 + id) 的合成 TrackId，不写 track 表。

CREATE TABLE podcast (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  feed_url          TEXT    NOT NULL UNIQUE,      -- 仅 http/https
  itunes_id         INTEGER,
  title             TEXT    NOT NULL,
  author            TEXT,
  description       TEXT,
  artwork_url       TEXT,
  link              TEXT,
  language          TEXT,
  categories_json   TEXT    NOT NULL DEFAULT '[]',
  subscribed        INTEGER NOT NULL DEFAULT 0,
  subscribed_at     INTEGER,
  last_refreshed_at INTEGER,
  last_error        TEXT,
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
);

CREATE INDEX idx_podcast_subscribed ON podcast(subscribed, subscribed_at);
CREATE INDEX idx_podcast_itunes ON podcast(itunes_id);

CREATE TABLE podcast_episode (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  podcast_id     INTEGER NOT NULL REFERENCES podcast(id) ON DELETE CASCADE,
  guid           TEXT    NOT NULL,
  title          TEXT    NOT NULL,
  description    TEXT,
  audio_url      TEXT    NOT NULL,
  mime_type      TEXT,
  size_bytes     INTEGER,
  duration_ms    INTEGER NOT NULL DEFAULT 0,
  published_at   INTEGER,
  artwork_url    TEXT,
  episode_no     INTEGER,
  season_no      INTEGER,
  link           TEXT,
  position_ms    INTEGER NOT NULL DEFAULT 0,
  played         INTEGER NOT NULL DEFAULT 0,
  last_played_at INTEGER,
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL,
  UNIQUE (podcast_id, guid)
);

CREATE INDEX idx_podcast_episode_feed ON podcast_episode(podcast_id, published_at);
CREATE INDEX idx_podcast_episode_published ON podcast_episode(published_at);
CREATE INDEX idx_podcast_episode_recent ON podcast_episode(last_played_at);
