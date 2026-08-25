#!/bin/zsh
# session-inject — UserPromptSubmit hook: surfaces router problems INSIDE the live
# session (auth lost, quota red zone, eco-mode active, stale monitoring), reading
# only the local cache — zero API calls per prompt. Same state is not repeated more
# than once per 30 min per session; a CHANGED state fires immediately.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin"

CUA_CACHE="${CUA_CACHE:-$HOME/.cache/claude-usage-autopilot}"
STATE="$CUA_CACHE/state.json"
SNAP="$CUA_CACHE/snapshot.txt"
MODE="$CUA_CACHE/mode.json"
now=$(date +%s)
[[ -f $STATE || -f $SNAP ]] || exit 0

payload=$(cat 2>/dev/null)
sid=$(print -r -- "$payload" | jq -r '.session_id // empty' 2>/dev/null)
[[ -z "$sid" ]] && sid="ppid-$PPID"
SEEN="$CUA_CACHE/seen-${sid//[^a-zA-Z0-9_-]/}"

typeset -a issues
sev=info
band=""; reason=""; week=""; auth=""
if [[ -f $STATE ]]; then
  band=$(jq -r '.band // ""' "$STATE" 2>/dev/null)
  reason=$(jq -r '.reason // ""' "$STATE" 2>/dev/null)
  week=$(jq -r '.week // ""' "$STATE" 2>/dev/null)
  auth=$(jq -r '.auth_issue // ""' "$STATE" 2>/dev/null)
  scoped=$(jq -r '.scoped // ""' "$STATE" 2>/dev/null)
  scoped_m=$(jq -r '.scoped_model // ""' "$STATE" 2>/dev/null)
fi

if [[ -n "$auth" ]]; then
  issues+=("🔴 AUTH: $auth"); sev=critical
fi
if [[ -f $SNAP ]]; then
  snap_age=$(( (now - $(stat -f %m "$SNAP" 2>/dev/null || echo $now)) / 60 ))
  if (( snap_age > 120 )); then
    issues+=("🟠 Quota snapshot is stale (${snap_age} min) — the watch agent looks broken; do not trust quota numbers.")
    [[ $sev == info ]] && sev=warn
  fi
fi
if [[ -f $MODE ]]; then
  issues+=("🔻 ECO-MODE ACTIVE (engaged automatically) — prefer the cheap model, delegate heavy work, keep this subscription for decisions.")
  [[ $sev == info ]] && sev=warn
elif [[ "$band" == "CONSERVATION" || "$band" == "EXHAUSTED" ]]; then
  issues+=("🔻 Claude weekly budget in the red: $band — $reason (week ${week}%). Eco-mode will engage on the next confirming tick.")
  sev=critical
elif [[ "$band" == "SELECTIVE" ]]; then
  issues+=("🟡 Band SELECTIVE — $reason. Delegate what you can; spend this subscription deliberately.")
fi
if [[ "$scoped" == <-> ]] && (( scoped >= 85 )); then
  issues+=("🟣 ${scoped_m:-Scoped} weekly bucket at ${scoped}% — that model may become unavailable before the shared budget runs out.")
  [[ $sev == info ]] && sev=warn
fi

(( ${#issues} == 0 )) && exit 0

sig=$(print -r -- "${issues[@]}" | /sbin/md5 -q 2>/dev/null)
prev_sig=$(cut -d' ' -f1 "$SEEN" 2>/dev/null); prev_ts=$(cut -d' ' -f2 "$SEEN" 2>/dev/null)
[[ "$prev_ts" == <-> ]] || prev_ts=0
[[ "$sig" == "$prev_sig" ]] && (( now - prev_ts < 1800 )) && exit 0
print -r -- "$sig $now" > "$SEEN.tmp" 2>/dev/null && mv "$SEEN.tmp" "$SEEN" 2>/dev/null

hdr="⚠️ QUOTA STATUS — tell the user about this in one line at the start of your reply, then answer their request:"
[[ $sev == critical ]] && hdr="🔴 QUOTA PROBLEM — tell the user in the FIRST line of your reply:"
ctx="$hdr
$(printf '%s\n' "${issues[@]}")
(source: local cache, no engines were polled; details: cat $SNAP)"

jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c},suppressOutput:true}'
if [[ $sev == critical ]]; then
  osascript -e "display notification \"$(print -r -- "${issues[1]}" | head -c 180 | sed 's/"/\\"/g')\" with title \"claude-usage-autopilot\" sound name \"Basso\"" 2>/dev/null
fi
exit 0
