'use strict';
// L7 reverse proxy for a loopback-bound upstream (originally the Hermes dashboard;
// reused for the OpenClaw gateway on the b2b/openclaw image). Hermes binds the dashboard to
// loopback (which exempts it from the non-loopback auth gate added in
// NousResearch/hermes-agent PR #50551, where `--insecure` became a no-op) but
// then enforces a Host allowlist (DNS-rebinding defence, GHSA-ppp5-vxwm-4cf7)
// that only accepts localhost/127.0.0.1/::1. Our edge forwards the public Host
// (`{id}-9119.agent37.app`), so we rewrite Host to the loopback target before
// forwarding. The edge signed-URL / forward-auth stays the only real gate.
//
// This is a workaround: as of 2026-06-25 there is no native config to expose the
// dashboard on a custom host without registering a Hermes auth provider. Track the
// upstream feature that would let us delete this file -- a `dashboard.allowed_hosts`
// setting (bind loopback + allowlist our host, no Host rewrite needed):
//   feature request: NousResearch/hermes-agent#34390 (orig #18415, canonical PR #20136)
//   our Docker break: NousResearch/hermes-agent#49567
// When that ships and we pin a version with it, set allowed_hosts and remove this.
//
// HTTP + WebSocket, no dependencies (built-in http + net only).
const http = require('http');
const net = require('net');

const LISTEN_PORT = Number(process.env.RELAY_LISTEN_PORT || 9119);
const TARGET_PORT = Number(process.env.RELAY_TARGET_PORT || 19119);
const TARGET_HOST = '127.0.0.1';
const HOST_VALUE = `${TARGET_HOST}:${TARGET_PORT}`;
// Some upstreams (Hermes' dashboard, GHSA-ppp5-vxwm-4cf7 DNS-rebind guard) also reject a non-loopback
// Origin on the WebSocket upgrade (`_ws_host_origin_reason` → origin_mismatch), not just the Host
// header. When RELAY_REWRITE_ORIGIN is set we rewrite a present Origin to the loopback target so the
// upgrade is accepted. Leave it OFF for upstreams that allowlist the real public origin themselves
// (e.g. OpenClaw's gateway.controlUi.allowedOrigins), which need to see the genuine browser Origin.
const REWRITE_ORIGIN = process.env.RELAY_REWRITE_ORIGIN === '1';
const ORIGIN_VALUE = `http://${HOST_VALUE}`;

function log(...args) {
  console.log(new Date().toISOString(), '[dashboard-relay]', ...args);
}

// Rewrite Host (always) and, when enabled, a present Origin -> the loopback target. Proxy
// attribution headers are dropped: OpenClaw 2026.8+ rejects a loopback request that still
// carries forwarded / x-real-ip / x-forwarded-* unless gateway.trustedProxies names the
// sender, so the relay presents itself as a plain local client.
function rewriteHeaders(reqHeaders) {
  const headers = { ...reqHeaders, host: HOST_VALUE };
  for (const name of Object.keys(headers)) {
    if (name === 'forwarded' || name === 'x-real-ip' || name.startsWith('x-forwarded-') || name.startsWith('tailscale-')) {
      delete headers[name];
    }
  }
  if (REWRITE_ORIGIN && headers.origin) headers.origin = ORIGIN_VALUE;
  return headers;
}

const server = http.createServer((req, res) => {
  const headers = rewriteHeaders(req.headers);
  const upstream = http.request(
    { host: TARGET_HOST, port: TARGET_PORT, method: req.method, path: req.url, headers },
    (ures) => {
      res.writeHead(ures.statusCode || 502, ures.headers);
      ures.pipe(res);
    }
  );
  upstream.on('error', () => {
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' });
    res.end('relay upstream error');
  });
  req.pipe(upstream);
});

// WebSocket / protocol upgrades: raw TCP splice with the Host header rewritten.
server.on('upgrade', (req, socket, head) => {
  const upstream = net.connect(TARGET_PORT, TARGET_HOST, () => {
    const headers = rewriteHeaders(req.headers);
    const lines = [`${req.method} ${req.url} HTTP/1.1`];
    for (const [k, v] of Object.entries(headers)) {
      if (Array.isArray(v)) for (const vv of v) lines.push(`${k}: ${vv}`);
      else lines.push(`${k}: ${v}`);
    }
    upstream.write(lines.join('\r\n') + '\r\n\r\n');
    if (head && head.length) upstream.write(head);
    socket.pipe(upstream);
    upstream.pipe(socket);
  });
  upstream.on('error', () => socket.destroy());
  socket.on('error', () => upstream.destroy());
});

server.on('clientError', (_err, socket) => {
  try { socket.end('HTTP/1.1 400 Bad Request\r\n\r\n'); } catch { /* noop */ }
});

server.listen(LISTEN_PORT, '0.0.0.0', () => log(`listening 0.0.0.0:${LISTEN_PORT} -> ${HOST_VALUE} (Host rewritten${REWRITE_ORIGIN ? ', Origin rewritten' : ''})`));
