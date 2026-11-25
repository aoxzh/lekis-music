-- CUE 整轨分轨范围、流媒体播放缓存（OFF-03）、统一资料库音频指纹与拆分记录（SRC-13）。

-- CUE 整轨支持：同一个底层音频文件（file_id）可以对应多首曲目，每首曲目记录起止毫秒与所属 .cue 路径。
ALTER TABLE track_file ADD COLUMN start_ms INTEGER NOT NULL DEFAULT 0;
ALTER TABLE track_file ADD COLUMN end_ms INTEGER;
ALTER TABLE track_file ADD COLUMN cue_path TEXT;
CREATE INDEX idx_track_file_cue ON track_file(source_id, cue_path) WHERE cue_path IS NOT NULL;

-- NAS / 远端流媒体播放缓存（OFF-03）：独立于用户主动离线下载，按 LRU 淘汰并受上限约束。
CREATE TABLE stream_cache (
  track_id   INTEGER PRIMARY KEY REFERENCES track(id) ON DELETE CASCADE,
  source_id  INTEGER NOT NULL REFERENCES source(id) ON DELETE CASCADE,
  cache_path TEXT    NOT NULL,
  bytes      INTEGER NOT NULL DEFAULT 0,
  last_used  INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX idx_stream_cache_lru ON stream_cache(last_used ASC);

-- 统一资料库（SRC-13）：本地计算出的 Chromaprint 音频指纹（压缩字符串）和用户手动拆分后禁止自动再合并的记录。
ALTER TABLE file ADD COLUMN fingerprint TEXT;
CREATE INDEX idx_file_fingerprint ON file(fingerprint) WHERE fingerprint IS NOT NULL;

CREATE TABLE unified_split_pair (
  uid_a      TEXT    NOT NULL,
  uid_b      TEXT    NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (uid_a, uid_b)
);
