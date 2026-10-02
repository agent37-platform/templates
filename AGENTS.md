# AGENTS.md

Guidance for AI coding agents working in this repo. `CLAUDE.md` imports this file via `@AGENTS.md`, so this is the single source of truth.

## What this is

The public source of every Agent37 system template image. Edits land here, images are published from here, and every published image tag has a matching git tag. Production does **not** follow this repo: it runs whatever tag the private platform repo pins (`agent37-web/docker/images.json`), so a change reaches customers only after a publish **and** a pin bump there.

This repo is public. Never commit a secret, a customer name, or an internal URL. Credentials reach an instance as environment at runtime; images carry none.

## Rules

- Keep changes small and simple. Handle only the important cases.
- Harness bugs (Hermes, OpenClaw, Codex, Claude Code, ...) are fixed upstream, not patched here. Pin a version that works and leave a comment saying when to remove the pin.
- Never reuse an image tag. A published tag is immutable: instances and customer builds pin it.
- Every image builds with the repo root as context, so `COPY` paths start at the root (`shared/...`, `images/...`).

## Layout

| Path | What | `images.json` key | GHCR packages |
| --- | --- | --- | --- |
| `images/b2b/hermes/` | `agent37-hermes`, `agent37-hermes-small` | `b2b-hermes` | `hermes-base`, `hermes-small`, `hermes` |
| `images/b2b/openclaw/` | `agent37-openclaw` | `b2b-openclaw` | `openclaw-base`, `openclaw` |
| `images/b2b/claude-code/` | `agent37-claude-code` | `b2b-claude-code` | `claude-code-base`, `claude-code` |
| `images/b2b/codex/` | `agent37-codex` | `b2b-codex` | `codex-base`, `codex` |
| `images/b2b/grok/` | `agent37-grok` | `b2b-grok` | `grok-base`, `grok` |
| `images/b2b/opencode/` | `agent37-opencode` | `b2b-opencode` | `opencode-base`, `opencode` |
| `images/b2b/pi/` | `agent37-pi` | `b2b-pi` | `pi-base`, `pi` |
| `images/b2b/n8n/` | `agent37-n8n` | `b2b-n8n` | `n8n` |
| `images/consumer/app/` | Personal Agents (Hermes + desktop + extra harnesses), `FROM hermes` | `consumer-app` | `app` (private) |
| `images/consumer/openclaw/` | Personal Agents on OpenClaw, `FROM openclaw` | `consumer-openclaw` | `app-openclaw` (private) |
| `shared/` | Files `COPY`'d into several images | | |

The `b2b` images are public on GHCR; the two consumer images stay private. A file in `shared/` reaches an image only when that image is republished: `grep -rn "shared/<file>" images/*/*/Dockerfile` lists who uses it.

Pinned versions inside the Dockerfiles: `ARG GATEWAY_VERSION` (the [gateway](https://github.com/agent37-platform/gateway) release each b2b image installs), the harness version ARGs, and in the consumer Dockerfiles `ARG HERMES_BASE_TAG` / `ARG OPENCLAW_BASE_TAG` (the b2b tag they build `FROM`).

## Test

```bash
python3 shared/test_configure_hermes_config.py
```

CI runs it on every PR. There is no image build in CI; a change to a Dockerfile is proven by publishing it and creating an instance from it.

## Change and release

1. Branch, edit, and in the same PR bump the image's tag in `images.json`: today's date plus the next unused letter (`2026.10.02a`, then `2026.10.02b`). Check `git tag -l '<key>/*'` and open PRs so two changes never claim the same tag. A consumer image built on a new b2b tag also bumps its `*_BASE_TAG` ARG.
2. Open the PR, wait for CI, squash-merge. Then `git checkout main && git pull`.
3. Publish: `./scripts/publish-image.sh <key>`. It needs `GH_USER=agent37-platform` and `CR_PAT` (a classic PAT with `write:packages`) in `.env` or the environment. It refuses a dirty tree, a commit that is not on `origin/main`, and a tag that already has a git tag. On success it pushes the git tag `<key>/<tag>`. Publish the b2b image before a consumer image that builds on it.
4. Pin it in production: in `agent37-web`, set the same key to the same tag in `docker/images.json` and ship that PR. Its CI provisions a real instance from the pinned tag, so the publish must finish first. Rolling existing instances onto the new tag is done from `agent37-web`; see its `AGENTS.md`.
5. If the change alters what customers see (what a template ships, how a base image behaves), update the matching page in the [docs](https://github.com/agent37-platform/docs) repo.

## Publishing notes

- The `hermes` publish pushes three multi-GB images and can take an hour on a slow uplink. Run it in the background and watch the log. Do not pass `--no-cache` for a version bump: cached base layers keep their digests, so GHCR skips re-uploading them.
- A publish that fails midway pushes no git tag. Fix it and run it again with the same tag; nothing pins that tag yet.
- If `docker login` hangs (Docker Desktop's credential helper wedges), give the publish its own `DOCKER_CONFIG` directory whose `config.json` has no `credsStore` and carries `auths["ghcr.io"].auth = base64(GH_USER:CR_PAT)`, with `~/.docker/cli-plugins` symlinked in. Delete the directory afterwards.
