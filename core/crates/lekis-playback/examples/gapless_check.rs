//! 离线无缝播放检查（PLY-01 / Alpha 退出标准「无缝测试专辑实测无间隙」）。
//!
//! 用法：
//!
//! ```text
//! cargo run --release -p lekis-playback --example gapless_check -- <专辑目录> [选项]
//! # 或者：LEKIS_GAPLESS_DIR=<专辑目录> cargo run --release -p lekis-playback --example gapless_check
//! ```
//!
//! 选项：
//! - `--device-rate <Hz>`：模拟共享模式设备采样率（例如 Windows 混音器的 48000），
//!   走 [`lekis_playback::FormatConverter`] 重采样链路；默认等于内容格式（逐样本精确比对）。
//! - `--window <帧>`：边界两侧各取多少帧算不连续度（默认 4096）。
//! - `--speed <倍速>`：输出端拉样本的速度上限（相对实时）；默认 0 = 不限速。
//!
//! 没有给目录、也没有 `LEKIS_GAPLESS_DIR` 时直接打印 SKIP 并以 0 退出（CI 没有测试专辑）。
//!
//! ## 做了什么
//!
//! 1. 用**播放器自己的** [`Session`]（解码线程 → 增益/EQ/限幅 → 格式转换 → 环形缓冲 →
//!    输出回调里的 20 ms 淡入包络）连续播放目录里按文件名排序的所有曲目，下一首通过
//!    `Session::queue_next` 预装、在解码线程里样本级拼接——和引擎的无缝路径完全一样。
//! 2. 输出后端换成一个「捕获输出」：它像声卡回调一样从 `SampleSource::fill` 拉样本，
//!    只是不放声音，而是把**真实取到的**样本（`fill` 的返回值以内的部分）交给分析线程。
//!    消费端比解码快时 `fill` 补的欠载静音不计入（那是实时调度问题，不是拼接问题）。
//! 3. 分析：
//!    - (a) 帧数：渲染总帧数 == 各曲独立解码帧数之和；FLAC 还和 STREAMINFO 的 total samples 对账。
//!      设备格式 == 内容格式时，渲染流还要和「逐曲独立解码 + 同一级软限幅」拼成的参考流
//!      **逐样本相等**（跳过开头 20 ms 淡入）。
//!    - (b) 不连续度：每条边界、每个声道，取边界跳变 |x[B] − x[B−1]|，
//!      和边界两侧 ±window 帧内其他相邻样本差的 p99 比（ratio）。另外统计窗口内最长全零帧段。
//!    - 时间轴：会话报告的拼接样本号（UI 切歌点）必须等于期望的边界。
//! 4. 反向对照：把第一个边界窗口在边界处人为插入 10 ms 零，用同一套指标重新评估，必须被判失败。

#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::print_stdout,
    clippy::print_stderr
)]

use lekis_playback::decode::Decoder;
use lekis_playback::dsp::{fade_frames, DspNode, SoftClipper, DEFAULT_FADE_MS};
use lekis_playback::output::{AudioOutput, OutputDevice, OutputMode, SampleSource};
use lekis_playback::{
    MediaLocation, MediaSource, OutputFactory, PcmFormat, Session, SymphoniaDecoder,
};
use lekis_types::TrackId;
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

/// 边界跳变超过局部 p99 的这么多倍判为「咔哒」。
const RATIO_LIMIT: f32 = 4.0;
/// 跳变本身低于这个幅度（约 −80 dBFS）时听不见，不判失败。
const AUDIBLE_FLOOR: f32 = 1.0e-4;
/// 窗口里至少这么多帧「所有声道都是 0.0」才算插入了静音缝。
const MIN_GAP_FRAMES: usize = 16;
/// 负对照插入的静音时长。
const NEGATIVE_GAP_MS: u32 = 10;

fn main() {
    match run() {
        Ok(true) => {}
        Ok(false) => std::process::exit(1),
        Err(e) => {
            eprintln!("gapless_check: error: {e}");
            std::process::exit(2);
        }
    }
}

struct Args {
    dir: PathBuf,
    device_rate: Option<u32>,
    window: usize,
    speed: f64,
}

fn parse_args() -> Result<Option<Args>, BoxError> {
    let mut dir: Option<PathBuf> = None;
    let mut device_rate = None;
    let mut window = 4096usize;
    let mut speed = 0.0f64;
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--device-rate" => {
                device_rate = Some(it.next().ok_or("--device-rate needs a value")?.parse()?)
            }
            "--window" => window = it.next().ok_or("--window needs a value")?.parse()?,
            "--speed" => speed = it.next().ok_or("--speed needs a value")?.parse()?,
            "-h" | "--help" => {
                println!("usage: gapless_check <album-dir> [--device-rate HZ] [--window FRAMES] [--speed X]");
                return Ok(None);
            }
            other if !other.starts_with("--") && dir.is_none() => dir = Some(PathBuf::from(other)),
            other => return Err(format!("unknown argument: {other}").into()),
        }
    }
    let dir = dir.or_else(|| std::env::var_os("LEKIS_GAPLESS_DIR").map(PathBuf::from));
    let Some(dir) = dir else {
        println!("SKIP: no album directory given (pass <dir> or set LEKIS_GAPLESS_DIR)");
        return Ok(None);
    };
    if !dir.is_dir() {
        println!("SKIP: {} is not a directory", dir.display());
        return Ok(None);
    }
    Ok(Some(Args {
        dir,
        device_rate,
        window: window.max(64),
        speed,
    }))
}

fn audio_files(dir: &Path) -> Result<Vec<PathBuf>, BoxError> {
    const EXT: &[&str] = &[
        "flac", "wav", "mp3", "m4a", "aac", "ogg", "opus", "aif", "aiff", "alac",
    ];
    let mut files: Vec<PathBuf> = std::fs::read_dir(dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| {
            p.extension()
                .and_then(|e| e.to_str())
                .is_some_and(|e| EXT.contains(&e.to_ascii_lowercase().as_str()))
        })
        .collect();
    files.sort();
    Ok(files)
}

fn run() -> Result<bool, BoxError> {
    let Some(args) = parse_args()? else {
        return Ok(true);
    };
    let files = audio_files(&args.dir)?;
    if files.len() < 2 {
        println!(
            "SKIP: need at least two audio files in {}",
            args.dir.display()
        );
        return Ok(true);
    }

    // 内容格式取第一首；整张专辑必须同格式（否则拼接会换转换级，这里不覆盖）。
    let first = open(&files[0])?;
    let content = first.format();
    drop(first);
    let device = PcmFormat {
        sample_rate: args.device_rate.unwrap_or(content.sample_rate),
        channels: content.channels,
    };
    let exact = device == content;
    let channels = usize::from(content.channels);

    println!(
        "gapless_check: {} tracks in {}",
        files.len(),
        args.dir.display()
    );
    println!(
        "content {} Hz / {} ch -> device {} Hz / {} ch ({})",
        content.sample_rate,
        content.channels,
        device.sample_rate,
        device.channels,
        if exact {
            "bit-exact comparison"
        } else {
            "resampled, statistical checks only"
        }
    );
    let mut streaminfo = Vec::new();
    for (i, f) in files.iter().enumerate() {
        let info = flac_streaminfo(f);
        if let Some(si) = info {
            println!(
                "  {:02} {}  STREAMINFO {} Hz {} ch {} bit, {} frames",
                i + 1,
                f.file_name().and_then(|n| n.to_str()).unwrap_or("?"),
                si.sample_rate,
                si.channels,
                si.bits,
                si.total_frames
            );
        } else {
            println!(
                "  {:02} {}",
                i + 1,
                f.file_name().and_then(|n| n.to_str()).unwrap_or("?")
            );
        }
        streaminfo.push(info);
    }

    // ---- 渲染：播放器的 Session + 捕获输出 ----
    let (tx, rx) = mpsc::sync_channel::<Vec<f32>>(256);
    let factory = Arc::new(CaptureFactory {
        device,
        sender: Arc::new(Mutex::new(Some(tx))),
        speed: args.speed,
    });
    let timeline_marks: Arc<Mutex<Vec<(usize, u64)>>> = Arc::new(Mutex::new(Vec::new()));

    let analyzer = {
        let files = files.clone();
        let marks = timeline_marks.clone();
        let window = args.window;
        std::thread::Builder::new()
            .name("gapless-analyzer".into())
            .spawn(move || analyze(rx, files, exact, channels, device, window, marks))?
    };

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()?;
    let started = Instant::now();
    let render = runtime.block_on(drive(&files, factory, timeline_marks.clone()));
    let render_secs = started.elapsed().as_secs_f64();
    let analysis = analyzer.join().map_err(|_| "analyzer thread panicked")??;
    let render = render?;

    // ---- 报告 ----
    let mut ok = true;
    println!();
    println!(
        "rendered in {:.1} s wall clock; splices {}; consumer underrun callbacks {} (padding discarded)",
        render_secs, render.splices, render.underruns
    );
    if render.splices as usize != files.len() - 1 {
        println!(
            "FAIL: expected {} gapless splices, session made {}",
            files.len() - 1,
            render.splices
        );
        ok = false;
    }

    // (a) 帧数
    let decoded_total: u64 = analysis.track_frames.iter().sum();
    println!();
    println!("(a) frame accounting");
    for (i, frames) in analysis.track_frames.iter().enumerate() {
        let si = streaminfo.get(i).copied().flatten();
        let si_note = match si {
            Some(si) if si.total_frames == *frames => "== STREAMINFO".to_string(),
            Some(si) => {
                ok = false;
                format!("!= STREAMINFO {} (FAIL)", si.total_frames)
            }
            None => String::new(),
        };
        println!(
            "  track {:02}: decoded {} frames {}",
            i + 1,
            frames,
            si_note
        );
    }
    if exact {
        println!(
            "  rendered {} frames, sum of decoded tracks {} frames, diff {}",
            analysis.rendered_frames,
            decoded_total,
            analysis.rendered_frames as i64 - decoded_total as i64
        );
        if analysis.rendered_frames != decoded_total {
            ok = false;
            println!("  FAIL: rendered frame count differs from the sum of the tracks");
        }
        println!(
            "  sample-by-sample vs reference (after {}-frame fade-in): {} mismatching samples, max |diff| {:e}{}",
            analysis.fade_frames,
            analysis.mismatches,
            analysis.max_diff,
            analysis
                .first_mismatch
                .map(|m| format!(", first at frame {}", m / channels as u64))
                .unwrap_or_default()
        );
        if analysis.mismatches > 0 {
            ok = false;
            println!("  FAIL: rendered stream is not identical to the concatenated tracks");
        }
    } else {
        let expected =
            decoded_total as f64 * f64::from(device.sample_rate) / f64::from(content.sample_rate);
        let diff = analysis.rendered_frames as f64 - expected;
        println!(
            "  rendered {} frames, expected {:.1} (sum {} x {}/{}), diff {:+.1} frames",
            analysis.rendered_frames,
            expected,
            decoded_total,
            device.sample_rate,
            content.sample_rate,
            diff
        );
        // 只允许重采样器一个块以内的尾差（共享同一个转换级时，整张专辑只会在最后冲一次尾巴）。
        if diff.abs() > 2048.0 {
            ok = false;
            println!("  FAIL: rendered frame count is off by more than one resampler block");
        }
    }

    // 时间轴 + (b)
    println!();
    println!(
        "(b) boundary continuity (window ±{} frames, click if jump > {}x local p99 and > {:e})",
        args.window, RATIO_LIMIT, AUDIBLE_FLOOR
    );
    for b in &analysis.boundaries {
        let name = format!("{:02}->{:02}", b.index + 1, b.index + 2);
        let content_cum: u64 = analysis.track_frames.iter().take(b.index + 1).sum();
        let timeline = match (b.expected_frame, b.timeline_frame) {
            (Some(exp), Some(tl)) if exp == tl => format!("splice @ frame {tl} (== expected)"),
            (Some(exp), Some(tl)) => {
                ok = false;
                format!("splice @ frame {tl} != expected {exp} (FAIL)")
            }
            (None, Some(tl)) => {
                // 重采样：转换级跨曲复用，时间轴记的是「下一首第一次推样本」的位置，
                // 会比声学边界早一个重采样器延迟。只影响 UI 切歌点，不影响样本连续性。
                let exp = (content_cum as f64 * f64::from(device.sample_rate)
                    / f64::from(content.sample_rate))
                .round() as i64;
                let offset = tl as i64 - exp;
                if offset.abs() > 2048 {
                    ok = false;
                }
                format!(
                    "splice @ frame {tl} (rate-scaled boundary {exp}, offset {offset:+} frames = {:+.2} ms resampler delay){}",
                    offset as f64 * 1000.0 / f64::from(device.sample_rate),
                    if offset.abs() > 2048 { " FAIL" } else { "" }
                )
            }
            (_, None) => {
                ok = false;
                "splice not reported by the session timeline (FAIL)".to_string()
            }
        };
        println!("  {name}: {timeline}");
        match &b.verdict {
            Some(v) => {
                print_verdict(v, b.ref_zero_run, device.sample_rate);
                if !v.pass(b.ref_zero_run) {
                    ok = false;
                }
            }
            None => {
                ok = false;
                println!("      FAIL: boundary window could not be captured");
            }
        }
    }

    // 反向对照
    println!();
    println!("negative control: insert {NEGATIVE_GAP_MS} ms of zeros at the first boundary");
    let control_ok = match analysis
        .boundaries
        .first()
        .and_then(|b| b.window.as_ref().map(|w| (b, w)))
    {
        Some((b, window)) => {
            let gap = fade_frames(device.sample_rate, NEGATIVE_GAP_MS);
            let tampered = insert_gap(window, channels, args.window, gap);
            let v = evaluate(&tampered, channels, args.window);
            print_verdict(&v, b.ref_zero_run, device.sample_rate);
            let rendered_with_gap = analysis.rendered_frames + gap as u64;
            println!(
                "      frame count with gap: {} vs {} expected (diff +{})",
                rendered_with_gap,
                if exact {
                    decoded_total
                } else {
                    analysis.rendered_frames
                },
                gap
            );
            let flagged = !v.pass(b.ref_zero_run);
            println!(
                "      => {} (jump criterion: {}, zero-run criterion: {}, frame count: +{gap})",
                if flagged {
                    "FLAGGED (metric works)"
                } else {
                    "NOT flagged (metric is blind!)"
                },
                if v.has_click() {
                    "click"
                } else {
                    "not triggered"
                },
                if v.has_gap(b.ref_zero_run) {
                    "gap"
                } else {
                    "not triggered"
                },
            );
            flagged
        }
        None => false,
    };
    if !control_ok {
        ok = false;
    }

    println!();
    println!("RESULT: {}", if ok { "PASS" } else { "FAIL" });
    Ok(ok)
}

fn print_verdict(v: &Verdict, ref_zero_run: Option<usize>, rate: u32) {
    for (ch, m) in v.channels.iter().enumerate() {
        println!(
            "      ch{ch}: jump {:.6}  local p99 {:.6}  median {:.6}  max {:.6}  ratio {:.2}  {}",
            m.boundary_delta,
            m.p99,
            m.median,
            m.max_local,
            m.ratio,
            if m.is_click() { "CLICK" } else { "ok" }
        );
    }
    let ms = v.zero_run as f64 * 1000.0 / f64::from(rate);
    let gap = if v.has_gap(ref_zero_run) { "  GAP" } else { "" };
    match ref_zero_run {
        Some(r) => println!(
            "      longest all-zero run in window: {} frames ({:.3} ms), reference {} frames{gap}",
            v.zero_run, ms, r
        ),
        None => println!(
            "      longest all-zero run in window: {} frames ({:.3} ms){gap}",
            v.zero_run, ms
        ),
    }
}

// ---------------------------------------------------------------------------
// 渲染
// ---------------------------------------------------------------------------

struct RenderOutcome {
    splices: u64,
    underruns: u64,
}

fn media(i: usize, path: &Path) -> MediaSource {
    MediaSource {
        track_id: TrackId(i as i64 + 1),
        location: MediaLocation::CachedFile {
            path: path.to_string_lossy().into_owned(),
        },
        duration_hint_ms: 0,
        gain_db: None,
    }
}

/// 像引擎一样驱动会话：开播第一首，每次拼接后立刻预装再下一首。
async fn drive(
    files: &[PathBuf],
    factory: Arc<CaptureFactory>,
    marks: Arc<Mutex<Vec<(usize, u64)>>>,
) -> Result<RenderOutcome, BoxError> {
    let mut session = Session::start_with_factory(
        &media(0, &files[0]),
        None,
        OutputMode::Shared,
        1.0,
        tokio::runtime::Handle::current(),
        factory.clone(),
    )
    .await?;
    let mut next_to_queue = 1usize;
    session.queue_next(media(1, &files[1]));
    next_to_queue += 1;
    let mut seen: HashMap<TrackId, u64> = HashMap::new();
    let device_channels = u64::from(session.device_format().channels.max(1));

    let record = |session: &Session, seen: &mut HashMap<TrackId, u64>| {
        if let Some(track) = session.audible_track() {
            if track.splice_count > 0 && !seen.contains_key(&track.track_id) {
                seen.insert(track.track_id, track.start_sample);
                let idx = (track.track_id.0 - 1) as usize;
                if let Ok(mut m) = marks.lock() {
                    m.push((idx, track.start_sample / device_channels));
                }
            }
        }
    };

    let mut worker_gone_at: Option<Instant> = None;
    loop {
        let splices = session.splice_count() as usize;
        // 第 k 次拼接之后正在解第 k 首（0 起），它的下一首要立刻预装。
        if next_to_queue == splices + 1 && next_to_queue < files.len() {
            session.queue_next(media(next_to_queue, &files[next_to_queue]));
            next_to_queue += 1;
        }
        record(&session, &mut seen);
        if session.finished() {
            break;
        }
        if session.worker_finished() {
            // 解码线程退出但缓冲还没播空：再等一下；异常退出（没报 EOF）时别卡死。
            let since = *worker_gone_at.get_or_insert_with(Instant::now);
            if since.elapsed() > Duration::from_secs(5) {
                eprintln!("decode thread exited without reaching the end of the album");
                break;
            }
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
    record(&session, &mut seen);
    let outcome = RenderOutcome {
        splices: session.splice_count(),
        underruns: session.underruns(),
    };
    session.stop();
    // 输出线程已经停了；收掉发送端，分析线程据此结束。
    if let Ok(mut s) = factory.sender.lock() {
        s.take();
    }
    Ok(outcome)
}

/// 捕获输出工厂：设备格式固定为 `device`。
struct CaptureFactory {
    device: PcmFormat,
    sender: Arc<Mutex<Option<SyncSender<Vec<f32>>>>>,
    speed: f64,
}

impl OutputFactory for CaptureFactory {
    fn plan_format(
        &self,
        _device_id: Option<&str>,
        _requested: PcmFormat,
    ) -> lekis_types::Result<PcmFormat> {
        Ok(self.device)
    }

    fn create(&self) -> Box<dyn AudioOutput> {
        Box::new(CaptureOutput {
            device: self.device,
            sender: self.sender.clone(),
            speed: self.speed,
            stop: Arc::new(AtomicBool::new(false)),
            thread: None,
        })
    }
}

/// 像声卡回调一样拉样本、但不出声的输出。
struct CaptureOutput {
    device: PcmFormat,
    sender: Arc<Mutex<Option<SyncSender<Vec<f32>>>>>,
    speed: f64,
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl AudioOutput for CaptureOutput {
    fn devices(&self) -> lekis_types::Result<Vec<OutputDevice>> {
        Ok(Vec::new())
    }

    fn start(
        &mut self,
        _device_id: Option<&str>,
        _requested: PcmFormat,
        _mode: OutputMode,
        mut source: Box<dyn SampleSource>,
    ) -> lekis_types::Result<PcmFormat> {
        let sender = self.sender.lock().ok().and_then(|s| s.clone());
        let Some(sender) = sender else {
            return Err(lekis_types::LekisError::internal(
                "capture output already used",
            ));
        };
        let stop = self.stop.clone();
        let channels = usize::from(self.device.channels.max(1));
        let rate = f64::from(self.device.sample_rate.max(1));
        let speed = self.speed;
        let pulled = Arc::new(AtomicU64::new(0));
        self.thread = Some(
            std::thread::Builder::new()
                .name("gapless-capture".into())
                .spawn(move || {
                    let frames = 1024usize;
                    let mut block = vec![0.0f32; frames * channels];
                    let began = Instant::now();
                    while !stop.load(Ordering::Relaxed) {
                        if speed > 0.0 {
                            let played_s =
                                pulled.load(Ordering::Relaxed) as f64 / channels as f64 / rate;
                            let due = Duration::from_secs_f64(played_s / speed);
                            let elapsed = began.elapsed();
                            if due > elapsed {
                                std::thread::sleep((due - elapsed).min(Duration::from_millis(5)));
                                continue;
                            }
                        }
                        let n = source.fill(&mut block);
                        if n == 0 {
                            std::thread::sleep(Duration::from_micros(200));
                            continue;
                        }
                        pulled.fetch_add(n as u64, Ordering::Relaxed);
                        if sender.send(block[..n].to_vec()).is_err() {
                            break;
                        }
                    }
                })
                .map_err(|e| lekis_types::LekisError::internal(format!("spawn capture: {e}")))?,
        );
        Ok(self.device)
    }

    fn pause(&mut self) -> lekis_types::Result<()> {
        Ok(())
    }

    fn resume(&mut self) -> lekis_types::Result<()> {
        Ok(())
    }

    fn stop(&mut self) -> lekis_types::Result<()> {
        self.stop.store(true, Ordering::Release);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// 参考流：逐曲独立解码 + 同一级软限幅（音量 1.0、无 ReplayGain、EQ 关闭时会话就是这样处理的）
// ---------------------------------------------------------------------------

fn open(path: &Path) -> Result<SymphoniaDecoder, BoxError> {
    let file = std::fs::File::open(path)?; // 只读打开
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase());
    Ok(SymphoniaDecoder::open_file(file, ext.as_deref())?)
}

struct Reference {
    files: Vec<PathBuf>,
    next_file: usize,
    decoder: Option<SymphoniaDecoder>,
    buf: Vec<f32>,
    pos: usize,
    channels: usize,
    clipper: SoftClipper,
    current_samples: u64,
    track_frames: Vec<u64>,
}

impl Reference {
    fn new(files: Vec<PathBuf>, channels: usize) -> Self {
        Self {
            files,
            next_file: 0,
            decoder: None,
            buf: Vec::new(),
            pos: 0,
            channels,
            clipper: SoftClipper,
            current_samples: 0,
            track_frames: Vec::new(),
        }
    }

    /// 下一个参考样本；整张专辑结束时 `None`。
    fn next(&mut self) -> Result<Option<f32>, BoxError> {
        loop {
            if self.pos < self.buf.len() {
                let s = self.buf[self.pos];
                self.pos += 1;
                self.current_samples += 1;
                return Ok(Some(s));
            }
            if self.decoder.is_none() {
                if self.next_file >= self.files.len() {
                    return Ok(None);
                }
                let dec = open(&self.files[self.next_file])?;
                if usize::from(dec.format().channels) != self.channels {
                    return Err("tracks have different channel counts".into());
                }
                self.next_file += 1;
                self.decoder = Some(dec);
            }
            self.buf.clear();
            self.pos = 0;
            let more = match self.decoder.as_mut() {
                Some(dec) => dec.decode_next(&mut self.buf)?,
                None => false,
            };
            if !more {
                self.track_frames
                    .push(self.current_samples / self.channels as u64);
                self.current_samples = 0;
                self.decoder = None;
                continue;
            }
            self.clipper.process(&mut self.buf, self.channels as u16);
        }
    }

    fn drain(&mut self) -> Result<u64, BoxError> {
        let mut n = 0;
        while self.next()?.is_some() {
            n += 1;
        }
        Ok(n)
    }
}

// ---------------------------------------------------------------------------
// 分析
// ---------------------------------------------------------------------------

struct Analysis {
    rendered_frames: u64,
    track_frames: Vec<u64>,
    mismatches: u64,
    max_diff: f32,
    first_mismatch: Option<u64>,
    fade_frames: usize,
    boundaries: Vec<BoundaryReport>,
}

struct BoundaryReport {
    /// 第几条边界（0 = 第 1 首 → 第 2 首）。
    index: usize,
    /// 参考流给出的期望边界帧号（只在逐样本模式下有）。
    expected_frame: Option<u64>,
    /// 会话时间轴报告的拼接帧号。
    timeline_frame: Option<u64>,
    window: Option<Vec<f32>>,
    ref_zero_run: Option<usize>,
    verdict: Option<Verdict>,
}

/// 保存最近若干帧的滚动缓冲（带绝对帧号）。
struct History {
    data: VecDeque<f32>,
    start_frame: u64,
    channels: usize,
    cap_frames: usize,
}

impl History {
    fn new(channels: usize, cap_frames: usize) -> Self {
        Self {
            data: VecDeque::with_capacity(cap_frames * channels + channels),
            start_frame: 0,
            channels,
            cap_frames,
        }
    }

    fn push(&mut self, s: f32) {
        self.data.push_back(s);
        if self.data.len() > (self.cap_frames + 1) * self.channels {
            for _ in 0..self.channels {
                self.data.pop_front();
            }
            self.start_frame += 1;
        }
    }

    fn end_frame(&self) -> u64 {
        self.start_frame + (self.data.len() / self.channels) as u64
    }

    /// 取 [from, to) 帧；越界返回 `None`。
    fn slice(&self, from: u64, to: u64) -> Option<Vec<f32>> {
        if from < self.start_frame || to > self.end_frame() || from > to {
            return None;
        }
        let a = ((from - self.start_frame) as usize) * self.channels;
        let b = ((to - self.start_frame) as usize) * self.channels;
        Some(self.data.range(a..b).copied().collect())
    }
}

#[allow(clippy::too_many_arguments)]
fn analyze(
    rx: Receiver<Vec<f32>>,
    files: Vec<PathBuf>,
    exact: bool,
    channels: usize,
    device: PcmFormat,
    window: usize,
    marks: Arc<Mutex<Vec<(usize, u64)>>>,
) -> Result<Analysis, BoxError> {
    let n_boundaries = files.len() - 1;
    let mut reference = Reference::new(files, channels);
    let fade = fade_frames(device.sample_rate, DEFAULT_FADE_MS);
    let fade_samples = (fade * channels) as u64;
    // 10 s 历史：时间轴通知比分析线程晚到也来得及取窗口。
    let hist_frames = (device.sample_rate as usize * 10).max(window * 4);
    let mut rendered_hist = History::new(channels, hist_frames);
    let mut ref_hist = History::new(channels, hist_frames);

    let mut reports: Vec<BoundaryReport> = (0..n_boundaries)
        .map(|index| BoundaryReport {
            index,
            expected_frame: None,
            timeline_frame: None,
            window: None,
            ref_zero_run: None,
            verdict: None,
        })
        .collect();

    let mut sample_idx: u64 = 0;
    let mut mismatches = 0u64;
    let mut max_diff = 0.0f32;
    let mut first_mismatch = None;
    let mut ref_tracks_seen = 0usize;

    let capture = |reports: &mut Vec<BoundaryReport>,
                   rendered_hist: &History,
                   ref_hist: &History,
                   final_pass: bool| {
        let marks = marks.lock().map(|m| m.clone()).unwrap_or_default();
        for (track_idx, frame) in marks {
            if track_idx == 0 || track_idx > reports.len() {
                continue;
            }
            let r = &mut reports[track_idx - 1];
            r.timeline_frame = Some(frame);
            if r.window.is_some() {
                continue;
            }
            let b = frame;
            if b < window as u64 {
                continue;
            }
            let to = b + window as u64;
            if rendered_hist.end_frame() < to && !final_pass {
                continue; // 还没渲染到
            }
            if let Some(w) =
                rendered_hist.slice(b - window as u64, to.min(rendered_hist.end_frame()))
            {
                if w.len() == 2 * window * channels {
                    r.verdict = Some(evaluate(&w, channels, window));
                    r.window = Some(w);
                    if exact {
                        if let Some(rw) = ref_hist.slice(b - window as u64, to) {
                            r.ref_zero_run = Some(longest_zero_run(&rw, channels));
                        }
                    }
                }
            }
        }
    };

    while let Ok(chunk) = rx.recv() {
        for &s in &chunk {
            rendered_hist.push(s);
            if exact {
                match reference.next()? {
                    Some(r) => {
                        ref_hist.push(r);
                        if sample_idx >= fade_samples && r.to_bits() != s.to_bits() {
                            mismatches += 1;
                            let d = (r - s).abs();
                            if d > max_diff {
                                max_diff = d;
                            }
                            if first_mismatch.is_none() {
                                first_mismatch = Some(sample_idx);
                            }
                        }
                    }
                    None => {
                        mismatches += 1;
                        if first_mismatch.is_none() {
                            first_mismatch = Some(sample_idx);
                        }
                    }
                }
                // 参考流每结束一首，就得到一条期望边界。
                while ref_tracks_seen < reference.track_frames.len() {
                    let cum: u64 = reference.track_frames[..=ref_tracks_seen].iter().sum();
                    if ref_tracks_seen < reports.len() {
                        reports[ref_tracks_seen].expected_frame = Some(cum);
                    }
                    ref_tracks_seen += 1;
                }
            }
            sample_idx += 1;
        }
        capture(&mut reports, &rendered_hist, &ref_hist, false);
    }
    capture(&mut reports, &rendered_hist, &ref_hist, true);

    let rendered_frames = sample_idx / channels as u64;
    // 参考流剩下的部分（渲染短了时）也要数进去，帧数对账才完整。
    let leftover = reference.drain()?;
    if exact && leftover > 0 {
        mismatches += leftover;
        if first_mismatch.is_none() {
            first_mismatch = Some(sample_idx);
        }
    }
    for (i, r) in reports.iter_mut().enumerate() {
        if r.expected_frame.is_none() && exact {
            r.expected_frame = Some(reference.track_frames[..=i].iter().sum());
        }
    }
    Ok(Analysis {
        rendered_frames,
        track_frames: reference.track_frames,
        mismatches,
        max_diff,
        first_mismatch,
        fade_frames: fade,
        boundaries: reports,
    })
}

// ---------------------------------------------------------------------------
// 指标（纯函数，有单元测试）
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct ChannelMetric {
    boundary_delta: f32,
    p99: f32,
    median: f32,
    max_local: f32,
    ratio: f32,
}

impl ChannelMetric {
    fn is_click(&self) -> bool {
        self.boundary_delta > AUDIBLE_FLOOR && self.ratio > RATIO_LIMIT
    }
}

#[derive(Debug, Clone)]
struct Verdict {
    channels: Vec<ChannelMetric>,
    zero_run: usize,
}

impl Verdict {
    /// 没有咔哒，且没有比参考流更长的全零段（没有参考流时以 0 为准）。
    ///
    /// 全零段至少 [`MIN_GAP_FRAMES`] 帧才算缝：两个声道恰好同时过零的单帧在真实音乐里会出现。
    fn pass(&self, ref_zero_run: Option<usize>) -> bool {
        !self.has_click() && !self.has_gap(ref_zero_run)
    }

    fn has_click(&self) -> bool {
        self.channels.iter().any(ChannelMetric::is_click)
    }

    fn has_gap(&self, ref_zero_run: Option<usize>) -> bool {
        self.zero_run >= MIN_GAP_FRAMES && self.zero_run > ref_zero_run.unwrap_or(0)
    }
}

/// 评估一个窗口：`window` 是交错样本，边界（下一首第一帧）在第 `b` 帧。
fn evaluate(window: &[f32], channels: usize, b: usize) -> Verdict {
    let frames = window.len() / channels;
    let mut out = Vec::with_capacity(channels);
    for ch in 0..channels {
        let x = |i: usize| window[i * channels + ch];
        let mut local: Vec<f32> = Vec::with_capacity(frames);
        let mut boundary_delta = 0.0f32;
        for i in 1..frames {
            let d = (x(i) - x(i - 1)).abs();
            if i == b {
                boundary_delta = d;
            } else {
                local.push(d);
            }
        }
        local.sort_by(f32::total_cmp);
        let pick = |q: f64| -> f32 {
            if local.is_empty() {
                0.0
            } else {
                let i = ((local.len() - 1) as f64 * q).round() as usize;
                local[i]
            }
        };
        let p99 = pick(0.99);
        let median = pick(0.5);
        let max_local = local.last().copied().unwrap_or(0.0);
        let ratio = boundary_delta / p99.max(f32::MIN_POSITIVE);
        out.push(ChannelMetric {
            boundary_delta,
            p99,
            median,
            max_local,
            ratio,
        });
    }
    Verdict {
        channels: out,
        zero_run: longest_zero_run(window, channels),
    }
}

/// 最长的「所有声道都是 0.0」的连续帧数。
fn longest_zero_run(window: &[f32], channels: usize) -> usize {
    let mut best = 0;
    let mut run = 0;
    for frame in window.chunks_exact(channels) {
        if frame.iter().all(|s| *s == 0.0) {
            run += 1;
            best = best.max(run);
        } else {
            run = 0;
        }
    }
    best
}

/// 负对照：在第 `b` 帧处插入 `gap` 帧静音，再截回原窗口长度（边界仍在第 `b` 帧）。
fn insert_gap(window: &[f32], channels: usize, b: usize, gap: usize) -> Vec<f32> {
    let mut out = Vec::with_capacity(window.len() + gap * channels);
    out.extend_from_slice(&window[..b * channels]);
    out.extend(std::iter::repeat_n(0.0f32, gap * channels));
    out.extend_from_slice(&window[b * channels..]);
    out.truncate(window.len());
    out
}

// ---------------------------------------------------------------------------
// FLAC STREAMINFO（独立于 symphonia 的帧数对账）
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy)]
struct StreamInfo {
    sample_rate: u32,
    channels: u8,
    bits: u8,
    total_frames: u64,
}

fn flac_streaminfo(path: &Path) -> Option<StreamInfo> {
    use std::io::Read;
    if !path
        .extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| e.eq_ignore_ascii_case("flac"))
    {
        return None;
    }
    let mut f = std::fs::File::open(path).ok()?;
    let mut head = [0u8; 4 + 4 + 34];
    f.read_exact(&mut head).ok()?;
    parse_streaminfo(&head)
}

fn parse_streaminfo(head: &[u8]) -> Option<StreamInfo> {
    if head.len() < 42 || &head[..4] != b"fLaC" || head[4] & 0x7f != 0 {
        return None;
    }
    let si = &head[8..42];
    let mut v = 0u64;
    for byte in &si[10..18] {
        v = (v << 8) | u64::from(*byte);
    }
    Some(StreamInfo {
        sample_rate: (v >> 44) as u32,
        channels: (((v >> 41) & 0x7) + 1) as u8,
        bits: (((v >> 36) & 0x1f) + 1) as u8,
        total_frames: v & 0xf_ffff_ffff,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 立体声低频正弦，跨边界连续（模拟真正无缝的两首）。
    fn sine_window(frames: usize, freq: f32, rate: f32) -> Vec<f32> {
        let mut w = Vec::with_capacity(frames * 2);
        for i in 0..frames {
            let t = i as f32 / rate;
            // 加相位，避免第 0 帧两个声道同时为 0。
            let s = 0.5 * (2.0 * std::f32::consts::PI * freq * t + 0.3).sin();
            w.push(s);
            w.push(-0.8 * s);
        }
        w
    }

    #[test]
    fn continuous_signal_passes() {
        let w = sine_window(8192, 220.0, 44_100.0);
        let v = evaluate(&w, 2, 4096);
        assert!(v.pass(Some(0)), "{v:?}");
        assert!(v.channels.iter().all(|m| m.ratio < 1.5), "{v:?}");
    }

    #[test]
    fn inserted_gap_is_flagged() {
        let w = sine_window(8192, 220.0, 44_100.0);
        let gap = fade_frames(44_100, NEGATIVE_GAP_MS);
        let tampered = insert_gap(&w, 2, 4096, gap);
        assert_eq!(tampered.len(), w.len());
        let v = evaluate(&tampered, 2, 4096);
        assert_eq!(v.zero_run, gap);
        assert!(!v.pass(Some(0)), "gap must be flagged: {v:?}");
    }

    #[test]
    fn dropped_frame_is_not_a_click_so_frame_counts_matter() {
        // 丢一帧在低频信号上几乎听不出跳变：这正是为什么帧数对账 / 逐样本比对必须单独做。
        let w = sine_window(8193, 220.0, 44_100.0);
        let mut dropped = w.clone();
        dropped.drain(4096 * 2..4097 * 2);
        let v = evaluate(&dropped, 2, 4096);
        assert!(v.channels.iter().all(|m| m.ratio < RATIO_LIMIT));
    }

    #[test]
    fn hard_step_is_a_click() {
        let mut w = sine_window(8192, 220.0, 44_100.0);
        for s in &mut w[4096 * 2..] {
            *s += 0.3;
        }
        let v = evaluate(&w, 2, 4096);
        assert!(!v.pass(Some(0)), "{v:?}");
    }

    #[test]
    fn parses_streaminfo() {
        let mut head = vec![0u8; 42];
        head[..4].copy_from_slice(b"fLaC");
        head[4] = 0x80; // last-metadata-block flag + type 0
        head[7] = 34;
        // 44100 Hz, 2 ch, 16 bit, 1234567 frames
        let v: u64 = (44_100u64 << 44) | (1u64 << 41) | (15u64 << 36) | 1_234_567;
        head[8 + 10..8 + 18].copy_from_slice(&v.to_be_bytes());
        let si = parse_streaminfo(&head).unwrap();
        assert_eq!(si.sample_rate, 44_100);
        assert_eq!(si.channels, 2);
        assert_eq!(si.bits, 16);
        assert_eq!(si.total_frames, 1_234_567);
    }
}
