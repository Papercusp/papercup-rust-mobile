// SPDX-License-Identifier: GPL-3.0-or-later
//
// WI-4966 (iOS half): user-visible failure states must be comprehensible
// and recoverable — never raw UniFFI enum dumps / reqwest transport text.
// Every view that renders an error string routes it through here; the
// raw detail is logged (not shown) so Diagnostics-style debugging still
// has it in the console.

import Foundation
import PapercupCore

enum FriendlyError {
    /// A friendly, actionable one-liner for any error the UniFFI client
    /// (or anything else) throws. `doing` names the user's action in
    /// gerund form, e.g. "loading the conversation", "sending your
    /// message"; it is woven into the copy when present.
    static func message(_ error: Error, doing what: String = "") -> String {
        let suffix = what.isEmpty ? "" : " while \(what)"
        logRawDetail(error, doing: what)
        if isCloudWorkspaceOffline(error) {
            return "Your cloud workspace is offline\(suffix). It may be stopped or still starting — the app reconnects on its own when it's back, or try again in about 30 seconds."
        }
        if let code = relayRefusalCode(error) {
            return "Your cloud workspace's relay refused this request\(suffix) (\(code)). Your pairing is still valid — if this keeps happening, update the app."
        }
        if isRateLimited(error) {
            return "Your workspace is receiving too many requests\(suffix). Wait a few seconds and try again."
        }
        if isPayloadTooLarge(error) {
            return "That was too large to send\(suffix). Try a shorter message or a smaller attachment."
        }
        switch error {
        case let api as ApiError:
            switch api {
            case .Network:
                return "Can't reach your desktop\(suffix). Check that it's online and on the same network, then try again."
            case .Server(let status, _):
                return "Your desktop hit an error\(suffix) (HTTP \(status)). Give it a moment and try again."
            case .Decode:
                return "Unexpected reply from your desktop\(suffix) — it may be mid-update. Try again shortly."
            case .Unauthorized:
                return "This device is no longer paired with your desktop. Re-pair from Settings."
            }
        case let pair as PairError:
            switch pair {
            case .InvalidQr:
                return "That pairing code didn't scan as valid. Get a fresh QR from your desktop and try again."
            case .Network:
                return "Can't reach the desktop at that address. Check the server address and that your desktop is online, then try again."
            case .Server(let status, _):
                return "The desktop refused the pairing (HTTP \(status)). Mint a fresh pairing code and try again."
            case .Decode:
                return "Unexpected pairing reply — your desktop may be mid-update. Try again shortly."
            case .Unauthorized:
                return "That pairing code was already used or expired. Mint a fresh one from your desktop."
            }
        case let voice as VoiceError:
            switch voice {
            case .Connect:
                return "Couldn't open the voice connection\(suffix). Check that your desktop is reachable, then try again."
            case .Closed:
                return "The voice connection dropped\(suffix). Tap to try again."
            default:
                return "Voice hit a problem\(suffix). Try again — if it keeps failing, check Settings → Diagnostics."
            }
        default:
            // Unknown error class: stay friendly, keep a short bounded
            // hint so support screenshots aren't a dead end.
            let detail = compactDetail(error)
            return "Something went wrong\(suffix). Try again — if it keeps happening: \(detail)"
        }
    }

    /// BYOC cloud workspaces (iphone#D-014, P-015): when the workspace's
    /// connector is down, the hosted relay refuses at once with HTTP 503
    /// and body `{"error":"workspace_offline"}` (Retry-After: 30; see
    /// papercusp hosted-app-relay.ts). The native client surfaces that as
    /// `ApiError.Server(503, "workspace_offline…")` — the flat code, plus
    /// any hint/detail the relay appends. It is reachability, never
    /// authorization, so the stored pairing stays valid.
    static func isCloudWorkspaceOffline(_ error: Error) -> Bool {
        guard let api = error as? ApiError, case let .Server(status, detail) = api else { return false }
        return status == 503 && detail.hasPrefix("workspace_offline")
    }

    /// Cloud relay POLICY refusals (android#D-013). The shared core surfaces
    /// them as `ApiError.Server(status, "relay_refused: <code>")`, e.g.
    /// `byoc_plaintext_relay_refused` or `route_not_relayed`. Waiting does
    /// not help and the pairing stays valid, so the copy must say neither
    /// "give it a moment" nor "re-pair". Returns the relay's code, bounded.
    static func relayRefusalCode(_ error: Error) -> String? {
        guard let api = error as? ApiError, case let .Server(_, detail) = api,
              detail.hasPrefix("relay_refused:") else { return nil }
        let code = detail.dropFirst("relay_refused:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? "relay_refused" : String(code.prefix(60))
    }

    /// `429` from the relay or desktop, surfaced as `Server(429, "rate_limited…")`.
    static func isRateLimited(_ error: Error) -> Bool {
        guard let api = error as? ApiError, case let .Server(status, detail) = api else { return false }
        return status == 429 && detail.hasPrefix("rate_limited")
    }

    /// `413` relay frame cap, surfaced as `Server(413, "request_body_too_large: …")`.
    static func isPayloadTooLarge(_ error: Error) -> Bool {
        guard let api = error as? ApiError, case let .Server(status, detail) = api else { return false }
        return status == 413 && detail.hasPrefix("request_body_too_large")
    }

    /// Bounded, single-line detail for genuinely unknown errors.
    static func compactDetail(_ error: Error, cap: Int = 120) -> String {
        var text = String(describing: error)
            .replacingOccurrences(of: "\n", with: " ")
        if text.count > cap {
            text = String(text.prefix(cap)) + "…"
        }
        return text
    }

    private static func logRawDetail(_ error: Error, doing what: String) {
        #if DEBUG
        print("[FriendlyError] \(what.isEmpty ? "error" : what): \(String(describing: error))")
        #endif
    }
}
