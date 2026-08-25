#!/bin/zsh
# quota-engine — reads server-truth usage for the Claude subscription (and optional
# Codex/ChatGPT accounts), computes weekly pace + a routing band, writes state.json
# and a human snapshot. Percentages come from the providers' own APIs, so plan size
# is already baked in. macOS only (Keychain). Zero LLM calls; costs one HTTPS request.
#
# Band model: pace = (fraction of weekly budget burned) / (fraction of week elapsed).
#   OK <=0.9 · WATCH <=1.2 · SELECTIVE <=1.5 · CONSERVATION >1.5 (confirmed) · EXHAUSTED
# Early-week noise guard: scary verdicts suppressed while <10% of the window elapsed
# and absolute burn <20%. Missing data degrades to band UNKNOWN, never to a false alarm.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin"

CUA_CFG_DIR="${CUA_CFG_DIR:-$HOME/.config/claude-usage-autopilot}"
CUA_CACHE="${CUA_CACHE:-$HOME/.cache/claude-usage-autopilot}"
CFG="$CUA_CFG_DIR/config.json"
mkdir -p "$CUA_CACHE"
now=$(date +%s)

cfg() { jq -r "($1) // empty" "$CFG" 2>/dev/null }

out=""
emit() { out+="$1"$'\n' }

emit "=== claude-usage-autopilot snapshot $(date '+%H:%M') (server truth) ==="

# --- Claude subscription: OAuth usage endpoint via the Claude Code Keychain token ---
tok=$(security find-generic-password -w -s "Claude Code-credentials" 2>/dev/null | jq -r '.claudeAiOauth.accessToken // empty')
a_week=""; a_5h=""; a_scoped=""; a_scoped_name=""; a_reset=""
auth_issue=""
if [[ -z "$tok" ]]; then
  auth_issue="Claude Code token not found in Keychain — run \`claude\` and /login"
  emit "Claude:   no token (login needed)"
else
  usage=$(curl -s -m 10 "https://api.anthropic.com/api/oauth/usage" \
    -H "Authorization: Bearer $tok" -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: claude-code/2.0.0" 2>/dev/null)
  line=$(print -r -- "$usage" | jq -r '
    if .limits then
      "Claude:   " + ([.limits[] |
        (if .kind=="session" then "5h" elif .kind=="weekly_all" then "week"
         elif .kind=="weekly_scoped" then (.scope.model.display_name // "scoped") else .kind end)
        + " \(.percent)%" + (if .percent>=90 then "!!" elif .percent>=70 then "!" else "" end)
      ] | join(" · "))
      + " (week resets " + ((.limits[] | select(.kind=="weekly_all") | .resets_at | split("T")[0]) // "?") + ")"
    else empty end' 2>/dev/null)
  if [[ -z "$line" ]]; then
    emit "Claude:   usage endpoint error (transient or API change)"
  else
    emit "$line"
    a_5h=$(print -r -- "$usage" | jq -r '[.limits[]|select(.kind=="session")][0].percent // empty')
    a_week=$(print -r -- "$usage" | jq -r '[.limits[]|select(.kind=="weekly_all")][0].percent // empty')
    a_scoped=$(print -r -- "$usage" | jq -r '[.limits[]|select(.kind=="weekly_scoped")][0].percent // empty')
    a_scoped_name=$(print -r -- "$usage" | jq -r '[.limits[]|select(.kind=="weekly_scoped")][0].scope.model.display_name // empty')
    a_reset=$(print -r -- "$usage" | jq -r '[.limits[]|select(.kind=="weekly_all")][0].resets_at // empty | sub("\\..*$";"Z") | try fromdateiso8601 // empty')
  fi
fi

# --- Optional Codex/ChatGPT accounts: rate_limits telemetry from local rollout files ---
typeset -a codex_json
codex_json=()
i=0
for chome in ${(f)"$(cfg '.codex_homes[]')"}; do
  chome=${chome/#\~/$HOME}; ((i++))
  [[ -d $chome/sessions ]] || { emit "Codex#$i:  no sessions dir ($chome)"; continue }
  rl=""
  for f in ${(f)"$(ls -t "$chome"/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | head -5)"}; do
    for l in ${(f)"$(grep '"rate_limits"' "$f" 2>/dev/null | tail -3)"}; do
      cand=$(print -r -- "$l" | jq -c '.. | objects | select(has("rate_limits")) | .rate_limits' 2>/dev/null | tail -1)
      [[ -n "$cand" ]] && rl=$cand
    done
    [[ -n "$rl" ]] && { src=$f; break }
  done
  if [[ -z "$rl" ]]; then emit "Codex#$i:  no telemetry yet (make one codex call)"; continue; fi
  pct=$(print -r -- "$rl" | jq -r '.primary.used_percent // empty')
  [[ -z "$pct" ]] && { emit "Codex#$i:  telemetry parse failed"; continue }
  age_h=$(( (now - $(stat -f %m "$src")) / 3600 ))
  stale=""; (( age_h >= 6 )) && stale=" [${age_h}h old]"
  emit "Codex#$i:  week ${pct%.*}% used (rolling 7d)$stale"
  codex_json+=("{\"home\":\"${chome//\"/}\",\"used\":${pct%.*},\"age_h\":$age_h}")
done

# --- weekly pace + band for the Claude account ---
band="UNKNOWN"; reason="no usage data"
sel_pace=$(cfg '.thresholds.selective_pace'); : ${sel_pace:=1.2}
con_pace=$(cfg '.thresholds.conservation_pace'); : ${con_pace:=1.5}
con_week=$(cfg '.thresholds.conservation_week'); : ${con_week:=70}
if [[ -n "$a_week" && -n "$a_reset" ]] && (( a_reset > now )); then
  elapsed=$(( now - (a_reset - 604800) ))
  if (( elapsed > 0 && elapsed < 604800 )); then
    ef=$(( elapsed / 604800.0 ))
    pace=$(( a_week / 100.0 / ef ))
    proj=$(( a_week / ef ))
    days_left=$(( (a_reset - now) / 86400.0 ))
    if   (( a_week >= 100 )); then band="EXHAUSTED"; reason="weekly limit hit"
    elif (( a_week >= con_week && days_left > 1.0 )); then band="CONSERVATION"; reason="week ${a_week}% with $(printf '%.1f' $days_left)d left"
    elif (( pace > con_pace )); then
      if (( ef >= 0.25 || a_week >= 40 )); then band="CONSERVATION"; reason="pace $(printf '%.1f' $pace)x, projected $(printf '%.0f' $proj)% by reset"
      else band="SELECTIVE"; reason="pace $(printf '%.1f' $pace)x early in week"
      fi
    elif (( pace > sel_pace )); then band="SELECTIVE"; reason="pace $(printf '%.1f' $pace)x"
    elif (( pace > 0.9 )); then band="WATCH"; reason="pace $(printf '%.1f' $pace)x"
    else band="OK"; reason="pace $(printf '%.1f' $pace)x"
    fi
    if (( ef < 0.10 && a_week < 20 )) && [[ "$band" == "SELECTIVE" || "$band" == "CONSERVATION" ]]; then
      band="WATCH"; reason="early week, pace still noisy"
    fi
    emit "$(printf 'Pace:     %.1fx burn · %s%% used in %.0f%% of the week · ~%.0f%% by reset (%.1fd left)' "$pace" "$a_week" "$((ef*100))" "$proj" "$days_left")"
  fi
fi
emit "Band:     $band — $reason"

# --- structured state (single source of truth for hooks/CLI) ---
cx="[]"; (( ${#codex_json} > 0 )) && cx="[${(j:,:)codex_json}]"
jq -n \
  --arg band "$band" --arg reason "$reason" --arg auth "$auth_issue" \
  --arg a5h "${a_5h:-}" --arg aw "${a_week:-}" --arg asc "${a_scoped:-}" \
  --arg ascn "${a_scoped_name:-}" --arg ar "${a_reset:-}" --argjson cx "$cx" \
  '{ts: now|floor, band:$band, reason:$reason,
    auth_issue: (if $auth=="" then null else $auth end),
    session: ($a5h|if .=="" then null else tonumber end),
    week: ($aw|if .=="" then null else tonumber end),
    scoped: ($asc|if .=="" then null else tonumber end),
    scoped_model: (if $ascn=="" then null else $ascn end),
    week_resets: ($ar|if .=="" then null else tonumber end),
    codex: $cx}' > "$CUA_CACHE/state.json.tmp" 2>/dev/null && mv "$CUA_CACHE/state.json.tmp" "$CUA_CACHE/state.json"

print -rn -- "$out"
