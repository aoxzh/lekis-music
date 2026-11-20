-- LIB-10 / LIB-11：重复检测与库健康报告用的索引。
-- 只加索引，不改表结构；规范化键仍然由 `lekis_norm` 标量函数在查询时计算。

CREATE INDEX IF NOT EXISTS idx_track_mbid_recording
  ON track(mbid_recording)
  WHERE mbid_recording IS NOT NULL AND TRIM(mbid_recording) <> '';

CREATE INDEX IF NOT EXISTS idx_track_duration
  ON track(duration_ms);

CREATE INDEX IF NOT EXISTS idx_file_source_scan_state
  ON file(source_id, scan_state);
