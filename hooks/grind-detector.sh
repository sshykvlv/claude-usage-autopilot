#!/bin/zsh
# grind-detector (optional extra) — PostToolUse hook, matcher ^(Edit|Write|NotebookEdit|Bash)$.
# Detects a "long grind": dozens of edits on an expensive model burn the weekly budget
# with no quality gain. Weighted score per session (Edit/Write/NB +2, Bash +1) stored
# atomically as appended bytes (score = file size; read-modify-write loses increments
# under parallel calls). At threshold: reads model+context from the statusline bridge;
# a cheap model silences the detector forever, an unknown model does NOT (a broken
# bridge must not silently disable it). Expensive model + context >=50% (or unknown)
# -> ONE advisory injection + a GRIND statusline token. Done-marker is written only
# after the advisory was successfully emitted. Kill-switch: CUA_GRIND_OFF=1.
[[ ${CUA_GRIND_OFF:-0} == 1 ]] && exit 0
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

payload=$(cat 2>/dev/null)
[[ -n "$payload" ]] || exit 0
[[ "$payload" =~ '"session_id":"([a-zA-Z0-9-]+)"' ]] || exit 0
sid=$match[1]
[[ "$payload" =~ '"tool_name":"([A-Za-z]+)"' ]] || exit 0
tool=$match[1]

CUA_CACHE="${CUA_CACHE:-$HOME/.cache/claude-usage-autopilot}"
CNT=$CUA_CACHE/grind-$sid.score
DONE=$CUA_CACHE/grind-$sid.done
FLAG=$CUA_CACHE/grind-flag-$sid
[[ -f $DONE ]] && exit 0

case $tool in
  Edit|Write|NotebookEdit) print -n -- "xx" >> "$CNT" 2>/dev/null ;;
  Bash)                    print -n -- "x"  >> "$CNT" 2>/dev/null ;;
  *) exit 0 ;;
esac
score=$(stat -f %z "$CNT" 2>/dev/null || echo 0)
(( score < ${CUA_GRIND_THRESHOLD:-40} )) && exit 0

B=$CUA_CACHE/sess-$sid.json
model=$(jq -r '.model // empty' "$B" 2>/dev/null)
[[ -n "$model" ]] || exit 0
case "$model" in
  *[Oo]pus*|*[Ff]able*) : ;;
  *) : > "$DONE"; exit 0 ;;
esac
ctx=$(jq -r '.ctx_used // empty' "$B" 2>/dev/null)
if [[ "$ctx" == <-> ]] && (( ctx < 50 )); then exit 0; fi

msg="GRIND: this session has score=$score edits/commands on an expensive model ($model), context ${ctx:-?}%. Suggest to the user ONCE, in one sentence: switch the rest of this session to a cheaper model (/model sonnet) or delegate the remaining mechanical work. Do not insist."
if jq -n --arg c "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c},suppressOutput:true}'; then
  : > "$DONE"; : > "$FLAG"
fi
exit 0
