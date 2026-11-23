//! Original protocol fixtures; no third-party provider code or lyric text.
#![allow(clippy::unwrap_used, clippy::panic)]
use super::*;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

fn hint(title: &str, artist: &str, ms: u64) -> TrackHint {
    TrackHint {
        title: title.into(),
        artists: if artist.is_empty() {
            vec![]
        } else {
            vec![artist.into()]
        },
        duration_ms: ms,
        ..Default::default()
    }
}
fn record(synced: bool) -> String {
    serde_json::json!({"trackName":"勇者","artistName":"YOASOBI","duration":196,
        "plainLyrics":"Original test fixture", "syncedLyrics":if synced {Some("[00:01.00]Original test fixture")} else {None}}).to_string()
}
fn server(
    responses: Vec<(u16, String)>,
) -> (String, Arc<Mutex<Vec<String>>>, std::thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let address = format!("http://{}", listener.local_addr().unwrap());
    let requests = Arc::new(Mutex::new(Vec::new()));
    let captured = requests.clone();
    let thread = std::thread::spawn(move || {
        let deadline = std::time::Instant::now() + Duration::from_secs(15);
        for (status, body) in responses {
            loop {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream.set_nonblocking(false).unwrap();
                        stream
                            .set_read_timeout(Some(Duration::from_secs(15)))
                            .unwrap();
                        let mut bytes = [0; 8192];
                        let n = stream.read(&mut bytes).unwrap();
                        captured.lock().unwrap().push(
                            String::from_utf8_lossy(&bytes[..n])
                                .lines()
                                .next()
                                .unwrap()
                                .to_string(),
                        );
                        write!(stream, "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
                        break;
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(
                            std::time::Instant::now() < deadline,
                            "missing expected provider request"
                        );
                        std::thread::sleep(Duration::from_millis(5));
                    }
                    Err(error) => panic!("{error}"),
                }
            }
        }
    });
    (address, requests, thread)
}
#[test]
fn japanese_cleaning_keeps_script_and_version_identity() {
    assert_eq!(
        lyrics_matching::clean_title(
            "ＹＯＡＳＯＢＩ「勇者」Official Music Video",
            &["YOASOBI".into()]
        ),
        "勇者"
    );
    assert_eq!(
        lyrics_matching::clean_title("アイドル (Official Music Video)", &[]),
        "アイドル"
    );
    for title in [
        "アイドル (TV Size)",
        "アイドル (Live)",
        "アイドル (カバー)",
        "アイドル (Instrumental)",
        "交響曲 (第1楽章)",
    ] {
        assert_eq!(lyrics_matching::clean_title(title, &[]), title);
    }
    assert_eq!(
        lyrics_matching::clean_title("別人「勇者」Official Music Video", &["YOASOBI".into()]),
        "別人「勇者」"
    );
}
#[test]
fn identity_blocks_wrong_artist_title_version_and_duration() {
    let wanted = hint("勇者", "YOASOBI", 196_000);
    for matched in [
        hint("勇者", "Other performer", 196_000),
        hint("全く違う曲", "YOASOBI", 196_000),
        hint("勇者 (TV Size)", "YOASOBI", 196_000),
        hint("勇者 (Live)", "YOASOBI", 196_000),
        hint("勇者", "YOASOBI", 230_000),
    ] {
        assert!(
            lyrics_matching::confidence(&wanted, &matched).is_none(),
            "{matched:?}"
        );
    }
    assert!(
        lyrics_matching::confidence(&hint("勇者", "", 196_000), &wanted).unwrap()
            < crate::AUTO_APPLY_THRESHOLD
    );
    assert!(
        lyrics_matching::confidence(
            &hint("アイドル", "ＹＯＡＳＯＢＩ", 196_000),
            &hint("アイドル", "YOASOBI", 196_000)
        )
        .unwrap()
            >= crate::AUTO_APPLY_THRESHOLD
    );
    assert!(lyrics_matching::confidence(
        &hint("アイドル", "YOASOBI", 196_000),
        &hint("Idol", "YOASOBI", 196_000)
    )
    .is_none());
}
#[test]
fn exact_parameters_round_and_validate_duration() {
    let provider = Lrclib::new().unwrap();
    assert!(provider
        .exact_url(&hint("Test", "Artist", 196_600))
        .unwrap()
        .query_pairs()
        .any(|(k, v)| k == "duration" && v == "197"));
    for ms in [0, 100, 3_601_000, u64::MAX] {
        assert!(!provider
            .exact_url(&hint("Test", "Artist", ms))
            .unwrap()
            .query_pairs()
            .any(|(k, _)| k == "duration"));
    }
}
#[tokio::test]
async fn missing_artist_searches_without_invalid_exact_and_requires_review() {
    let (base, requests, thread) = server(vec![(200, format!("[{}]", record(true)))]);
    let found = Lrclib::with_base_url(&base)
        .unwrap()
        .find_lyrics(&hint("勇者", "", 196_000))
        .await
        .unwrap();
    thread.join().unwrap();
    assert_eq!(found.len(), 1);
    assert!(found[0].provider_confidence < crate::AUTO_APPLY_THRESHOLD);
    let requests = requests.lock().unwrap();
    assert_eq!(requests.len(), 1);
    assert!(requests[0].contains("/api/search?track_name="));
    assert!(!requests[0].contains("artist_name"));
}
#[tokio::test]
async fn synced_search_wins_without_losing_plain_exact_fallback_or_cache() {
    let (base, requests, thread) = server(vec![
        (200, record(false)),
        (200, format!("[{}]", record(true))),
    ]);
    let provider = Lrclib::with_base_url(&base).unwrap();
    let wanted = hint("勇者", "YOASOBI", 196_000);
    let found = provider.find_lyrics(&wanted).await.unwrap();
    thread.join().unwrap();
    assert_eq!(requests.lock().unwrap().len(), 2);
    assert_eq!(found[0].payload.format, LyricsFormat::Lrc);
    assert!(found
        .iter()
        .any(|c| c.payload.format == LyricsFormat::Plain));
    assert_eq!(provider.find_lyrics(&wanted).await.unwrap(), found);
}
#[tokio::test]
async fn official_video_clean_query_finds_japanese_record() {
    let (base, requests, thread) = server(vec![
        (404, "{}".into()),
        (200, "[]".into()),
        (200, format!("[{}]", record(true))),
    ]);
    let found = Lrclib::with_base_url(&base)
        .unwrap()
        .find_lyrics(&hint(
            "YOASOBI「勇者」Official Music Video",
            "YOASOBI",
            196_000,
        ))
        .await
        .unwrap();
    thread.join().unwrap();
    assert_eq!(found.len(), 1);
    assert!(found[0].provider_confidence >= crate::AUTO_APPLY_THRESHOLD);
    let requests = requests.lock().unwrap();
    assert_eq!(requests.len(), 3);
    assert!(requests[2].contains("track_name=%E5%8B%87%E8%80%85&artist_name=YOASOBI"));
    assert!(!requests[2].contains("?q="));
}
#[tokio::test]
async fn no_result_network_failure_and_plain_fallback_remain_distinct() {
    let (base, _, thread) = server(vec![
        (404, "{}".into()),
        (200, "[]".into()),
        (200, "[]".into()),
    ]);
    let found = Lrclib::with_base_url(&base)
        .unwrap()
        .find_lyrics(&hint("勇者", "YOASOBI", 196_000))
        .await
        .unwrap();
    thread.join().unwrap();
    assert!(found.is_empty());
    let (base, requests, thread) = server(vec![(500, "{}".into())]);
    let failure = Lrclib::with_base_url(&base)
        .unwrap()
        .find_lyrics(&hint("勇者", "YOASOBI", 196_000))
        .await
        .unwrap_err();
    thread.join().unwrap();
    assert_eq!(failure.code, ErrorCode::Network);
    assert_eq!(requests.lock().unwrap().len(), 1);
    let (base, _, thread) = server(vec![(200, record(false)), (500, "{}".into())]);
    let found = Lrclib::with_base_url(&base)
        .unwrap()
        .find_lyrics(&hint("勇者", "YOASOBI", 196_000))
        .await
        .unwrap();
    thread.join().unwrap();
    assert_eq!(found[0].payload.format, LyricsFormat::Plain);
}

#[test]
fn ascii_version_words_do_not_match_inside_song_names() {
    assert!(lyrics_matching::confidence(
        &hint("Deliver", "Artist", 0),
        &hint("Deliver", "Artist", 0)
    )
    .is_some());
    assert!(lyrics_matching::confidence(
        &hint("Deliver", "Artist", 0),
        &hint("Deliver (Live)", "Artist", 0)
    )
    .is_none());
    assert!(lyrics_matching::confidence(
        &hint("Song", "Artist", 0),
        &hint("Song (TV Size)", "Artist", 0)
    )
    .is_none());
}

#[test]
fn synchronized_payload_requires_a_real_timestamp_and_text() {
    for invalid in [
        "not synced",
        "[ar:Artist]",
        "[00:99.00]fixture",
        "[00:01.00]",
    ] {
        let entry = parse_lrclib_record(&record(true)).unwrap().unwrap();
        let entry = LrcEntry {
            synced_lyrics: Some(invalid.into()),
            ..entry
        };
        let found = lyrics_candidates("lrclib", &hint("勇者", "YOASOBI", 196_000), &[entry]);
        assert_eq!(found[0].payload.format, LyricsFormat::Plain);
    }
    assert!(has_lyric_timestamp("[00:01.00]fixture"));
}

#[tokio::test]
async fn malformed_search_preserves_plain_but_reports_decode_without_fallback() {
    for plain in [true, false] {
        let (base, _, thread) = server(vec![
            (
                if plain { 200 } else { 404 },
                if plain { record(false) } else { "{}".into() },
            ),
            (200, "malformed".into()),
        ]);
        let result = Lrclib::with_base_url(&base)
            .unwrap()
            .find_lyrics(&hint("勇者", "YOASOBI", 196_000))
            .await;
        thread.join().unwrap();
        if plain {
            assert_eq!(result.unwrap()[0].payload.format, LyricsFormat::Plain);
        } else {
            assert_eq!(result.unwrap_err().code, ErrorCode::Decode);
        }
    }
}

#[tokio::test]
async fn retry_after_cools_only_this_provider_without_blocking() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let thread = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut bytes = [0; 8192];
        let bytes_read = stream.read(&mut bytes).unwrap();
        assert!(bytes_read > 0, "expected an HTTP request");
        stream.write_all(b"HTTP/1.1 429 Too Many Requests\r\nRetry-After: 120\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
    });
    let provider = Lrclib::with_base_url(&base).unwrap();
    let wanted = hint("勇者", "YOASOBI", 196_000);
    assert_eq!(
        provider.find_lyrics(&wanted).await.unwrap_err().code,
        ErrorCode::RateLimited
    );
    thread.join().unwrap();
    let start = std::time::Instant::now();
    assert_eq!(
        provider.find_lyrics(&wanted).await.unwrap_err().code,
        ErrorCode::RateLimited
    );
    assert!(start.elapsed() < Duration::from_secs(2));
}

#[test]
fn uploader_title_identity_is_review_only_and_keeps_version_guard() {
    for title in [
        "YOASOBI「勇者」Official Music Video",
        "YOASOBI - 勇者 (Official Video)",
    ] {
        let video = hint(title, "Anime uploader", 196_000);
        let score = lyrics_matching::confidence(&video, &hint("勇者", "YOASOBI", 196_000)).unwrap();
        assert!(score < crate::AUTO_APPLY_THRESHOLD);
        assert!(lyrics_matching::confidence(&video, &hint("勇者", "Other", 196_000)).is_none());
        assert!(
            lyrics_matching::confidence(&video, &hint("勇者 (Live)", "YOASOBI", 196_000)).is_none()
        );
        assert!(lyrics_matching::confidence(&video, &hint("勇者", "YOASOBI", 230_000)).is_none());
    }
}

#[tokio::test]
async fn uploader_video_searches_inferred_song_and_artist() {
    let (base, requests, thread) = server(vec![
        (404, "{}".into()),
        (200, "[]".into()),
        (200, "[]".into()),
        (200, format!("[{}]", record(true))),
        (200, "[]".into()),
    ]);
    let found = Lrclib::with_base_url(&base)
        .unwrap()
        .find_lyrics(&hint(
            "YOASOBI「勇者」Official Music Video",
            "Anime uploader",
            196_000,
        ))
        .await
        .unwrap();
    thread.join().unwrap();
    assert_eq!(found.len(), 1);
    assert!(found[0].provider_confidence < crate::AUTO_APPLY_THRESHOLD);
    assert!(requests
        .lock()
        .unwrap()
        .iter()
        .any(|request| request.contains("track_name=%E5%8B%87%E8%80%85&artist_name=YOASOBI")));
}

#[test]
fn anime_theme_upload_is_review_only_and_preserves_versions() {
    let title = "《葬送的芙莉莲》OP主题曲「勇者」YOASOBI【Hi-Res百万级录音棚试听】";
    let wanted = hint(title, "JLRS-jayfm", 196_000);
    assert!(lyrics_matching::search_variants(&wanted)
        .contains(&("勇者".into(), Some("YOASOBI".into()))));
    let candidate = hint("勇者", "YOASOBI", 194_000);
    assert!(
        lyrics_matching::confidence(&wanted, &candidate).unwrap() < crate::AUTO_APPLY_THRESHOLD
    );
    for suffix in [" Live", " TV Size", " カバー"] {
        let version = hint(&format!("{title}{suffix}"), "JLRS-jayfm", 196_000);
        assert!(lyrics_matching::confidence(&version, &candidate).is_none());
    }
    assert!(lyrics_matching::confidence(&hint(title, "JLRS-jayfm", 90_000), &candidate).is_none());
    assert!(
        lyrics_matching::confidence(&hint("勇者", "YOASOBI", 196_000), &candidate).unwrap()
            >= crate::AUTO_APPLY_THRESHOLD
    );
}

// Opt-in live-response verification: the payload is fetched separately and is
// not checked into the repository because it contains third-party lyrics.
#[test]
#[ignore]
fn actual_lrclib_response_matches_bilibili_upload_for_review() {
    let body = std::fs::read_to_string("/tmp/lekis-lrclib-yuusha.json").unwrap();
    let records = parse_lrclib_search(&body).unwrap();
    let title = "《葬送的芙莉莲》OP主题曲「勇者」YOASOBI【Hi-Res百万级录音棚试听】";
    let candidates = lyrics_candidates("lrclib", &hint(title, "JLRS-jayfm", 196_000), &records);
    assert!(candidates
        .iter()
        .any(|c| c.payload.format == LyricsFormat::Lrc));
    assert!(candidates
        .iter()
        .all(|c| c.provider_confidence < crate::AUTO_APPLY_THRESHOLD));
    let short = lyrics_candidates("lrclib", &hint(title, "JLRS-jayfm", 30_000), &records);
    assert!(short.is_empty());
}

#[test]
fn kana_equivalence_keeps_identity_and_version_guards() {
    let wanted = hint("アイドル", "ヨアソビ", 196_000);
    let equivalent = hint("あいどる", "よあそび", 196_000);
    assert!(
        lyrics_matching::confidence(&wanted, &equivalent).unwrap() >= crate::AUTO_APPLY_THRESHOLD
    );
    for rejected in [
        hint("あいどる (Live)", "よあそび", 196_000),
        hint("あいどる", "別人", 196_000),
        hint("あいどる", "よあそび", 230_000),
        hint("勇者", "よあそび", 196_000),
    ] {
        assert!(lyrics_matching::confidence(&wanted, &rejected).is_none());
    }
    assert!(lyrics_matching::confidence(
        &hint("勇者", "YOASOBI", 196_000),
        &hint("ゆうしゃ", "YOASOBI", 196_000)
    )
    .is_none());
}

#[tokio::test]
async fn kana_search_fallback_preserves_existing_variants() {
    let response = serde_json::json!([{"trackName":"あいどる","artistName":"YOASOBI","duration":196,"syncedLyrics":"[00:01.00]fixture"}]).to_string();
    let (base, requests, thread) = server(vec![
        (404, "{}".into()),
        (200, "[]".into()),
        (200, "[]".into()),
        (200, response),
    ]);
    let found = Lrclib::with_base_url(&base)
        .unwrap()
        .find_lyrics(&hint("アイドル", "YOASOBI", 196_000))
        .await
        .unwrap();
    thread.join().unwrap();
    assert_eq!(found.len(), 1);
    assert!(found[0].provider_confidence >= crate::AUTO_APPLY_THRESHOLD);
    let requests = requests.lock().unwrap();
    assert!(requests[1].contains("artist_name=YOASOBI"));
    assert!(!requests[2].contains("artist_name"));
    assert!(
        requests[3].contains("track_name=%E3%81%82%E3%81%84%E3%81%A9%E3%82%8B&artist_name=YOASOBI")
    );
}
