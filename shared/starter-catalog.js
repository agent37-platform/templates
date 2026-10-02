'use strict';

// Shared by both OpenClaw config updaters (b2c configure-runtime-config.js and
// b2b/openclaw configure-openclaw-config.js). Each image's Dockerfile COPYs this
// file next to its updater under /usr/local/lib/openclaw/, so the updaters
// `require('./starter-catalog.js')` at boot. Keep this dependency-free.

const STARTER_CATALOG_TIMEOUT_MS = 8000;

// A custom AGENT37_LLM_PROXY_URL can serve any upstream catalog, and one
// modality OpenClaw cannot parse rejects the whole config, not just that model.
const OPENCLAW_INPUT_MODALITIES = ['text', 'image', 'video', 'audio'];

function asNonEmptyString(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function starterModelsUrl(starterProxyUrl) {
  let base = starterProxyUrl.replace(/\/+$/, '');
  if (!base.endsWith('/v1')) base = `${base}/v1`;
  return `${base}/models`;
}

// Fetch the managed proxy's paid catalog so the OpenClaw picker offers every
// model, not just the default. Returns an array of { id, name, input } excluding
// excludeModelId, or null on any failure; each caller decides its own fallback.
async function fetchStarterCatalogModels(starterProxyUrl, starterToken, excludeModelId) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), STARTER_CATALOG_TIMEOUT_MS);
  try {
    const response = await fetch(starterModelsUrl(starterProxyUrl), {
      headers: { Authorization: `Bearer ${starterToken}` },
      signal: controller.signal,
    });
    if (!response.ok) return null;
    const payload = await response.json();
    const data = Array.isArray(payload && payload.data) ? payload.data : [];
    const entries = [];
    for (const raw of data) {
      if (!raw || typeof raw !== 'object') continue;
      const id = asNonEmptyString(raw.id);
      if (!id || id === excludeModelId) continue;
      const modalities = Array.isArray(raw.architecture && raw.architecture.input_modalities)
        ? raw.architecture.input_modalities.filter((value) => OPENCLAW_INPUT_MODALITIES.includes(value))
        : [];
      entries.push({
        id,
        name: asNonEmptyString(raw.name) || id,
        input: modalities.length > 0 ? modalities : ['text'],
      });
    }
    return entries.length > 0 ? entries : null;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

module.exports = { fetchStarterCatalogModels };
