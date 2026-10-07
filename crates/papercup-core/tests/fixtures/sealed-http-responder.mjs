// Maintained interop fixture: real TS Noise responder + OperatorHttpChannel,
// real WebSocket boundary, injected VM fetch only. No portal plaintext path.
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import http from 'node:http';
const [root, mode = 'normal'] = process.argv.slice(2);
const channelPath = `${root}/packages/operator-core/lib/workspace-host/byoc-sealed-channel.ts`;
const require = createRequire(channelPath);
const { WebSocketServer } = require('ws');
const SecretStream = require('@hyperswarm/secret-stream');
const { ByocSealedChannel } = await import(pathToFileURL(channelPath));
const { OperatorHttpChannel } = await import(pathToFileURL(`${root}/packages/operator-core/lib/workspace-host/hosted-operator-http.ts`));
const key = SecretStream.keyPair(Buffer.alloc(32, 9));
const phone = SecretStream.keyPair(Buffer.alloc(32, 0x31));
const server = http.createServer((_req, res) => {
  res.writeHead(500); res.end('plaintext path must never be used');
});
const sockets = new WebSocketServer({ noServer: true, maxPayload: 512 * 1024 });
server.on('upgrade', (req, socket, head) => {
  if (req.url !== '/api/workspaces/ws_1/api/device/sealed' || req.headers.authorization) {
    socket.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n'); return;
  }
  if (mode === 'offline') {
    socket.end('HTTP/1.1 503 Service Unavailable\r\nRetry-After: 7\r\nContent-Length: 0\r\n\r\n'); return;
  }
  sockets.handleUpgrade(req, socket, head, ws => sockets.emit('connection', ws));
});
sockets.on('connection', ws => {
  let sealed;
  let maximumPacketBytes = 0;
  let uploadFragments = 0;
  const controlPackets = [];
  const pipe = new OperatorHttpChannel({
    origin: 'http://vm.test', audit: () => {}, maxChunkedRequestBodyBytes: 32 * 1024 * 1024,
    decideRoute: (method, path) => ({ ok: true, method, path, surface: 'device-test', awaitsRouteBudget: false }),
    requestHeaders: headers => headers,
    send: frame => {
      if (mode === 'bad-id') frame = { ...frame, requestId: 'another-request' };
      sealed.send(frame).catch(() => ws.close());
    },
    fetch: async (url, init) => {
      if (url.endsWith('/api/device/pair')) {
        const body = JSON.parse(Buffer.from(init.body).toString());
        if (init.headers.authorization || body.noisePublicKey !== phone.publicKey.toString('base64')) {
          return Response.json({error:'pair_contract_mismatch'}, {status:400});
        }
        return Response.json({deviceToken:'test-jwt',deviceId:'did-sealed',desktopHost:'host:3070',workspaceId:'ws_1',noiseKey:key.publicKey.toString('base64')});
      }
      if (mode === 'unauthorized') return Response.json({error:'device_revoked'}, {status:403});
      if (mode === 'relay-refused') return Response.json({error:'byoc_plaintext_relay_refused'}, {status:403});
      if (url.includes('/rest-query')) return Response.json({version:'fixture-1',rows:{
        authorization:init.headers.authorization, maximumPacketBytes, uploadFragments,
        plaintextCanaryFound:controlPackets.some(p=>p.includes('CANARY-private-🌍') || p.includes('test-jwt')),
      }});
      if (url.endsWith('/operator/converse')) {
        const body = JSON.parse(Buffer.from(init.body).toString());
        if (!body.text.startsWith('CANARY-private-🌍') || init.headers.authorization !== 'Bearer test-jwt'
          || controlPackets.some(p => p.includes('CANARY-private-🌍') || p.includes('test-jwt'))
          || maximumPacketBytes > 512 * 1024) {
          return Response.json({error:'upload_corrupted'}, {status:400});
        }
        const encode = new TextEncoder();
        return new Response(new ReadableStream({
          start(controller) {
            const bytes = encode.encode('event: delta\r\ndata: {"text":"héllo 🌍"}\r\n\r\n');
            // Every byte crosses separately, including UTF-8 and CRLF boundaries.
            for (const byte of bytes) controller.enqueue(Uint8Array.of(byte));
            controller.enqueue(encode.encode(`event: delta\ndata: ${JSON.stringify({text:`chunks=${uploadFragments}`})}\n\n`));
            controller.enqueue(encode.encode('event: done\ndata: {}\n\n'));
            controller.close();
          }
        }), {headers:{'content-type':'text/event-stream'}});
      }
      return Response.json({harnesses:[]});
    },
  });
  sealed = new ByocSealedChannel({
    initiator: false, localKeyPair:key, expectedRemotePublicKey:phone.publicKey,
    sendPacket: packet => ws.send(JSON.stringify(packet)),
    onFrame: frame => { if (frame.type === 'http.body') uploadFragments++; void pipe.accept(frame.type, frame); },
    onError: () => ws.close(),
  });
  sealed.opened.catch(() => {});
  // HostedWorkspaceSessionHost emits readiness inside Noise before any
  // response. The real phone must accept this channel-level control frame.
  sealed.opened.then(() => sealed.send({type:'http.ready'})).catch(() => {});
  ws.on('message', bytes => {
    maximumPacketBytes = Math.max(maximumPacketBytes, bytes.length);
    controlPackets.push(bytes.toString());
    sealed.receive(JSON.parse(bytes));
  });
  ws.on('close', () => { pipe.close(); sealed.close(); });
});
server.listen(0, '127.0.0.1', () => process.stdout.write(JSON.stringify({
  base:`http://127.0.0.1:${server.address().port}/api/workspaces/ws_1`,
  publicKey:Array.from(key.publicKey),
}) + '\n'));
