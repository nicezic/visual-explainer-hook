#!/usr/bin/env bash
# Claude Code Stop hook (POC, see README.md): append this turn to its session's append-only log, then let
# a pi explainer (model at the bottom) turn the latest entry into a visual-explainer page or SKIP.
# The log stays append-only (explainer output is never added back except a one-line page marker).
set -uo pipefail
H=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")   # this repo's hook/ (the entry point may be a wrapper elsewhere)
# Runtime data (session logs, explainer journals, run views) lives OUTSIDE the repo: git clean or a push never touches it.
D=${VISUAL_EXPLAINER_HOOK_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/visual-explainer-hook}
OUT=~/.agent/diagrams
VE=$H/../plugins/visual-explainer   # this fork's VE, whose docs put auto-layout figures first

# Foreground: grab the hook JSON and detach, so Claude never waits and session exit does not kill us.
if [ -z "${EXPLAIN_BG:-}" ]; then
  mkdir -p "$D" "$OUT"
  f=$(mktemp "$D/in.XXXXXX"); cat >"$f"
  EXPLAIN_BG=1 setsid -f "$0" "$f" >>"$D/run.log" 2>&1 </dev/null
  exit 0
fi

in=$1; trap 'rm -f "$in"' EXIT
reply=$(jq -r '.last_assistant_message // ""' "$in")
cwd=$(jq -r '.cwd // ""' "$in")
# One log per Claude session, so other sessions (concurrent or earlier) never leak into this one's ctx.
sid=$(jq -r '.session_id // ""' "$in"); sid=${sid//[^A-Za-z0-9_-]/_}   # sanitized: it becomes a file name
L="$D/logs/${sid:-nosession}.md"; mkdir -p "$D/logs"
# This turn's input: the last real user prompt (string, or text blocks without tool_result)
# plus messages typed mid-turn, which the transcript stores as queued_command attachments.
# A compact summary is a non-meta user message too; skip it, or a mid-turn auto-compact would pose as the prompt.
prompt=$(jq -rs '[.[] |
    if .type=="user" and (.isMeta|not) and (.isCompactSummary|not) then .message.content
      | (if type=="string" then . else ([.[]? | select(.type=="text") | .text] | join("\n")) end)
      | select(length>0) | {p: .}
    elif .type=="attachment" and .attachment.type=="queued_command" then {q: (.attachment.prompt | tostring)}
    else empty end]
  | (map(has("p")) | rindex(true)) as $i
  | if $i == null then "" else [.[$i:][] | .p // "(added mid-turn) \(.q)"] | join("\n\n") end' \
  "$(jq -r .transcript_path "$in")")

# Stage 1 (free): stray Enter, slash command. No reply-length rule: short parent replies are the goal,
# so whether a turn deserves a page is left to the model (SKIP).
[ ${#prompt} -lt 5 ] && exit 0
case "$prompt" in "<command-"*|/*) exit 0 ;; esac

# shortcut: regex masking only catches common key shapes; upgrade to a real scanner (gitleaks) if turns carry secrets.
mask() { sed -E 's/sk-[A-Za-z0-9_-]{16,}/sk-***/g; s/(ghp|gho|ghs|github_pat)_[A-Za-z0-9_]{20,}/gh_***/g;
  s/xox[abposr]-[A-Za-z0-9-]{10,}/xox-***/g; s/AKIA[0-9A-Z]{16}/AKIA***/g; s/AIza[0-9A-Za-z_-]{30,}/AIza***/g;
  s/[A-Za-z0-9+\/]{40,}={0,2}/<redacted>/g'; }

id="turn-$(date +%Y%m%d-%H%M%S)-$$"
append() { { flock 9; cat >>"$L"; wc -l <"$L"; } 9>"$D/.lock"; }   # prints the log's new last line number
# Parent compacted (manual or auto, maybe mid-turn): copy its newest summary into the log once, before this
# turn's entry, so ctx below can start where the parent's own context now starts.
cs=$(jq -c 'select(.isCompactSummary == true and .uuid) | {u: .uuid, t: (.message.content
  | if type == "string" then . else ([.[]? | select(.type == "text") | .text] | join("\n")) end)}' \
  "$(jq -r .transcript_path "$in")" | tail -1)
if [ -n "$cs" ] && ! grep -qxF "## compact $(jq -r .u <<<"$cs")" "$L" 2>/dev/null; then
  printf '\n## compact %s\n%s\n' "$(jq -r .u <<<"$cs")" "$(jq -r .t <<<"$cs" | mask)" | append >/dev/null; fi
end=$(printf '\n## %s · %s\n### user\n%s\n### claude\n%s\n' "$id" "$cwd" "$(mask <<<"$prompt")" "$(mask <<<"$reply")" | append)

# Rules (contract.md) REPLACE pi's own coding-assistant prompt, whose "inspect files" role and pi-doc pointers made
# explainers wander; --no-skills drops pi's skill list. VE docs follow, each labelled with its path so the model
# can tell a preloaded doc from one it has not seen. All static, so the prefix stays cache-friendly.
# Preloaded: the references every page may need (user's call, ~21:30; cached after a segment's first run).
# Not preloaded: slides/video and plans/machines (the explainer never makes decks, plans, or walks code), and
# diagrams.md (the hand-drawn SVG manual), read on demand since 23:30: M3 copied its SVG template on 30 of 30 pages.
# Tools are read + write (read came back at ~04:20, unlimited by the user's call).
sys=(--system-prompt "$(cat "$H/contract.md")" --no-skills)
for doc in SKILL.md references/{style-guide,kit,motion,themes,extras}.md; do
  sys+=(--append-system-prompt "$(printf '<doc path="%s">\n%s\n</doc>' "$VE/$doc" "$(cat "$VE/$doc")")"); done

cd "$D" || exit 1   # fixed cwd: pi puts cwd in the system prompt
mkdir -p runs
# The explainer's context mirrors the parent's: one segment per session, from the session start or the parent's
# latest compact summary, no size cap (user's call; the parent compacts before its window fills).
c=$(grep -nE '^## compact [0-9a-f-]{36}$' "$L" | tail -1)   # "<line>:## compact <uuid>", empty before any compact
first=${c%%:*}; seg=${c##* }

# explain <tag> <model> [runner...]: one explainer run; page and per-run view are named <id>-<tag>.
# No bash tool: log text is untrusted input, so the explainer cannot run anything; this script renders.
explain() {
  local tag=$1 model=$2; shift 2
  local page="$id-$tag" J="$D/sessions/$sid.${seg:-start}-$tag.jsonl" view="$D/runs/$id-$tag.jsonl" res pos before new=
  # Append-only conversation, one pi journal per segment: each run adds only the log lines written since the last
  # run, as a NEW user message, so the previous request is an exact prefix of this one and MiniMax's prefix cache
  # hits (measured 2026-11-14 ~21:00). Rewriting one big user message every run missed it every time.
  # Cost: the explainer's own page writes stay in its context (~3k tokens per turn) until the parent compacts.
  mkdir -p "$D/sessions"; exec 8>>"$J.pos"; flock 8   # one run at a time per journal, or overlapping turns interleave it
  # Context cap (user's call: 512k tokens of M3's 1M): the explainer's own pages pile up in the journal, so past the
  # cap start over from the log alone (pages dropped). Costs one cache miss; editing history instead would break it.
  if [ "$(jq -s '[.[] | select(.type=="message" and .message.role=="assistant") | .message.usage
      | .input + .cacheRead + .output] | last // 0' "$J" 2>/dev/null || echo 0)" -gt 512000 ]; then
    mv "$J" "$J.$(date +%Y%m%d-%H%M%S)"; : >"$J.pos"; fi
  # pi needs a session header to open the file (MiniMax is not sent its id).
  [ -s "$J" ] || printf '{"type":"session","version":3,"id":"00000000-0000-7000-8000-0000000e0e0e","timestamp":"%s","cwd":"%s"}\n' \
    "$(date -u +%FT%T.000Z)" "$D" >"$J"
  pos=$(cat "$J.pos"); pos=${pos:-$(( ${first:-1} - 1 ))}   # last log line already in the journal
  before=$(wc -l <"$J")
  # Per-run view for status.sh / stats.sh: header now (shows as running), this run's journal lines at the end.
  printf '{"type":"session","version":3,"id":"%s","timestamp":"%s","cwd":"%s"}\n' "$page" "$(date -u +%FT%T.000Z)" "$D" >"$view"
  # '→ page:' lines are left out: the journal already holds those pages as the explainer's own replies.
  [ "$end" -gt "$pos" ] && new=$(sed -n "$((pos + 1)),${end}p" "$L" | grep -v '^→ page:')
  # The varying part (entry id, page path) goes LAST, after the log lines.
  # "Figures:" restates the docs' auto-layout-first rule near the end of each page request (HISTORY decisions 14, 18).
  # The format below is single-quoted: an apostrophe in its text breaks the live hook.
  if res=$(printf '<log>\n%s\n</log>\n\nExplain ONLY entry "## %s". Page source path: %s\nFigures: draw every figure with auto-layout: <ve-flow> for boxes and arrows, <ve-bars> / <ve-waffle> / <ve-stack> for numbers, .kpis for key numbers, .ve-table for rows, CSS grid for cards and timelines. Hand-drawn <svg> only when truly needed, that is, when auto-layout cannot show the figure at all; then read references/diagrams.md first.\nFinal reply: "%s.html | <title>", or SKIP.\n' \
      "$new" "$id" "$OUT/$page.src.html" "$page" \
    | "$@" pi -p --model "$model" --tools read,write --no-context-files "${sys[@]}" --session "$J" 2>&1 | tail -1); then
    [ "$end" -gt "$pos" ] && echo "$end" >"$J.pos"; fi   # on failure pos stays, so the next run resends these lines
  # first_cacheRead ≈ the whole previous request on step 1 means the cross-turn cache hit.
  tail -n +$((before + 1)) "$J" | jq -sc --arg id "$page" '[.[] | select(.type=="message" and .message.role=="assistant") | .message.usage]
    | {id: $id, steps: length, first_cacheRead: .[0].cacheRead, first_input: .[0].input,
       input: (map(.input) | add), cacheRead: (map(.cacheRead) | add), output: (map(.output) | add)}' >>"$D/usage.log"
  if [ -f "$OUT/$page.src.html" ]; then
    # No --open here: render opens even a page that failed its visual check, so a repaired page opened twice.
    out=$(node "$VE/kit/render.mjs" "$OUT/$page.src.html" 2>&1); ok=$?
    # A malformed kit link (e.g. data-ve-kit">) renders "as given": no kit CSS, no visual check, exit 0. Repair it too.
    grep -q 'no kit marker' <<<"$out" && { ok=1; out+=$'\n✗ no kit marker: <head> needs exactly <link rel="stylesheet" href="kit.css" data-ve-kit>'; }
    [ "$ok" = 0 ] || {
      echo "first render (sent back for repair):"; grep '✗' <<<"$out"   # problem lines only, to measure the repair
      # One repair round: with no bash the explainer never sees render errors, so pass them back in the same journal.
      printf 'Render failed:\n%s\nCall write once more with the whole fixed page at %s, then reply with the same one line.\n' \
          "$out" "$OUT/$page.src.html" \
        | "$@" pi -p --model "$model" --tools read,write --no-context-files "${sys[@]}" --session "$J" >/dev/null 2>&1
      out=$(node "$VE/kit/render.mjs" "$OUT/$page.src.html" 2>&1); }
    echo "$out"
    # xdg-open = the WSL wrapper (wslview); detached, as render's own --open does
    [ -f "$OUT/$page.html" ] && setsid -f xdg-open "$OUT/$page.html" >/dev/null 2>&1
  fi
  { head -1 "$view"; head -"$before" "$J" | grep -m2 -E '"type":"(model_change|thinking_level_change)"'
    tail -n +$((before + 1)) "$J"; } >"$view.tmp" && mv "$view.tmp" "$view"
  echo "$(date -Is) $page ${res:-<no reply>}"
  [ "$res" != SKIP ] && [ -f "$OUT/$page.html" ] && printf '→ page: %s\n' "$res" | append >/dev/null
}

# Models to run: $D/models, one `<tag> <model> [runner...]` per line, # comments (README "Models").
# No file = the A/B winner (HISTORY decision 1): m3, key from creds, thinking off (it drove M3's slowness).
if [ -f "$D/models" ]; then
  # shortcut: runner is split on spaces (no quoting), enough for `creds run ai --`
  while read -r tag model runner || [ -n "$tag" ]; do   # || : keep a last line that has no newline
    runner=${runner%%#*}   # an end-of-line comment is not part of the runner
    [[ -z $tag || $tag == \#* ]] || explain "$tag" "$model" $runner </dev/null &
  done <"$D/models"
else
  explain m3 minimax/MiniMax-M3:off creds run ai -- &
fi
wait
exit 0
