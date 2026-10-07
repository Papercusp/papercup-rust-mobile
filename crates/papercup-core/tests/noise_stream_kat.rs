//! Known-answer tests: src/noise_stream.rs must reproduce, byte for byte, what the real
//! JavaScript stack (@hyperswarm/secret-stream 6.9.x) produced in
//! tests/fixtures/noise_xx_kat.json (regenerate with tests/fixtures/gen-noise-xx-kat.cjs).

use papercup_core::noise_stream::{
    frame, stream_id, Ed25519KeyPair, NoiseStreamError, SecretStreamInitiator,
};
use serde_json::Value;

const KAT: &str = include_str!("fixtures/noise_xx_kat.json");

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

fn arr32(v: &Value) -> [u8; 32] {
    unhex(v.as_str().unwrap()).try_into().unwrap()
}

fn vectors() -> Vec<Value> {
    let kat: Value = serde_json::from_str(KAT).unwrap();
    let vectors = kat["vectors"].as_array().unwrap().clone();
    assert!(vectors.len() >= 2, "KAT file must carry vectors");
    vectors
}

#[test]
fn key_derivation_and_dh_match_noise_curve_ed() {
    for v in vectors() {
        let kp = |name: &str| Ed25519KeyPair::from_seed(&arr32(&v["seeds"][name]));
        for name in [
            "initiatorStatic",
            "initiatorEphemeral",
            "responderStatic",
            "responderEphemeral",
        ] {
            assert_eq!(
                kp(name).public_key(),
                arr32(&v["publicKeys"][name]),
                "{} {name}",
                v["name"]
            );
        }
        let pk = |name: &str| arr32(&v["publicKeys"][name]);
        let dh = |local: &str, remote: &str| *kp(local).diffie_hellman(&pk(remote)).unwrap();
        assert_eq!(
            dh("initiatorEphemeral", "responderEphemeral"),
            arr32(&v["dh"]["initiatorEphemeral_responderEphemeral"])
        );
        assert_eq!(
            dh("initiatorEphemeral", "responderStatic"),
            arr32(&v["dh"]["initiatorEphemeral_responderStatic"])
        );
        assert_eq!(
            dh("initiatorStatic", "responderEphemeral"),
            arr32(&v["dh"]["initiatorStatic_responderEphemeral"])
        );
    }
}

#[test]
fn handshake_and_responder_stream_match_secret_stream() {
    for v in vectors() {
        let name = v["name"].as_str().unwrap().to_string();
        let hs = &v["handshake"];
        let (mut session, first) = SecretStreamInitiator::start_with_ephemeral(
            Ed25519KeyPair::from_seed(&arr32(&v["seeds"]["initiatorStatic"])),
            Ed25519KeyPair::from_seed(&arr32(&v["seeds"]["initiatorEphemeral"])),
            Some(arr32(&v["publicKeys"]["responderStatic"])),
        )
        .unwrap();
        assert_eq!(
            first,
            frame(&unhex(hs["msg1"].as_str().unwrap())).unwrap(),
            "{name} msg1"
        );

        // msg2 split across two reads, to exercise frame reassembly.
        let msg2 = frame(&unhex(hs["msg2"].as_str().unwrap())).unwrap();
        assert_eq!(session.receive(&msg2[..40]).unwrap(), Default::default());
        let progress = session.receive(&msg2[40..]).unwrap();
        assert!(session.is_handshake_complete());
        assert_eq!(
            progress.outbound.len(),
            2,
            "{name}: msg3 then the id/header frame"
        );
        assert_eq!(
            progress.outbound[0],
            frame(&unhex(hs["msg3"].as_str().unwrap())).unwrap(),
            "{name} msg3"
        );
        let id_header = &progress.outbound[1];
        assert_eq!(&id_header[..3], &[56, 0, 0]);
        assert_eq!(
            id_header[3..35].to_vec(),
            unhex(hs["initiatorStreamId"].as_str().unwrap()),
            "{name} id"
        );

        let hash: [u8; 64] = unhex(hs["handshakeHash"].as_str().unwrap())
            .try_into()
            .unwrap();
        assert_eq!(session.handshake_hash(), Some(hash));
        assert_eq!(
            session.remote_public_key(),
            Some(arr32(&v["publicKeys"]["responderStatic"]))
        );
        assert_eq!(
            stream_id(&hash, false).to_vec(),
            unhex(hs["responderStreamId"].as_str().unwrap())
        );

        // The responder's header plus every pushed message, coalesced into one read.
        let rs = &v["responderStream"];
        let mut wire = unhex(hs["responderStreamId"].as_str().unwrap());
        wire.extend(unhex(rs["header"].as_str().unwrap()));
        let mut wire = frame(&wire).unwrap();
        let mut expected = Vec::new();
        for m in rs["messages"].as_array().unwrap() {
            wire.extend(frame(&unhex(m["ciphertext"].as_str().unwrap())).unwrap());
            let plain = unhex(m["plaintext"].as_str().unwrap());
            if !plain.is_empty() {
                expected.push(plain);
            }
        }
        let progress = session.receive(&wire).unwrap();
        assert!(session.is_open());
        assert_eq!(
            progress.messages, expected,
            "{name}: keepalive dropped, the rest decrypted in order"
        );
    }
}

#[test]
fn pinned_remote_key_mismatch_aborts_the_handshake() {
    let v = &vectors()[0];
    let (mut session, _) = SecretStreamInitiator::start_with_ephemeral(
        Ed25519KeyPair::from_seed(&arr32(&v["seeds"]["initiatorStatic"])),
        Ed25519KeyPair::from_seed(&arr32(&v["seeds"]["initiatorEphemeral"])),
        Some([0x11; 32]),
    )
    .unwrap();
    let msg2 = frame(&unhex(v["handshake"]["msg2"].as_str().unwrap())).unwrap();
    assert_eq!(
        session.receive(&msg2),
        Err(NoiseStreamError::RemoteKeyMismatch)
    );
}

#[test]
fn tampered_message2_fails_authentication() {
    let v = &vectors()[0];
    let (mut session, _) = SecretStreamInitiator::start_with_ephemeral(
        Ed25519KeyPair::from_seed(&arr32(&v["seeds"]["initiatorStatic"])),
        Ed25519KeyPair::from_seed(&arr32(&v["seeds"]["initiatorEphemeral"])),
        None,
    )
    .unwrap();
    let mut msg2 = unhex(v["handshake"]["msg2"].as_str().unwrap());
    msg2[40] ^= 1;
    assert_eq!(
        session.receive(&frame(&msg2).unwrap()),
        Err(NoiseStreamError::HandshakeDecrypt)
    );
}

#[test]
fn wrong_responder_stream_id_is_refused() {
    let v = &vectors()[0];
    let (mut session, _) = SecretStreamInitiator::start_with_ephemeral(
        Ed25519KeyPair::from_seed(&arr32(&v["seeds"]["initiatorStatic"])),
        Ed25519KeyPair::from_seed(&arr32(&v["seeds"]["initiatorEphemeral"])),
        None,
    )
    .unwrap();
    session
        .receive(&frame(&unhex(v["handshake"]["msg2"].as_str().unwrap())).unwrap())
        .unwrap();
    // The initiator's own id is not the responder's id.
    let mut wire = unhex(v["handshake"]["initiatorStreamId"].as_str().unwrap());
    wire.extend(unhex(v["responderStream"]["header"].as_str().unwrap()));
    assert_eq!(
        session.receive(&frame(&wire).unwrap()),
        Err(NoiseStreamError::InvalidHeader)
    );
}
