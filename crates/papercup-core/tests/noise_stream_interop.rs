//! Live interop: the Rust initiator talks to a real @hyperswarm/secret-stream responder
//! (tests/fixtures/secret-stream-echo.cjs) over TCP, in both directions.
//!
//! Needs `node` and a node_modules containing @hyperswarm/secret-stream. It looks in
//! $PAPERCUP_SECRET_STREAM_NODE_PATH, then the sibling papercusp checkout. With neither
//! present it prints SKIP; set PAPERCUP_REQUIRE_SECRET_STREAM_INTEROP=1 to fail instead.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

use papercup_core::noise_stream::{Ed25519KeyPair, NoiseStreamError, SecretStreamInitiator};

fn node_path() -> Option<PathBuf> {
    let candidates = std::env::var_os("PAPERCUP_SECRET_STREAM_NODE_PATH")
        .map(PathBuf::from)
        .into_iter()
        .chain(std::iter::once(
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../papercusp/node_modules"),
        ));
    candidates
        .into_iter()
        .find(|dir| dir.join("@hyperswarm/secret-stream/package.json").is_file())
}

struct Responder {
    child: std::process::Child,
    port: u16,
    public_key: [u8; 32],
}

impl Drop for Responder {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn start_responder() -> Option<Responder> {
    let Some(modules) = node_path() else {
        if std::env::var("PAPERCUP_REQUIRE_SECRET_STREAM_INTEROP").as_deref() == Ok("1") {
            panic!("@hyperswarm/secret-stream not found; set PAPERCUP_SECRET_STREAM_NODE_PATH");
        }
        eprintln!("SKIP noise_stream_interop: no node_modules with @hyperswarm/secret-stream");
        return None;
    };
    let script =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/secret-stream-echo.cjs");
    let mut child = Command::new("node")
        .arg(script)
        .env("NODE_PATH", modules)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn node");
    let mut line = String::new();
    BufReader::new(child.stdout.take().unwrap())
        .read_line(&mut line)
        .unwrap();
    let info: serde_json::Value = serde_json::from_str(&line).expect("responder announce line");
    let hex = info["publicKey"].as_str().unwrap();
    let public_key: Vec<u8> = (0..64)
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
        .collect();
    Some(Responder {
        child,
        port: info["port"].as_u64().unwrap() as u16,
        public_key: public_key.try_into().unwrap(),
    })
}

/// Read from the socket until `want` application messages arrived.
fn pump(sock: &mut TcpStream, session: &mut SecretStreamInitiator, want: usize) -> Vec<Vec<u8>> {
    let mut messages = Vec::new();
    let mut buf = vec![0u8; 64 * 1024];
    while messages.len() < want {
        let n = sock.read(&mut buf).expect("read from responder");
        assert!(n > 0, "responder closed the connection");
        let progress = session.receive(&buf[..n]).expect("receive");
        for chunk in progress.outbound {
            sock.write_all(&chunk).unwrap();
        }
        messages.extend(progress.messages);
    }
    messages
}

#[test]
fn rust_initiator_interoperates_with_real_secret_stream() {
    let Some(responder) = start_responder() else {
        return;
    };
    let mut sock = TcpStream::connect(("127.0.0.1", responder.port)).unwrap();
    sock.set_read_timeout(Some(Duration::from_secs(15)))
        .unwrap();

    let (mut session, first) =
        SecretStreamInitiator::start(Ed25519KeyPair::generate(), Some(responder.public_key))
            .unwrap();
    sock.write_all(&first).unwrap();

    // Handshake completes, the responder's header arrives, then its greeting.
    let greeting = pump(&mut sock, &mut session, 1);
    assert_eq!(greeting, vec![b"hello-from-responder".to_vec()]);
    assert_eq!(session.remote_public_key(), Some(responder.public_key));

    // Small and large messages, both directions. 200 KB spans many TCP reads.
    let large: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
    for msg in [b"{\"type\":\"device.pair\"}\n".to_vec(), large] {
        sock.write_all(&session.encrypt(&msg).unwrap()).unwrap();
        let echoed = pump(&mut sock, &mut session, 1);
        let mut expected = b"echo:".to_vec();
        expected.extend(&msg);
        assert_eq!(echoed, vec![expected]);
    }
}

#[test]
fn pinning_the_wrong_responder_key_fails_against_real_secret_stream() {
    let Some(responder) = start_responder() else {
        return;
    };
    let mut sock = TcpStream::connect(("127.0.0.1", responder.port)).unwrap();
    sock.set_read_timeout(Some(Duration::from_secs(15)))
        .unwrap();
    let wrong = Ed25519KeyPair::from_seed(&[8u8; 32]).public_key();
    let (mut session, first) =
        SecretStreamInitiator::start(Ed25519KeyPair::generate(), Some(wrong)).unwrap();
    sock.write_all(&first).unwrap();
    let mut buf = vec![0u8; 4096];
    loop {
        let n = sock.read(&mut buf).unwrap();
        assert!(n > 0, "responder closed before message 2");
        match session.receive(&buf[..n]) {
            Ok(p) if p.outbound.is_empty() => continue,
            Ok(_) => panic!("handshake completed despite a pinned-key mismatch"),
            Err(e) => {
                assert_eq!(e, NoiseStreamError::RemoteKeyMismatch);
                break;
            }
        }
    }
}
