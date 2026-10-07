// The REAL papercusp ByocSealedChannel (packages/operator-core/lib/workspace-host/
// byoc-sealed-channel.ts) as a RESPONDER, for tests/byoc_sealed_interop.rs.
//
// Run with `node --import tsx <this file> <channel.ts> <accept|refuse> <initiatorPubHex>`
// from a papercusp checkout root (so `tsx` resolves). stdio is the untrusted relay:
//   stdin  — one ByocSealedPacket JSON per line, fed to channel.receive()
//   stdout — one event JSON per line:
//     {event:'ready', publicKey}        responder static key (hex), printed first
//     {event:'packet', packet}          a packet the channel wants relayed
//     {event:'open'}                    handshake complete
//     {event:'frame', frame}            a decrypted application frame (then echoed back
//                                       as {type: frame.type, echo: frame})
//     {event:'error', message}          the channel failed (terminal)
// The responder verifies the initiator with verifyRemotePublicKey (D-013 #6): 'accept'
// admits exactly <initiatorPubHex>; 'refuse' resolves false for every key.
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const [channelPath, mode, initiatorHex] = process.argv.slice(2);
if (!channelPath || !['accept', 'refuse'].includes(mode) || !/^[0-9a-f]{64}$/.test(initiatorHex ?? '')) {
  process.stderr.write('usage: byoc-sealed-responder.mjs <channel.ts> <accept|refuse> <initiatorPubHex>\n');
  process.exit(2);
}

const emit = (value) => process.stdout.write(JSON.stringify(value) + '\n');
// Resolve secret-stream from the channel's own tree, not from this fixture's location.
const SecretStream = createRequire(channelPath)('@hyperswarm/secret-stream');
const { ByocSealedChannel } = await import(pathToFileURL(channelPath).href);

const keyPair = SecretStream.keyPair(Buffer.alloc(32, 9));
let channel;
channel = new ByocSealedChannel({
  initiator: false,
  localKeyPair: keyPair,
  verifyRemotePublicKey: async (remote) => mode === 'accept' && remote.toString('hex') === initiatorHex,
  sendPacket: (packet) => emit({ event: 'packet', packet }),
  onFrame: (frame) => {
    emit({ event: 'frame', frame });
    channel.send({ type: frame.type, echo: frame }).catch((error) => emit({ event: 'error', message: String(error?.message ?? error) }));
  },
  onError: (error) => emit({ event: 'error', message: String(error?.message ?? error) }),
});
channel.opened.then(
  () => {
    emit({ event: 'open' });
    channel.send({ type: 'hello', from: 'ts-responder' }).catch(() => {});
  },
  () => {},
);
emit({ event: 'ready', publicKey: keyPair.publicKey.toString('hex') });

let buffered = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buffered += chunk;
  let newline;
  while ((newline = buffered.indexOf('\n')) >= 0) {
    const line = buffered.slice(0, newline);
    buffered = buffered.slice(newline + 1);
    if (line.trim()) channel.receive(JSON.parse(line));
  }
});
process.stdin.on('end', () => {
  channel.close();
  process.exit(0);
});
