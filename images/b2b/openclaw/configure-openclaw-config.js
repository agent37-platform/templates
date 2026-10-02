'use strict';

// Lean OpenClaw config updater for the B2B Agents API v1 image. Runs at every
// boot and is idempotent. Three jobs:
//   1. Structural (always): enable the gateway's OpenResponses endpoint and set a
//      gateway auth token, so the co-located agent37-gateway can drive this
//      OpenClaw over POST /v1/responses. This is what the OpenClaw adapter needs
//      and is the one thing the B2C updater never did.
//   2. Managed (self-gating): starter credentials configure the managed model. The
//      managed image also enables the Brave/environment plugins and native Composio
//      MCP server; the clean base image has no managed integrations.
//   3. Control UI (self-gating): when CONTROL_UI_INSTANCE_ORIGIN is passed (the
//      instance's edge dashboard origin), make OpenClaw's Control UI on 18789
//      browser-usable behind the edge by dropping the gateway credential
//      (auth.mode='none') and allowing that origin. The edge signed URL / Bearer is
//      the only gate, the same way ttyd and File Browser sit behind it. Absent the
//      env (clean base run locally) the gateway stays locked to token auth.
//
// Still omits the B2C desktop machinery (visible browser, noVNC/x11): this image is
// headless. The gateway token is always set so the co-located adapter can authenticate
// over loopback; only the auth MODE relaxes (to 'none') when the Control UI is exposed
// through the edge.

const fs = require('node:fs');
const vm = require('node:vm');
// Copied next to this script from docker/shared/ by the image build (see Dockerfile).
const { fetchStarterCatalogModels } = require('./starter-catalog.js');

function asObject(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
}

function asNonEmptyString(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function parseBool(value, fallback) {
  const raw = String(value ?? '').trim().toLowerCase();
  if (raw === 'true' || raw === '1' || raw === 'yes' || raw === 'on') return true;
  if (raw === 'false' || raw === '0' || raw === 'no' || raw === 'off') return false;
  return fallback;
}

// OpenClaw may persist its config as JSON5 (comments / trailing commas), so fall
// back to a sandboxed object literal eval when strict JSON parsing fails.
function parseConfig(raw) {
  try {
    return JSON.parse(raw);
  } catch {
    const context = vm.createContext(Object.create(null));
    return new vm.Script(`(${raw})`).runInContext(context, { timeout: 250 });
  }
}

function appendUniquePath(list, value) {
  const arr = Array.isArray(list) ? list.slice() : [];
  if (!arr.includes(value)) arr.push(value);
  return arr;
}

const PLUGIN_DIR = '/usr/local/lib/openclaw/plugins';
const MANAGED_PLUGINS = [
  { id: 'agent37-environment', enabled: true },
  { id: 'agent37-brave', enabled: parseBool(process.env.MANAGED_PLUGIN_BRAVE_ENABLED, true) },
];

const STARTER_MODEL_NAME = 'Agent37 Default';

function enableManagedPlugin(config, pluginId) {
  config.plugins = asObject(config.plugins);
  config.plugins.enabled = true;
  config.plugins.entries = asObject(config.plugins.entries);
  const entry = asObject(config.plugins.entries[pluginId]);
  // OpenClaw 2026.8+ blocks conversation hooks (before_prompt_build) from non-bundled plugins
  // unless the entry opts in explicitly.
  config.plugins.entries[pluginId] = { ...entry, enabled: true, hooks: { ...asObject(entry.hooks), allowConversationAccess: true } };
  config.plugins.load = asObject(config.plugins.load);
  config.plugins.load.paths = appendUniquePath(config.plugins.load.paths, `${PLUGIN_DIR}/${pluginId}`);
}

function disableManagedPlugin(config, pluginId) {
  if (!config.plugins || typeof config.plugins !== 'object') return;
  if (config.plugins.entries && typeof config.plugins.entries === 'object') {
    delete config.plugins.entries[pluginId];
  }
  if (config.plugins.load && Array.isArray(config.plugins.load.paths)) {
    config.plugins.load.paths = config.plugins.load.paths.filter((p) => p !== `${PLUGIN_DIR}/${pluginId}`);
  }
}

// WhatsApp is the one channel plugin we bake: OpenClaw made it external in 2026.9, and it refuses
// to enable one that is missing from plugins.allow, which is where connecting WhatsApp dead-ends.
const WHATSAPP_PLUGIN_ROOT = `${PLUGIN_DIR}/whatsapp/node_modules/@openclaw/whatsapp`;

// A copy the customer installed themselves stays the one that loads: two sources for one plugin id
// is not a state we want a live gateway to resolve.
function whatsappInstalledInStateDir() {
  const stateDir = process.env.OPENCLAW_STATE_DIR || '/home/node/.openclaw';
  const roots = [];
  for (const [dir, suffix] of [
    [`${stateDir}/npm/projects`, '/node_modules/@openclaw/whatsapp'],
    [`${stateDir}/extensions`, ''],
  ]) {
    try {
      for (const entry of fs.readdirSync(dir)) roots.push(`${dir}/${entry}${suffix}`);
    } catch {}
  }
  // The manifest is what makes a directory the WhatsApp plugin. Matching on the name alone would
  // let any leftover with the word in it withdraw the baked path and leave the agent with none.
  return roots.some((root) => {
    try {
      return JSON.parse(fs.readFileSync(`${root}/openclaw.plugin.json`, 'utf8')).id === 'whatsapp';
    } catch {
      return false;
    }
  });
}

function enableBakedWhatsappPlugin(config) {
  if (!fs.existsSync(`${WHATSAPP_PLUGIN_ROOT}/openclaw.plugin.json`)) return false;
  config.plugins = asObject(config.plugins);
  // Plugins switched off wholesale is an operator decision about every plugin, not about this one.
  if (config.plugins.enabled === false) return false;
  config.plugins.enabled = true;
  config.plugins.entries = asObject(config.plugins.entries);
  config.plugins.entries.whatsapp = { ...asObject(config.plugins.entries.whatsapp), enabled: true };
  // An absent allow list allows every plugin, so it is only ever appended to: authoring one here
  // would silently restrict everything else the agent loads.
  const allow = config.plugins.allow;
  if (Array.isArray(allow) && allow.length && !allow.includes('whatsapp')) {
    config.plugins.allow = [...allow, 'whatsapp'];
  }
  // The customer's own copy wins, and the baked path is withdrawn rather than left beside it: an
  // instance that took the baked path first would otherwise keep both sources for one plugin id.
  config.plugins.load = asObject(config.plugins.load);
  const loadPaths = Array.isArray(config.plugins.load.paths) ? config.plugins.load.paths : [];
  config.plugins.load.paths = whatsappInstalledInStateDir()
    ? loadPaths.filter((path) => path !== WHATSAPP_PLUGIN_ROOT)
    : appendUniquePath(loadPaths, WHATSAPP_PLUGIN_ROOT);
  return true;
}

const configPath = process.env.CONFIG_PATH || '';
const metaPath = process.env.META_PATH || '';
const generatedGatewayToken = asNonEmptyString(process.env.GENERATED_GATEWAY_TOKEN);
const starterProviderId = process.env.STARTER_PROVIDER_ID || 'agent37';
const starterModelId = process.env.STARTER_MODEL_ID || 'default';
const starterProxyUrl = asNonEmptyString(process.env.STARTER_PROXY_URL);
const starterToken = asNonEmptyString(process.env.STARTER_TOKEN);
const hasStarterProvider = Boolean(starterProxyUrl && starterToken);
const managedIntegrationsAvailable = parseBool(process.env.AGENT37_MANAGED_INTEGRATIONS, false);
const starterModel = `${starterProviderId}/${starterModelId}`;
// The instance's edge dashboard origin (e.g. https://<id>-18789.agent37.app). When set, the
// Control UI on 18789 is opened up for that origin so it is usable in a browser behind the edge.
const controlUiOrigin = asNonEmptyString(process.env.CONTROL_UI_INSTANCE_ORIGIN).replace(/\/+$/, '');

if (!configPath) {
  console.error('CONFIG_PARSE_ERROR CONFIG_PATH is required');
  process.exit(2);
}

let config = {};
try {
  config = parseConfig(fs.readFileSync(configPath, 'utf8'));
} catch (error) {
  console.error('CONFIG_PARSE_ERROR', error instanceof Error ? error.message : String(error));
  process.exit(2);
}
if (!config || typeof config !== 'object' || Array.isArray(config)) {
  config = {};
}

// 0. Heal stale plugin refs carried over from another image (the Phase 2 migration outage:
// B2C configs reference /usr/local/lib/openclaw/plugins/agent37-browser, which this image
// does not ship, and OpenClaw refuses to boot on a load path that doesn't exist). Only
// paths under the baked PLUGIN_DIR are candidates — customer paths (incl. ~/ syntax,
// which fs.existsSync can't judge) are never touched. A stripped path drops its
// entries/allow refs too; the managed-plugin reconcile below re-adds what this image ships.
{
  const plugins = asObject(config.plugins);
  const load = asObject(plugins.load);
  if (Array.isArray(load.paths)) {
    const missing = load.paths.filter((p) => typeof p === 'string' && p.startsWith(PLUGIN_DIR + '/') && !fs.existsSync(p));
    if (missing.length > 0) {
      load.paths = load.paths.filter((p) => !missing.includes(p));
      for (const stale of missing) {
        const pluginId = String(stale).split('/').filter(Boolean).pop();
        if (plugins.entries && typeof plugins.entries === 'object') delete plugins.entries[pluginId];
        if (Array.isArray(plugins.allow)) plugins.allow = plugins.allow.filter((id) => id !== pluginId);
        console.error(`[configure-openclaw-config] stripped missing plugin path ${stale}`);
      }
    }
  }
}

// 1. Structural: gateway auth + the OpenResponses endpoint the adapter calls. The token always
// stays set so the co-located agent37-gateway adapter can authenticate over loopback; the auth
// MODE is decided below based on whether this instance's Control UI is exposed through the edge.
config.gateway = asObject(config.gateway);
config.gateway.auth = asObject(config.gateway.auth);
const gatewayToken = asNonEmptyString(config.gateway.auth.token) || generatedGatewayToken;
config.gateway.auth.token = gatewayToken;
config.gateway.http = asObject(config.gateway.http);
config.gateway.http.endpoints = asObject(config.gateway.http.endpoints);
config.gateway.http.endpoints.responses = asObject(config.gateway.http.endpoints.responses);
config.gateway.http.endpoints.responses.enabled = true;

// Control UI (OpenClaw dashboard on 18789) behind the edge: when the platform passes the instance's
// dashboard origin, 18789 (Control UI + responses) is reachable only through the authenticated edge
// (signed URL / Bearer) -- the same gate ttyd and File Browser already sit behind. OpenClaw's token
// gate can't be satisfied by a browser here: a token-mode gateway makes the Control UI demand a
// hand-typed token ("Auth required"). Drop the gateway credential (auth.mode='none') and let the
// edge be the only gate, mirroring the Hermes dashboard decision in #359; with auth.mode='none'
// OpenClaw also skips Control UI device pairing (the old dangerouslyDisableDeviceAuth key is retired
// since 2026.8 and is removed here so doctor stops flagging it). The loopback adapter still works:
// it sends the Bearer token only when set, which 'none' simply ignores. No origin (clean base run
// locally) keeps the gateway locked to token auth.
//
// IMPORTANT: auth.mode='none' is ONLY safe because the entrypoint binds the gateway to LOOPBACK and
// fronts it with a Host-rewriting relay (start_openclaw_relay). OpenClaw REFUSES a non-loopback
// ('--bind lan') bind without a token/password, so a lan bind + auth.mode='none' makes the whole
// gateway fail to start (container_unreachable). Keep the loopback bind and this mode in lockstep.
if (controlUiOrigin) {
  config.gateway.auth.mode = 'none';
  config.gateway.controlUi = asObject(config.gateway.controlUi);
  delete config.gateway.controlUi.dangerouslyDisableDeviceAuth;
  config.gateway.controlUi.allowedOrigins = appendUniquePath(config.gateway.controlUi.allowedOrigins, controlUiOrigin);
} else {
  config.gateway.auth.mode = 'token';
}

// Headless browser: no display in this image.
config.browser = asObject(config.browser);
if (typeof config.browser.headless !== 'boolean') config.browser.headless = true;
if (typeof config.browser.noSandbox !== 'boolean') config.browser.noSandbox = true;

config.agents = asObject(config.agents);
config.agents.defaults = asObject(config.agents.defaults);
config.agents.defaults.heartbeat = asObject(config.agents.defaults.heartbeat);
if (Object.keys(config.agents.defaults.heartbeat).length === 0) {
  config.agents.defaults.heartbeat = { every: '0m' };
}

// 2. Managed model injection (only when the platform passes starter credentials).
let previousStarterModels = [];
if (hasStarterProvider) {
  config.models = asObject(config.models);
  config.models.mode = 'merge';
  config.models.providers = asObject(config.models.providers);
  previousStarterModels = (asObject(config.models.providers[starterProviderId]).models || []).filter(
    (m) => m && typeof m === 'object' && asNonEmptyString(m.id) && m.id !== starterModelId
  );
  // auth:'api-key' makes this apiKey win over OpenClaw's stored auth profiles (2026.8+ prefers
  // the profile store otherwise), which matters because the token rotates on every recreate.
  config.models.providers[starterProviderId] = {
    baseUrl: starterProxyUrl,
    apiKey: starterToken,
    auth: 'api-key',
    api: 'openai-completions',
    models: [{ id: starterModelId, name: STARTER_MODEL_NAME, input: ['text', 'image'] }],
  };
  config.agents.defaults.model = typeof config.agents.defaults.model === 'string'
    ? { primary: config.agents.defaults.model }
    : asObject(config.agents.defaults.model);
  if (!asNonEmptyString(config.agents.defaults.model.primary)) {
    config.agents.defaults.model.primary = starterModel;
  }
  // Model visibility: OpenClaw restricts the picker (and blocks selecting) to the
  // allowlist the moment ANY exact ref is present, and provider onboarding writes one
  // exact ref per provider a customer connects (ChatGPT/Codex, Claude, Grok...). Left
  // alone that collapses the picker to one model per provider. Rewrite the allowlist to
  // a per-provider wildcard so every connected provider lists all its models and all
  // stay selectable. Providers are discovered from the current allowlists (onboarding
  // leaves one entry per connected provider), the configured providers, and the
  // starter provider. A provider connected at runtime re-collapses to its single
  // onboarded model until the next boot re-expands it. Since 2026.8 the restriction
  // lives in agents.defaults.modelPolicy.allow (agents.defaults.models is metadata
  // once OpenClaw has migrated a config), so both are written.
  const providerWildcards = new Set([starterProviderId]);
  const legacyAllow = Object.keys(asObject(config.agents.defaults.models));
  const policyAllow = asObject(config.agents.defaults.modelPolicy).allow;
  for (const key of [...legacyAllow, ...(Array.isArray(policyAllow) ? policyAllow : [])]) {
    const provider = String(key).split('/')[0].trim();
    if (provider && provider !== '*') providerWildcards.add(provider);
  }
  for (const key of Object.keys(asObject(config.models.providers))) {
    if (asNonEmptyString(key)) providerWildcards.add(key);
  }
  config.agents.defaults.models = {};
  for (const provider of providerWildcards) {
    config.agents.defaults.models[`${provider}/*`] = {};
  }
  config.agents.defaults.modelPolicy = { allow: [...providerWildcards].map((provider) => `${provider}/*`) };
}

// Managed plugins: enable each only when its dir is baked (full image) and the
// platform leaves it on; reconcile (disable) otherwise so a flag flip takes effect.
const activePlugins = [];
for (const plugin of MANAGED_PLUGINS) {
  const present = fs.existsSync(`${PLUGIN_DIR}/${plugin.id}`);
  if (present && plugin.enabled) {
    enableManagedPlugin(config, plugin.id);
    activePlugins.push(plugin.id);
  } else {
    disableManagedPlugin(config, plugin.id);
  }
}

if (enableBakedWhatsappPlugin(config)) activePlugins.push('whatsapp');

// Configure the native Composio MCP server with starter-token authentication. Remove managed
// plugin entries so persisted config exposes Composio through one path.
disableManagedPlugin(config, 'agent37-composio');
const composioMcpEnabled = parseBool(process.env.MANAGED_PLUGIN_COMPOSIO_ENABLED, true);
const composioMcpUrl = asNonEmptyString(process.env.AGENT37_COMPOSIO_MCP_URL);
const composioMcpConfigured = managedIntegrationsAvailable && composioMcpEnabled && hasStarterProvider && composioMcpUrl;
if (composioMcpConfigured) {
  config.mcp = asObject(config.mcp);
  config.mcp.servers = asObject(config.mcp.servers);
  config.mcp.servers.composio = {
    url: composioMcpUrl,
    transport: 'streamable-http',
    headers: { Authorization: `Bearer ${starterToken}` },
  };
} else if (config.mcp && typeof config.mcp === 'object' && config.mcp.servers && typeof config.mcp.servers === 'object') {
  delete config.mcp.servers.composio;
}

// Paid tools: one metered pay-per-call server on the same managed proxy and starter token. The
// control plane injects the URL only where paid tools apply, so its absence is the off switch.
const perfloMcpEnabled = parseBool(process.env.MANAGED_PLUGIN_PERFLO_ENABLED, true);
const perfloMcpUrl = asNonEmptyString(process.env.AGENT37_PERFLO_MCP_URL);
const perfloMcpConfigured = managedIntegrationsAvailable && perfloMcpEnabled && hasStarterProvider && perfloMcpUrl;
if (perfloMcpConfigured) {
  config.mcp = asObject(config.mcp);
  config.mcp.servers = asObject(config.mcp.servers);
  config.mcp.servers.perflo = {
    url: perfloMcpUrl,
    transport: 'streamable-http',
    headers: { Authorization: `Bearer ${starterToken}` },
  };
} else if (config.mcp && typeof config.mcp === 'object' && config.mcp.servers && typeof config.mcp.servers === 'object') {
  delete config.mcp.servers.perflo;
}

// The managed proxy lists the full paid catalog at /v1/models; bake it into the
// provider entry so the OpenClaw picker offers every model, not just the default.
// On failure, last boot's baked catalog is kept (default-only when there is none).
async function main() {
  if (hasStarterProvider) {
    const catalogModels = await fetchStarterCatalogModels(starterProxyUrl, starterToken, starterModelId);
    if (catalogModels) {
      config.models.providers[starterProviderId].models.push(...catalogModels);
      console.error(`[configure-openclaw-config] starter catalog baked: ${catalogModels.length} models`);
    } else if (previousStarterModels.length > 0) {
      // One failed fetch must not shrink the picker to the default-only entry
      // until the next boot: keep what the last successful boot baked.
      config.models.providers[starterProviderId].models.push(...previousStarterModels);
      console.error(
        `[configure-openclaw-config] starter catalog unavailable; kept ${previousStarterModels.length} previously baked models`
      );
    } else {
      console.error('[configure-openclaw-config] starter catalog unavailable; picker shows default only');
    }
  }

  if (metaPath) {
    fs.writeFileSync(
      metaPath,
      `${JSON.stringify({
        responsesEndpointEnabled: true,
        starterProviderConfigured: hasStarterProvider,
        controlUiOrigin: controlUiOrigin || null,
        activePlugins,
        composioMcpConfigured,
        perfloMcpConfigured,
      }, null, 2)}\n`
    );
  }

  process.stdout.write(`${JSON.stringify(config, null, 2)}\n`);
}

main().catch((error) => {
  console.error('CONFIG_PARSE_ERROR', error instanceof Error ? error.message : String(error));
  process.exit(2);
});
