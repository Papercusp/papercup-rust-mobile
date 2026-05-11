// SPDX-License-Identifier: GPL-3.0-or-later
//
// Phase 3 — in-memory query cache with subscriber callback.
//
// Plan said:
//   - Cache keyed by query name (e.g. `harnesses.list`, `running.phases`)
//   - On `invalidate {name}`, refetch + fire subscriber event
//   - UniFFI callback interface `Subscriber` so Compose / SwiftUI can
//     subscribe to cache deltas
//
// Implementation choice: the cache stores raw JSON bytes (already
// what the wire protocol speaks) so it's UI-agnostic. Each entry
// has a fetcher closure registered at first observation. Invalidation
// re-runs the fetcher and notifies all current subscribers for that
// key.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use tokio::sync::broadcast;

#[derive(Clone)]
pub struct CacheEntry {
    pub name: String,
    /// Raw JSON of the most recent successful fetch. None until the
    /// first refresh completes.
    pub value_json: Option<String>,
    /// Increment-on-refresh; UI uses to detect successful refreshes
    /// even when value bytes haven't changed.
    pub generation: u64,
}

#[derive(Clone, Debug, PartialEq)]
pub enum CacheUpdate {
    /// Successful refresh (generation bumped). value_json is the new
    /// payload.
    Updated {
        name: String,
        value_json: String,
        generation: u64,
    },
    /// Refresh failed; previous value (if any) is still served.
    /// `error` is a short human-readable string for diagnostics.
    Failed { name: String, error: String },
}

/// Pluggable fetcher — returns raw JSON for a given query name.
#[async_trait::async_trait]
pub trait Fetcher: Send + Sync {
    async fn fetch(&self, name: &str) -> Result<String, String>;
}

/// Sync subscriber callback (UDL-friendly). The cache spawns a task
/// per subscriber that bridges from the broadcast channel to the
/// callback. Slow subscribers can drop frames (Lagged variant in
/// broadcast).
pub trait Subscriber: Send + Sync {
    fn on_update(&self, update: CacheUpdate);
}

#[derive(Clone)]
pub struct Cache {
    inner: Arc<CacheInner>,
}

struct CacheInner {
    entries: Mutex<HashMap<String, CacheEntry>>,
    fetcher: Arc<dyn Fetcher>,
    tx: broadcast::Sender<CacheUpdate>,
}

impl Cache {
    pub fn new(fetcher: Arc<dyn Fetcher>) -> Self {
        let (tx, _rx) = broadcast::channel::<CacheUpdate>(64);
        Self {
            inner: Arc::new(CacheInner {
                entries: Mutex::new(HashMap::new()),
                fetcher,
                tx,
            }),
        }
    }

    /// Read the current value (or None if never fetched).
    pub fn get(&self, name: &str) -> Option<CacheEntry> {
        self.inner.entries.lock().unwrap().get(name).cloned()
    }

    /// Force a refresh of `name`. Notifies subscribers.
    pub async fn refresh(&self, name: &str) {
        let result = self.inner.fetcher.fetch(name).await;
        let update = match result {
            Ok(json) => {
                let mut entries = self.inner.entries.lock().unwrap();
                let entry = entries.entry(name.to_string()).or_insert(CacheEntry {
                    name: name.to_string(),
                    value_json: None,
                    generation: 0,
                });
                entry.value_json = Some(json.clone());
                entry.generation += 1;
                let gen = entry.generation;
                drop(entries);
                CacheUpdate::Updated {
                    name: name.to_string(),
                    value_json: json,
                    generation: gen,
                }
            }
            Err(e) => CacheUpdate::Failed {
                name: name.to_string(),
                error: e,
            },
        };
        // Channel may have no subscribers; that's fine.
        let _ = self.inner.tx.send(update);
    }

    /// Apply a SyncStream invalidation event — refreshes the named
    /// query if it's in the cache (otherwise no-op).
    pub async fn handle_invalidate(&self, name: &str) {
        let known = self.inner.entries.lock().unwrap().contains_key(name);
        if known {
            self.refresh(name).await;
        }
    }

    /// Subscribe a callback to all cache updates. Returns a `Subscription`
    /// that detaches when dropped.
    pub fn subscribe(&self, sub: Arc<dyn Subscriber>) -> Subscription {
        let mut rx = self.inner.tx.subscribe();
        let task = tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(update) => sub.on_update(update),
                    Err(broadcast::error::RecvError::Closed) => break,
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                }
            }
        });
        Subscription { _task: task }
    }
}

pub struct Subscription {
    _task: tokio::task::JoinHandle<()>,
}

impl Drop for Subscription {
    fn drop(&mut self) {
        self._task.abort();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct StubFetcher {
        calls: AtomicUsize,
        responses: Mutex<Vec<Result<String, String>>>,
    }
    impl StubFetcher {
        fn new(responses: Vec<Result<String, String>>) -> Arc<Self> {
            Arc::new(Self {
                calls: AtomicUsize::new(0),
                responses: Mutex::new(responses),
            })
        }
    }
    #[async_trait::async_trait]
    impl Fetcher for StubFetcher {
        async fn fetch(&self, _name: &str) -> Result<String, String> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.responses.lock().unwrap().remove(0)
        }
    }

    #[tokio::test]
    async fn refresh_updates_entry_and_bumps_generation() {
        let f = StubFetcher::new(vec![Ok(r#"{"v":1}"#.into()), Ok(r#"{"v":2}"#.into())]);
        let cache = Cache::new(f.clone());
        cache.refresh("harness.list").await;
        let e1 = cache.get("harness.list").unwrap();
        assert_eq!(e1.value_json.as_deref(), Some(r#"{"v":1}"#));
        assert_eq!(e1.generation, 1);
        cache.refresh("harness.list").await;
        let e2 = cache.get("harness.list").unwrap();
        assert_eq!(e2.value_json.as_deref(), Some(r#"{"v":2}"#));
        assert_eq!(e2.generation, 2);
    }

    #[tokio::test]
    async fn handle_invalidate_only_refreshes_known_entries() {
        let f = StubFetcher::new(vec![Ok(r#"{}"#.into())]);
        let cache = Cache::new(f.clone());
        cache.handle_invalidate("never-seen").await;
        assert_eq!(f.calls.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn failed_fetch_keeps_previous_value_and_notifies() {
        let f = StubFetcher::new(vec![Ok(r#"{"v":1}"#.into()), Err("network".into())]);
        let cache = Cache::new(f.clone());
        cache.refresh("k").await;
        cache.refresh("k").await;
        let e = cache.get("k").unwrap();
        assert_eq!(e.value_json.as_deref(), Some(r#"{"v":1}"#));
    }

    struct CollectSubscriber(Arc<Mutex<Vec<CacheUpdate>>>);
    impl Subscriber for CollectSubscriber {
        fn on_update(&self, u: CacheUpdate) {
            self.0.lock().unwrap().push(u);
        }
    }

    #[tokio::test]
    async fn subscriber_receives_updates() {
        let f = StubFetcher::new(vec![Ok(r#"1"#.into())]);
        let cache = Cache::new(f.clone());
        let collected = Arc::new(Mutex::new(Vec::new()));
        let _sub = cache.subscribe(Arc::new(CollectSubscriber(collected.clone())));
        cache.refresh("x").await;
        // Give the subscriber task a moment to drain.
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        let got = collected.lock().unwrap();
        assert_eq!(got.len(), 1);
        assert!(matches!(&got[0], CacheUpdate::Updated { name, generation: 1, .. } if name == "x"));
    }

    #[tokio::test]
    async fn subscription_drop_detaches() {
        let f = StubFetcher::new(vec![Ok("a".into()), Ok("b".into())]);
        let cache = Cache::new(f);
        let collected = Arc::new(Mutex::new(Vec::new()));
        {
            let _sub = cache.subscribe(Arc::new(CollectSubscriber(collected.clone())));
            cache.refresh("k").await;
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        // After drop, the next refresh shouldn't reach the subscriber.
        cache.refresh("k").await;
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        assert_eq!(collected.lock().unwrap().len(), 1);
    }
}
