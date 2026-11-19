-- 离线下载（OFF-01/02）。
--
-- 每个曲目最多一条记录；缓存文件放在 app 数据目录的 offline/ 下，不放进数据库。
-- state: queued / downloading / ready / failed。
-- bytes 是已经写进缓存文件的字节数，total_bytes 是解析到的源文件大小（未知时 0）。

CREATE TABLE offline_download (
  track_id    INTEGER PRIMARY KEY REFERENCES track(id) ON DELETE CASCADE,
  source_id   INTEGER NOT NULL REFERENCES source(id) ON DELETE CASCADE,
  cache_path  TEXT    NOT NULL,
  bytes       INTEGER NOT NULL DEFAULT 0,
  total_bytes INTEGER NOT NULL DEFAULT 0,
  state       TEXT    NOT NULL DEFAULT 'queued',
  error       TEXT,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);

CREATE INDEX idx_offline_state ON offline_download(state, updated_at);
