---
name: agent37-cron
description: Schedule a prompt to run against this agent on a recurring basis, and list, edit, pause or delete existing schedules. Use when the user wants something done every day, every weekday, hourly, or on any repeating cadence, or asks what is currently scheduled.
version: 1.0.0
metadata:
  hermes:
    tags: [hosting, cron, schedule]
    category: platform
---

# Recurring work (agent37 cron)

## When to Use

- The user wants something done on a repeating cadence: "check my email every weekday at 9", "post the summary every Friday", "watch this page hourly".
- The user asks what is scheduled, wants a schedule paused, changed, or removed, or asks why one did not run.

Prefer this over a crontab, `systemd` timer, `at`, or a long-running sleep loop. Agent37 runs the schedule outside the container: it wakes this instance to deliver the prompt, and between firings the instance is free to sleep. A schedule inside the container only runs while the container is running, so it stops the moment the instance sleeps and keeps it awake for nothing when it does not.

## Procedure

`agent37 cron add --schedule "0 9 * * 1-5" --prompt "Check my inbox and send me a two-line summary of anything that needs an answer today." --name "Weekday briefing" --timezone America/New_York`

Prints the schedule as one JSON line. `prompt` and `schedule` are required; `timezone` defaults to UTC, so pass the user's zone when you know it.

- `schedule` is a five-field cron expression (minute, hour, day of month, month, day of week). No seconds field.
- The prompt arrives as a fresh message in its own chat, not in the conversation you are having now. Write it so it stands on its own: whoever reads it will not have this context.

Other verbs:

- `agent37 cron list` — every schedule, with its next and last run.
- `agent37 cron update <id> --prompt "..."` — changes only what you pass. `--pause` and `--resume` stop and restart it.
- `agent37 cron remove <id>` — deletes it.
- `agent37 cron runs <id>` — the latest firings: when, and whether each one ran or was skipped.

## Pitfalls

- Times are read in the schedule's own timezone, so "9am" stays 9am across daylight saving. Ask the user for their zone rather than guessing UTC.
- A missed window is skipped, never replayed. Changing the schedule computes the next run from now.
- A firing is recorded as started, not as succeeded. If the user asks what happened, read the chat the firing opened, not the run list.
- A schedule does not restart an instance the owner stopped; those firings are recorded as skipped.

## Verification

`agent37 cron list` after adding: the new entry's `next_run` should be the next occurrence the user described.
