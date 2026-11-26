# Explainer hook

A turn-end hook for a coding agent (today: Claude Code's `Stop`) that hands every finished turn to cheaper "explainer" models.
Each one draws a human-facing visual-explainer (VE) page for that turn, or answers `SKIP`.
Status: **pilot POC since 2026-11-14, live on one machine.** Why it is shaped this way, mistakes, open items: [HISTORY.md](HISTORY.md).

## Why use it

- **Each finished turn becomes a page you can read** (or a SKIP when there is nothing to show), drawn with visual-explainer (VE), while the main agent does no extra work: the hand-off costs it zero tokens and no context (the hook takes the reply from `last_assistant_message` and the prompt from the transcript on disk).
- **The main agent spends nothing on the pages.** A separate, cheaper model draws them, so the main agent's tokens and quota go to the work itself. The bigger saving, shorter main replies, is stage 3 and has not started (stage plan: [HISTORY.md](HISTORY.md)).
- **A testbed for instruction changes.** Several models and effort levels explain the same real turns side by side (one line each in the models file; `stats.sh` compares them), so after a change to the explainer's instructions (`contract.md`, the VE docs) you see how each model and effort handles it.
- **The explainer has one job:** help the user understand the latest turn, quickly, with one VE page.

What no similar project combined when this started: one persistent explainer conversation per session, a semantic SKIP, an explainer on a different, cheaper model, and offloading so the main replies can shrink.

## How it works

```
main turn ends
  └─ Claude Code runs the Stop hook: hook/explain.sh   (stdin JSON: last_assistant_message, transcript_path, cwd)
       foreground: save stdin to in.XXXXXX, detach with `setsid -f`, exit 0 (Claude never waits)
       background:
         1. prompt = last real user prompt from the transcript (compact summaries skipped) + mid-turn messages (queued_command attachments)
         2. free filter: prompt < 5 chars, or a slash command → stop
         3. if the transcript has a new compact summary, append it once as "## compact <uuid>" (this starts a new segment)
         4. mask key-like strings → append "## turn-<ts>-<pid>" entry to logs/<session_id>.md (flock on .lock)
         5. for each model line, in parallel, under a flock on the segment's journal:
              pi -p --model <m> --tools read,write --no-context-files --session sessions/<sid>.<start|compact uuid>-<tag>.jsonl \
                 --system-prompt <contract.md> --no-skills --append-system-prompt <doc path=…> × 6 (VE SKILL.md + style-guide, kit, motion, themes, extras)
                 < "<log>log lines since the last run</log>" + "Explain ONLY entry ## <id>. Page source path: …" + "Figures: …" + "Final reply: …"
                 (a NEW user message appended to the same journal; .pos records the last log line sent)
              → the model calls write once: $VISUAL_EXPLAINER_OUTPUT_DIR/<id>-<tag>.src.html, or replies SKIP (no tool call)
              → the script renders: node kit/render.mjs <src>, whose visual check (headless Chromium) flags overlapping, overflowing, or tiny labels (at 1280px only: VISUAL_EXPLAINER_WIDTHS=1280)
              → if render fails: its ✗ lines go to run.log ("first render …"), ONE repair round in the same journal (tools read,write,edit), render again
              → the final page opens once (xdg-open, the wslview wrapper); "→ page: <file> | <title>" goes into the session log
```

## Where things live

- **Code:** this `hook/` dir of the `visual-explainer-hook` fork. Fork upkeep and new-machine setup: [../README-DOWNSTREAM.md](../README-DOWNSTREAM.md).
- **VE:** this fork's `plugins/visual-explainer` (upstream plus the lines listed in the ledger).
- **Runtime data:** `${XDG_STATE_HOME:-~/.local/state}/visual-explainer-hook`. It holds conversations, so it stays outside this public repo, and off `/tmp` (its cleanup would delete the models file and idle journals).
- **Pages:** `$VISUAL_EXPLAINER_OUTPUT_DIR`, upstream's output variable; default `~/.agents/diagrams`.
- **This machine:** `~/.claude/settings.json` → `hooks.Stop` runs `hook/explain.sh` here, and its `env` sets `VISUAL_EXPLAINER_OUTPUT_DIR=/tmp/ve`. Edits here go live at once, for every session in every project.

## Files

| Path | What |
|---|---|
| `explain.sh` | The hook. All logic lives here. |
| `contract.md` | The explainer's system prompt. It replaces pi's default coding-assistant prompt, whose "inspect files" role made explainers wander. |
| `test.sh` | Self-check with a stub `pi` (no model calls). Must print `all passed` after every edit to `explain.sh`. |
| `status.sh [N]` | The last N runs: time, effort, steps, step-1 cache, reply, files read or written. `⏳ running (or died)` marks an unfinished run. |
| `stats.sh [since] [until]` | Per-model scoreboard from `runs/` and the pages: runs, pages, SKIP, failed, repaired, time to a page, steps, reads. |
| data `logs/<session_id>.md` | Append-only log per Claude session: masked prompt + reply per turn, `## compact` summaries, `→ page:` markers. |
| data `sessions/<sid>.<segment>-<tag>.jsonl` (+ `.pos`) | The explainer's pi conversation for one session segment; `.pos` = last log line sent. Restarts past 512k tokens. |
| data `runs/<id>-<tag>.jsonl` | The lines each run added to its journal, for `status.sh` / `stats.sh`. |
| data `run.log`, `usage.log` | One result line per run with render output; one usage JSON line per run. |
| data `in.XXXXXX` | Hook stdin while a run is in flight; a leftover file means a run is still going or crashed. |
| data `models` | The lineup (below). |
| `$VISUAL_EXPLAINER_OUTPUT_DIR/turn-*-<tag>.html` | Output pages. |

## Models (`models` in the data dir)

One `<tag> <model>:<effort> [runner...]` per line, `#` for comments; retired models stay as comments with their numbers. All lines run in parallel and `stats.sh` compares them by tag. No file = `m3` alone.

- A new model or effort gets a new tag (no `-` in it: `stats.sh` reads the tag after the last `-`), because each tag keeps its own journal and cache.
- MiniMax runs on the user's subscription through the runner `creds run ai --`, never through OpenRouter; the other providers use pi's own login and config.
- One run at a time per journal: a slow model's next turn waits for its previous run, so its pages lag behind.
- Speed comes from thinking volume, not model size: thinking off made `m3` usable (first A/B test, 2026-11-14; HISTORY decision 1).

## Commands

```bash
hook/status.sh 6                               # the last 6 runs
hook/stats.sh                                  # per-model scoreboard
hook/test.sh                                   # self-check, must print "all passed"
ls -t "$VISUAL_EXPLAINER_OUTPUT_DIR"/turn-*.html | head   # latest pages
```

**Turn it off:** remove the `explain.sh` entry from `~/.claude/settings.json` (`hooks.Stop`). **Remove every trace:** also delete the data dir and `$VISUAL_EXPLAINER_OUTPUT_DIR/turn-*`.

## Mechanics that matter

- **Append-only journal per session segment** (HISTORY decision 5): each run appends only the new log lines as a new user message, so the previous request is a prefix of the next one and the provider's prefix cache hits. The varying text (entry id, page path) goes last.
- **pi gotchas:** a journal needs a session header to open; cwd goes into the system prompt, so the hook runs from the data dir; `--no-context-files` keeps any CLAUDE.md/AGENTS.md out; pi has no inter-process lock, so runs are serialized by flock; a changed system prompt is only patched into a live journal (HISTORY mistake 4).
- **Take the reply from `last_assistant_message`,** never from the transcript, which can still hold the previous turn at Stop time.
- **Tools `read,write` (plus `edit` in the repair round), never bash:** the log is untrusted input, so the explainer cannot run anything; the script renders.
- **Masking** is regex only (sk-, gh tokens, xox, AKIA, AIza, 40+ char base64/hex): a shortcut; upgrade to gitleaks if turns carry secrets.

## Known limits

- `last_assistant_message` holds only the main agent's **last** text block; text written between tool calls is lost.
- Different sessions run in parallel: a burst of quick turns starts one pi process per model line per session, and tabs can open out of order.
- With `read`, a prompt injection in the log could make an explainer read a local file and send it to its provider. Nothing blocks paths.
- A turn started by a background-task notification is logged with the `<task-notification>` text as its prompt; every `claude -p` run also fires the hook.
- A problem can survive the one repair round. A source error leaves only `.src.html` and no page; a visual `✗` still writes and opens the page.
- `m3` almost never answers SKIP; a "pass this turn" request addressed to the explainer stops a page.
- `status.sh` cannot tell a still-running run from a dead one; `runs/`, `sessions/` and `logs/` grow without pruning.
- If pi fails after it saved the user message, the next run resends those log lines (duplicated in the journal, harmless).
