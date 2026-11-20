// In-memory diagnostic log ring (SET-03). The desktop/mobile app can show the
// last N lines from Settings without reading platform log files. Secrets are
// redacted before a line is stored.
use std::collections::VecDeque;
use std::io;
use std::sync::{Arc, Mutex, OnceLock};

use tracing_subscriber::fmt::MakeWriter;

const CAPACITY: usize = 2000;

type Buffer = Arc<Mutex<VecDeque<String>>>;

static LOGS: OnceLock<Buffer> = OnceLock::new();

fn buffer() -> &'static Buffer {
    LOGS.get_or_init(|| Arc::new(Mutex::new(VecDeque::with_capacity(CAPACITY))))
}

/// Installs the process-wide tracing subscriber once. Returns false if another
/// subscriber already exists (e.g. the headless node binary).
pub fn init() -> bool {
    struct Writer(Buffer);
    impl io::Write for Writer {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            let text = String::from_utf8_lossy(bytes);
            for line in text.lines() {
                let line = line.trim_end();
                if line.is_empty() {
                    continue;
                }
                let line = redact(line);
                if let Ok(mut logs) = self.0.lock() {
                    if logs.len() >= CAPACITY {
                        logs.pop_front();
                    }
                    logs.push_back(line);
                }
            }
            Ok(bytes.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    impl<'a> MakeWriter<'a> for Writer {
        type Writer = Writer;
        fn make_writer(&'a self) -> Self::Writer {
            Writer(self.0.clone())
        }
    }

    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| "info,lekis_library=info,lekis_playback=info,lekis_core=debug".into());
    let subscriber = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(Writer(buffer().clone()))
        .with_ansi(false)
        .finish();
    tracing::subscriber::set_global_default(subscriber).is_ok()
}

/// Last `limit` lines, newest last.
pub fn recent(limit: usize) -> Vec<String> {
    let Ok(logs) = buffer().lock() else {
        return Vec::new();
    };
    logs.iter()
        .skip(logs.len().saturating_sub(limit))
        .cloned()
        .collect()
}

/// Clears the diagnostic ring.
pub fn clear() {
    if let Ok(mut logs) = buffer().lock() {
        logs.clear();
    }
}

/// Keep credentials out of the diagnostic view. This is deliberately simple:
/// it masks the value after common secret keys and bearer tokens.
fn redact(line: &str) -> String {
    let mut out = line.to_string();
    for key in [
        "password=",
        "password:",
        "token=",
        "token:",
        "api_key=",
        "api-key=",
        "authorization:",
        "authorization=",
        "secret=",
    ] {
        let lower = out.to_lowercase();
        let mut search = 0;
        while let Some(pos) = lower[search..].find(key) {
            let start = search + pos + key.len();
            let end = out[start..]
                .find(|c: char| c.is_whitespace() || c == '&' || c == ',' || c == '"')
                .map_or(out.len(), |n| start + n);
            out.replace_range(start..end, "***");
            search = start + 3;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ring_is_bounded_and_redacts() {
        let buf = buffer();
        {
            let mut logs = buf.lock().unwrap();
            logs.clear();
            for i in 0..(CAPACITY + 10) {
                logs.push_back(format!("{i} token=abc password:xyz"));
            }
        }
        assert_eq!(recent(CAPACITY).len(), CAPACITY);
        let redacted = redact("request token=abc password:xyz authorization: Bearer x");
        assert!(redacted.contains("token=***"));
        assert!(redacted.contains("password:***"));
        assert!(redacted.contains("authorization:***"));
        clear();
    }
}
