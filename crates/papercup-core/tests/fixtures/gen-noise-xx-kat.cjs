// Generates the known-answer vectors in noise_xx_kat.json from the REAL JavaScript
// implementation the Papercusp operator runs for the hosted/BYOC sealed channel:
// @hyperswarm/secret-stream 6.9.x = noise-handshake (XX) + noise-curve-ed (Ed25519 DH)
// + sodium-secretstream (libsodium crypto_secretstream_xchacha20poly1305).
//
// The Rust side (src/noise_stream.rs) must reproduce every byte of these vectors, so a
// change to either implementation that breaks wire compatibility fails `cargo test`.
//
// Regenerate (NODE_PATH must contain @hyperswarm/secret-stream, e.g. the papercusp tree):
//   NODE_PATH=../papercusp/node_modules \
//     node crates/papercup-core/tests/fixtures/gen-noise-xx-kat.cjs \
//     > crates/papercup-core/tests/fixtures/noise_xx_kat.json
//
// WI-10006994 / android-public-release-2026-10-01#D-018.
'use strict'

const path = require('path')

const ssDir = path.dirname(require.resolve('@hyperswarm/secret-stream'))
const req = (m) => require(require.resolve(m, { paths: [ssDir] }))

const Noise = req('noise-handshake')
const curve = req('noise-curve-ed')
const sodium = req('sodium-universal')
const { Push } = req('sodium-secretstream')
const crypto = req('hypercore-crypto')

const hex = (b) => Buffer.from(b).toString('hex')
const seedOf = (byte) => Buffer.alloc(32, byte)

const [NS_INITIATOR, NS_RESPONDER] = crypto.namespace('hyperswarm/secret-stream', 3)

function streamId(handshakeHash, ns) {
  const out = Buffer.alloc(32)
  sodium.crypto_generichash(out, ns, handshakeHash)
  return out
}

function keyPairFromSeed(seed) {
  return curve.generateKeyPair(seed)
}

function handshakeVector(name, seeds) {
  const iS = keyPairFromSeed(seedOf(seeds.initiatorStatic))
  const iE = keyPairFromSeed(seedOf(seeds.initiatorEphemeral))
  const rS = keyPairFromSeed(seedOf(seeds.responderStatic))
  const rE = keyPairFromSeed(seedOf(seeds.responderEphemeral))

  const record = {
    name,
    seeds: {
      initiatorStatic: hex(seedOf(seeds.initiatorStatic)),
      initiatorEphemeral: hex(seedOf(seeds.initiatorEphemeral)),
      responderStatic: hex(seedOf(seeds.responderStatic)),
      responderEphemeral: hex(seedOf(seeds.responderEphemeral))
    },
    publicKeys: {
      initiatorStatic: hex(iS.publicKey),
      initiatorEphemeral: hex(iE.publicKey),
      responderStatic: hex(rS.publicKey),
      responderEphemeral: hex(rE.publicKey)
    },
    // DH(local secret, remote public), as noise-curve-ed computes it.
    dh: {
      initiatorEphemeral_responderEphemeral: hex(curve.dh(rE.publicKey, iE)),
      initiatorEphemeral_responderStatic: hex(curve.dh(rS.publicKey, iE)),
      initiatorStatic_responderEphemeral: hex(curve.dh(rE.publicKey, iS))
    }
  }

  // noise-handshake zeroes ephemeral secrets in _clear(), so hand it copies.
  const copy = (kp) => ({ publicKey: Buffer.from(kp.publicKey), secretKey: Buffer.from(kp.secretKey) })

  const initiator = new Noise('XX', true, copy(iS), { curve })
  const responder = new Noise('XX', false, copy(rS), { curve })
  initiator.initialise(Buffer.alloc(0))
  responder.initialise(Buffer.alloc(0))
  initiator.e = copy(iE)
  responder.e = copy(rE)

  const msg1 = initiator.send()
  responder.recv(msg1)
  const msg2 = responder.send()
  initiator.recv(msg2)
  const msg3 = initiator.send()
  responder.recv(msg3)

  if (!initiator.complete || !responder.complete) throw new Error('handshake did not complete')

  const hash = Buffer.from(initiator.hash)
  record.handshake = {
    msg1: hex(msg1),
    msg2: hex(msg2),
    msg3: hex(msg3),
    initiatorTx: hex(initiator.tx),
    initiatorRx: hex(initiator.rx),
    handshakeHash: hex(hash),
    responderHandshakeHash: hex(responder.hash),
    initiatorStreamId: hex(streamId(hash, NS_INITIATOR)),
    responderStreamId: hex(streamId(hash, NS_RESPONDER))
  }

  // The responder's data channel, as the initiator receives it: Push keyed with the
  // responder tx (= initiator rx). The header is random; the Rust side only needs to
  // PULL these, so recording the header the JS side chose is enough.
  const push = new Push(Buffer.from(responder.tx).subarray(0, 32))
  const plaintexts = ['{"type":"session.ready"}\n', '', '{"type":"device.pairing.accepted","n":2}\n']
  record.responderStream = {
    header: hex(push.header),
    messages: plaintexts.map((p) => {
      const plain = Buffer.from(p, 'utf8')
      return { plaintext: hex(plain), ciphertext: hex(push.next(plain)) }
    })
  }
  return record
}

const out = {
  generator: 'gen-noise-xx-kat.cjs',
  secretStreamVersion: require(path.join(ssDir, 'package.json')).version,
  protocol: 'Noise_XX_Ed25519_ChaChaPoly_BLAKE2b',
  namespaces: {
    initiator: hex(NS_INITIATOR),
    responder: hex(NS_RESPONDER)
  },
  vectors: [
    handshakeVector('ascending-seeds', {
      initiatorStatic: 1,
      initiatorEphemeral: 2,
      responderStatic: 3,
      responderEphemeral: 4
    }),
    handshakeVector('high-seeds', {
      initiatorStatic: 0xa1,
      initiatorEphemeral: 0xb2,
      responderStatic: 0xc3,
      responderEphemeral: 0xd4
    })
  ]
}

process.stdout.write(JSON.stringify(out, null, 2) + '\n')
