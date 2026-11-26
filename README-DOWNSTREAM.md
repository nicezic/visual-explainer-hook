# README-DOWNSTREAM: fork upkeep

`visual-explainer-hook` = upstream [nicobailon/visual-explainer](https://github.com/nicobailon/visual-explainer) + a small stack of our commits on top.
This file is the ledger an agent reads before an upgrade: what is ours, what we changed upstream and **why**, and how to rebase.

Remotes: `origin` = github.com/nicezic/visual-explainer-hook, `upstream` = nicobailon/visual-explainer (push disabled).
Branches: `main` = ours (upstream + our stack, the fork's default branch). `upstream-main` = a mirror of upstream's `main`: never commit to it, only fast-forward.
`git log --oneline upstream-main..main` lists exactly our commits. Branch upstream PRs (e.g. the `.ve-n` centring doc) from `upstream-main`, never from `main`.
`git config rerere.enabled true` is set, so a conflict resolved once is replayed on later rebases.

## Downstream-only (never conflicts)

| Path | What |
|---|---|
| `hook/` | The Claude Code Stop hook and its docs (`hook/README.md`, `hook/HISTORY.md`). |
| `README-DOWNSTREAM.md`, `CLAUDE.md` | This ledger and the agent entry point (upstream has neither). |
| `README.md` top block | Between `<!-- downstream:start -->` and `<!-- downstream:end -->`; may conflict only if upstream edits its first lines. |

## Upstream lines we changed (re-apply the INTENT if a rebase conflicts)

None as of v0.16.0: both of ours landed upstream, so those files are upstream's text again — `.ve-n` x-centring (upstream `83d33cf`, PR #136) and `<ve-flow>` as the default for plain flows (upstream `a148a62`, PR #137).

When an upstream PR candidate lands upstream, drop our line during the rebase and remove its row here.

## Upgrade (rebase) procedure

1. `git fetch upstream && git branch -f upstream-main upstream/main && git rebase upstream-main main`
2. On a conflict in an upstream file: take upstream's new text, then re-apply the **intent** from the table above in the fewest words. Never keep a stale copy of their old sentence.
3. `hook/test.sh` must print `all passed`. Render one page through the visual check: `node plugins/visual-explainer/kit/render.mjs <some>.src.html`.
4. Restart the live explainer journals, because the preloaded VE docs changed: `hook/HISTORY.md` mistake 4.
5. Update this table, then `git push origin upstream-main && git push --force-with-lease origin main`.

## Setup on a new machine

- Repo root: `pnpm install -D --config.auto-install-peers=false --config.lockfile=false` (playwright-core only, for render's visual check), then `pnpm exec playwright-core install chromium-headless-shell`.
- Point the Claude Code `Stop` hook at `hook/explain.sh`, or at a wrapper that sets `VISUAL_EXPLAINER_HOOK_DIR` first (default data dir: `${XDG_STATE_HOME:-~/.local/state}/visual-explainer-hook`).
- Runtime data holds conversation logs: keep it outside this public repo.
