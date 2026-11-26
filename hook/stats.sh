#!/usr/bin/env bash
# Per-model scoreboard from the run journals: pages / SKIP / failed, repair rounds, time to a page, reads.
# Args: [since] [until] as YYYYMMDD-HHMMSS (default since: start of the system-prompt setup).
# Periods: write-only 20261114-024100 .. 20261114-042300, read+write from 20261114-042300.
D=${XDG_STATE_HOME:-$HOME/.local/state}/visual-explainer-hook OUT=${VISUAL_EXPLAINER_OUTPUT_DIR:-$HOME/.agents/diagrams} since=${1:-20261114-024100} until=${2:-}
for j in "$D"/runs/turn-*.jsonl; do
  id=$(basename "$j" .jsonl); t=${id#turn-}; [[ "${t:0:15}" < "$since" ]] && continue
  [[ -n "$until" && ! "${t:0:15}" < "$until" ]] && continue
  tag=${id##*-}; [[ $tag =~ ^[0-9]+$ ]] && tag=terra   # the first runs had no tag and were all terra
  if [ -f "$OUT/$id.html" ]; then f=page; elif [ -f "$OUT/$id.src.html" ]; then f=fail; else f=none; fi
  jq -sc --arg tag "$tag" --arg f "$f" 'def t: sub("\\.[0-9]+Z$"; "Z") | fromdate;
    [.[] | select(.type=="message") | .message] as $msgs | [$msgs[] | select(.role=="assistant")] as $m
    | (($m[-1].content // []) | map(select(.type=="text") | .text) | join("") | gsub("^\\s+|\\s+$"; "")) as $reply
    | {tag: $tag, sec: ((.[-1].timestamp | t) - (.[0].timestamp | t)), steps: ($m | length),
       reads: ([$m[] | .content[]? | select(.type=="toolCall" and .name=="read")] | length),
       repaired: ([$msgs[] | select(.role=="user") | .content | tostring | select(test("Render failed"))] | length > 0),
       # shortcut: a page gone from the output dir (/tmp keeps a day) counts by its "<page>.html | <title>" reply (a repair round may reply otherwise), so an old failed render counts as a page
       r: (if $f == "page" or ($f == "none" and ([$m[] | .content[]? | select(.type=="text") | .text] | any(test("\\.html \\|")))) then "page"
           elif ($m | length) == 0 or ($m[-1].stopReason // "") == "toolUse" then "running"
           elif $f == "fail" then "fail" elif $reply == "SKIP" then "skip" else "fail" end)}' "$j"
done | jq -rs 'def avg(f): if length > 0 then (map(f)|add/length*10|round/10) else "-" end;
  ["model","runs","page","skip","fail","repaired","page_avg_s","page_min_s","page_max_s","steps_avg","reads_avg","running"],
  (group_by(.tag)[] | . as $all | map(select(.r != "running")) as $d | [$d[] | select(.r=="page")] as $p
   | [$all[0].tag, ($d|length), ($p|length), ([$d[]|select(.r=="skip")]|length), ([$d[]|select(.r=="fail")]|length),
      ([$d[]|select(.repaired)]|length), ($p|avg(.sec)|if type=="number" then round else . end),
      ($p|map(.sec)|min // "-"), ($p|map(.sec)|max // "-"),
      ($d|avg(.steps)), ($d|avg(.reads)), (($all|length) - ($d|length))])
  | @tsv' | column -t
