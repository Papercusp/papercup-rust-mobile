//! Noise XX initiator plus data channel, wire-compatible with `@hyperswarm/secret-stream`
//! 6.9.x. The Papercusp operator uses that stream for the hosted/BYOC sealed channel,
//! so this module is what lets a phone pair through the cloud relay without the relay
//! reading the traffic.
//!
//! Wire format (verified against the JS sources and pinned by the known-answer vectors
//! in `tests/fixtures/noise_xx_kat.json`, which are generated from the real JS stack):
//!
//! * Handshake: `Noise_XX_Ed25519_ChaChaPoly_BLAKE2b`, empty prologue. The DH is
//!   `noise-curve-ed`, not X25519: the clamped SHA-512(seed) scalar multiplies a
//!   prime-order Ed25519 point (libsodium `crypto_scalarmult_ed25519_noclamp`). Each
//!   handshake message goes on the wire as `uint24le(len) || message`.
//! * After the handshake each side sends one `uint24le(56) || streamId(32) || header(24)`
//!   frame. Here `streamId = BLAKE2b-256(key = handshake hash, input = role namespace)`
//!   and `header` starts a libsodium `crypto_secretstream_xchacha20poly1305` stream keyed
//!   with the first 32 bytes of the Noise tx key.
//! * Data: `uint24le(len) || secretstream_push(TAG_MESSAGE, plaintext)`. A zero-length
//!   plaintext is a keepalive and is never surfaced.
//!
//! The module is sans-IO: callers feed received bytes in and send the returned chunks
//! out. Each returned chunk is exactly one write the JS side would have made, so a
//! relay that maps one write to one packet stays aligned.
//!
//! WI-10006994 / android-public-release-2026-10-01#D-013, #D-018.

use blake2::digest::consts::U32;
use blake2::digest::{Digest, Mac};
use blake2::{Blake2b512, Blake2bMac};
use chacha20poly1305::aead::{Aead, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key as AeadKey, KeyInit, Nonce};
use crypto_secretstream::{Header, Key as StreamKey, PullStream, PushStream, Tag};
use curve25519_dalek::edwards::{CompressedEdwardsY, EdwardsPoint};
use curve25519_dalek::traits::IsIdentity;
use hmac::SimpleHmac;
use rand_core::{OsRng, RngCore};
use sha2::Sha512;
use zeroize::Zeroizing;

/// The Noise protocol name secret-stream uses.
pub const PROTOCOL_NAME: &str = "Noise_XX_Ed25519_ChaChaPoly_BLAKE2b";
/// Largest payload a 24-bit length prefix can carry.
pub const MAX_FRAME_BYTES: usize = 0xFF_FFFF;
/// libsodium secretstream overhead per message: 1 tag byte plus a 16-byte MAC.
pub const SECRETSTREAM_ABYTES: usize = 17;

const HASHLEN: usize = 64;
const KEYLEN: usize = 32;
const MACLEN: usize = 16;
const HEADER_BYTES: usize = 24;
const ID_HEADER_BYTES: usize = 32 + HEADER_BYTES;
/// msg2 = re(32) || encrypted s(32 + 16) || encrypted empty payload(16).
const MSG2_MIN_BYTES: usize = KEYLEN + KEYLEN + MACLEN + MACLEN;

/// `hypercore-crypto.namespace('hyperswarm/secret-stream', 3)[0]`.
const NS_INITIATOR: [u8; 32] =
    hex32("a931a0155b5c09e6d28628236af83c4b8a6af9af60986edeede9dc5d63192bf7");
/// `hypercore-crypto.namespace('hyperswarm/secret-stream', 3)[1]`.
const NS_RESPONDER: [u8; 32] =
    hex32("742c9d833d430af4c48a8705e91631eecf295442bbca18996e597097723b1061");

type HmacBlake2b = SimpleHmac<Blake2b512>;

/// Errors from the handshake or the data channel. Any error poisons the stream.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum NoiseStreamError {
    #[error("remote public key is not a canonical Ed25519 point in the prime-order subgroup")]
    InvalidPublicKey,
    #[error("Diffie-Hellman produced the identity point")]
    WeakSharedSecret,
    #[error("handshake message is too short: need at least {expected} bytes, got {actual}")]
    MessageLength { expected: usize, actual: usize },
    #[error("handshake message failed authentication")]
    HandshakeDecrypt,
    #[error("handshake encryption failed")]
    HandshakeEncrypt,
    #[error("remote static key does not match the pinned key")]
    RemoteKeyMismatch,
    #[error("responder sent an invalid stream id/header frame")]
    InvalidHeader,
    #[error("secret stream message is shorter than the 17-byte overhead")]
    ShortMessage,
    #[error("secret stream message failed authentication")]
    StreamDecrypt,
    #[error("secret stream encryption failed")]
    StreamEncrypt,
    #[error("frame of {0} bytes exceeds the 24-bit length prefix")]
    FrameTooLarge(usize),
    #[error("the handshake has not completed")]
    NotOpen,
    #[error("the stream failed earlier and cannot be used")]
    Failed,
}

pub type Result<T> = std::result::Result<T, NoiseStreamError>;

/// An Ed25519 key pair used as a Noise DH key, derived from a 32-byte seed the same way
/// libsodium's `crypto_sign_seed_keypair` derives it.
#[derive(Clone)]
pub struct Ed25519KeyPair {
    scalar: Zeroizing<[u8; 32]>,
    public: [u8; 32],
}

impl std::fmt::Debug for Ed25519KeyPair {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Ed25519KeyPair")
            .field("public", &hex_string(&self.public))
            .finish_non_exhaustive()
    }
}

impl Ed25519KeyPair {
    /// Derive the key pair from a seed: scalar = clamp(SHA-512(seed)[..32]).
    pub fn from_seed(seed: &[u8; 32]) -> Self {
        let mut digest = Zeroizing::new([0u8; 64]);
        digest.copy_from_slice(&Sha512::digest(seed));
        let mut scalar = Zeroizing::new([0u8; 32]);
        scalar.copy_from_slice(&digest[..32]);
        scalar[0] &= 248;
        scalar[31] &= 127;
        scalar[31] |= 64;
        let public = EdwardsPoint::mul_base_clamped(*scalar)
            .compress()
            .to_bytes();
        Self { scalar, public }
    }

    /// A fresh random key pair from the OS RNG.
    pub fn generate() -> Self {
        let mut seed = Zeroizing::new([0u8; 32]);
        OsRng.fill_bytes(&mut seed[..]);
        Self::from_seed(&seed)
    }

    /// The Ed25519 public key (compressed Edwards point).
    pub fn public_key(&self) -> [u8; 32] {
        self.public
    }

    /// `noise-curve-ed` DH: scalar times the remote point, compressed. Rejects
    /// non-canonical, small-order and mixed-order points and an identity result,
    /// matching libsodium `crypto_scalarmult_ed25519_noclamp`.
    pub fn diffie_hellman(&self, remote_public: &[u8; 32]) -> Result<Zeroizing<[u8; 32]>> {
        let point = CompressedEdwardsY(*remote_public)
            .decompress()
            .ok_or(NoiseStreamError::InvalidPublicKey)?;
        if point.compress().to_bytes() != *remote_public
            || point.is_small_order()
            || !point.is_torsion_free()
        {
            return Err(NoiseStreamError::InvalidPublicKey);
        }
        let shared = point.mul_clamped(*self.scalar);
        if shared.is_identity() {
            return Err(NoiseStreamError::WeakSharedSecret);
        }
        Ok(Zeroizing::new(shared.compress().to_bytes()))
    }
}

/// The secret-stream id a side announces after the handshake.
pub fn stream_id(handshake_hash: &[u8; 64], initiator: bool) -> [u8; 32] {
    let mut mac = <Blake2bMac<U32> as Mac>::new_from_slice(handshake_hash)
        .expect("BLAKE2b accepts a 64-byte key");
    Mac::update(
        &mut mac,
        if initiator {
            &NS_INITIATOR
        } else {
            &NS_RESPONDER
        },
    );
    let mut out = [0u8; 32];
    out.copy_from_slice(&mac.finalize().into_bytes());
    out
}

/// Prefix a payload with its 24-bit little-endian length.
pub fn frame(payload: &[u8]) -> Result<Vec<u8>> {
    let len = payload.len();
    if len > MAX_FRAME_BYTES {
        return Err(NoiseStreamError::FrameTooLarge(len));
    }
    let mut out = Vec::with_capacity(3 + len);
    out.extend_from_slice(&[
        (len & 0xff) as u8,
        ((len >> 8) & 0xff) as u8,
        ((len >> 16) & 0xff) as u8,
    ]);
    out.extend_from_slice(payload);
    Ok(out)
}

/// Reassembles `uint24le(len) || payload` frames from arbitrarily split input.
#[derive(Debug, Default)]
pub struct FrameDecoder {
    buf: Vec<u8>,
}

impl FrameDecoder {
    pub fn push(&mut self, bytes: &[u8]) {
        self.buf.extend_from_slice(bytes);
    }

    /// The next complete frame body, or `None` until more bytes arrive.
    pub fn next_frame(&mut self) -> Option<Vec<u8>> {
        if self.buf.len() < 3 {
            return None;
        }
        let len = self.buf[0] as usize | (self.buf[1] as usize) << 8 | (self.buf[2] as usize) << 16;
        if self.buf.len() < 3 + len {
            return None;
        }
        let body = self.buf[3..3 + len].to_vec();
        self.buf.drain(..3 + len);
        Some(body)
    }

    /// Bytes held back waiting for the rest of a frame.
    pub fn pending_bytes(&self) -> usize {
        self.buf.len()
    }
}

fn hmac(key: &[u8], parts: &[&[u8]]) -> [u8; HASHLEN] {
    let mut mac = <HmacBlake2b as Mac>::new_from_slice(key).expect("HMAC accepts any key length");
    for part in parts {
        Mac::update(&mut mac, part);
    }
    let mut out = [0u8; HASHLEN];
    out.copy_from_slice(&mac.finalize().into_bytes());
    out
}

/// noise-handshake's HKDF over HMAC-BLAKE2b with empty info and two 64-byte outputs.
fn hkdf2(salt: &[u8], ikm: &[u8]) -> (Zeroizing<[u8; HASHLEN]>, Zeroizing<[u8; HASHLEN]>) {
    let prk = Zeroizing::new(hmac(salt, &[ikm]));
    let t1 = Zeroizing::new(hmac(&prk[..], &[&[1u8]]));
    let t2 = Zeroizing::new(hmac(&prk[..], &[&t1[..], &[2u8]]));
    (t1, t2)
}

fn first_key(bytes: &[u8; HASHLEN]) -> Zeroizing<[u8; KEYLEN]> {
    let mut k = Zeroizing::new([0u8; KEYLEN]);
    k.copy_from_slice(&bytes[..KEYLEN]);
    k
}

/// noise-handshake's ChaCha20-Poly1305 nonce: `setUint32(4, n, true)` on 12 zero bytes.
fn aead_nonce(n: u64) -> [u8; 12] {
    let mut nonce = [0u8; 12];
    nonce[4..8].copy_from_slice(&(n as u32).to_le_bytes());
    nonce
}

struct SymmetricState {
    h: [u8; HASHLEN],
    ck: Zeroizing<[u8; HASHLEN]>,
    k: Option<Zeroizing<[u8; KEYLEN]>>,
    n: u64,
}

impl SymmetricState {
    fn new() -> Self {
        let mut h = [0u8; HASHLEN];
        h[..PROTOCOL_NAME.len()].copy_from_slice(PROTOCOL_NAME.as_bytes());
        let mut state = Self {
            h,
            ck: Zeroizing::new(h),
            k: None,
            n: 0,
        };
        state.mix_hash(&[]); // empty prologue
        state
    }

    fn mix_hash(&mut self, data: &[u8]) {
        let mut d = Blake2b512::new();
        Digest::update(&mut d, self.h);
        Digest::update(&mut d, data);
        self.h.copy_from_slice(&d.finalize());
    }

    fn mix_key(&mut self, ikm: &[u8]) {
        let (ck, temp_k) = hkdf2(&self.ck[..], ikm);
        self.ck = ck;
        self.k = Some(first_key(&temp_k));
        self.n = 0;
    }

    fn encrypt_and_hash(&mut self, plaintext: &[u8]) -> Result<Vec<u8>> {
        let ciphertext = match self.k.as_ref() {
            None => plaintext.to_vec(),
            Some(k) => ChaCha20Poly1305::new(AeadKey::from_slice(&k[..]))
                .encrypt(
                    Nonce::from_slice(&aead_nonce(self.n)),
                    Payload {
                        msg: plaintext,
                        aad: &self.h,
                    },
                )
                .map_err(|_| NoiseStreamError::HandshakeEncrypt)?,
        };
        if self.k.is_some() {
            self.n += 1;
        }
        self.mix_hash(&ciphertext);
        Ok(ciphertext)
    }

    fn decrypt_and_hash(&mut self, ciphertext: &[u8]) -> Result<Vec<u8>> {
        let plaintext = match self.k.as_ref() {
            None => ciphertext.to_vec(),
            Some(k) => ChaCha20Poly1305::new(AeadKey::from_slice(&k[..]))
                .decrypt(
                    Nonce::from_slice(&aead_nonce(self.n)),
                    Payload {
                        msg: ciphertext,
                        aad: &self.h,
                    },
                )
                .map_err(|_| NoiseStreamError::HandshakeDecrypt)?,
        };
        if self.k.is_some() {
            self.n += 1;
        }
        self.mix_hash(ciphertext);
        Ok(plaintext)
    }

    fn split(&self) -> (Zeroizing<[u8; KEYLEN]>, Zeroizing<[u8; KEYLEN]>) {
        let (t1, t2) = hkdf2(&self.ck[..], &[]);
        (first_key(&t1), first_key(&t2))
    }
}

/// Result of a completed initiator handshake.
pub struct HandshakeOutcome {
    /// The third handshake message (unframed).
    pub message3: Vec<u8>,
    /// Initiator send key (secretstream push key).
    pub tx: Zeroizing<[u8; KEYLEN]>,
    /// Initiator receive key (secretstream pull key).
    pub rx: Zeroizing<[u8; KEYLEN]>,
    pub handshake_hash: [u8; HASHLEN],
    pub remote_public_key: [u8; 32],
}

/// The Noise XX initiator state machine (handshake only).
pub struct NoiseXxInitiator {
    ss: SymmetricState,
    s: Ed25519KeyPair,
    e: Ed25519KeyPair,
    expected_remote: Option<[u8; 32]>,
}

impl NoiseXxInitiator {
    /// `expected_remote` pins the responder's static key; a mismatch aborts the handshake.
    pub fn new(static_keys: Ed25519KeyPair, expected_remote: Option<[u8; 32]>) -> Self {
        Self::with_ephemeral(static_keys, Ed25519KeyPair::generate(), expected_remote)
    }

    /// Fixed ephemeral key, for known-answer tests only.
    pub fn with_ephemeral(
        static_keys: Ed25519KeyPair,
        ephemeral: Ed25519KeyPair,
        expected_remote: Option<[u8; 32]>,
    ) -> Self {
        Self {
            ss: SymmetricState::new(),
            s: static_keys,
            e: ephemeral,
            expected_remote,
        }
    }

    /// `-> e`: the first message (unframed).
    pub fn write_message1(&mut self) -> Result<Vec<u8>> {
        let e_pub = self.e.public_key();
        self.ss.mix_hash(&e_pub);
        let payload = self.ss.encrypt_and_hash(&[])?;
        let mut out = e_pub.to_vec();
        out.extend_from_slice(&payload);
        Ok(out)
    }

    /// `<- e, ee, s, es` then `-> s, se`, then split.
    pub fn read_message2(mut self, msg2: &[u8]) -> Result<HandshakeOutcome> {
        if msg2.len() < MSG2_MIN_BYTES {
            return Err(NoiseStreamError::MessageLength {
                expected: MSG2_MIN_BYTES,
                actual: msg2.len(),
            });
        }
        let mut re = [0u8; 32];
        re.copy_from_slice(&msg2[..32]);
        self.ss.mix_hash(&re);
        let ee = self.e.diffie_hellman(&re)?;
        self.ss.mix_key(&ee[..]);

        let rs_bytes = self.ss.decrypt_and_hash(&msg2[32..32 + KEYLEN + MACLEN])?;
        let mut rs = [0u8; 32];
        rs.copy_from_slice(&rs_bytes);
        if let Some(expected) = self.expected_remote {
            if expected != rs {
                return Err(NoiseStreamError::RemoteKeyMismatch);
            }
        }
        let es = self.e.diffie_hellman(&rs)?;
        self.ss.mix_key(&es[..]);
        self.ss.decrypt_and_hash(&msg2[32 + KEYLEN + MACLEN..])?;

        let mut message3 = self.ss.encrypt_and_hash(&self.s.public_key())?;
        let se = self.s.diffie_hellman(&re)?;
        self.ss.mix_key(&se[..]);
        message3.extend_from_slice(&self.ss.encrypt_and_hash(&[])?);

        let (tx, rx) = self.ss.split();
        Ok(HandshakeOutcome {
            message3,
            tx,
            rx,
            handshake_hash: self.ss.h,
            remote_public_key: rs,
        })
    }
}

/// What one `receive` call produced.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Progress {
    /// Chunks to send to the responder, in order; one chunk per JS-side write.
    pub outbound: Vec<Vec<u8>>,
    /// Decrypted application messages, keepalives removed.
    pub messages: Vec<Vec<u8>>,
}

struct Established {
    push: PushStream,
    pull: Option<PullStream>,
    rx: Zeroizing<[u8; KEYLEN]>,
    handshake_hash: [u8; HASHLEN],
    remote_public_key: [u8; 32],
}

enum State {
    Handshaking(Box<NoiseXxInitiator>),
    Established(Box<Established>),
    Failed,
}

/// The initiator side of a secret-stream session: handshake plus data channel.
pub struct SecretStreamInitiator {
    state: State,
    decoder: FrameDecoder,
}

impl SecretStreamInitiator {
    /// Start a session. Returns the session and the first chunk to send.
    pub fn start(
        static_keys: Ed25519KeyPair,
        expected_remote: Option<[u8; 32]>,
    ) -> Result<(Self, Vec<u8>)> {
        Self::from_handshake(NoiseXxInitiator::new(static_keys, expected_remote))
    }

    /// Like [`Self::start`] with a fixed ephemeral key, for known-answer tests only.
    pub fn start_with_ephemeral(
        static_keys: Ed25519KeyPair,
        ephemeral: Ed25519KeyPair,
        expected_remote: Option<[u8; 32]>,
    ) -> Result<(Self, Vec<u8>)> {
        Self::from_handshake(NoiseXxInitiator::with_ephemeral(
            static_keys,
            ephemeral,
            expected_remote,
        ))
    }

    fn from_handshake(mut handshake: NoiseXxInitiator) -> Result<(Self, Vec<u8>)> {
        let first = frame(&handshake.write_message1()?)?;
        Ok((
            Self {
                state: State::Handshaking(Box::new(handshake)),
                decoder: FrameDecoder::default(),
            },
            first,
        ))
    }

    /// True once the handshake finished and data can be sent.
    pub fn is_handshake_complete(&self) -> bool {
        matches!(self.state, State::Established(_))
    }

    /// True once the responder's header arrived, so its messages can be read.
    pub fn is_open(&self) -> bool {
        matches!(&self.state, State::Established(est) if est.pull.is_some())
    }

    pub fn remote_public_key(&self) -> Option<[u8; 32]> {
        match &self.state {
            State::Established(est) => Some(est.remote_public_key),
            _ => None,
        }
    }

    pub fn handshake_hash(&self) -> Option<[u8; 64]> {
        match &self.state {
            State::Established(est) => Some(est.handshake_hash),
            _ => None,
        }
    }

    /// Feed bytes received from the responder.
    pub fn receive(&mut self, bytes: &[u8]) -> Result<Progress> {
        if matches!(self.state, State::Failed) {
            return Err(NoiseStreamError::Failed);
        }
        self.decoder.push(bytes);
        let mut progress = Progress::default();
        while let Some(body) = self.decoder.next_frame() {
            if let Err(err) = self.handle_frame(body, &mut progress) {
                self.state = State::Failed;
                return Err(err);
            }
        }
        Ok(progress)
    }

    fn handle_frame(&mut self, body: Vec<u8>, progress: &mut Progress) -> Result<()> {
        match std::mem::replace(&mut self.state, State::Failed) {
            State::Failed => Err(NoiseStreamError::Failed),
            State::Handshaking(handshake) => {
                let outcome = handshake.read_message2(&body)?;
                let (header, push) = PushStream::init(OsRng, &StreamKey::from(*outcome.tx));
                progress.outbound.push(frame(&outcome.message3)?);
                let mut id_header = stream_id(&outcome.handshake_hash, true).to_vec();
                id_header.extend_from_slice(header.as_ref());
                progress.outbound.push(frame(&id_header)?);
                self.state = State::Established(Box::new(Established {
                    push,
                    pull: None,
                    rx: outcome.rx,
                    handshake_hash: outcome.handshake_hash,
                    remote_public_key: outcome.remote_public_key,
                }));
                Ok(())
            }
            State::Established(mut est) => {
                match est.pull.as_mut() {
                    None => {
                        if body.len() != ID_HEADER_BYTES
                            || body[..32] != stream_id(&est.handshake_hash, false)
                        {
                            return Err(NoiseStreamError::InvalidHeader);
                        }
                        let header = Header::try_from(&body[32..])
                            .map_err(|_| NoiseStreamError::InvalidHeader)?;
                        est.pull = Some(PullStream::init(header, &StreamKey::from(*est.rx)));
                    }
                    Some(pull) => {
                        if body.len() < SECRETSTREAM_ABYTES {
                            return Err(NoiseStreamError::ShortMessage);
                        }
                        let mut buf = body;
                        pull.pull(&mut buf, &[])
                            .map_err(|_| NoiseStreamError::StreamDecrypt)?;
                        if !buf.is_empty() {
                            progress.messages.push(buf);
                        }
                    }
                }
                self.state = State::Established(est);
                Ok(())
            }
        }
    }

    /// Encrypt one application message into a single framed chunk.
    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>> {
        let est = match &mut self.state {
            State::Established(est) => est,
            State::Handshaking(_) => return Err(NoiseStreamError::NotOpen),
            State::Failed => return Err(NoiseStreamError::Failed),
        };
        if plaintext.len() + SECRETSTREAM_ABYTES > MAX_FRAME_BYTES {
            return Err(NoiseStreamError::FrameTooLarge(
                plaintext.len() + SECRETSTREAM_ABYTES,
            ));
        }
        let mut buf = plaintext.to_vec();
        est.push
            .push(&mut buf, &[], Tag::Message)
            .map_err(|_| NoiseStreamError::StreamEncrypt)?;
        frame(&buf)
    }
}

const fn hex_nibble(c: u8) -> u8 {
    match c {
        b'0'..=b'9' => c - b'0',
        b'a'..=b'f' => c - b'a' + 10,
        _ => panic!("invalid hex digit"),
    }
}

const fn hex32(s: &str) -> [u8; 32] {
    let b = s.as_bytes();
    assert!(b.len() == 64);
    let mut out = [0u8; 32];
    let mut i = 0;
    while i < 32 {
        out[i] = hex_nibble(b[2 * i]) << 4 | hex_nibble(b[2 * i + 1]);
        i += 1;
    }
    out
}

fn hex_string(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_decoder_reassembles_split_and_coalesced_frames() {
        let mut wire = frame(b"abc").unwrap();
        wire.extend(frame(b"").unwrap());
        wire.extend(frame(&[7u8; 300]).unwrap());
        let mut dec = FrameDecoder::default();
        let mut got = Vec::new();
        for byte in &wire {
            dec.push(std::slice::from_ref(byte));
            while let Some(f) = dec.next_frame() {
                got.push(f);
            }
        }
        assert_eq!(got, vec![b"abc".to_vec(), Vec::new(), vec![7u8; 300]]);
        assert_eq!(dec.pending_bytes(), 0);
    }

    #[test]
    fn frame_rejects_oversized_payload() {
        assert_eq!(
            frame(&vec![0u8; MAX_FRAME_BYTES + 1]),
            Err(NoiseStreamError::FrameTooLarge(MAX_FRAME_BYTES + 1))
        );
    }

    #[test]
    fn dh_rejects_small_order_and_non_canonical_points() {
        let kp = Ed25519KeyPair::from_seed(&[9u8; 32]);
        // The identity point (small order).
        let mut identity = [0u8; 32];
        identity[0] = 1;
        assert_eq!(
            kp.diffie_hellman(&identity),
            Err(NoiseStreamError::InvalidPublicKey)
        );
        // y = p (non-canonical encoding of y = 0).
        let mut non_canonical = [0xffu8; 32];
        non_canonical[0] = 0xed;
        non_canonical[31] = 0x7f;
        assert!(kp.diffie_hellman(&non_canonical).is_err());
    }

    #[test]
    fn encrypt_before_handshake_is_refused() {
        let (mut s, _) = SecretStreamInitiator::start(Ed25519KeyPair::generate(), None).unwrap();
        assert_eq!(s.encrypt(b"x"), Err(NoiseStreamError::NotOpen));
    }

    #[test]
    fn short_message2_is_refused_and_poisons_the_stream() {
        let (mut s, _) = SecretStreamInitiator::start(Ed25519KeyPair::generate(), None).unwrap();
        let err = s.receive(&frame(&[0u8; 10]).unwrap()).unwrap_err();
        assert_eq!(
            err,
            NoiseStreamError::MessageLength {
                expected: MSG2_MIN_BYTES,
                actual: 10
            }
        );
        assert_eq!(s.receive(&[]), Err(NoiseStreamError::Failed));
    }
}
