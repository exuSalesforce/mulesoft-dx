#!/usr/bin/env node
// Local Remote Design Service (RDS) stub: answers /healthz and /v1/test-connection
// with the same wire contract HttpRemoteDesignServiceClient expects.
// Mirrors testConnection.integration.test.ts:110-148.
//
// Usage:
//   node rds_stub.mjs                    # picks a free port, writes it to stdout
//   PORT=8090 node rds_stub.mjs          # binds to PORT
//   RDS_STUB_LOG=1 node rds_stub.mjs     # logs each request line
//
// Lifecycle: the process answers SIGTERM/SIGINT cleanly; bash drivers can kill it
// by pid (written to {PID_FILE} when set).
import { createServer } from 'node:http';
import { writeFileSync, appendFileSync } from 'node:fs';

const port = Number(process.env.PORT ?? 0);
const pidFile = process.env.PID_FILE ?? null;
const portFile = process.env.PORT_FILE ?? null;
const logFile = process.env.LOG_FILE ?? null;
const verbose = process.env.RDS_STUB_LOG === '1';

const requests = [];

const log = (msg) => {
  if (verbose) process.stderr.write(`[rds-stub] ${msg}\n`);
  if (logFile) {
    try {
      appendFileSync(logFile, `${new Date().toISOString()} ${msg}\n`);
    } catch {}
  }
};

const server = createServer((req, res) => {
  const url = req.url ?? '/';
  const method = req.method ?? 'GET';

  if (method === 'GET' && url === '/healthz') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ready: true }));
    return;
  }

  if (method === 'GET' && url === '/_requests') {
    // Test affordance: read the request log without parsing the wire format.
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(requests));
    return;
  }

  if (method === 'POST' && url === '/v1/test-connection') {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      let parsed;
      try {
        parsed = JSON.parse(body || '{}');
      } catch (e) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ success: false, message: `bad JSON: ${e.message}` }));
        return;
      }
      requests.push({ at: new Date().toISOString(), body: parsed });
      log(`test-connection connector=${parsed.connector} provider=${parsed.providerName}`);

      // Simple deterministic policy:
      // - any field equal to "FAIL" → return failure
      // - missing username/password → failure
      // - otherwise success, echo a marker and the connector name
      const config = parsed.config ?? {};
      const valuesContainFail = Object.values(config).some(
        (v) => typeof v === 'string' && v.toUpperCase() === 'FAIL'
      );
      const hasCreds = !!config.username && !!config.password;
      const success = !valuesContainFail && hasCreds;
      const message = success
        ? `validated-by-stub-rds:${parsed.connector}:${parsed.providerName || 'default'}`
        : valuesContainFail
        ? 'rejected by stub: a config value was "FAIL"'
        : 'rejected by stub: missing required credentials';

      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ success, message }));
    });
    return;
  }

  res.writeHead(404, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ error: `no route: ${method} ${url}` }));
});

server.listen(port, '127.0.0.1', () => {
  const addr = server.address();
  const boundPort = typeof addr === 'object' && addr ? addr.port : port;
  const url = `http://127.0.0.1:${boundPort}`;
  process.stdout.write(`${url}\n`);
  log(`listening on ${url}`);
  if (portFile) writeFileSync(portFile, String(boundPort));
  if (pidFile) writeFileSync(pidFile, String(process.pid));
});

const shutdown = (sig) => {
  log(`received ${sig}, exiting`);
  server.close(() => process.exit(0));
};
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
