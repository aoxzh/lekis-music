//! DIS-06 listening statistics.
//!
//! Everything is derived from `play_event` (written by [`Library::record_play`]); no extra
//! bookkeeping table is needed. The queries intentionally aggregate in SQLite so a 100k-track
//! library never has to be loaded into memory.

use crate::db::DbResultExt;
use crate::tracks::{map_track_row, TRACK_ROW_COLUMNS};
use crate::Library;
use lekis_types::{LekisError, Result, TrackRow};
use rusqlite::params;

/// The filter shared by every aggregate. `?1` is an optional year and `NULL` means "all time".
const YEAR_FILTER: &str = "(?1 IS NULL
    OR CAST(strftime('%Y', pe.started_at / 1000, 'unixepoch', 'localtime') AS INTEGER) = ?1)";

/// One row in the monthly or hourly histogram.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ListeningBucket {
    /// 1-12 for months, 0-23 for hours.
    pub index: u32,
    /// Number of play events in this bucket.
    pub plays: u64,
    /// Total listened milliseconds in this bucket.
    pub played_ms: u64,
}

/// An artist ranked by listening time.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ArtistListening {
    /// Artist display line as stored on the track.
    pub artist: String,
    /// Number of plays.
    pub plays: u64,
    /// Total listened milliseconds.
    pub played_ms: u64,
}

/// An album ranked by listening time.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AlbumListening {
    /// Album title.
    pub title: String,
    /// Album artist line.
    pub artist: String,
    /// Number of plays.
    pub plays: u64,
    /// Total listened milliseconds.
    pub played_ms: u64,
}

/// A track ranked by listening time.
#[derive(Debug, Clone, PartialEq)]
pub struct TrackListening {
    /// Track row, ready for the existing list widgets.
    pub track: TrackRow,
    /// Number of plays.
    pub plays: u64,
    /// Total listened milliseconds.
    pub played_ms: u64,
}

/// Aggregated listening report used by the year-in-review UI.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ListeningSummary {
    /// Total play events.
    pub total_plays: u64,
    /// Total listened milliseconds.
    pub total_played_ms: u64,
    /// Distinct tracks played.
    pub unique_tracks: u64,
    /// Distinct non-empty artist lines played.
    pub unique_artists: u64,
    /// Distinct albums played.
    pub unique_albums: u64,
    /// Earliest play timestamp (Unix ms), if any.
    pub first_played_at: Option<i64>,
    /// Latest play timestamp (Unix ms), if any.
    pub last_played_at: Option<i64>,
    /// Years that contain at least one play event, newest first.
    pub available_years: Vec<i32>,
    /// Twelve monthly buckets (January..December).
    pub months: Vec<ListeningBucket>,
    /// Twenty-four hourly buckets in the device's local timezone.
    pub hours: Vec<ListeningBucket>,
    /// Top artists by listened time.
    pub top_artists: Vec<ArtistListening>,
    /// Top albums by listened time.
    pub top_albums: Vec<AlbumListening>,
    /// Top tracks by listened time.
    pub top_tracks: Vec<TrackListening>,
}

impl Library {
    /// Years that have listening history, newest first.
    pub async fn listening_years(&self) -> Result<Vec<i32>> {
        self.read(|c| {
            let mut stmt = c
                .prepare_cached(
                    "SELECT DISTINCT CAST(strftime('%Y', started_at / 1000, 'unixepoch', 'localtime') AS INTEGER)
                     FROM play_event
                     ORDER BY 1 DESC",
                )
                .db()?;
            let rows = stmt.query_map([], |r| r.get::<_, i64>(0)).db()?;
            let mut out = rows.collect::<rusqlite::Result<Vec<_>>>().db()?;
            out.retain(|y| (1900..=3000).contains(y));
            Ok(out.into_iter().map(|y| y as i32).collect())
        })
        .await
    }

    /// Aggregated listening statistics for one year (`None` = all time).
    ///
    /// `top_limit` is clamped to 1..=50. The monthly/hourly histograms always contain 12/24
    /// entries, even when the selected year has no plays.
    pub async fn listening_summary(
        &self,
        year: Option<i32>,
        top_limit: u32,
    ) -> Result<ListeningSummary> {
        if !(1..=50).contains(&top_limit) {
            return Err(LekisError::invalid("top_limit must be 1..=50"));
        }
        if let Some(y) = year {
            if !(1900..=3000).contains(&y) {
                return Err(LekisError::invalid("year must be 1900..=3000"));
            }
        }
        let limit = i64::from(top_limit);
        self.read(move |c| {
            let (total_plays, total_played_ms, unique_tracks, unique_artists, unique_albums,
                first_played_at, last_played_at) = c
                .query_row(
                    &format!(
                        "SELECT COUNT(*), COALESCE(SUM(pe.played_ms), 0),
                                COUNT(DISTINCT pe.track_uid),
                                COUNT(DISTINCT NULLIF(t.artist_line, '')),
                                COUNT(DISTINCT t.album_id),
                                MIN(pe.started_at), MAX(pe.started_at)
                         FROM play_event pe
                         JOIN track t ON t.uid = pe.track_uid
                         WHERE {YEAR_FILTER}"
                    ),
                    params![year],
                    |r| {
                        Ok((
                            r.get::<_, i64>(0)?,
                            r.get::<_, i64>(1)?,
                            r.get::<_, i64>(2)?,
                            r.get::<_, i64>(3)?,
                            r.get::<_, i64>(4)?,
                            r.get::<_, Option<i64>>(5)?,
                            r.get::<_, Option<i64>>(6)?,
                        ))
                    },
                )
                .db()?;

            let mut months = (1..=12)
                .map(|index| ListeningBucket {
                    index,
                    ..Default::default()
                })
                .collect::<Vec<_>>();
            {
                let mut stmt = c
                    .prepare_cached(&format!(
                        "SELECT CAST(strftime('%m', pe.started_at / 1000, 'unixepoch', 'localtime') AS INTEGER),
                                COUNT(*), COALESCE(SUM(pe.played_ms), 0)
                         FROM play_event pe
                         JOIN track t ON t.uid = pe.track_uid
                         WHERE {YEAR_FILTER}
                         GROUP BY 1"
                    ))
                    .db()?;
                let rows = stmt
                    .query_map(params![year], |r| {
                        Ok((
                            r.get::<_, i64>(0)?,
                            r.get::<_, i64>(1)?,
                            r.get::<_, i64>(2)?,
                        ))
                    })
                    .db()?;
                for row in rows {
                    let (month, plays, played_ms) = row.db()?;
                    if let Some(slot) = months.get_mut(month.saturating_sub(1) as usize) {
                        slot.plays = plays.max(0) as u64;
                        slot.played_ms = played_ms.max(0) as u64;
                    }
                }
            }

            let mut hours = (0..24)
                .map(|index| ListeningBucket {
                    index,
                    ..Default::default()
                })
                .collect::<Vec<_>>();
            {
                let mut stmt = c
                    .prepare_cached(&format!(
                        "SELECT CAST(strftime('%H', pe.started_at / 1000, 'unixepoch', 'localtime') AS INTEGER),
                                COUNT(*), COALESCE(SUM(pe.played_ms), 0)
                         FROM play_event pe
                         JOIN track t ON t.uid = pe.track_uid
                         WHERE {YEAR_FILTER}
                         GROUP BY 1"
                    ))
                    .db()?;
                let rows = stmt
                    .query_map(params![year], |r| {
                        Ok((
                            r.get::<_, i64>(0)?,
                            r.get::<_, i64>(1)?,
                            r.get::<_, i64>(2)?,
                        ))
                    })
                    .db()?;
                for row in rows {
                    let (hour, plays, played_ms) = row.db()?;
                    if let Some(slot) = hours.get_mut(hour.max(0) as usize) {
                        slot.plays = plays.max(0) as u64;
                        slot.played_ms = played_ms.max(0) as u64;
                    }
                }
            }

            let top_artists = c
                .prepare_cached(&format!(
                    "SELECT t.artist_line, COUNT(*), COALESCE(SUM(pe.played_ms), 0)
                     FROM play_event pe
                     JOIN track t ON t.uid = pe.track_uid
                     WHERE {YEAR_FILTER} AND t.artist_line <> ''
                     GROUP BY t.artist_line
                     ORDER BY 3 DESC, 2 DESC
                     LIMIT ?2"
                ))
                .db()?
                .query_map(params![year, limit], |r| {
                    Ok(ArtistListening {
                        artist: r.get(0)?,
                        plays: r.get::<_, i64>(1)?.max(0) as u64,
                        played_ms: r.get::<_, i64>(2)?.max(0) as u64,
                    })
                })
                .db()?
                .collect::<rusqlite::Result<Vec<_>>>()
                .db()?;

            let top_albums = c
                .prepare_cached(&format!(
                    "SELECT a.title, a.artist_line, COUNT(*), COALESCE(SUM(pe.played_ms), 0)
                     FROM play_event pe
                     JOIN track t ON t.uid = pe.track_uid
                     JOIN album a ON a.id = t.album_id
                     WHERE {YEAR_FILTER} AND a.title <> ''
                     GROUP BY t.album_id
                     ORDER BY 4 DESC, 3 DESC
                     LIMIT ?2"
                ))
                .db()?
                .query_map(params![year, limit], |r| {
                    Ok(AlbumListening {
                        title: r.get(0)?,
                        artist: r.get(1)?,
                        plays: r.get::<_, i64>(2)?.max(0) as u64,
                        played_ms: r.get::<_, i64>(3)?.max(0) as u64,
                    })
                })
                .db()?
                .collect::<rusqlite::Result<Vec<_>>>()
                .db()?;

            let top_tracks = c
                .prepare_cached(&format!(
                    "SELECT {TRACK_ROW_COLUMNS}, COUNT(pe.id), COALESCE(SUM(pe.played_ms), 0)
                     FROM play_event pe
                     JOIN track t ON t.uid = pe.track_uid
                     LEFT JOIN album a ON a.id = t.album_id
                     LEFT JOIN user_state u ON u.track_uid = t.uid
                     WHERE {YEAR_FILTER}
                     GROUP BY t.id
                     ORDER BY SUM(pe.played_ms) DESC, COUNT(pe.id) DESC
                     LIMIT ?2"
                ))
                .db()?
                .query_map(params![year, limit], |r| {
                    Ok(TrackListening {
                        track: map_track_row(r)?,
                        plays: r.get::<_, i64>(8)?.max(0) as u64,
                        played_ms: r.get::<_, i64>(9)?.max(0) as u64,
                    })
                })
                .db()?
                .collect::<rusqlite::Result<Vec<_>>>()
                .db()?;

            let available_years = {
                let mut stmt = c
                    .prepare_cached(
                        "SELECT DISTINCT CAST(strftime('%Y', started_at / 1000, 'unixepoch', 'localtime') AS INTEGER)
                         FROM play_event ORDER BY 1 DESC",
                    )
                    .db()?;
                let rows = stmt.query_map([], |r| r.get::<_, i64>(0)).db()?;
                rows.collect::<rusqlite::Result<Vec<_>>>()
                    .db()?
                    .into_iter()
                    .filter(|y| (1900..=3000).contains(y))
                    .map(|y| y as i32)
                    .collect()
            };

            Ok(ListeningSummary {
                total_plays: total_plays.max(0) as u64,
                total_played_ms: total_played_ms.max(0) as u64,
                unique_tracks: unique_tracks.max(0) as u64,
                unique_artists: unique_artists.max(0) as u64,
                unique_albums: unique_albums.max(0) as u64,
                first_played_at,
                last_played_at,
                available_years,
                months,
                hours,
                top_artists,
                top_albums,
                top_tracks,
            })
        })
        .await
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;
    use crate::{ScannedFile, ScannedTags};
    use lekis_types::{SourceConfig, SourceKind};
    use std::collections::BTreeMap;

    async fn seed(lib: &Library, title: &str, artist: &str, album: &str) -> Result<TrackRow> {
        let source = lib
            .add_source(SourceConfig {
                id: None,
                kind: SourceKind::Local,
                name: "local".into(),
                addresses: vec![],
                root_path: "/music".into(),
                credential_ref: None,
                options: BTreeMap::new(),
                enabled: true,
            })
            .await?;
        lib.upsert_scanned(vec![ScannedFile {
            source_id: source,
            path: format!("{title}.flac"),
            size: 10,
            mtime_ms: 1,
            tags: ScannedTags {
                title: title.into(),
                artists: vec![artist.into()],
                album: Some(album.into()),
                duration_ms: 120_000,
                ..Default::default()
            },
        }])
        .await?;
        let tracks = lib
            .list_track_rows(lekis_types::TrackQuery {
                sort: lekis_types::TrackSort::Title,
                offset: 0,
                limit: 10,
            })
            .await?;
        Ok(tracks
            .into_iter()
            .find(|t| t.title == title)
            .expect("seeded track"))
    }

    #[tokio::test]
    async fn summary_groups_by_year_artist_album_and_top_tracks() -> Result<()> {
        let lib = temp_library("listening-stats")?;
        let a = seed(&lib, "晴天", "周杰伦", "叶惠美").await?;
        let b = seed(&lib, "夜曲", "周杰伦", "十一月的萧邦").await?;
        let c = seed(&lib, "如果当时", "许嵩", "自定义").await?;
        let ua = lib.get_track(a.id).await?.uid;
        let ub = lib.get_track(b.id).await?.uid;
        let uc = lib.get_track(c.id).await?.uid;

        // 2024-01-01T00:00:00Z and 2025-01-01T00:00:00Z in ms.
        let t2024 = 1_704_067_200_000i64;
        let t2025 = 1_735_689_600_000i64;
        lib.record_play(ua.clone(), "dev".into(), 1000, t2025)
            .await?;
        lib.record_play(ua, "dev".into(), 2000, t2025 + 1000)
            .await?;
        lib.record_play(ub, "dev".into(), 3000, t2025 + 2000)
            .await?;
        lib.record_play(uc, "dev".into(), 4000, t2024).await?;

        let all = lib.listening_summary(None, 10).await?;
        assert_eq!(all.total_plays, 4);
        assert_eq!(all.total_played_ms, 10_000);
        assert_eq!(all.unique_tracks, 3);
        assert_eq!(all.unique_artists, 2);
        assert_eq!(all.unique_albums, 3);
        assert_eq!(all.available_years, vec![2025, 2024]);
        assert_eq!(all.months.iter().map(|m| m.plays).sum::<u64>(), 4);
        assert_eq!(all.hours.iter().map(|h| h.plays).sum::<u64>(), 4);
        assert_eq!(all.top_artists[0].artist, "周杰伦");
        assert_eq!(all.top_artists[0].plays, 3);
        assert_eq!(all.top_albums[0].title, "自定义");
        assert_eq!(all.top_tracks[0].track.title, "如果当时");
        assert_eq!(all.top_tracks[0].plays, 1);

        let y2024 = lib.listening_summary(Some(2024), 10).await?;
        assert_eq!(y2024.total_plays, 1);
        assert_eq!(y2024.unique_artists, 1);
        assert_eq!(y2024.top_artists[0].artist, "许嵩");

        let empty = lib.listening_summary(Some(1999), 10).await?;
        assert_eq!(empty.total_plays, 0);
        assert!(empty.top_tracks.is_empty());
        assert_eq!(empty.months.len(), 12);
        assert_eq!(empty.hours.len(), 24);
        Ok(())
    }

    #[tokio::test]
    async fn rejects_bad_limits_and_year() -> Result<()> {
        let lib = temp_library("listening-bad")?;
        assert_eq!(
            lib.listening_summary(None, 0).await.unwrap_err().code,
            lekis_types::ErrorCode::InvalidArgument
        );
        assert_eq!(
            lib.listening_summary(Some(1800), 10)
                .await
                .unwrap_err()
                .code,
            lekis_types::ErrorCode::InvalidArgument
        );
        Ok(())
    }
}
