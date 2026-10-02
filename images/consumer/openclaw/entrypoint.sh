#!/bin/bash
# Consumer wrapper around the b2b openclaw entrypoint: own the noVNC desktop (Piece 5a), then
# hand off to the untouched base entrypoint. The b2b image is fully headless (no display code
# at all), so unlike the hermes wrapper there is nothing to race — the wrapper's Xtigervnc is
# the only :99 server. browser.headless is seeded from the tier BEFORE the base configure pass
# runs (the base only defaults the flag when unset, and a persisted value from an earlier image
# would otherwise stick): pro/max (AGENT_BROWSER_HEADED=1) get a headed browser that paints on
# the desktop so the customer can watch the agent browse; basic/plus have no X server at all,
# so their browser is forced headless.
# Absolute shebang, not /usr/bin/env bash: this is the container ENTRYPOINT and the image
# ENV PATH is customer-first, so `env bash` picks the wrapper's own interpreter out of a
# persisted customer directory.
set -euo pipefail

log() {
  printf '%s [agent37-app-openclaw] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

export DISPLAY="${DISPLAY:-:99}"

# Fail-closed like the base config updater: OpenClaw may persist its config as JSON5
# (comments / trailing commas), so mirror its vm fallback and NEVER write when parsing
# fails — a lost parse must not wipe the customer's gateway/agents/channel config.
seed_browser_config() {
  local config_path="${OPENCLAW_CONFIG_PATH:-${OPENCLAW_STATE_DIR:-${HOME}/.openclaw}/openclaw.json}"
  mkdir -p "$(dirname "${config_path}")"
  [ -f "${config_path}" ] || printf '{}\n' > "${config_path}"
  CONFIG_PATH="${config_path}" /usr/local/bin/node -e '
    const fs = require("fs");
    const vm = require("vm");
    const path = process.env.CONFIG_PATH;
    const raw = fs.readFileSync(path, "utf8");
    let config;
    try {
      config = JSON.parse(raw);
    } catch {
      const context = vm.createContext(Object.create(null));
      config = new vm.Script(`(${raw})`).runInContext(context, { timeout: 250 });
    }
    if (typeof config !== "object" || config === null || Array.isArray(config)) {
      throw new Error("config is not an object");
    }
    const browser = config.browser;
    config.browser = (typeof browser === "object" && browser !== null && !Array.isArray(browser)) ? browser : {};
    config.browser.headless = process.env.AGENT_BROWSER_HEADED !== "1";
    if (typeof config.browser.noSandbox !== "boolean") config.browser.noSandbox = true;
    const tmp = path + ".seed-tmp";
    fs.writeFileSync(tmp, JSON.stringify(config, null, 2) + "\n");
    fs.renameSync(tmp, path);
  ' 2>/dev/null
}

if seed_browser_config; then
  log "Browser config seeded: headless=$([ "${AGENT_BROWSER_HEADED:-0}" = "1" ] && echo false || echo true)"
else
  log "Warning: failed to seed browser config; leaving the persisted value."
fi

# The desktop is a pro/max perk: the control plane sets AGENT_BROWSER_HEADED per tier on every
# create/recreate (agentInstances.ts), and the base image defaults it to 0.
if [ "${AGENT_BROWSER_HEADED:-0}" = "1" ]; then
  source /usr/local/lib/agent37/app-desktop.sh
  supervise_app_desktop &
else
  log "Desktop disabled (AGENT_BROWSER_HEADED=${AGENT_BROWSER_HEADED:-0})."
fi

exec /usr/local/bin/entrypoint.sh "$@"
