//! Live interop: the Rust `ByocSealedChannel` initiator against the REAL papercusp
//! TypeScript `ByocSealedChannel` responder (tests/fixtures/byoc-sealed-responder.mjs
//! loads packages/operator-core/lib/workspace-host/byoc-sealed-channel.ts via tsx).
//! The test itself plays the untrusted control-plane relay: every packet crosses as
//! the JSON shape the relay carries.
//!
//! Needs `node` and a papercusp checkout (with node_modules holding tsx and
//! @hyperswarm/secret-stream). It looks in $PAPERCUP_PAPERCUSP_ROOT, then the sibling
//! papercusp checkout. With neither it prints SKIP; set
//! PAPERCUP_REQUIRE_SECRET_STREAM_INTEROP=1 to fail instead.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

use papercup_core::byoc_sealed::{ByocSealedChannel, ByocSealedPacket};
use papercup_core::noise_stream::Ed25519KeyPair;
use serde_json::{json, Map, Value};

const CHANNEL_TS: &str = "packages/operator-core/lib/workspace-host/byoc-sealed-channel.ts";
const WAIT: Duration = Duration::from_secs(20);

fn to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn from_hex32(text: &str) -> [u8; 32] {
    assert_eq!(text.len(), 64, "expected 32-byte hex key, got {text:?}");
    let mut out = [0u8; 32];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&text[2 * i..2 * i + 2], 16).expect("hex key");
    }
    out
}

fn papercusp_root() -> Option<PathBuf> {
    let candidates = std::env::var_os("PAPERCUP_PAPERCUSP_ROOT")
        .map(PathBuf::from)
        .into_iter()
        .chain(std::iter::once(
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../papercusp"),
        ));
    candidates.into_iter().find(|dir| {
        dir.join(CHANNEL_TS).is_file()
            && dir.join("node_modules/tsx/package.json").is_file()
            && dir
                .join("node_modules/@hyperswarm/secret-stream/package.json")
                .is_file()
    })
}

struct Responder {
    child: Child,
    stdin: Option<ChildStdin>,
    events: Receiver<Value>,
    public_key: [u8; 32],
}

impl Drop for Responder {
    fn drop(&mut self) {
        drop(self.stdin.take());
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Responder {
    fn relay(&mut self, packet: &ByocSealedPacket) {
        let line = serde_json::to_string(packet).expect("serialize packet") + "\n";
        let stdin = self.stdin.as_mut().expect("responder stdin");
        stdin.write_all(line.as_bytes()).expect("write packet");
        stdin.flush().expect("flush packet");
    }

    fn next_event(&self, deadline: Instant) -> Option<Value> {
        let left = deadline.saturating_duration_since(Instant::now());
        self.events.recv_timeout(left).ok()
    }
}

fn start_responder(mode: &str, initiator_public: &[u8; 32]) -> Option<Responder> {
    let Some(root) = papercusp_root() else {
        if std::env::var("PAPERCUP_REQUIRE_SECRET_STREAM_INTEROP").as_deref() == Ok("1") {
            panic!("papercusp checkout with tsx + @hyperswarm/secret-stream not found; set PAPERCUP_PAPERCUSP_ROOT");
        }
        eprintln!("SKIP byoc_sealed_interop: no papercusp checkout with tsx + secret-stream");
        return None;
    };
    let fixture =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/byoc-sealed-responder.mjs");
    let mut child = Command::new("node")
        .current_dir(&root)
        .arg("--import")
        .arg("tsx")
        .arg(&fixture)
        .arg(root.join(CHANNEL_TS))
        .arg(mode)
        .arg(to_hex(initiator_public))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn node responder");
    let stdout = child.stdout.take().expect("responder stdout");
    let (tx, events) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else { break };
            let Ok(value) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if tx.send(value).is_err() {
                break;
            }
        }
    });
    let stdin = child.stdin.take();
    let mut responder = Responder {
        child,
        stdin,
        events,
        public_key: [0; 32],
    };
    let ready = responder
        .next_event(Instant::now() + WAIT)
        .expect("responder printed no ready line");
    assert_eq!(ready["event"], "ready", "first responder event: {ready}");
    responder.public_key = from_hex32(ready["publicKey"].as_str().expect("publicKey"));
    Some(responder)
}

fn frame(value: Value) -> Map<String, Value> {
    match value {
        Value::Object(map) => map,
        other => panic!("not an object frame: {other}"),
    }
}

/// What the relay saw from the TS side while pumping until `done` or the deadline.
#[derive(Default)]
struct Observed {
    rust_frames: Vec<Map<String, Value>>,
    ts_frames: Vec<Value>,
    ts_errors: Vec<String>,
    ts_open: bool,
    rust_error: Option<String>,
}

/// Pump TS packets into the Rust channel (and Rust replies back) until `done`.
fn pump(
    responder: &mut Responder,
    channel: &mut ByocSealedChannel,
    seen: &mut Observed,
    done: impl Fn(&Observed, &ByocSealedChannel) -> bool,
) {
    let deadline = Instant::now() + WAIT;
    while !done(seen, channel) {
        let Some(event) = responder.next_event(deadline) else {
            return;
        };
        match event["event"].as_str() {
            Some("packet") => {
                let packet: ByocSealedPacket =
                    serde_json::from_value(event["packet"].clone()).expect("relay packet shape");
                match channel.receive(&packet) {
                    Ok(progress) => {
                        for out in &progress.outbound {
                            responder.relay(out);
                        }
                        seen.rust_frames.extend(progress.frames);
                    }
                    Err(error) => {
                        seen.rust_error = Some(error.to_string());
                        return;
                    }
                }
            }
            Some("open") => seen.ts_open = true,
            Some("frame") => seen.ts_frames.push(event["frame"].clone()),
            Some("error") => seen
                .ts_errors
                .push(event["message"].as_str().unwrap_or_default().to_owned()),
            _ => {}
        }
    }
}

#[test]
fn rust_initiator_round_trips_frames_with_real_ts_channel() {
    let local = Ed25519KeyPair::from_seed(&[3; 32]);
    let initiator_public = local.public_key();
    let Some(mut responder) = start_responder("accept", &initiator_public) else {
        return;
    };
    let (mut channel, first) =
        ByocSealedChannel::start(local, responder.public_key).expect("start channel");
    assert_eq!(first.content_type, None, "handshake packets carry no type");
    responder.relay(&first);

    let mut seen = Observed::default();
    pump(&mut responder, &mut channel, &mut seen, |s, c| {
        c.is_open() && s.ts_open && !s.rust_frames.is_empty()
    });
    assert!(seen.ts_errors.is_empty(), "TS errors: {:?}", seen.ts_errors);
    assert_eq!(seen.rust_error, None);
    assert!(channel.is_open() && seen.ts_open, "both sides open");
    assert_eq!(channel.remote_public_key(), Some(responder.public_key));
    assert_eq!(
        Value::Object(seen.rust_frames[0].clone()),
        json!({ "type": "hello", "from": "ts-responder" }),
        "TS -> Rust frame decrypted",
    );

    let sent = frame(json!({ "type": "chat.send", "text": "hi from rust", "n": 7 }));
    let packets = channel.send(&sent).expect("send frame");
    assert!(!packets.is_empty());
    for packet in &packets {
        assert_eq!(packet.content_type.as_deref(), Some("chat.send"));
        responder.relay(packet);
    }
    pump(&mut responder, &mut channel, &mut seen, |s, _| {
        s.rust_frames.len() >= 2
    });
    assert!(seen.ts_errors.is_empty(), "TS errors: {:?}", seen.ts_errors);
    assert_eq!(
        seen.ts_frames,
        vec![Value::Object(sent.clone())],
        "Rust -> TS frame decrypted"
    );
    assert_eq!(
        Value::Object(seen.rust_frames[1].clone()),
        json!({ "type": "chat.send", "echo": Value::Object(sent) }),
        "TS echo decrypted under the same label",
    );
}

#[test]
fn ts_responder_refusing_the_initiator_key_never_opens() {
    let local = Ed25519KeyPair::from_seed(&[4; 32]);
    let initiator_public = local.public_key();
    let Some(mut responder) = start_responder("refuse", &initiator_public) else {
        return;
    };
    let (mut channel, first) =
        ByocSealedChannel::start(local, responder.public_key).expect("start channel");
    responder.relay(&first);

    let mut seen = Observed::default();
    pump(&mut responder, &mut channel, &mut seen, |s, _| {
        !s.ts_errors.is_empty() || s.rust_error.is_some()
    });
    assert!(
        !seen.ts_errors.is_empty(),
        "TS responder must fail a refused initiator key"
    );
    assert!(
        !seen.ts_open,
        "refused channel must not open on the TS side"
    );
    // Noise completion on the initiator proves the responder's pinned identity,
    // not the responder's authorization of this phone. That asynchronous check
    // is responder-local: it must never open or deliver frames on refusal, even
    // if the initiator has already finished its cryptographic handshake.
    assert!(seen.rust_frames.is_empty() && seen.ts_frames.is_empty());
}

#[test]
fn relay_relabelling_a_rust_frame_is_terminal_on_the_ts_side() {
    let local = Ed25519KeyPair::from_seed(&[5; 32]);
    let initiator_public = local.public_key();
    let Some(mut responder) = start_responder("accept", &initiator_public) else {
        return;
    };
    let (mut channel, first) =
        ByocSealedChannel::start(local, responder.public_key).expect("start channel");
    responder.relay(&first);
    let mut seen = Observed::default();
    pump(&mut responder, &mut channel, &mut seen, |s, c| {
        c.is_open() && s.ts_open
    });
    assert!(channel.is_open() && seen.ts_open);

    let packets = channel
        .send(&frame(json!({ "type": "chat.send", "text": "x" })))
        .expect("send frame");
    for mut packet in packets {
        // A hostile relay relabels the ciphertext into another allowlisted operation.
        packet.content_type = Some("workspace.delete".to_owned());
        responder.relay(&packet);
    }
    pump(&mut responder, &mut channel, &mut seen, |s, _| {
        !s.ts_errors.is_empty()
    });
    assert!(
        !seen.ts_errors.is_empty(),
        "TS must fail a frame whose decrypted type differs from its relay label"
    );
    assert!(
        seen.ts_frames.is_empty(),
        "relabelled frame must not be delivered"
    );
}
