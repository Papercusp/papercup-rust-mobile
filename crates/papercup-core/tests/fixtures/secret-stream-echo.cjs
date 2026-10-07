// A real @hyperswarm/secret-stream RESPONDER on a localhost TCP port, for the live
// interop test in tests/noise_stream_interop.rs. On handshake it sends a greeting, then
// echoes each received message back prefixed with "echo:". It prints one JSON line
// {port, publicKey} on stdout and exits when stdin closes.
// NODE_PATH must contain @hyperswarm/secret-stream (e.g. the papercusp tree's node_modules).
'use strict'

const net = require('net')
const SecretStream = require('@hyperswarm/secret-stream')

const keyPair = SecretStream.keyPair(Buffer.alloc(32, 7))

const server = net.createServer((socket) => {
  const stream = new SecretStream(false, socket, { keyPair })
  stream.on('error', () => {})
  stream.on('open', () => stream.write(Buffer.from('hello-from-responder')))
  stream.on('data', (data) => stream.write(Buffer.concat([Buffer.from('echo:'), data])))
})

server.listen(0, '127.0.0.1', () => {
  const { port } = server.address()
  process.stdout.write(JSON.stringify({ port, publicKey: keyPair.publicKey.toString('hex') }) + '\n')
})

process.stdin.on('end', () => process.exit(0))
process.stdin.resume()
