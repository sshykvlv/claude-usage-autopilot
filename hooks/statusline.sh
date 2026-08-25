#!/bin/zsh
# statusline — wraps your existing statusline command (kept in config as
# "wrap_command" by the installer) and appends a tiny quota segment:
#   h35%  = 5-hour session window used     w37% = weekly quota used
#   color = verdict (yellow watch · orange delegate-more · red critical)
#   ECO   = autonomous eco-mode active     nothing shown when all is calm
# Also publishes a per-session bridge (model + context%) for the grind detector.
# Any failure degrades to your original statusline untouched.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

CUA_CFG_DIR="${CUA_CFG_DIR:-$HOME/.config/claude-usage-autopilot}"
CUA_CACHE="${CUA_CACHE:-$HOME/.cache/claude-usage-autopilot}"
CFG="$CUA_CFG_DIR/config.json"
STATE="$CUA_CACHE/state.json"

input=$(cat)
wrap=$(jq -r '.wrap_command // empty' "$CFG" 2>/dev/null)
if [[ -n "$wrap" ]]; then
  base=$(print -r -- "$input" | eval "$wrap" 2>/dev/null)
else
  m=$(print -r -- "$input" | jq -r '.model.display_name // "Claude"' 2>/dev/null)
  d=$(print -r -- "$input" | jq -r '.workspace.current_dir // "~"' 2>/dev/null)
  base=$'\e[2m'"$m"$' | '"${d:t}"$'\e[0m'
fi

# session bridge for the grind detector (model + context used %)
sb=$(print -r -- "$input" | jq -r '[(.session_id//""), (.model.display_name//""), (.context_window.remaining_percentage//""|tostring)] | @tsv' 2>/dev/null)
sid=${sb%%$'\t'*}; rest=${sb#*$'\t'}; smodel=${rest%%$'\t'*}; srem=${rest#*$'\t'}
if [[ "$sid" =~ '^[a-zA-Z0-9-]+$' && -n "$smodel" ]]; then
  sctx=""
  [[ "$srem" == <-> || "$srem" == <->.<-> ]] && sctx=$(( 100 - ${srem%.*} ))
  print -r -- "{\"model\":\"$smodel\",\"ctx_used\":${sctx:-null},\"ts\":$(date +%s)}" \
    > "$CUA_CACHE/sess-$sid.json.tmp" 2>/dev/null && mv "$CUA_CACHE/sess-$sid.json.tmp" "$CUA_CACHE/sess-$sid.json" 2>/dev/null
fi

seg=""
if [[ -f $CUA_CACHE/mode.json ]]; then
  seg=$' \e[5;31mECO\e[0m'
elif [[ -f $STATE ]]; then
  band=$(jq -r '.band // empty' "$STATE" 2>/dev/null)
  aw=$(jq -r '.week // empty' "$STATE" 2>/dev/null)
  as=$(jq -r '.session // empty' "$STATE" 2>/dev/null)
  s5=""
  if [[ "$as" == <-> ]]; then
    if   (( as >= 80 )); then s5=$' \e[31mh'"${as}"$'%\e[0m'
    elif (( as >= 60 )); then s5=$' \e[33mh'"${as}"$'%\e[0m'
    else s5=$' \e[2mh'"${as}"$'%\e[0m'
    fi
  fi
  case $band in
    WATCH)        seg="$s5"$' \e[33mw'"${aw}"$'%\e[0m' ;;
    SELECTIVE)    seg="$s5"$' \e[38;5;208mw'"${aw}"$'%\e[0m' ;;
    CONSERVATION) seg="$s5"$' \e[31mw'"${aw}"$'%\e[0m' ;;
    EXHAUSTED)    seg="$s5"$' \e[5;31mw100%\e[0m' ;;
    OK)           [[ "$as" == <-> ]] && (( as >= 60 )) && seg="$s5" ;;
    *) ;;
  esac
fi
[[ -n "$sid" && -f $CUA_CACHE/grind-flag-$sid ]] && seg+=$' \e[33mGRIND\e[0m'

print -rn -- "$base$seg"
