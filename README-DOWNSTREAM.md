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

| File | Intent | Why |
|---|---|---|
| `plugins/visual-explainer/SKILL.md` (figure table "Architecture…" row, and the paragraph after the table); `references/diagrams.md` (line 3) | Auto-layout figures come first, defined in that paragraph: the renderer or the browser places them (`<ve-flow>`, `<ve-bars>` / `<ve-waffle>` / `<ve-stack>`, `.kpis`, `.ve-table`, CSS grid), so no coordinates are written. Hand-drawn SVG only when truly needed. Replaces upstream's "Hand-drawn SVG is the default; never bend a figure to fit a tag" (#119). | Efficiency: auto-layout costs fewer tokens, less context and less time, and every failed render check repeats that cost. Weak explainer models (MiniMax-M3) misplace hand-drawn labels. |
| `plugins/visual-explainer/kit/flow.mjs` (3 lines before `const pairs`), `kit/kit.css` (`figure:has(.ve-flow)` rule), `scripts/check-figures.mjs` (last assertion) | On a page, a `<ve-flow>` with 5+ columns and more columns than rows turns to run top-down; a flow figure in a page's own grid takes the whole row. | At 1280 px, 21 flow frames on 17 of 120 M3 pages scrolled sideways (5+ boxes in a row, or a half-width grid cell) and the visual check let them pass; after: 0, with the same `✗` count (34). Offered upstream as **PR #147** (branch `fix/flow-fits-page`). |

`.ve-n` x-centring is upstream's now: **PR #136 landed as upstream `83d33cf`**, so its `kit.md` row is dropped here and never re-applied.

The figure row above was offered as **PR #137 and merged narrower**: `<ve-flow>` for plain box-and-arrow flows only (`a148a62`). The maintainer kept hand-drawn SVG the default where `<ve-flow>` can't draw ("stronger models do well there", 2026-11-25) and left `references/diagrams.md` unchanged, so the auto-layout-first wording stays downstream.

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
