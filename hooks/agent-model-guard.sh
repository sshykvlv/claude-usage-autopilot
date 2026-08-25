#!/bin/zsh
# agent-model-guard (optional extra) — PreToolUse hook, matcher ^Agent$.
# Blocks spawning a GENERIC subagent without an explicit `model`: generic agents
# inherit the main-loop model (often the most expensive one) and silently burn its
# weekly cap on search mechanics. Custom agent types pass through untouched (their
# definitions pin their own models); `fork` passes (model is ignored by contract).
# Retry-loop cap: 3 blocks within 5 min -> the guard gives up and allows (a stuck
# automation is worse than a burned percent). Kill-switch: CUA_GUARD_OFF=1.
[[ ${CUA_GUARD_OFF:-0} == 1 ]] && exit 0
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

payload=$(cat 2>/dev/null)
[[ -n "$payload" ]] || exit 0
tool=$(print -r -- "$payload" | jq -r '.tool_name // empty' 2>/dev/null)
[[ "$tool" == "Agent" ]] || exit 0
model=$(print -r -- "$payload" | jq -r '.tool_input.model // empty' 2>/dev/null)
[[ -n "$model" ]] && exit 0
st=$(print -r -- "$payload" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)
case "$st" in
  ""|general-purpose|Explore|Plan|claude) : ;;
  *) exit 0 ;;
esac

CUA_CACHE="${CUA_CACHE:-$HOME/.cache/claude-usage-autopilot}"
STRIKES=$CUA_CACHE/guard.strikes
now=$(date +%s); s_cnt=0; s_ts=0
if [[ -f $STRIKES ]]; then
  s_cnt=$(cut -d' ' -f1 "$STRIKES" 2>/dev/null); s_ts=$(cut -d' ' -f2 "$STRIKES" 2>/dev/null)
  [[ "$s_cnt" == <-> ]] || s_cnt=0; [[ "$s_ts" == <-> ]] || s_ts=0
  (( now - s_ts > 300 )) && s_cnt=0
fi
(( s_cnt >= 3 )) && { rm -f "$STRIKES"; exit 0 }
print -r -- "$(( s_cnt + 1 )) $now" > "$STRIKES.tmp" 2>/dev/null && mv "$STRIKES.tmp" "$STRIKES" 2>/dev/null

cat >&2 <<'MSG'
Agent call without an explicit model: a generic subagent inherits the main-loop model and burns its weekly cap. Retry the call with model set explicitly: "haiku" for mechanics/summaries, "sonnet" for search/reading/normal work (default), "opus" only for real depth. Guard kill-switch: CUA_GUARD_OFF=1.
MSG
exit 2
