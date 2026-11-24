ALTER TABLE lyrics ADD COLUMN selected_by_user INTEGER NOT NULL DEFAULT 0;
UPDATE lyrics SET selected_by_user = 1 WHERE is_active = 1;
CREATE TABLE lyric_recording (
    lyrics_id INTEGER PRIMARY KEY REFERENCES lyrics(id) ON DELETE CASCADE,
    title TEXT,
    artists TEXT NOT NULL,
    album TEXT,
    duration_ms INTEGER
);
