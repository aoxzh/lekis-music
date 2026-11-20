-- 网络电台（SRC-11）。
--
-- Radio Browser 的浏览结果会 upsert 到这里；收藏和自定义电台永久保存。
-- 播放时电台 ID 映射成负数 TrackId，不写 track 表，避免污染曲库。

CREATE TABLE radio_station (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  station_uuid   TEXT UNIQUE,                   -- Radio Browser UUID；自定义电台为 NULL
  name           TEXT    NOT NULL,
  url            TEXT    NOT NULL UNIQUE,       -- 仅 http/https
  favicon        TEXT,
  country        TEXT,
  country_code   TEXT,
  language       TEXT,
  tags_json      TEXT    NOT NULL DEFAULT '[]',
  codec          TEXT,
  bitrate        INTEGER,
  homepage       TEXT,
  is_custom      INTEGER NOT NULL DEFAULT 0,
  favorite       INTEGER NOT NULL DEFAULT 0,
  last_played_at INTEGER,
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL
);

CREATE INDEX idx_radio_station_favorite ON radio_station(favorite, last_played_at);
CREATE INDEX idx_radio_station_recent ON radio_station(last_played_at);
CREATE INDEX idx_radio_station_custom ON radio_station(is_custom, created_at);
