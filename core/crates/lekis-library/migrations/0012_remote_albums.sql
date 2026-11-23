CREATE TABLE remote_album (
  source_id INTEGER NOT NULL REFERENCES source(id) ON DELETE CASCADE,
  external_id TEXT NOT NULL,
  album_id INTEGER NOT NULL REFERENCES album(id) ON DELETE CASCADE,
  PRIMARY KEY (source_id, external_id)
);
