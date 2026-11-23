-- Hot lookups for large libraries. The primary keys already cover the
-- per-track direction; these indexes cover browsing by genre / artist,
-- a track's play history and which playlists contain it.
CREATE INDEX IF NOT EXISTS idx_track_genre_genre
  ON track_genre(genre_id, track_id);
CREATE INDEX IF NOT EXISTS idx_album_artist_artist
  ON album_artist(artist_id, album_id);
CREATE INDEX IF NOT EXISTS idx_play_event_track
  ON play_event(track_uid, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_playlist_item_track
  ON playlist_item(track_uid);
CREATE INDEX IF NOT EXISTS idx_enrich_candidate_track
  ON enrich_candidate(track_id, kind);
