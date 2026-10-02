# Agent37 templates

The Dockerfiles behind every [Agent37](https://www.agent37.com) system template. If your agent hits an error on an Agent37 instance, or you want to extend a template, this is exactly how the image is built.

## Templates

| Template | Image | Clean base for your own builds | Source |
| --- | --- | --- | --- |
| `agent37-hermes` | `hermes` | `hermes-base` | [`images/b2b/hermes`](images/b2b/hermes) |
| `agent37-openclaw` | `openclaw` | `openclaw-base` | [`images/b2b/openclaw`](images/b2b/openclaw) |
| `agent37-claude-code` | `claude-code` | `claude-code-base` | [`images/b2b/claude-code`](images/b2b/claude-code) |
| `agent37-codex` | `codex` | `codex-base` | [`images/b2b/codex`](images/b2b/codex) |
| `agent37-grok` | `grok` | `grok-base` | [`images/b2b/grok`](images/b2b/grok) |
| `agent37-opencode` | `opencode` | `opencode-base` | [`images/b2b/opencode`](images/b2b/opencode) |
| `agent37-pi` | `pi` | `pi-base` | [`images/b2b/pi`](images/b2b/pi) |
| `agent37-n8n` | `n8n` | | [`images/b2b/n8n`](images/b2b/n8n) |

Every image is published at `ghcr.io/agent37-platform/<image>`. [`images/consumer`](images/consumer) holds the images behind Agent37 Personal Agents (the noVNC desktop and the extra harnesses), built on top of `hermes` and `openclaw`.

## Find the source of the version you run

Every publish tags the commit it was built from as `<key>/<tag>`, where `<key>` is the entry in [`images.json`](images.json). So `agent37-hermes@2026.09.27b`, `hermes:2026.09.27b` and `hermes-base:2026.09.27b` were all built from the git tag [`b2b-hermes/2026.09.27b`](https://github.com/agent37-platform/templates/tree/b2b-hermes/2026.09.27b).

`main` can be ahead of what your instance runs. Your template's current tag is in its `image_ref` on `GET /v1/templates`; an instance pinned with `@<tag>` runs that tag.

## Build your own

Start from a `-base` image: the harness, the gateway that serves the chat API, and a general toolchain, with no managed model or integrations wired in. The platform puts a working model endpoint and integrations in every instance's environment at runtime, so your image carries no credentials.

```dockerfile
FROM ghcr.io/agent37-platform/hermes-base:latest
RUN pip install your-package
```

`latest` tracks the newest base; pin a date tag for reproducible builds. Publish it as a workspace template with a [cloud build](https://www.agent37.com/docs/agents-api/templates#build-an-image-in-the-cloud).

## Layout

- `images/b2b/<harness>/`: one multi-stage `Dockerfile` per harness (`--target base` is the clean image, `--target full` the template) plus its `entrypoint.sh`, which configures the runtime on every boot from the instance environment.
- `images/consumer/`: thin layers on the b2b images for Personal Agents.
- `shared/`: files copied into more than one image: the `agent37` CLI, the managed-config writers for each harness, the Hermes and OpenClaw plugins, and the desktop assets.

Every image builds with the repo root as context:

```bash
docker buildx build -f images/b2b/hermes/Dockerfile --target base .
```

## License

[MIT](LICENSE)
