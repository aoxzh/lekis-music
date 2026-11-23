use crate::migrations;
use crate::normalize::norm_key;
use lekis_types::{ErrorCode, LekisError, Result};
use rusqlite::functions::FunctionFlags;
use rusqlite::{Connection, OpenFlags};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};

/// 只读连接数量。
const READER_COUNT: usize = 4;

type WriteJob = Box<dyn FnOnce(&mut Connection) + Send>;

/// 把 rusqlite 的错误转成 [`LekisError`]。
///
/// （孤儿规则不允许在这里给 `LekisError` 实现 `From<rusqlite::Error>`，所以用扩展 trait。）
pub trait DbResultExt<T> {
    /// 转换错误。
    fn db(self) -> Result<T>;
}

impl<T> DbResultExt<T> for rusqlite::Result<T> {
    fn db(self) -> Result<T> {
        self.map_err(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => LekisError::not_found("row not found"),
            other => LekisError::new(ErrorCode::Database, other.to_string()),
        })
    }
}

/// 资料库句柄。可以廉价地克隆，在多个任务之间共享。
#[derive(Clone)]
pub struct Library {
    inner: Arc<Inner>,
}

struct Inner {
    writer: mpsc::Sender<WriteJob>,
    readers: Vec<Mutex<Connection>>,
    next_reader: AtomicUsize,
}

fn configure(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA synchronous = NORMAL;
         PRAGMA foreign_keys = ON;
         PRAGMA busy_timeout = 5000;
         PRAGMA temp_store = MEMORY;
         -- Large scans write in 500-track transactions. Fewer, larger WAL
         -- checkpoints and a bounded WAL keep fsync work down without letting
         -- the sidecar files grow without limit.
         PRAGMA wal_autocheckpoint = 2000;
         PRAGMA journal_size_limit = 33554432;
         -- 100k-track libraries: keep the hot pages in memory instead of
         -- re-reading the B-trees for every list / search page. 8 MiB per
         -- connection keeps the five-connection pool bounded on phones.
         PRAGMA cache_size = -8192;
         PRAGMA mmap_size = 67108864;",
    )
    .db()?;
    register_functions(conn)
}

/// 注册只在 SQL 里用到的 Rust 函数。
///
/// 去重 / 健康报告在 SQL 里按规范化标题、艺人、专辑聚合。SQLite 本身不认简繁和
/// Unicode 大小写，所以把 [`norm_key`] 注册成标量函数，避免把十万行拉到内存里。
/// 只读连接也要注册，否则同一个查询在写线程上能跑、在查询线程上报 "no such function"。
fn register_functions(conn: &Connection) -> Result<()> {
    conn.create_scalar_function(
        "lekis_norm",
        1,
        FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_DETERMINISTIC,
        |ctx| {
            let value: Option<String> = ctx.get(0)?;
            Ok(value.map(|s| norm_key(&s)).unwrap_or_default())
        },
    )
    .db()
}

impl Library {
    /// 打开（不存在就创建）数据库，并执行迁移。
    pub fn open(path: &Path) -> Result<Self> {
        let mut writer = Connection::open(path).db()?;
        configure(&writer)?;
        let migrated = migrations::run(&mut writer)?;
        if migrated {
            // Refresh planner statistics only after this launch actually changed
            // the schema. Running ANALYZE on every open added startup work even
            // when the database was already up to date.
            writer.execute_batch("PRAGMA optimize;").db()?;
        }

        let readers = (0..READER_COUNT)
            .map(|_| {
                let conn = Connection::open_with_flags(
                    path,
                    OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
                )
                .db()?;
                conn.execute_batch(
                    "PRAGMA busy_timeout = 5000;
                     PRAGMA query_only = ON;
                     PRAGMA cache_size = -8192;
                     PRAGMA mmap_size = 67108864;",
                )
                .db()?;
                register_functions(&conn)?;
                Ok(Mutex::new(conn))
            })
            .collect::<Result<Vec<_>>>()?;

        let (tx, rx) = mpsc::channel::<WriteJob>();
        std::thread::Builder::new()
            .name("lekis-db-writer".into())
            .spawn(move || {
                let mut conn = writer;
                for job in rx {
                    job(&mut conn);
                }
                tracing::debug!(target: "library", "writer thread exiting");
            })?;

        Ok(Self {
            inner: Arc::new(Inner {
                writer: tx,
                readers,
                next_reader: AtomicUsize::new(0),
            }),
        })
    }

    /// 在写线程上执行 `f`。需要事务时在 `f` 里自己开 `conn.transaction()`。
    pub async fn write<F, R>(&self, f: F) -> Result<R>
    where
        F: FnOnce(&mut Connection) -> Result<R> + Send + 'static,
        R: Send + 'static,
    {
        let (tx, rx) = tokio::sync::oneshot::channel();
        let job: WriteJob = Box::new(move |conn| {
            let _ = tx.send(f(conn));
        });
        self.inner
            .writer
            .send(job)
            .map_err(|_| LekisError::new(ErrorCode::Database, "database writer has stopped"))?;
        rx.await
            .map_err(|_| LekisError::new(ErrorCode::Database, "database writer dropped the job"))?
    }

    /// 在只读连接上执行查询。
    pub async fn read<F, R>(&self, f: F) -> Result<R>
    where
        F: FnOnce(&Connection) -> Result<R> + Send + 'static,
        R: Send + 'static,
    {
        let inner = self.inner.clone();
        tokio::task::spawn_blocking(move || {
            let idx = inner.next_reader.fetch_add(1, Ordering::Relaxed) % inner.readers.len();
            let conn = inner.readers[idx]
                .lock()
                .map_err(|_| LekisError::internal("reader connection mutex poisoned"))?;
            f(&conn)
        })
        .await
        .map_err(|e| LekisError::internal(format!("reader task failed: {e}")))?
    }
}

#[cfg(test)]
pub(crate) mod test_util {
    use super::*;

    /// 在临时目录创建一个新数据库。
    pub fn temp_library(name: &str) -> Result<Library> {
        let dir =
            std::env::temp_dir().join(format!("lekis-library-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir)?;
        Library::open(&dir.join("library.sqlite"))
    }
}

#[cfg(test)]
mod tests {
    use super::test_util::temp_library;
    use super::*;

    #[tokio::test]
    async fn migrations_apply_and_reads_work() -> Result<()> {
        let lib = temp_library("migrate")?;
        let n: i64 = lib
            .read(|c| {
                c.query_row("SELECT COUNT(*) FROM track", [], |r| r.get(0))
                    .db()
            })
            .await?;
        assert_eq!(n, 0);
        Ok(())
    }
}
