// SPDX-License-Identifier: GPL-3.0-or-later
//
// In-memory query cache with subscriber callback + change-detecting
// polling.
//
// The server's SSE invalidation stream is gone (mobile-apps-revival
// D-001.1); the replacement transport is polling `GET
// /api/device/rest-query` (libs/sync's polling-fetcher design — push
// notifications cover interrupt latency, D-004). The cache owns that
// loop: `start_polling(interval)` refetches every registered query and
// notifies subscribers ONLY when the payload actually changed (the
// rest-query `version` field is a timestamp, useless for diffing — we
// diff the raw JSON instead). `refresh()` keeps always-notify semantics
// for explicit pull-to-refresh.
//
// Implementation choice: the cache stores raw JSON bytes (already
// what the wire protocol speaks) so it's UI-agnostic. Refreshes run
// through the pluggable `Fetcher` (the bindings layer maps query names
// onto `OperatorClient` calls).

use std::collections::{HashMap, HashSet};
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
    /// Names whose most recent poll tick failed — `Failed` is emitted on
    /// the success→failure transition only, not every tick offline.
    poll_failed: Mutex<HashSet<String>>,
    poll_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl Drop for CacheInner {
    fn drop(&mut self) {
        if let Some(t) = self.poll_task.lock().unwrap().take() {
            t.abort();
        }
    }
}

impl Cache {
    pub fn new(fetcher: Arc<dyn Fetcher>) -> Self {
        let (tx, _rx) = broadcast::channel::<CacheUpdate>(64);
        Self {
            inner: Arc::new(CacheInner {
                entries: Mutex::new(HashMap::new()),
                fetcher,
                tx,
                poll_failed: Mutex::new(HashSet::new()),
                poll_task: Mutex::new(None),
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

    /// Refresh the named query if it's in the cache (otherwise no-op).
    /// Kept for host-triggered invalidations (e.g. a push notification
    /// naming a changed surface).
    pub async fn handle_invalidate(&self, name: &str) {
        let known = self.inner.entries.lock().unwrap().contains_key(name);
        if known {
            self.refresh(name).await;
        }
    }

    /// Register a query name without fetching it yet — the polling loop
    /// (or an explicit `refresh`) picks it up.
    pub fn register(&self, name: &str) {
        self.inner
            .entries
            .lock()
            .unwrap()
            .entry(name.to_string())
            .or_insert(CacheEntry {
                name: name.to_string(),
                value_json: None,
                generation: 0,
            });
    }

    /// Start the polling loop: every `interval`, refetch every registered
    /// query and notify subscribers ONLY on actual payload change (or on
    /// the success→failure transition). Replaces the retired SSE
    /// invalidation stream. Idempotent — restarting replaces the loop.
    pub fn start_polling(&self, interval: std::time::Duration) {
        let weak = Arc::downgrade(&self.inner);
        let task = tokio::spawn(async move {
            loop {
                tokio::time::sleep(interval).await;
                let Some(inner) = weak.upgrade() else { break };
                let names: Vec<String> = inner.entries.lock().unwrap().keys().cloned().collect();
                for name in names {
                    let result = inner.fetcher.fetch(&name).await;
                    match result {
                        Ok(json) => {
                            inner.poll_failed.lock().unwrap().remove(&name);
                            let update = {
                                let mut entries = inner.entries.lock().unwrap();
                                let entry = entries.entry(name.clone()).or_insert(CacheEntry {
                                    name: name.clone(),
                                    value_json: None,
                                    generation: 0,
                                });
                                if entry.value_json.as_deref() == Some(json.as_str()) {
                                    None // unchanged — stay quiet
                                } else {
                                    entry.value_json = Some(json.clone());
                                    entry.generation += 1;
                                    Some(CacheUpdate::Updated {
                                        name: name.clone(),
                                        value_json: json,
                                        generation: entry.generation,
                                    })
                                }
                            };
                            if let Some(u) = update {
                                let _ = inner.tx.send(u);
                            }
                        }
                        Err(e) => {
                            // Emit Failed once per outage, not per tick.
                            let first_failure =
                                inner.poll_failed.lock().unwrap().insert(name.clone());
                            if first_failure {
                                let _ = inner.tx.send(CacheUpdate::Failed {
                                    name: name.clone(),
                                    error: e,
                                });
                            }
                        }
                    }
                }
            }
        });
        let mut guard = self.inner.poll_task.lock().unwrap();
        if let Some(old) = guard.replace(task) {
            old.abort();
        }
    }

    /// Stop the polling loop (no-op when not polling).
    pub fn stop_polling(&self) {
        if let Some(t) = self.inner.poll_task.lock().unwrap().take() {
            t.abort();
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
            let mut responses = self.responses.lock().unwrap();
            if responses.len() > 1 {
                responses.remove(0)
            } else {
                // Repeat the final response — polling tests tick an
                // unpredictable number of times.
                responses[0].clone()
            }
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
    async fn polling_emits_only_on_change() {
        // Three poll ticks return: same value, same value, new value.
        // Subscriber must see exactly ONE update for the first value
        // (via explicit refresh) and one for the change — silent ticks
        // in between.
        let f = StubFetcher::new(vec![
            Ok(r#"{"v":1}"#.into()), // initial refresh → Updated (gen 1)
            Ok(r#"{"v":1}"#.into()), // poll: unchanged → quiet
            Ok(r#"{"v":2}"#.into()), // poll: changed → Updated (gen 2)
                                     // repeats {"v":2} → quiet
        ]);
        let cache = Cache::new(f.clone());
        let collected = Arc::new(Mutex::new(Vec::new()));
        let _sub = cache.subscribe(Arc::new(CollectSubscriber(collected.clone())));
        cache.refresh("k").await; // generation 1, Updated
        cache.start_polling(std::time::Duration::from_millis(20));
        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        cache.stop_polling();
        let got = collected.lock().unwrap().clone();
        let updates: Vec<_> = got
            .iter()
            .filter(|u| matches!(u, CacheUpdate::Updated { .. }))
            .collect();
        assert_eq!(updates.len(), 2, "one initial + one change, got {got:?}");
        assert!(
            matches!(updates[1], CacheUpdate::Updated { value_json, .. } if value_json == r#"{"v":2}"#)
        );
    }

    #[tokio::test]
    async fn polling_emits_failed_once_per_outage() {
        let f = StubFetcher::new(vec![
            Ok(r#"1"#.into()),      // initial refresh
            Err("net down".into()), // poll: failure → Failed
            Err("net down".into()), // poll: still down → quiet
            Ok(r#"1"#.into()),      // poll: recovered, unchanged → quiet
            Err("net down".into()), // poll: new outage → Failed again (repeats)
        ]);
        let cache = Cache::new(f.clone());
        let collected = Arc::new(Mutex::new(Vec::new()));
        let _sub = cache.subscribe(Arc::new(CollectSubscriber(collected.clone())));
        cache.refresh("k").await;
        cache.start_polling(std::time::Duration::from_millis(20));
        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        cache.stop_polling();
        let got = collected.lock().unwrap().clone();
        let failures = got
            .iter()
            .filter(|u| matches!(u, CacheUpdate::Failed { .. }))
            .count();
        assert_eq!(failures, 2, "one Failed per outage, got {got:?}");
    }

    #[tokio::test]
    async fn register_makes_name_pollable_without_refresh() {
        let f = StubFetcher::new(vec![Ok(r#"{"a":1}"#.into())]);
        let cache = Cache::new(f.clone());
        cache.register("lazy");
        assert!(cache.get("lazy").unwrap().value_json.is_none());
        cache.start_polling(std::time::Duration::from_millis(10));
        tokio::time::sleep(std::time::Duration::from_millis(120)).await;
        cache.stop_polling();
        assert_eq!(
            cache.get("lazy").unwrap().value_json.as_deref(),
            Some(r#"{"a":1}"#)
        );
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
