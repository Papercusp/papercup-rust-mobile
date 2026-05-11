// SPDX-License-Identifier: GPL-3.0-or-later
//
// Phase 4 — voice intent dispatch.
//
// The voice WS server speaks plain text; the operator may embed an
// inline directive prefix the client should act on locally before
// playing the rest. Tiny, opinionated parser that recognizes:
//
//   "[NAVIGATE: <slug>] <speak text>"     → Intent::Navigate(slug)
//   "[PAUSE] <speak text>"                → Intent::Pause
//   "[RESUME] <speak text>"               → Intent::Resume
//   "[CLAIM_VOICE] <speak text>"          → Intent::ClaimVoice
//   anything else                          → Intent::Speak(text)
//
// The matcher is intentionally narrow: a misformed prefix becomes
// part of the spoken text rather than silently swallowed. Platform
// shells call `parse_intent(text)` on every Speak frame; the host
// code (Compose / SwiftUI) decides whether/how to act on the intent
// (typically navigate to the slug + still speak the remainder).

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Intent {
    Navigate { slug: String, speak: String },
    Pause { speak: String },
    Resume { speak: String },
    ClaimVoice { speak: String },
    Speak { text: String },
}

pub fn parse(raw: &str) -> Intent {
    let trimmed = raw.trim_start();
    if !trimmed.starts_with('[') {
        return Intent::Speak {
            text: raw.to_string(),
        };
    }
    let Some(end) = trimmed.find(']') else {
        return Intent::Speak {
            text: raw.to_string(),
        };
    };
    let directive = &trimmed[1..end];
    let rest = trimmed[end + 1..].trim_start().to_string();
    match directive.split_once(':').map(|(k, v)| (k.trim(), v.trim())) {
        Some(("NAVIGATE", slug)) if !slug.is_empty() => Intent::Navigate {
            slug: slug.to_string(),
            speak: rest,
        },
        _ => match directive.trim() {
            "PAUSE" => Intent::Pause { speak: rest },
            "RESUME" => Intent::Resume { speak: rest },
            "CLAIM_VOICE" => Intent::ClaimVoice { speak: rest },
            _ => Intent::Speak {
                text: raw.to_string(),
            },
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_text_is_speak() {
        assert_eq!(
            parse("hello world"),
            Intent::Speak {
                text: "hello world".into()
            }
        );
    }

    #[test]
    fn navigate_extracts_slug_and_speak_remainder() {
        assert_eq!(
            parse("[NAVIGATE: alpha-1] taking you there"),
            Intent::Navigate {
                slug: "alpha-1".into(),
                speak: "taking you there".into()
            }
        );
    }

    #[test]
    fn navigate_without_slug_falls_through_to_speak() {
        assert_eq!(
            parse("[NAVIGATE: ] uh oh"),
            Intent::Speak {
                text: "[NAVIGATE: ] uh oh".into()
            }
        );
    }

    #[test]
    fn pause_resume_claim_recognised() {
        assert!(matches!(parse("[PAUSE] paused"), Intent::Pause { .. }));
        assert!(matches!(parse("[RESUME] resumed"), Intent::Resume { .. }));
        assert!(matches!(
            parse("[CLAIM_VOICE] hi"),
            Intent::ClaimVoice { .. }
        ));
    }

    #[test]
    fn unknown_bracket_directive_kept_in_speak() {
        assert_eq!(
            parse("[FROBNICATE] beep"),
            Intent::Speak {
                text: "[FROBNICATE] beep".into()
            }
        );
    }

    #[test]
    fn missing_close_bracket_is_speak() {
        assert_eq!(
            parse("[NAVIGATE: foo no close"),
            Intent::Speak {
                text: "[NAVIGATE: foo no close".into()
            }
        );
    }

    #[test]
    fn leading_whitespace_tolerated() {
        assert_eq!(
            parse("  [PAUSE] all stop"),
            Intent::Pause {
                speak: "all stop".into()
            }
        );
    }
}
