// SPDX-License-Identifier: GPL-3.0-or-later
//
// Phase 8 — biometric gating.
//
// `BiometricPrompt` is a UniFFI callback interface implemented by the
// platform shell (Android: BiometricPrompt; iOS: LAContext). Rust core
// decides which actions need a biometric check based on a RiskLevel
// tag and invokes the prompt before the action proceeds.

use std::sync::Arc;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BiometricResult {
    Approved,
    Denied,
    /// Hardware unavailable, no enrolled biometric, or platform error.
    /// String carries a short human-readable reason for logging only.
    Unavailable(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RiskLevel {
    Low,
    Medium,
    High,
}

/// Platform-implemented prompt. Shell shows the OS-native UI and
/// returns the result. Rust core treats `Unavailable` as Denied for
/// High-risk actions and Approved for Low-risk; Medium can be wired
/// to a confirm-button fallback by the host.
#[async_trait::async_trait]
pub trait BiometricPrompt: Send + Sync {
    async fn prompt(&self, reason: String) -> BiometricResult;
}

/// `gate(prompt, risk, reason, body)` — runs `body` iff the prompt
/// resolves Approved. Low risk is auto-approved (no prompt). Medium
/// risk falls back to Approved when the platform reports Unavailable
/// (so non-biometric devices can still act). High risk requires a
/// real Approved.
pub async fn gate<F, Fut, T, E>(
    prompt: Option<Arc<dyn BiometricPrompt>>,
    risk: RiskLevel,
    reason: &str,
    body: F,
) -> Result<T, BiometricGateError<E>>
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = Result<T, E>>,
{
    if matches!(risk, RiskLevel::Low) {
        return body().await.map_err(BiometricGateError::Inner);
    }
    let Some(p) = prompt else {
        return match risk {
            RiskLevel::High => Err(BiometricGateError::Denied),
            _ => body().await.map_err(BiometricGateError::Inner),
        };
    };
    let outcome = p.prompt(reason.to_string()).await;
    match (risk, outcome) {
        (_, BiometricResult::Approved) => body().await.map_err(BiometricGateError::Inner),
        (RiskLevel::High, _) => Err(BiometricGateError::Denied),
        (RiskLevel::Medium, BiometricResult::Unavailable(_)) => {
            body().await.map_err(BiometricGateError::Inner)
        }
        _ => Err(BiometricGateError::Denied),
    }
}

#[derive(Debug, thiserror::Error)]
pub enum BiometricGateError<E> {
    #[error("biometric check denied")]
    Denied,
    #[error(transparent)]
    Inner(E),
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    struct StubPrompt {
        next: Mutex<Vec<BiometricResult>>,
        called_reasons: Mutex<Vec<String>>,
    }
    impl StubPrompt {
        fn new(results: Vec<BiometricResult>) -> Arc<Self> {
            Arc::new(Self {
                next: Mutex::new(results),
                called_reasons: Mutex::new(Vec::new()),
            })
        }
    }
    #[async_trait::async_trait]
    impl BiometricPrompt for StubPrompt {
        async fn prompt(&self, reason: String) -> BiometricResult {
            self.called_reasons.lock().unwrap().push(reason);
            self.next.lock().unwrap().remove(0)
        }
    }

    #[tokio::test]
    async fn low_risk_skips_prompt() {
        let p = StubPrompt::new(vec![BiometricResult::Denied]);
        let r: Result<i32, BiometricGateError<()>> =
            gate(Some(p.clone() as _), RiskLevel::Low, "x", || async {
                Ok(42)
            })
            .await;
        assert_eq!(r.unwrap(), 42);
        assert!(p.called_reasons.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn high_risk_approved_runs_body() {
        let p = StubPrompt::new(vec![BiometricResult::Approved]);
        let r: Result<i32, BiometricGateError<()>> = gate(
            Some(p.clone() as _),
            RiskLevel::High,
            "revoke device",
            || async { Ok(7) },
        )
        .await;
        assert_eq!(r.unwrap(), 7);
        assert_eq!(p.called_reasons.lock().unwrap()[0], "revoke device");
    }

    #[tokio::test]
    async fn high_risk_denied_blocks_body() {
        let p = StubPrompt::new(vec![BiometricResult::Denied]);
        let mut ran = false;
        let r: Result<(), BiometricGateError<()>> = gate(
            Some(p.clone() as _),
            RiskLevel::High,
            "revoke device",
            || async {
                ran = true;
                Ok(())
            },
        )
        .await;
        assert!(matches!(r, Err(BiometricGateError::Denied)));
        assert!(!ran, "body must not run when denied");
    }

    #[tokio::test]
    async fn medium_risk_unavailable_falls_through() {
        let p = StubPrompt::new(vec![BiometricResult::Unavailable("no hw".into())]);
        let r: Result<i32, BiometricGateError<()>> = gate(
            Some(p.clone() as _),
            RiskLevel::Medium,
            "switch workspace",
            || async { Ok(11) },
        )
        .await;
        assert_eq!(r.unwrap(), 11);
    }

    #[tokio::test]
    async fn high_risk_no_prompt_at_all_denies() {
        let r: Result<(), BiometricGateError<()>> =
            gate(None, RiskLevel::High, "x", || async { Ok(()) }).await;
        assert!(matches!(r, Err(BiometricGateError::Denied)));
    }
}
