from __future__ import annotations

import os
import shutil


def _env_truthy(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "on"}


def _env_present(name: str) -> bool:
    return bool(os.environ.get(name, "").strip())

_BASE_CONTEXT = """\
<agent37-environment>
You are running inside Agent37, a managed agent hosting platform.

Persistent paths (survive container restarts and runtime image updates): /home/node (user home + agent state) and /home/linuxbrew (Homebrew). Anything written outside these paths is reset on image update.

- Post-restart hook (~/.agent37/hooks/post-restart.sh): runs every container start. Use it for any state the user wants to persist across restarts, such as a background worker or re-exported env vars.\
"""

_HOSTING_CONTEXT = """

- Hosting a website. Always use this workflow when the user wants to build, preview, run, or "see" a web app. Do not suggest ngrok / Cloudflare tunnels / localtunnel / similar — Agent37 has native hosting built in. The `agent37-host` CLI bundles: start the dev server detached, expose the port, and register it to auto-restart on container restart. Do the whole thing yourself so the user never has to think about plumbing.

    `/usr/local/bin/agent37-host add --port 3000 --dir /absolute/path/to/project --cmd "npm run dev"`

    Output is one JSON line on stdout: `{ "url": "...", "port": ..., "slug": "...", "devServerPid": ..., "devServerLog": "/tmp/dev-<port>.log" }`. Give the user the `url` field exactly as returned (do not retype it or substitute env var names yourself). Add ONE caveat: "This URL is public — anyone with the link can open it." That's it. Do not explain restart hooks, port forwarding, or any other plumbing.

    To stop hosting a port: `/usr/local/bin/agent37-host stop --port 3000` (removes the exposed port and the auto-restart entry; does not kill the running dev server process — use `pkill` or similar if you need to).

    Troubleshooting: if the URL returns 502, the dev server isn't running or is bound to a different port — check `ss -ltnp` and the log at `/tmp/dev-<port>.log`. If the URL returns a Traefik 404 after an instance migration, run `agent37-host add` again with the same args to get a fresh URL on the new host shard (the slug is preserved, only the domain changes).\
"""

_CONSUMER_HOSTING_CONTEXT = """

- Hosting a website / sharing a public link. Always use this workflow when the user wants to build, preview, run, or "see" a web app, or asks for a public link to something running here. Do not suggest ngrok / Cloudflare tunnels / localtunnel / similar — Agent37 has native hosting built in. See the agent37-expose skill for details.

    1. Start the server yourself, detached, logging to a file: `nohup npm run dev >/tmp/dev-3000.log 2>&1 &` (or equivalent).
    2. `agent37 expose 3000 --label "My app"` — prints one JSON line with the public `url`. Give the user the `url` field exactly as returned, with ONE caveat: "This URL is public — anyone with the link can open it." Do not explain any other plumbing.
    3. To survive container restarts, add the start command to `~/.agent37/hooks/post-restart.sh` (it runs on every container start).

    `agent37 unexpose 3000` removes the link. `agent37 list-exposed` lists every live link — use it whenever the user asks about their links or reports one broken (if this instance was migrated, old links are dead; check `~/.hermes/MIGRATION.md` if present, then hand back the live URLs or re-expose).

- No root access: `sudo` does not elevate here. Install tools with Homebrew (`brew install ...`), `uv`, or npm/pip user installs.\
"""

_CONSUMER_PLATFORM_CONTEXT = """

- Building another agent. Agent37 has a public API for creating agents: docs at https://www.agent37.com/docs, API keys at https://www.agent37.com/dashboard/cloud/api-keys. If the user wants another agent, that is the way to build it, and you can do it for them.\
"""

_CRON_CONTEXT = """

- Scheduling recurring work. Agent37 runs schedules outside the container, so a firing wakes this instance to deliver its prompt and the instance is free to sleep in between; a crontab (or systemd timer, or sleep loop) inside the container stops the moment the instance sleeps. `agent37 cron add --schedule "0 9 * * 1-5" --prompt "..." --timezone America/New_York`, plus `agent37 cron list|update|remove|runs`. The prompt arrives as a fresh message in its own chat, so write it to stand on its own. Docs: https://www.agent37.com/docs/agents-api/crons\
"""

_COMPOSIO_CONTEXT = """

- Third-party SaaS integrations (Composio). Composio is Agent37's managed OAuth path for general SaaS APIs, wired in as the `composio` MCP server. Its tools are self-describing — discover them from that server; do not assume tool names.
    - Use Composio for general SaaS apps: Gmail, Google Calendar, Notion, GitHub, Linear, Jira, HubSpot, Salesforce, Airtable, and similar. To connect one, start the Composio connection flow, show the returned OAuth link as a markdown link, and wait for the user to come back and confirm before checking connection status.
    - Do not use Composio for messaging/bot channels Agent37 supports natively (Slack, Discord, Telegram, WhatsApp, Google Chat, Signal). Use native channel tools first; fall back to Composio only for an operation native tools cannot perform.
    - Prefer an installed skill when it covers the task — but for connecting a SaaS account, go straight to Composio; do not weigh it against skills that need their own OAuth client or API key (e.g. google-workspace).
    - Try Composio before telling the user to manually get an API key or configure a vendor dashboard for a general SaaS app. Connections persist for this instance — reuse them.\
"""

_FOOTER = """
</agent37-environment>"""


def _consumer_instance() -> bool:
    # The starter token prefix is the product line: subscription (consumer) instances keep an
    # `ocst.` credential across every recreate, B2B gets `a37st.`. It replaced a
    # `which("agent37")` check once the cron CLI shipped into the B2B images too, and it is the
    # sharper gate anyway: `agent37 expose` is exactly what the starter endpoint 403s on a
    # B2B token.
    return os.environ.get("AGENT37_STARTER_TOKEN", "").strip().startswith("ocst.")


def _build_prompt_context() -> str:
    # The hosting workflow self-gates on which expose CLI the image ships: agent37-host on the
    # B2C VPS fleet, agent37 on the consumer (B2B-hosted) images, neither on customer images.
    if shutil.which("agent37-host"):
        hosting = _HOSTING_CONTEXT
    elif shutil.which("agent37") and _consumer_instance():
        hosting = _CONSUMER_HOSTING_CONTEXT
    else:
        hosting = ""
    composio_configured = (
        _env_truthy("AGENT37_MANAGED_INTEGRATIONS")
        and _env_truthy("AGENT37_HERMES_COMPOSIO_ENABLED")
        and _env_present("AGENT37_STARTER_PROXY_URL")
        and _env_present("AGENT37_STARTER_TOKEN")
    )
    composio = _COMPOSIO_CONTEXT if composio_configured else ""
    # The platform pitch is for consumer instances only: a B2B customer's own end users must
    # never be sold Agent37 directly.
    platform = _CONSUMER_PLATFORM_CONTEXT if _consumer_instance() else ""
    # Schedules work on both products, so this one rides the CLI alone.
    cron = _CRON_CONTEXT if shutil.which("agent37") else ""
    return f"{_BASE_CONTEXT}{hosting}{cron}{platform}{composio}{_FOOTER}"


PROMPT_CONTEXT = _build_prompt_context()


def inject_prompt_context(**kwargs):
    del kwargs
    return {"context": PROMPT_CONTEXT}
