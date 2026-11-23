-- Source-first indexes for large-library maintenance: removing a source or
-- an unseen file set otherwise scans track_file / file by source_id.
CREATE INDEX IF NOT EXISTS idx_track_file_source
  ON track_file(source_id, track_id);
CREATE INDEX IF NOT EXISTS idx_file_source_seen
  ON file(source_id, last_seen_at);
