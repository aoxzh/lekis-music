#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

//! 测试辅助：空输出后端 + 生成小 WAV 文件。
//!
//! 只在 `cfg(test)` 下编译。空输出按真实时间节奏从 [`SampleSource`] 拉样本，
//! 记录下完整的输出序列，这样没有声卡也能断言无缝拼接的样本边界（PLY-01）。
//! 它**不会**在测试之外进入生产代码。

use crate::decode::PcmFormat;
use crate::output::{AudioOutput, OutputDevice, OutputMode, SampleSource};
use crate::session::OutputFactory;
use lekis_types::Result;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// 生成一个 16-bit PCM WAV 文件（常数样本，便于校验拼接点）。
///
/// 返回文件路径；调用方负责删除临时目录。
pub(crate) fn write_wav(
    dir: &Path,
    name: &str,
    sample_rate: u32,
    channels: u16,
    frames: usize,
    sample: i16,
) -> PathBuf {
    let bits = 16u16;
    let block_align = channels * bits / 8;
    let data_len = (frames as u32) * u32::from(block_align);
    let mut buf = Vec::with_capacity(44 + data_len as usize);
    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&(36 + data_len).to_le_bytes());
    buf.extend_from_slice(b"WAVE");
    buf.extend_from_slice(b"fmt ");
    buf.extend_from_slice(&16u32.to_le_bytes());
    buf.extend_from_slice(&1u16.to_le_bytes()); // PCM
    buf.extend_from_slice(&channels.to_le_bytes());
    buf.extend_from_slice(&sample_rate.to_le_bytes());
    buf.extend_from_slice(&(sample_rate * u32::from(block_align)).to_le_bytes());
    buf.extend_from_slice(&block_align.to_le_bytes());
    buf.extend_from_slice(&bits.to_le_bytes());
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_len.to_le_bytes());
    for _ in 0..frames {
        for _ in 0..channels {
            buf.extend_from_slice(&sample.to_le_bytes());
        }
    }
    std::fs::create_dir_all(dir).expect("create temp dir");
    let path = dir.join(name);
    std::fs::write(&path, buf).expect("write test wav");
    path
}

/// 每次测试用的唯一临时目录。
pub(crate) fn temp_dir(label: &str) -> PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!("lekis-playback-{label}-{}-{n}", std::process::id()))
}

/// 空输出工厂：协商格式固定，记录所有实际送进设备的样本。
#[derive(Clone)]
pub(crate) struct NullOutputFactory {
    /// 模拟的设备格式。
    pub planned: PcmFormat,
    /// 录下来的样本（交错、设备格式）。
    pub capture: Arc<Mutex<Vec<f32>>>,
    /// 每次 fill 的帧数。
    pub chunk_frames: usize,
    /// 开播前等解码线程把缓冲填起来，避免测试一开始就欠载。
    pub startup_delay: Duration,
}

impl NullOutputFactory {
    pub(crate) fn new(planned: PcmFormat) -> Self {
        Self {
            planned,
            capture: Arc::new(Mutex::new(Vec::new())),
            chunk_frames: 400,
            startup_delay: Duration::from_millis(120),
        }
    }

    pub(crate) fn captured(&self) -> Vec<f32> {
        self.capture
            .lock()
            .map(|samples| samples.clone())
            .unwrap_or_default()
    }
}

impl OutputFactory for NullOutputFactory {
    fn plan_format(&self, _device_id: Option<&str>, _requested: PcmFormat) -> Result<PcmFormat> {
        Ok(self.planned)
    }

    fn create(&self) -> Box<dyn AudioOutput> {
        Box::new(NullOutput {
            capture: self.capture.clone(),
            planned: self.planned,
            chunk_frames: self.chunk_frames,
            startup_delay: self.startup_delay,
            stop: Arc::new(AtomicBool::new(false)),
            paused: Arc::new(AtomicBool::new(false)),
            thread: None,
        })
    }
}

/// 把样本按真实时间节奏拉走的空输出。
struct NullOutput {
    capture: Arc<Mutex<Vec<f32>>>,
    planned: PcmFormat,
    chunk_frames: usize,
    startup_delay: Duration,
    stop: Arc<AtomicBool>,
    paused: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl AudioOutput for NullOutput {
    fn devices(&self) -> Result<Vec<OutputDevice>> {
        Ok(Vec::new())
    }

    fn start(
        &mut self,
        _device_id: Option<&str>,
        _requested: PcmFormat,
        _mode: OutputMode,
        mut source: Box<dyn SampleSource>,
    ) -> Result<PcmFormat> {
        let stop = self.stop.clone();
        let paused = self.paused.clone();
        let capture = self.capture.clone();
        let format = self.planned;
        let frames = self.chunk_frames.max(1);
        let channels = usize::from(format.channels.max(1));
        let rate = u64::from(format.sample_rate.max(1));
        let period = Duration::from_nanos(frames as u64 * 1_000_000_000 / rate);
        let startup = self.startup_delay;
        self.thread = Some(
            std::thread::Builder::new()
                .name("lekis-null-output".to_string())
                .spawn(move || {
                    std::thread::sleep(startup);
                    let mut block = vec![0.0f32; frames * channels];
                    while !stop.load(Ordering::Relaxed) {
                        if paused.load(Ordering::Relaxed) {
                            std::thread::sleep(Duration::from_millis(5));
                            continue;
                        }
                        let began = Instant::now();
                        let _ = source.fill(&mut block);
                        if let Ok(mut out) = capture.lock() {
                            out.extend_from_slice(&block);
                        }
                        let spent = began.elapsed();
                        if spent < period {
                            std::thread::sleep(period - spent);
                        }
                    }
                })
                .expect("spawn null output thread"),
        );
        Ok(format)
    }

    fn pause(&mut self) -> Result<()> {
        self.paused.store(true, Ordering::Release);
        Ok(())
    }

    fn resume(&mut self) -> Result<()> {
        self.paused.store(false, Ordering::Release);
        Ok(())
    }

    fn stop(&mut self) -> Result<()> {
        self.stop.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
        Ok(())
    }
}

/// 去掉首尾静音，返回中间那段（测试里用常数非零样本，内部出现零就是断点）。
pub(crate) fn nonzero_span(samples: &[f32]) -> &[f32] {
    let start = samples.iter().position(|s| *s != 0.0).unwrap_or(0);
    let end = samples
        .iter()
        .rposition(|s| *s != 0.0)
        .map(|i| i + 1)
        .unwrap_or(start);
    &samples[start..end]
}
