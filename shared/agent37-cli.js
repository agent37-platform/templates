#!/usr/bin/env node
'use strict';

// Platform CLI for a hosted agent, talking to the starter endpoints with the instance's own
// starter token. Two surfaces:
//   expose/unexpose/list-exposed  public_port records (consumer instances only; a B2B token
//                                 gets 403 from the endpoint). In the OpenClaw image this is
//                                 also installed as `exposed-port` with the B2C registry
//                                 CLI's argv dialect: list / add --port [--label] / remove --port.
//   cron add|list|update|remove|runs   scheduled prompts, on both products.

const PORTS_PATH = '/api/starter/public-ports';
const CRONS_PATH = '/api/starter/crons';
const TIMEOUT_MS = 15000;

function fail(code, message) {
  process.stderr.write(JSON.stringify({ error: { code, message } }) + '\n');
  process.exit(1);
}

function starterToken() {
  const token = (process.env.AGENT37_STARTER_TOKEN || process.env.OPENCLAW_STARTER_TOKEN || '').trim();
  if (!token) fail('MISSING_TOKEN', 'No starter token in the environment (AGENT37_STARTER_TOKEN).');
  return token;
}

function apiOrigin() {
  return (process.env.AGENT37_STARTER_API_ORIGIN || 'https://www.agent37.com').trim().replace(/\/+$/, '');
}

async function request(method, query, body) {
  return call(method, `${PORTS_PATH}${query || ''}`, body, portStatusToCode);
}

async function call(method, path, body, codeFor) {
  const url = `${apiOrigin()}${path}`;
  let res;
  try {
    res = await fetch(url, {
      method,
      headers: {
        Authorization: `Bearer ${starterToken()}`,
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (err) {
    fail('NETWORK_ERROR', `Could not reach ${url}: ${err && err.message ? err.message : String(err)}`);
  }
  let payload = null;
  try {
    payload = await res.json();
  } catch {
    // fall through with null payload
  }
  if (!res.ok) {
    const message = (payload && payload.error && payload.error.message) || `HTTP ${res.status}`;
    fail(codeFor(res.status, message, payload), message);
  }
  return payload;
}

// Ports keep their own port-flavoured codes: they are the contract the guidance and the legacy
// registry dialect were written against.
function portStatusToCode(status, message) {
  if (status === 400) return /reserved/i.test(message) ? 'RESERVED_PORT' : 'INVALID_PORT';
  if (status === 401 || status === 403) return 'AUTH_FAILED';
  if (status === 404) return 'PORT_NOT_EXPOSED';
  if (status === 409) return 'PORT_ALREADY_EXPOSED';
  return 'HTTP_ERROR';
}

// Schedules hand back the API's own error code (`not_found`, `invalid_request`, ...), so a
// caller sees what actually went wrong rather than a port code.
function cronStatusToCode(status, message, payload) {
  const code = payload && payload.error && payload.error.code;
  return code ? String(code).toUpperCase() : 'HTTP_ERROR';
}

function parsePort(raw) {
  const port = Number(raw);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    fail('INVALID_PORT', `Port must be an integer between 1 and 65535, got ${raw}`);
  }
  return port;
}

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg.startsWith('--')) {
      const key = arg.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) {
        out[key] = true;
      } else {
        out[key] = next;
        i++;
      }
    } else {
      out._.push(arg);
    }
  }
  return out;
}

// Legacy entries carried slug/createdAt; keep those keys so old prompts and parsers hold.
function toEntry(apiEntry) {
  const entry = {
    port: apiEntry.port,
    url: apiEntry.url,
    slug: apiEntry.url ? new URL(apiEntry.url).hostname.split('.')[0] : null,
    createdAt: apiEntry.created ?? null,
  };
  if (apiEntry.label) entry.label = apiEntry.label;
  return entry;
}

function print(value) {
  process.stdout.write(JSON.stringify(value) + '\n');
}

async function cmdExpose(portRaw, label) {
  const port = parsePort(portRaw);
  const body = { port };
  if (label !== undefined && label !== true && String(label).trim()) body.label = String(label).trim();
  const created = await request('POST', '', body);
  print(toEntry(created));
}

async function cmdUnexpose(portRaw) {
  const port = parsePort(portRaw);
  const removed = await request('DELETE', `?port=${port}`);
  print(removed);
}

async function cmdList() {
  const listed = await request('GET', '');
  print({ exposedPorts: (listed.data || []).map(toEntry) });
}

// Legacy dialect mirrors the old CLI's contract: add/remove echo the full list afterwards.
async function cmdLegacyAdd(args) {
  if (args.port === undefined || args.port === true) fail('MISSING_PORT', 'Missing required argument --port');
  const port = parsePort(args.port);
  const body = { port };
  if (args.label !== undefined && args.label !== true && String(args.label).trim()) body.label = String(args.label).trim();
  await request('POST', '', body);
  await cmdList();
}

async function cmdLegacyRemove(args) {
  if (args.port === undefined || args.port === true) fail('MISSING_PORT', 'Missing required argument --port');
  const port = parsePort(args.port);
  await request('DELETE', `?port=${port}`);
  await cmdList();
}


// --- Schedules -------------------------------------------------------------------------
// A platform cron wakes the instance to deliver its prompt; a crontab inside the container
// cannot, and stops firing the moment the instance sleeps.

function cronBody(args, { requireFields }) {
  const body = {};
  for (const field of ['prompt', 'schedule', 'timezone', 'name']) {
    const value = args[field];
    if (value === undefined) continue;
    // A flag with nothing after it would otherwise drop out of the body and read as success.
    if (value === true) fail('MISSING_ARGUMENT', `--${field} needs a value`);
    body[field] = String(value);
  }
  if (args.enabled !== undefined) body.enabled = String(args.enabled) !== 'false';
  if (args.pause) body.enabled = false;
  if (args.resume) body.enabled = true;
  for (const field of requireFields) {
    if (body[field] === undefined) fail('MISSING_ARGUMENT', `Missing required argument --${field}`);
  }
  return body;
}

async function cmdCronAdd(args) {
  const body = cronBody(args, { requireFields: ['prompt', 'schedule'] });
  print(await call('POST', CRONS_PATH, body, cronStatusToCode));
}

async function cmdCronList() {
  print({ crons: (await call('GET', CRONS_PATH, undefined, cronStatusToCode)).data || [] });
}

async function cmdCronUpdate(args) {
  const id = cronId(args);
  const body = cronBody(args, { requireFields: [] });
  if (Object.keys(body).length === 0) {
    fail('MISSING_ARGUMENT', 'Nothing to update: pass --prompt, --schedule, --timezone, --name, or --pause|--resume');
  }
  print(await call('PATCH', `${CRONS_PATH}/${encodeURIComponent(id)}`, body, cronStatusToCode));
}

async function cmdCronRemove(args) {
  print(await call('DELETE', `${CRONS_PATH}/${encodeURIComponent(cronId(args))}`, undefined, cronStatusToCode));
}

async function cmdCronRuns(args) {
  const listed = await call('GET', `${CRONS_PATH}/${encodeURIComponent(cronId(args))}/runs`, undefined, cronStatusToCode);
  print({ runs: listed.data || [] });
}

function cronId(args) {
  const id = args.id !== undefined && args.id !== true ? String(args.id) : args._[0];
  if (!id) fail('MISSING_ARGUMENT', 'Missing the schedule id (positional, or --id)');
  return id;
}

async function cmdCron(argv) {
  const verb = argv[0];
  const args = parseArgs(argv.slice(1));
  switch (verb) {
    case 'add':
      return cmdCronAdd(args);
    case 'list':
      return cmdCronList();
    case 'update':
      return cmdCronUpdate(args);
    case 'remove':
      return cmdCronRemove(args);
    case 'runs':
      return cmdCronRuns(args);
    default:
      return fail(
        'UNKNOWN_SUBCOMMAND',
        'Usage: agent37 cron add --schedule "0 9 * * 1-5" --prompt "..." [--name X] [--timezone America/New_York] | '
          + 'agent37 cron list | agent37 cron update <id> [--prompt ...] [--schedule ...] [--pause|--resume] | '
          + 'agent37 cron remove <id> | agent37 cron runs <id>'
      );
  }
}

function usage() {
  fail(
    'UNKNOWN_SUBCOMMAND',
    'Usage: agent37 expose <port> [--label "Name"] | agent37 unexpose <port> | agent37 list-exposed | agent37 cron <add|list|update|remove|runs>'
  );
}

async function main() {
  const argv = process.argv.slice(2);
  const subcommand = argv[0];
  const args = parseArgs(argv.slice(1));
  switch (subcommand) {
    case 'expose':
      if (!args._[0]) fail('MISSING_PORT', 'Usage: agent37 expose <port> [--label "Name"]');
      return cmdExpose(args._[0], args.label);
    case 'unexpose':
      if (!args._[0]) fail('MISSING_PORT', 'Usage: agent37 unexpose <port>');
      return cmdUnexpose(args._[0]);
    case 'list-exposed':
    case 'list':
      return cmdList();
    case 'add':
      return cmdLegacyAdd(args);
    case 'remove':
      return cmdLegacyRemove(args);
    case 'cron':
      return cmdCron(argv.slice(1));
    default:
      return usage();
  }
}

main().catch((err) => {
  fail('UNEXPECTED_ERROR', err && err.message ? err.message : String(err));
});
