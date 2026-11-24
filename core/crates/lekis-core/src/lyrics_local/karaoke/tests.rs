use super::*;
use crate::lyrics_local::load;
use lekis_types::LyricsFormat;
use lekis_vfs::local::LocalVfs;

// Original test lines encoded independently using Python zlib and the LDDC
// local QRC encoder primitives. Hex keeps the exact binary fixtures reviewable.
const QRC: &str = concat!(
    "9825b0ace3028368e8fc6cde126efb031840bddb18fc5957d2508762fa12846787",
    "a06031197fe083687f9203024b8ce09eae79bfc7679346a2393c9eef5a816f11e",
    "122f673f1244c0c4f39999be21739ccb33d127257db1d088dac4ecb185bf208a",
    "825ef38ba0e5c63fe501bbe2d8bdd916c255958ee191855725ff877057f91081e",
    "189aea1fb78653e905ff7cd25fff281c9cea4359826be2d5cbc302ac107bfc77a3",
    "4a987622e23c1e27cbaa9c8b5cc3bd70f1ffb61dbd81129754be9a762c3f574b"
);
const QRC_TS: &str = concat!(
    "9825b0ace3028368e8fc6cf7bc8a49f2368214c0474246569623aa483e8207c7d1",
    "b3d93ea689d7b7fdcae5515ed5b38fd62a96f410d8e7a175e9c5"
);
const KRC: &str = concat!(
    "6b72633138dbeab917fe3f681c7a7e98847f9aa30a755342d6384372a1fa1b65cc20",
    "633b63db134bedc05f3bcd8bbb7eed6e644b4dbbabe5acb006d5a33402d0bd98fc5",
    "5f36c53e57c2ea7fa63ab03bebda1dccacc055254dc19e67b628b635112585dea82b",
    "a93e4748f2665733abbbc02f9a9001e69f1eac5ae7dd3fe7e3d5ae521a2586849ce",
    "83947d7d8857bfa80b48490a2fc45e3b759381f9a2b4bc0719fee6bc58f3f7e9c26",
    "fe245738607815674a69d927df40dfb724778ca5db6cdca433903e56d8a15fb527e",
    "f57be4513abacca77770585f61325272525fd2ee976d78dfe66bd9771ae9d3233059",
    "994d0852fdd25c5b205c"
);

async fn from_files(files: &[(&str, &[u8])]) -> String {
    let dir = tempfile::tempdir().unwrap();
    for (name, bytes) in files {
        std::fs::write(dir.path().join(name), bytes).unwrap();
    }
    let vfs = LocalVfs::new(dir.path()).unwrap();
    let lyrics = load(&vfs, &VfsPath::parse("sample.flac").unwrap())
        .await
        .unwrap();
    assert_eq!(lyrics.source, "sidecar");
    assert_eq!(lyrics.format, LyricsFormat::Ttml);
    lyrics.content
}

fn assert_times(xml: &str) {
    for fragment in [
        "<p begin=\"1012ms\" end=\"1700ms\"",
        "<span begin=\"1041ms\" end=\"1161ms\">灯</span>",
        "<span begin=\"1408ms\" end=\"1613ms\">&amp;桥</span>",
        "<span ttm:role=\"x-translation\">Lamp &amp; bridge</span>",
    ] {
        assert!(xml.contains(fragment), "missing {fragment}");
    }
}

#[tokio::test]
async fn cloud_qrc_hex_file() {
    let hex = b"6eb8984dfdfa792d83ad6bb107f29d61\n85b27d5de24a6fa29df7876d297b8798";
    let xml = from_files(&[("sample.qrc", hex)]).await;
    assert!(xml.contains(
        "<p begin=\"321ms\" end=\"721ms\"><span begin=\"330ms\" end=\"520ms\">纸</span>"
    ));
}

#[tokio::test]
async fn keeps_overlap_gaps_inner_spaces_and_file_offset() {
    let raw = "[offset:40]\n[10,500](10,20,0) [A](81,30,0)one (152,100,0)two   \n[10,400](10,20,0)[B](81,30,0)三";
    let xml = from_files(&[("sample.yrc", raw.as_bytes())]).await;
    assert!(xml.contains("begin=\"0ms\" end=\"470ms\" ttm:agent=\"v1\"><span begin=\"41ms\" end=\"71ms\">one </span><span begin=\"112ms\" end=\"212ms\">two</span>"));
    assert!(xml.contains("begin=\"0ms\" end=\"370ms\" ttm:agent=\"v2\""));
}

#[tokio::test]
async fn encrypted_local_qrc_and_companion() {
    let xml = from_files(&[
        ("sample.qrc", &hex::decode(QRC).unwrap()),
        ("sample_qmts.qrc", &hex::decode(QRC_TS).unwrap()),
        ("sample.lrc", b"[00:00.00]fallback"),
    ])
    .await;
    assert_times(&xml);
    assert!(xml.contains("type=\"group\"><ttm:name>合</ttm:name>"));
    assert!(xml.contains("end=\"1700ms\" ttm:agent=\"v1\""));
    assert!(xml.contains("end=\"3500ms\"><span"));
    assert!(xml.contains("ttm:role=\"x-translation\">Echo</span>"));
}

#[tokio::test]
async fn compressed_krc_with_language_rows_and_voice() {
    let xml = from_files(&[("sample.KRC", &hex::decode(KRC).unwrap())]).await;
    assert_times(&xml);
    assert!(xml.contains("type=\"person\"><ttm:name>女</ttm:name>"));
    assert!(xml.contains("end=\"1700ms\" ttm:agent=\"v1\""));
    assert!(xml.contains("ttm:role=\"x-roman\">dengqiao</span>"));
    assert!(xml.contains("ttm:role=\"x-translation\">Echo</span>"));
    assert!(xml.contains("ttm:role=\"x-roman\">huiyin</span>"));
    assert!(!xml.contains("begin=\"2000ms\""));
}

#[tokio::test]
async fn yrc_json_and_raw_metadata_lines() {
    let row = "[1012,688](1012,17,0)[Vocal: 岚](1041,120,0)灯(1408,205,0)&桥";
    let json = serde_json::json!({"yrc":{"lyric":row},"ytlrc":{"lyric":"[00:01.012]Lamp & bridge"},"tlyric":{"lyric":"[00:01.012]older translation"}});
    let xml = from_files(&[("sample.YRC", json.to_string().as_bytes())]).await;
    assert_times(&xml);
    assert!(xml.contains("<ttm:name>岚</ttm:name>"));
    assert!(!xml.contains("older translation"));
    let raw = format!("{{\"t\":0,\"c\":[{{\"tx\":\"credit\"}}]}}\n{row}");
    let xml = from_files(&[("sample.yrc", raw.as_bytes())]).await;
    assert!(xml.contains("end=\"1613ms\">&amp;桥</span>"));
    assert!(!xml.contains("credit"));
}

#[tokio::test]
async fn plain_qrc_xml_entities_and_legacy_encodings() {
    let original = "<QrcInfos><Lyric_1 LyricContent=\"[8,120]桥(12,10)&#10;[130,100](&amp;)(141,21)\"/></QrcInfos>";
    let gbk = encoding_rs::GBK.encode(original).0;
    let utf16be: Vec<_> = [0xfe, 0xff]
        .into_iter()
        .chain(original.encode_utf16().flat_map(u16::to_be_bytes))
        .collect();
    let utf16le: Vec<_> = [0xff, 0xfe]
        .into_iter()
        .chain(original.encode_utf16().flat_map(u16::to_le_bytes))
        .collect();
    for bytes in [gbk.as_ref(), &utf16be, &utf16le] {
        let xml = from_files(&[("sample.QRC", bytes)]).await;
        assert!(xml.contains("begin=\"12ms\" end=\"22ms\">桥</span>"));
        assert!(xml.contains("begin=\"141ms\" end=\"162ms\">(&amp;)</span>"));
    }
}

#[tokio::test]
async fn corrupt_or_oversized_payload_falls_back_to_original_ttml() {
    let fallback = b"<tt><body><div><p begin=\"1s\">original</p></div></body></tt>";
    let deflated =
        miniz_oxide::deflate::compress_to_vec_zlib(&vec![b'a'; MAX_SIDECAR_BYTES as usize + 1], 6);
    let mut bomb = b"krc1".to_vec();
    bomb.extend(
        deflated
            .iter()
            .enumerate()
            .map(|(index, byte)| byte ^ b"@Gaw^2tGQ61-\xce\xd2ni"[index % 16]),
    );
    assert_eq!(
        from_files(&[
            ("sample.QRC", qrc_container::MAGIC),
            ("sample.YRC", b"[1,9](4294967295,1,0)x"),
            ("sample.KRC", &bomb),
            ("sample.ttml", fallback),
        ])
        .await
        .as_bytes(),
        fallback
    );
}
