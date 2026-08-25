#!/bin/zsh
# watch — the autopilot tick (launchd, every 30 min): runs the engine, then manages
# eco-mode transitions with the safety guards, appends history, sends notifications.
#
# Eco-mode contract (all guards required — they exist because each one caught a real
# failure during development):
#   ENTER: band CONSERVATION/EXHAUSTED confirmed by 2 consecutive ticks (a config
#     flip NEVER happens on a single reading; immediate ticks only warn). Writes a
#     single transactional mode.json {prev_model, settings_hash, week_resets} BEFORE
#     touching settings.json; flips .model -> eco_model for NEW sessions only.
#   EXIT: band OK/WATCH for 2 consecutive ticks (usually right after the weekly
#     reset). Restores the previous model ONLY if settings.json still carries our
#     own md5 (any manual edit after the flip = hands off, notify instead).
#   TTL: eco that survives past the weekly reset cries once a day, never auto-reverts
#     on UNKNOWN data.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin"

LIB="${0:A:h}"
CUA_CFG_DIR="${CUA_CFG_DIR:-$HOME/.config/claude-usage-autopilot}"
CUA_CACHE="${CUA_CACHE:-$HOME/.cache/claude-usage-autopilot}"
CFG="$CUA_CFG_DIR/config.json"
SETTINGS="${CUA_SETTINGS:-$HOME/.claude/settings.json}"
STATE="$CUA_CACHE/state.json"
SNAP="$CUA_CACHE/snapshot.txt"
MODE="$CUA_CACHE/mode.json"
SEEN="$CUA_CACHE/band.seen"
NOTIFIED="$CUA_CACHE/band.notified"
HIST="$CUA_CACHE/history.jsonl"
LOCK="$CUA_CACHE/watch.lock"

cfg() { jq -r "($1) // empty" "$CFG" 2>/dev/null }
now=$(date +%s)

if ! mkdir "$LOCK" 2>/dev/null; then
  (( now - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) < 600 )) && exit 0
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 0
fi
trap 'rm -rf "$LOCK"' EXIT

out=$(zsh "$LIB/quota-engine.sh" 2>/dev/null)

notify() { # $1 = message; macOS always (if enabled), Telegram if configured
  [[ "$(cfg '.notify.macos')" == "false" ]] || \
    osascript -e "display notification \"$(print -r -- "$1" | head -c 180 | sed 's/"/\\"/g')\" with title \"claude-usage-autopilot\"" 2>/dev/null
  local tk chat; tk=$(cfg '.notify.telegram_bot_token'); chat=$(cfg '.notify.telegram_chat_id')
  [[ -n "$tk" && -n "$chat" ]] || return 0
  curl -s -m 10 "https://api.telegram.org/bot${tk}/sendMessage" -d chat_id="$chat" \
    --data-urlencode text="$1" | grep -q '"ok":true'
}

set_model() { # atomic .model edit with a lost-update guard against concurrent /model
  local want="$1" cur mt1 mt2 perms
  cur=$(jq -r '.model // empty' "$SETTINGS" 2>/dev/null)
  [[ -z "$cur" ]] && return 1
  [[ "$cur" == "$want" ]] && return 0
  mt1=$(stat -f %m "$SETTINGS" 2>/dev/null); perms=$(stat -f %Lp "$SETTINGS" 2>/dev/null)
  jq --arg m "$want" '.model = $m' "$SETTINGS" > "$SETTINGS.cuatmp" 2>/dev/null || { rm -f "$SETTINGS.cuatmp"; return 1 }
  jq -e . "$SETTINGS.cuatmp" >/dev/null 2>&1 || { rm -f "$SETTINGS.cuatmp"; return 1 }
  mt2=$(stat -f %m "$SETTINGS" 2>/dev/null)
  [[ "$mt1" != "$mt2" ]] && { rm -f "$SETTINGS.cuatmp"; return 1 }
  [[ -n "$perms" ]] && chmod "$perms" "$SETTINGS.cuatmp" 2>/dev/null
  mv "$SETTINGS.cuatmp" "$SETTINGS"
}

shash() { /sbin/md5 -q "$SETTINGS" 2>/dev/null }
mget() { jq -r "($1) // empty" "$MODE" 2>/dev/null }
ECO_MODEL=$(cfg '.eco.eco_model'); : ${ECO_MODEL:=sonnet}
ECO_ON=$(cfg '.eco.enabled'); : ${ECO_ON:=true}

enter_eco() { # $1=band $2=reason $3=week%
  local prevm resets flip="switched new sessions to $ECO_MODEL"
  prevm=$(jq -r '.model // empty' "$SETTINGS" 2>/dev/null)
  resets=$(jq -r '.week_resets // 0' "$STATE" 2>/dev/null)
  jq -n --arg pm "$prevm" --arg em "$ECO_MODEL" --arg b "$1" --argjson ts "$now" --argjson rst "${resets:-0}" \
    '{band:$b, prev_model:(if $pm=="" or $pm==$em then null else $pm end),
      settings_hash:null, entered_at:$ts, week_resets:$rst, overdue_at:0}' \
    > "$MODE.tmp" 2>/dev/null && mv "$MODE.tmp" "$MODE"
  if set_model "$ECO_MODEL"; then
    jq --arg h "$(shash)" '.settings_hash=$h' "$MODE" > "$MODE.tmp" 2>/dev/null && mv "$MODE.tmp" "$MODE"
  else
    flip="model flip failed (race/parse) — will retry in 30 min"
  fi
  notify "🔻 Eco-mode ON automatically: $1 — $2 (week ${3}%). $flip. Open sessions untouched — restart them to apply. Undo: rm $MODE and restore model in settings.json." \
    && print -r -- "enter" > "$NOTIFIED.tmp" && mv "$NOTIFIED.tmp" "$NOTIFIED"
}

exit_eco() { # $1=reason
  local prevm cur h_now h_ours restored
  prevm=$(mget '.prev_model'); cur=$(jq -r '.model // empty' "$SETTINGS" 2>/dev/null)
  h_now=$(shash); h_ours=$(mget '.settings_hash')
  if [[ -z "$prevm" ]]; then restored="model untouched (was already $ECO_MODEL)"
  elif [[ "$cur" != "$ECO_MODEL" ]]; then restored="model changed manually ($cur) — leaving it"
  elif [[ -n "$h_ours" && "$h_now" != "$h_ours" ]]; then
    restored="settings.json edited after the flip — not auto-reverting; restore manually if wanted: $prevm"
  elif set_model "$prevm"; then restored="model restored: $prevm"
  else restored="restore failed — set manually: $prevm"
  fi
  rm -f "$MODE"
  notify "✅ Eco-mode OFF automatically ($1). $restored." && : > "$NOTIFIED"
}

state_ts=$(jq -r '.ts // 0' "$STATE" 2>/dev/null); [[ -z "$state_ts" ]] && state_ts=0
if (( now - state_ts <= 600 )); then
  band=$(jq -r '.band // "UNKNOWN"' "$STATE" 2>/dev/null)
  reason=$(jq -r '.reason // ""' "$STATE" 2>/dev/null)
  week=$(jq -r '.week // -1' "$STATE" 2>/dev/null)
  jq -c . "$STATE" >> "$HIST" 2>/dev/null
  prev=$(cat "$SEEN" 2>/dev/null); notified=$(cat "$NOTIFIED" 2>/dev/null)
  print -r -- "$band" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"

  if [[ "$ECO_ON" != "false" ]]; then
    case "$band" in
      CONSERVATION|EXHAUSTED)
        if [[ ! -f $MODE ]]; then
          if [[ "$prev" == "$band" ]]; then enter_eco "$band" "$reason" "$week"
          elif (( ${week%.*} >= 85 )) && [[ "$notified" != "warn" ]]; then
            notify "!! Claude week at ${week}% — critical. Eco-mode will engage automatically if confirmed in 30 min." \
              && { print -r -- "warn" > "$NOTIFIED.tmp"; mv "$NOTIFIED.tmp" "$NOTIFIED" }
          fi
        elif [[ -f $MODE && "$(jq -r '.model // empty' "$SETTINGS" 2>/dev/null)" != "$ECO_MODEL" && -z "$(mget '.settings_hash')" ]]; then
          set_model "$ECO_MODEL" && { jq --arg h "$(shash)" '.settings_hash=$h' "$MODE" > "$MODE.tmp" 2>/dev/null && mv "$MODE.tmp" "$MODE" }
        fi ;;
      OK|WATCH)
        if [[ -f $MODE ]] && [[ "$prev" == "OK" || "$prev" == "WATCH" ]]; then exit_eco "$reason"
        elif [[ ! -f $MODE && "$notified" == "warn" ]]; then : > "$NOTIFIED"
        fi ;;
      *) : ;;
    esac
    if [[ -f $MODE ]]; then
      wr=$(mget '.week_resets'); oa=$(mget '.overdue_at')
      [[ "$wr" == <-> ]] || wr=0; [[ "$oa" == <-> ]] || oa=0
      if (( wr > 0 && now > wr + 21600 && now - oa > 86400 )); then
        notify "⚠️ Eco-mode looks STUCK: the week reset but recovery never confirmed (noisy/missing data). Check $SNAP; undo manually: rm $MODE + restore model." \
          && { jq --argjson t "$now" '.overdue_at=$t' "$MODE" > "$MODE.tmp" 2>/dev/null && mv "$MODE.tmp" "$MODE" }
      fi
    fi
  fi
fi

# per-session detector files older than 2 days (live ones refresh their own mtime)
find "$CUA_CACHE" -maxdepth 1 \( -name 'grind-*' -o -name 'sess-*' -o -name 'seen-*' \) -mtime +2 -delete 2>/dev/null

extra=""
[[ -f $MODE ]] && extra=$'\n'"ECO-MODE ACTIVE (auto since $(date -r "$(mget '.entered_at' 2>/dev/null || echo $now)" '+%d.%m %H:%M' 2>/dev/null)) — new sessions should prefer the cheap model and delegate heavy work."
[[ -n "$out" ]] && { print -r -- "$out$extra" > "$SNAP.tmp" && mv "$SNAP.tmp" "$SNAP" }
