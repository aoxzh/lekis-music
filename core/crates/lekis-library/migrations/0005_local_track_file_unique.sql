-- 本地文件行的 external_id 是空字符串，而不是 NULL。
-- 0002 的部分唯一索引只排除了 NULL，导致同一首歌（同一 track / 同一源）
-- 来自两个文件时会在 (track_id, source_id, '') 上冲突，整次扫描回滚。
-- 远程行的唯一性保持不变，只把本地行（空 external_id）排除在索引之外。

DROP INDEX IF EXISTS idx_track_file_remote;

CREATE UNIQUE INDEX idx_track_file_remote
    ON track_file(track_id, source_id, external_id)
 WHERE external_id IS NOT NULL
   AND external_id <> '';
