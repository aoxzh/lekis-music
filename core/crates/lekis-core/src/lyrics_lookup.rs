//! Per-library lyrics request coordination and short-lived negative caching.
use lekis_types::{LekisError, Lyrics, Result, TrackId};
use std::{
    collections::HashMap,
    future::Future,
    sync::{Arc, Mutex, Weak},
    time::{Duration, Instant},
};
use tokio::sync::{Mutex as AsyncMutex, Semaphore};

const NO_RESULT_TTL: Duration = Duration::from_secs(300);
const ERROR_TTL: Duration = Duration::from_secs(30);
const MAX_ENTRIES: usize = 512;

pub(crate) struct LyricsLookup {
    entries: Mutex<HashMap<TrackId, (Instant, Option<LekisError>)>>,
    gates: Mutex<HashMap<TrackId, Weak<AsyncMutex<()>>>>,
    permits: Semaphore,
}
impl Default for LyricsLookup {
    fn default() -> Self {
        Self {
            entries: Mutex::new(HashMap::new()),
            gates: Mutex::new(HashMap::new()),
            permits: Semaphore::new(4),
        }
    }
}
impl LyricsLookup {
    pub(crate) async fn lookup<F, Fut>(
        &self,
        id: TrackId,
        force: bool,
        fetch: F,
    ) -> Result<Option<Lyrics>>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<Option<Lyrics>>>,
    {
        let gate = {
            let mut gates = self
                .gates
                .lock()
                .map_err(|_| LekisError::internal("lyrics request lock poisoned"))?;
            gates.retain(|_, gate| gate.strong_count() > 0);
            gates.entry(id).or_default().upgrade().unwrap_or_else(|| {
                let gate = Arc::new(AsyncMutex::new(()));
                gates.insert(id, Arc::downgrade(&gate));
                gate
            })
        };
        let _track = gate.lock().await;
        if !force {
            let mut entries = self
                .entries
                .lock()
                .map_err(|_| LekisError::internal("lyrics cache lock poisoned"))?;
            let now = Instant::now();
            entries.retain(|_, (until, _)| *until > now);
            if let Some((_, error)) = entries.get(&id) {
                return match error {
                    Some(error) => Err(error.clone()),
                    None => Ok(None),
                };
            }
        }
        let _permit = self
            .permits
            .acquire()
            .await
            .map_err(|_| LekisError::internal("lyrics requests closed"))?;
        let result = fetch().await;
        let mut entries = self
            .entries
            .lock()
            .map_err(|_| LekisError::internal("lyrics cache lock poisoned"))?;
        let now = Instant::now();
        entries.retain(|_, (until, _)| *until > now);
        match &result {
            Ok(Some(_)) => {
                entries.remove(&id);
            }
            result => {
                if entries.len() >= MAX_ENTRIES {
                    if let Some(oldest) = entries
                        .iter()
                        .min_by_key(|(_, (until, _))| *until)
                        .map(|(id, _)| *id)
                    {
                        entries.remove(&oldest);
                    }
                }
                let error = result.as_ref().err().cloned();
                let ttl = if error.is_some() {
                    ERROR_TTL
                } else {
                    NO_RESULT_TTL
                };
                entries.insert(id, (now + ttl, error));
            }
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lekis_types::ErrorCode;
    use std::sync::atomic::{AtomicUsize, Ordering};
    #[tokio::test]
    async fn no_result_error_retry_expiration_and_library_scope() {
        let lookup = LyricsLookup::default();
        let calls = AtomicUsize::new(0);
        for _ in 0..2 {
            assert!(lookup
                .lookup(TrackId(1), false, || async {
                    calls.fetch_add(1, Ordering::SeqCst);
                    Ok(None)
                })
                .await
                .unwrap()
                .is_none());
        }
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        let error = lookup
            .lookup(TrackId(1), true, || async {
                Err(LekisError::new(ErrorCode::Network, "offline"))
            })
            .await
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::Network);
        assert_eq!(
            lookup
                .lookup(TrackId(1), false, || async { panic!("cached error") })
                .await
                .unwrap_err()
                .code,
            ErrorCode::Network
        );
        lookup
            .entries
            .lock()
            .unwrap()
            .get_mut(&TrackId(1))
            .unwrap()
            .0 = Instant::now() - Duration::from_secs(1);
        assert!(lookup
            .lookup(TrackId(1), false, || async { Ok(None) })
            .await
            .is_ok());
        let independent = LyricsLookup::default();
        assert_eq!(
            independent
                .lookup(TrackId(1), false, || async {
                    Err(LekisError::new(ErrorCode::RateLimited, "later"))
                })
                .await
                .unwrap_err()
                .code,
            ErrorCode::RateLimited
        );
    }
    #[tokio::test]
    async fn concurrent_missing_requests_are_deduplicated_and_cache_is_bounded() {
        let lookup = Arc::new(LyricsLookup::default());
        let calls = Arc::new(AtomicUsize::new(0));
        let mut tasks = Vec::new();
        for _ in 0..8 {
            let lookup = lookup.clone();
            let calls = calls.clone();
            tasks.push(tokio::spawn(async move {
                lookup
                    .lookup(TrackId(7), false, || async {
                        calls.fetch_add(1, Ordering::SeqCst);
                        tokio::task::yield_now().await;
                        Ok(None)
                    })
                    .await
                    .unwrap()
            }));
        }
        for task in tasks {
            task.await.unwrap();
        }
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        for id in 0..600 {
            lookup
                .lookup(TrackId(id), false, || async { Ok(None) })
                .await
                .unwrap();
        }
        assert!(lookup.entries.lock().unwrap().len() <= MAX_ENTRIES);
        assert!(lookup.gates.lock().unwrap().len() <= 1);
    }
}
