# visual-explainer-hook

Fork of nicobailon/visual-explainer. Before touching anything, read `README-DOWNSTREAM.md` (what is ours, what is upstream, how to rebase).

`hook/` holds a live POC: a global Claude Code Stop hook (`hook/explain.sh`) that sends every turn to pi explainers, which draw visual-explainer pages.

Before doing anything:
1. Read `hook/HISTORY.md` (why it is shaped this way, mistakes not to repeat, open items).
2. Read `hook/README.md` (goal, how it works, where code and data live, commands).
3. Run `~/.agent/explainer/status.sh 6` for the latest runs and `~/.agent/explainer/stats.sh` for the scoreboard (wrappers that point the scripts at this machine's data dir).

Rules:
- Neither upstream nor this fork is Claude-only: write for any agent and model. The hook itself targets Claude Code for now, so Claude in hook docs is fine.
- The hook is live for ALL sessions on this machine, and it runs the files in `hook/`. Run `hook/test.sh` (it must print `all passed`) after every edit to `hook/explain.sh`.
- `hook/contract.md` and VE doc edits apply only after a journal restart (`hook/HISTORY.md` mistake 4).
- `hook/contract.md` holds only what the preloaded VE docs and the per-message lines in `hook/explain.sh` do not already say.
- Explainers explain, they never verify (user rule). Their tools are `read,write` (plus `edit` in the repair round), never bash (rules + VE docs are in the system prompt); the script renders.
- Runtime data (conversation logs) lives in `$VISUAL_EXPLAINER_HOOK_DIR`, never in this repo. The repo is public.
- **Ours are `hook/`, `CLAUDE.md`, `README-DOWNSTREAM.md` and the top block of `README.md`; every other file is upstream's. Keep an edit to an upstream file to the fewest lines and record file, intent and why in `README-DOWNSTREAM.md`.**
- Checking an explainer's or an experiment's page: do not read its HTML, `.src.html`, or sheet PNG into context. Reduce it to one line of counts taken from the `.src.html` (the rendered HTML turns every tag into `<svg>`): hand-drawn `<svg>`, `<ve-flow>`, `ve-table`, data tags (`grep -o … | wc -l`), plus render's result and `✗` count. Read the `✗` lines (`grep '✗'`) only when there are some; open the sheet only when the `✗` lines cannot explain what the user sees.
