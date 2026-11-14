#!/usr/bin/env bash
# Self-check for explain.sh: stage-1 filter, mid-turn capture, compact sync, append-only journal, failure logging. Stub pi, no model calls.
set -u
H=$(dirname "$(readlink -f "$0")")
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
# stub pi: records stdin + args; fails, unless $t/ok exists (then it answers SKIP)
mkdir -p "$t/bin"; printf '#!/bin/sh\ncat >"%s/stdin"; printf "%%s\\n" "$@" >"%s/args"; [ -f "%s/ok" ] && { echo SKIP; exit 0; }; echo "Error: stub pi failed"; exit 1\n' "$t" "$t" "$t" >"$t/bin/pi"; chmod +x "$t/bin/pi"
fails=0; sid=s1
# run <name> <prompt> <reply> [extra transcript line]  -> prints the entry count delta in logs/$sid.md
run() {
  printf '{"type":"user","message":{"role":"user","content":%s}}\n' "$(jq -Rn --arg s "$2" '$s')" >"$t/tr.jsonl"
  [ -n "${4:-}" ] && printf '%s\n' "$4" >>"$t/tr.jsonl"
  jq -n --arg tp "$t/tr.jsonl" --arg r "$3" --arg s "$sid" '{transcript_path:$tp, cwd:"/x", session_id:$s, last_assistant_message:$r}' >"$t/in.json"
  before=$(grep -c '^## turn-' "$t/logs/$sid.md" 2>/dev/null); before=${before:-0}
  PATH="$t/bin:$PATH" VISUAL_EXPLAINER_HOOK_DIR="$t" EXPLAIN_BG=1 "$H/explain.sh" "$t/in.json" >"$t/out" 2>&1
  after=$(grep -c '^## turn-' "$t/logs/$sid.md" 2>/dev/null); echo $(( ${after:-0} - before ))
}
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got $2, want $3)"; fails=$((fails+1)); fi; }
long=$'a\nb\nc\nd\ne'

check "stray Enter is skipped"      "$(run enter 'ㅇㅇ' "$long")" 0
check "slash command is skipped"    "$(run slash '<command-name>/clear</command-name>' "$long")" 0
check "short reply still goes on"   "$(run short 'what changed here?' $'one\ntwo')" 1
check "normal turn is logged"       "$(run normal 'explain the hook flow' "$long")" 1
check "pi failure lands in run log" "$(grep -c 'Error: stub pi failed' "$t/out")" 1   # one per model line in explain.sh
check "no page marker on failure"   "$(grep -c '^→ page' "$t/logs/$sid.md")" 0
run midturn 'first ask' "$long" '{"type":"attachment","attachment":{"type":"queued_command","prompt":"second ask typed mid-turn"}}' >/dev/null
check "mid-turn input is captured"  "$(grep -c '(added mid-turn) second ask typed mid-turn' "$t/logs/$sid.md")" 1
cs='{"type":"user","uuid":"11111111-2222-3333-4444-555555555555","isCompactSummary":true,"message":{"role":"user","content":"Summary of the earlier session"}}'
run compact 'ask before auto-compact' "$long" "$cs" >/dev/null
check "compact summary is not the prompt" "$(grep -c '^ask before auto-compact$' "$t/logs/$sid.md")" 1
run compact2 'next ask after compact' "$long" "$cs" >/dev/null
check "compact summary copied once" "$(grep -c '^## compact ' "$t/logs/$sid.md")" 1
check "ctx starts at the compact"   "$(sed -n 2p "$t/stdin" | grep -c '^## compact ')" 1   # line 1 is <log>
check "ctx drops pre-compact turns" "$(grep -c 'explain the hook flow' "$t/stdin")" 0
check "contract replaces pi prompt" "$(grep -c -e "^--system-prompt$" -e "^--no-skills$" -e "^Your one job" "$t/args")" 3
check "VE docs carry their path"    "$(grep -c "^<doc path=\"/" "$t/args")" 6
sid=s2; mkdir -p "$t/logs"; head -c 60000 /dev/zero | tr '\0' x >"$t/logs/s2.md"; run other 'a second session' "$long" >/dev/null
check "no size cap"                 "$(( $(wc -c <"$t/stdin") > 60000 ))" 1
check "sessions do not mix"         "$(grep -c 'next ask after compact' "$t/stdin")" 0
sid=s3; touch "$t/ok"; run first 'first ask in s3' "$long" >/dev/null; run second 'second ask in s3' "$long" >/dev/null
check "next run sends only new lines" "$(grep -c 'first ask in s3' "$t/stdin")$(grep -c 'second ask in s3' "$t/stdin")" 01
check "one journal per segment"     "$(ls "$t"/sessions/s3.*.jsonl | wc -l)" 1
check "per-run view for status.sh"  "$(grep -l '"id":"turn-' "$t"/runs/turn-*-m3.jsonl | wc -l | awk '{print ($1 >= 2)}')" 1
j3=$(ls "$t"/sessions/s3.*.jsonl); printf '{"type":"message","message":{"role":"assistant","usage":{"input":600000,"cacheRead":0,"output":0}}}\n' >>"$j3"
run third 'third ask in s3' "$long" >/dev/null
check "journal restarts past 512k"  "$(grep -c 'first ask in s3' "$t/stdin") $(ls "$t"/sessions/s3.*.jsonl.2* | wc -l)" "1 1"
# comment line, blank line, end-of-line comment, and a last line with no newline
printf '# comment\nm3 minimax/MiniMax-M3:off   # note\n\nqwen4 qwen-token-plan/qwen4-max-preview' >"$t/models"; rm -f "$t/ok"
run models 'ask with a models file' "$long" >/dev/null
check "models file runs each line"  "$(grep -c 'Error: stub pi failed' "$t/out")" 2
check "end-of-line comment ignored" "$(grep -c 'not found' "$t/out")" 0
[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
