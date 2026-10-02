const DEFAULT_TIMEOUT_MS = 30_000;
const SEARCH_OPTIONAL_FIELDS = ['country', 'searchLang', 'uiLang', 'safesearch', 'freshness'];
const BRAVE_PROXY_URL_ENV = 'OPENCLAW_BRAVE_PROXY_URL';
const CANONICAL_BRAVE_PROXY_URL_ENV = 'AGENT37_BRAVE_PROXY_URL';
// The platform injects the URL above. This is only the floor for an image booted without it;
// it is never derived from another managed service's URL (that mismatch broke Brave for a
// month when the LLM proxy moved hosts).
const DEFAULT_BRAVE_PROXY_URL = 'https://api.agent37.com/search/brave';

function readEnv(name) {
  const value = process.env[name];
  if (typeof value !== 'string') return '';
  return value.trim();
}

function resolveBraveProxyUrl() {
  return readEnv(BRAVE_PROXY_URL_ENV) || readEnv(CANONICAL_BRAVE_PROXY_URL_ENV) || DEFAULT_BRAVE_PROXY_URL;
}

function getRuntimeConfig() {
  const proxyUrl = resolveBraveProxyUrl();
  const starterToken = readEnv('OPENCLAW_STARTER_TOKEN');
  if (!proxyUrl || !starterToken) return null;
  return { proxyUrl, starterToken };
}

function parseJson(raw) {
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function asObject(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
}

function floorFiniteNumber(value) {
  if (typeof value !== 'number' || !Number.isFinite(value)) return null;
  return Math.floor(value);
}

function normalizeTimeoutMs(value) {
  const normalized = floorFiniteNumber(value);
  if (normalized === null || value <= 0) return DEFAULT_TIMEOUT_MS;
  return Math.min(normalized, 120_000);
}

function normalizeCount(value) {
  const normalized = floorFiniteNumber(value);
  if (normalized === null) return undefined;
  return Math.max(1, Math.min(20, normalized));
}

function trimmedString(value) {
  if (typeof value !== 'string') return '';
  return value.trim();
}

function optionalString(value) {
  const trimmed = trimmedString(value);
  return trimmed || undefined;
}

function normalizeSearchPayload(args) {
  const query = optionalString(args?.query);
  if (!query) {
    throw new Error('Missing required parameter: query');
  }

  const payload = { query };

  const count = normalizeCount(args?.count);
  if (typeof count === 'number') payload.count = count;

  for (const key of SEARCH_OPTIONAL_FIELDS) {
    const value = optionalString(args?.[key]);
    if (value) payload[key] = value;
  }

  return payload;
}

function normalizeSearchResults(result) {
  const payload = asObject(result);
  const web = asObject(payload.web);
  const entries = Array.isArray(web.results) ? web.results : [];

  const results = entries.map((entry) => {
    const item = asObject(entry);
    return {
      title: typeof item.title === 'string' ? item.title : '',
      url: typeof item.url === 'string' ? item.url : '',
      description: typeof item.description === 'string' ? item.description : '',
      age: typeof item.age === 'string' ? item.age : '',
      language: typeof item.language === 'string' ? item.language : '',
    };
  }).filter((entry) => entry.url || entry.title);

  return {
    count: results.length,
    results,
  };
}

function formatResult(payload) {
  return {
    content: [{ type: 'text', text: JSON.stringify(payload, null, 2) }],
    details: { json: payload },
  };
}

function buildProxyRequestOptions(config, payload, signal) {
  return {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${config.starterToken}`,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: JSON.stringify(payload),
    signal,
  };
}

async function callBraveProxy(config, payload, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetch(
      config.proxyUrl,
      buildProxyRequestOptions(config, payload, controller.signal)
    );

    const raw = await response.text();
    const parsed = parseJson(raw);

    if (!response.ok) {
      const message =
        optionalString(asObject(parsed).error) ||
        `Brave proxy request failed with status ${response.status}`;
      throw new Error(message);
    }

    if (parsed) return parsed;
    throw new Error('Brave proxy returned a non-JSON response');
  } finally {
    clearTimeout(timer);
  }
}

const searchParameters = {
  type: 'object',
  additionalProperties: false,
  required: ['query'],
  properties: {
    query: {
      type: 'string',
      description: 'Search query text.',
    },
    count: {
      type: 'integer',
      minimum: 1,
      maximum: 20,
      description: 'Maximum results to return.',
    },
    country: {
      type: 'string',
      description: 'Two-letter country code, for example "US".',
    },
    searchLang: {
      type: 'string',
      description: 'Search language, for example "en".',
    },
    uiLang: {
      type: 'string',
      description: 'UI language, for example "en-US".',
    },
    safesearch: {
      type: 'string',
      enum: ['off', 'moderate', 'strict'],
      description: 'SafeSearch mode.',
    },
    freshness: {
      type: 'string',
      enum: ['pd', 'pw', 'pm', 'py'],
      description: 'Freshness filter: day, week, month, year.',
    },
    timeoutMs: {
      type: 'integer',
      minimum: 1,
      maximum: 120000,
      description: 'Override network timeout for this call.',
    },
  },
};

export default {
  id: 'agent37-brave',
  name: 'Agent37 Brave Search',
  description: 'Brave web search proxy for OpenClaw instances.',
  register(api) {
    api.registerTool(
      () => {
        if (!getRuntimeConfig()) return null;

        return [
          {
            name: 'brave_web_search',
            label: 'Brave Web Search',
            description: 'Search the web via Brave.',
            parameters: searchParameters,
            async execute(_toolCallId, args) {
              const config = getRuntimeConfig();
              if (!config) {
                throw new Error('Brave integration is not configured');
              }

              const timeoutMs = normalizeTimeoutMs(args?.timeoutMs);
              const payload = normalizeSearchPayload(args);
              const response = await callBraveProxy(config, payload, timeoutMs);
              return formatResult(normalizeSearchResults(response));
            },
          },
        ];
      },
      {
        names: ['brave_web_search'],
      }
    );
  },
};
