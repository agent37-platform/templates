---
name: agent37-expose
description: Create, list, and remove public URLs for ports on this Agent37 instance. Use when the user wants a shareable public link to a web app or service running here, wants a link taken down, or reports a shared link as broken.
version: 1.0.0
metadata:
  hermes:
    tags: [hosting, expose, public-url]
    category: platform
---

# Public URLs for instance ports (agent37 CLI)

## When to Use

- The user wants to preview, share, or "see" a web app or service running on this instance.
- The user wants a public link removed, rotated, or listed.
- The user reports a previously shared link as broken.

Never suggest ngrok, Cloudflare tunnels, localtunnel, or similar — this platform has native hosting.

## Procedure

1. Start the server yourself if it is not running, detached, logging to a file:
   `nohup npm run dev >/tmp/dev-3000.log 2>&1 &` (or the project's equivalent).
2. `agent37 expose 3000 --label "My app"` — prints one JSON line; `url` is the permanent public link.
3. Give the user the `url` exactly as returned, with one caveat: "This URL is public — anyone with the link can open it." Do not explain other plumbing.
4. To keep the server running across container restarts, append the start command to `~/.agent37/hooks/post-restart.sh` (it runs on every container start).

Other verbs:

- `agent37 unexpose 3000` — removes the link (permanently; re-exposing mints a fresh URL).
- `agent37 list-exposed` — lists every live link as JSON.

## Pitfalls

- The URL routes to the exact port you exposed; a 502 means nothing is listening there — check `ss -ltnp` and the log file.
- One URL per port. To rotate a leaked link: `agent37 unexpose <port>` then `agent37 expose <port>` again.
- If the user says an old link is broken, run `agent37 list-exposed` and compare: this instance may have been migrated (check `~/.hermes/MIGRATION.md` if present), which invalidates old URLs. Hand back the live URL or re-expose.
- Reserved platform ports cannot be exposed; pick the app's own port.

## Verification

`curl -sI <url>` from this instance should return the app's response (not 404/502) once the server is up.
