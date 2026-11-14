#!/usr/bin/env bash
# Explainer monitor: last N runs with result, cache hit on step 1, and the files the explainer touched.
D=${VISUAL_EXPLAINER_HOOK_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/visual-explainer-hook}
for f in $(ls -t "$D"/runs/*.jsonl 2>/dev/null | head -"${1:-5}"); do
  id=$(basename "$f" .jsonl)
  jq -rs --arg id "$id" 'def t: sub("\\.[0-9]+Z$"; "Z") | fromdate;
    ((.[-1].timestamp | t) - (.[0].timestamp | t)) as $sec
    | (map(select(.type=="thinking_level_change") | .thinkingLevel) | last) as $th
    | [.[] | select(.type=="message" and .message.role=="assistant") | .message] as $m
    | ($m[0].usage) as $u
    | (if ($m | length) == 0 or ($m[-1].stopReason // "") == "toolUse" then "  ⏳ running (or died)" else "" end) as $run
    | "\($id)\($run)  time=\($sec)s  effort=\($th)  steps=\($m|length)  cache(step1)=\($u.cacheRead // 0)/\(($u.cacheRead // 0) + ($u.input // 0))",
      "  reply: \(($m[-1].content // []) | map(select(.type=="text") | .text) | join(" ") | .[0:100])",
      ($m[] | .content[]? | select(.type=="toolCall") | "  \(.name) \(.arguments.path // "")")' "$f"
done
