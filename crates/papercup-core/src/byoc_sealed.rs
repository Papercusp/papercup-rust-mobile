//! BYOC hosted-relay sealed channel — the phone (initiator) side.
//!
//! Wire-compatible with papercusp
//! `packages/operator-core/lib/workspace-host/byoc-sealed-channel.ts`
//! (`ByocSealedChannel`). The control-plane relay carries `ByocSealedPacket`
//! values and never sees a Noise key:
//!
//! - each raw secret-stream chunk travels as ONE packet, `packet` = canonical
//!   standard base64 of the chunk bytes;
//! - handshake chunks (Noise XX messages + the stream-id/header frame) are
//!   labelled `contentType: null`;
//! - an application frame is a JSON object with a non-empty string `type`,
//!   written as `JSON + "\n"` INSIDE the ciphertext, and its packet is labelled
//!   `contentType: <type>` so the relay can enforce channel policy;
//! - on receive, every decrypted frame must carry the same `type` as the label
//!   of the packet that produced it, and a partial line may never continue
//!   under a different label. Any mismatch is terminal, so a relay cannot
//!   relabel ciphertext into another allowlisted operation.
//!
//! Sans-IO: the caller moves `ByocSealedPacket`s over whatever transport it has
//! (the device-http relay, D-013/D-017). WI-10006994 /
//! android-public-release-2026-10-01#D-018.

use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::noise_stream::{Ed25519KeyPair, NoiseStreamError, SecretStreamInitiator};

/// `BYOC_SEALED_PROTOCOL` in byoc-sealed-channel.ts.
pub const BYOC_SEALED_PROTOCOL: &str = "papercusp-byoc-noise-xx.v1";
/// The relay envelope's `type` discriminator.
pub const SEALED_PACKET_TYPE: &str = "sealed.packet";

/// One ordered fragment of the Noise XX + secretstream wire, as relayed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ByocSealedPacket {
    #[serde(rename = "type")]
    pub kind: String,
    pub protocol: String,
    /// The application frame type (relay policy metadata, never content);
    /// `None` (serialized `null`) for handshake fragments.
    pub content_type: Option<String>,
    /// Canonical standard base64 of one raw chunk.
    pub packet: String,
}

impl ByocSealedPacket {
    fn for_chunk(chunk: &[u8], content_type: Option<String>) -> Self {
        Self {
            kind: SEALED_PACKET_TYPE.to_owned(),
            protocol: BYOC_SEALED_PROTOCOL.to_owned(),
            content_type,
            packet: STANDARD.encode(chunk),
        }
    }

    /// True when this is a sealed packet of our protocol (others are ignored,
    /// matching the TS `receive` early return).
    pub fn is_ours(&self) -> bool {
        self.kind == SEALED_PACKET_TYPE && self.protocol == BYOC_SEALED_PROTOCOL
    }
}

/// Errors from the sealed channel. Every error closes the channel.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ByocSealedError {
    #[error(transparent)]
    Noise(#[from] NoiseStreamError),
    #[error("sealed packet must be canonical base64")]
    PacketEncoding,
    #[error("sealed packet content type is invalid")]
    InvalidContentType,
    #[error("sealed frame requires a non-empty type")]
    MissingFrameType,
    #[error("sealed channel content type mismatch")]
    ContentTypeMismatch,
    #[error("sealed channel produced invalid JSON")]
    InvalidJson,
    #[error("BYOC sealed channel is not open yet")]
    NotOpen,
    #[error("BYOC sealed channel is closed")]
    Closed,
}

pub type Result<T> = std::result::Result<T, ByocSealedError>;

/// What one `receive` produced.
#[derive(Debug, Default, PartialEq)]
pub struct SealedProgress {
    /// Packets to relay back to the responder, in order.
    pub outbound: Vec<ByocSealedPacket>,
    /// Decrypted, type-verified application frames.
    pub frames: Vec<Map<String, Value>>,
}

/// `decodePacket` in byoc-sealed-channel.ts: non-empty, canonical base64 only.
pub fn decode_packet(value: &str) -> Result<Vec<u8>> {
    if value.is_empty() {
        return Err(ByocSealedError::PacketEncoding);
    }
    let bytes = STANDARD
        .decode(value)
        .map_err(|_| ByocSealedError::PacketEncoding)?;
    if bytes.is_empty() || STANDARD.encode(&bytes) != value {
        return Err(ByocSealedError::PacketEncoding);
    }
    Ok(bytes)
}

fn frame_type(frame: &Map<String, Value>) -> Option<&str> {
    match frame.get("type") {
        Some(Value::String(t)) if !t.is_empty() => Some(t.as_str()),
        _ => None,
    }
}

/// Initiator side of a pinned-static-key Noise XX session over relay packets.
pub struct ByocSealedChannel {
    stream: SecretStreamInitiator,
    /// Bytes of a partial line awaiting its newline.
    line: Vec<u8>,
    /// Label the buffered partial line arrived under.
    line_type: Option<String>,
    closed: bool,
}

impl std::fmt::Debug for ByocSealedChannel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ByocSealedChannel")
            .field("open", &self.is_open())
            .field("closed", &self.closed)
            .finish_non_exhaustive()
    }
}

impl ByocSealedChannel {
    /// Begin the handshake. The initiator always pins the responder's key
    /// (the TS channel allows `verifyRemotePublicKey` only on the responder).
    /// Returns the channel and the first packet to relay.
    pub fn start(
        local: Ed25519KeyPair,
        expected_remote: [u8; 32],
    ) -> Result<(Self, ByocSealedPacket)> {
        let (stream, first) = SecretStreamInitiator::start(local, Some(expected_remote))?;
        Ok((
            Self::from_stream(stream),
            ByocSealedPacket::for_chunk(&first, None),
        ))
    }

    fn from_stream(stream: SecretStreamInitiator) -> Self {
        Self {
            stream,
            line: Vec::new(),
            line_type: None,
            closed: false,
        }
    }

    /// Handshake done and the responder's stream header received.
    pub fn is_open(&self) -> bool {
        !self.closed && self.stream.is_open()
    }

    pub fn is_closed(&self) -> bool {
        self.closed
    }

    /// The responder's proven static key once the handshake has completed.
    pub fn remote_public_key(&self) -> Option<[u8; 32]> {
        self.stream.remote_public_key()
    }

    /// Feed one packet received from the untrusted relay. Foreign packets
    /// (wrong `type`/`protocol`) are ignored, like the TS implementation.
    pub fn receive(&mut self, packet: &ByocSealedPacket) -> Result<SealedProgress> {
        if self.closed {
            return Err(ByocSealedError::Closed);
        }
        if !packet.is_ours() {
            return Ok(SealedProgress::default());
        }
        let result = self.receive_inner(packet);
        if result.is_err() {
            self.close();
        }
        result
    }

    fn receive_inner(&mut self, packet: &ByocSealedPacket) -> Result<SealedProgress> {
        if matches!(packet.content_type.as_deref(), Some("")) {
            return Err(ByocSealedError::InvalidContentType);
        }
        let bytes = decode_packet(&packet.packet)?;
        let progress = self.stream.receive(&bytes)?;
        let mut out = SealedProgress {
            outbound: progress
                .outbound
                .iter()
                .map(|c| ByocSealedPacket::for_chunk(c, None))
                .collect(),
            frames: Vec::new(),
        };
        let label = packet.content_type.as_deref();
        for message in progress.messages {
            if !self.line.is_empty() && self.line_type.as_deref() != label {
                return Err(ByocSealedError::ContentTypeMismatch);
            }
            self.line.extend_from_slice(&message);
            self.line_type = label.map(str::to_owned);
            while let Some(pos) = self.line.iter().position(|b| *b == b'\n') {
                let raw: Vec<u8> = self.line.drain(..=pos).collect();
                let parsed: Value = serde_json::from_slice(&raw[..raw.len() - 1])
                    .map_err(|_| ByocSealedError::InvalidJson)?;
                // A null label is handshake-only: application content relabelled to
                // null would skip relay policy, so it is a mismatch too.
                let Value::Object(frame) = parsed else {
                    return Err(ByocSealedError::ContentTypeMismatch);
                };
                match (frame_type(&frame), label) {
                    (Some(decrypted), Some(relayed)) if decrypted == relayed => {
                        out.frames.push(frame)
                    }
                    _ => return Err(ByocSealedError::ContentTypeMismatch),
                }
            }
        }
        Ok(out)
    }

    /// Encrypt one JSON frame; returns the packet(s) to relay.
    pub fn send(&mut self, frame: &Map<String, Value>) -> Result<Vec<ByocSealedPacket>> {
        if self.closed {
            return Err(ByocSealedError::Closed);
        }
        let content_type = frame_type(frame)
            .ok_or(ByocSealedError::MissingFrameType)?
            .to_owned();
        if !self.stream.is_open() {
            return Err(ByocSealedError::NotOpen);
        }
        let mut line = serde_json::to_vec(frame).map_err(|_| ByocSealedError::InvalidJson)?;
        line.push(b'\n');
        match self.stream.encrypt(&line) {
            Ok(chunk) => Ok(vec![ByocSealedPacket::for_chunk(
                &chunk,
                Some(content_type),
            )]),
            Err(e) => {
                self.close();
                Err(e.into())
            }
        }
    }

    pub fn close(&mut self) {
        self.closed = true;
        self.line.clear();
        self.line_type = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn obj(v: Value) -> Map<String, Value> {
        v.as_object().cloned().unwrap()
    }

    #[test]
    fn decode_packet_requires_canonical_nonempty_base64() {
        assert_eq!(decode_packet("AAEC"), Ok(vec![0, 1, 2]));
        assert_eq!(decode_packet(""), Err(ByocSealedError::PacketEncoding));
        assert_eq!(decode_packet("AAE"), Err(ByocSealedError::PacketEncoding)); // unpadded
        assert_eq!(decode_packet("AAE="), Ok(vec![0, 1]));
        assert_eq!(decode_packet("AAF="), Err(ByocSealedError::PacketEncoding)); // non-canonical trailing bits
        assert_eq!(decode_packet("AA-_"), Err(ByocSealedError::PacketEncoding));
        // url-safe alphabet
    }

    #[test]
    fn packet_serializes_like_the_ts_envelope() {
        let p = ByocSealedPacket::for_chunk(&[1, 2, 3], None);
        assert_eq!(
            serde_json::to_value(&p).unwrap(),
            json!({ "type": "sealed.packet", "protocol": "papercusp-byoc-noise-xx.v1", "contentType": null, "packet": "AQID" })
        );
        let q: ByocSealedPacket = serde_json::from_value(
            json!({ "type": "sealed.packet", "protocol": BYOC_SEALED_PROTOCOL, "contentType": "chat.send", "packet": "AQID" }),
        )
        .unwrap();
        assert_eq!(q.content_type.as_deref(), Some("chat.send"));
    }

    #[test]
    fn start_emits_a_null_labelled_handshake_packet() {
        let (ch, first) = ByocSealedChannel::start(
            Ed25519KeyPair::generate(),
            Ed25519KeyPair::generate().public_key(),
        )
        .unwrap();
        assert!(first.is_ours());
        assert_eq!(first.content_type, None);
        assert!(!decode_packet(&first.packet).unwrap().is_empty());
        assert!(!ch.is_open());
    }

    #[test]
    fn send_before_open_and_untyped_frames_are_refused() {
        let (mut ch, _) = ByocSealedChannel::start(
            Ed25519KeyPair::generate(),
            Ed25519KeyPair::generate().public_key(),
        )
        .unwrap();
        assert_eq!(
            ch.send(&obj(json!({ "x": 1 }))),
            Err(ByocSealedError::MissingFrameType)
        );
        assert_eq!(
            ch.send(&obj(json!({ "type": "" }))),
            Err(ByocSealedError::MissingFrameType)
        );
        assert_eq!(
            ch.send(&obj(json!({ "type": "ping" }))),
            Err(ByocSealedError::NotOpen)
        );
        assert!(
            !ch.is_closed(),
            "a refused send before open must not poison the channel"
        );
    }

    #[test]
    fn foreign_packets_are_ignored_and_bad_packets_close_the_channel() {
        let (mut ch, _) = ByocSealedChannel::start(
            Ed25519KeyPair::generate(),
            Ed25519KeyPair::generate().public_key(),
        )
        .unwrap();
        let mut foreign = ByocSealedPacket::for_chunk(&[1], None);
        foreign.protocol = "other".into();
        assert_eq!(ch.receive(&foreign), Ok(SealedProgress::default()));
        assert!(!ch.is_closed());

        let mut empty_label = ByocSealedPacket::for_chunk(&[1], None);
        empty_label.content_type = Some(String::new());
        assert_eq!(
            ch.receive(&empty_label),
            Err(ByocSealedError::InvalidContentType)
        );
        assert!(ch.is_closed());
        assert_eq!(
            ch.receive(&ByocSealedPacket::for_chunk(&[1], None)),
            Err(ByocSealedError::Closed)
        );
    }
}
