#!/bin/zsh
# uninstall — reverts everything install.sh did: hooks out of settings.json,
# statusline restored to the wrapped original, launchd agent removed, files deleted.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

DEST="$HOME/.local/share/claude-usage-autopilot"
CFG_DIR="$HOME/.config/claude-usage-autopilot"
SETTINGS="$HOME/.claude/settings.json"
PLIST="$HOME/Library/LaunchAgents/com.claude-usage-autopilot.watch.plist"

launchctl unload "$PLIST" 2>/dev/null
rm -f "$PLIST"

if [[ -f "$SETTINGS" ]]; then
  cp "$SETTINGS" "$SETTINGS.cua-uninstall-backup"
  wrap=$(jq -r '.wrap_command // empty' "$CFG_DIR/config.json" 2>/dev/null)
  tmp=$(mktemp)
  jq --arg w "$wrap" '
    .hooks = ((.hooks // {}) | with_entries(.value = (.value | map(
        select((.hooks // []) | map(.command // "") | any(contains("claude-usage-autopilot")) | not)
      )) | select(.value != []))) |
    (if (.statusLine.command // "" | contains("claude-usage-autopilot")) then
       (if $w == "" then del(.statusLine) else .statusLine = {type:"command", command:$w} end)
     else . end)
  ' "$SETTINGS" > "$tmp" && jq -e . "$tmp" >/dev/null && mv "$tmp" "$SETTINGS"
fi

rm -f "$HOME/.local/bin/cua"
rm -rf "$DEST" "$HOME/.cache/claude-usage-autopilot"
echo "claude-usage-autopilot removed. Config kept at $CFG_DIR (delete manually if unwanted)."
echo "Restart Claude Code sessions to drop the hooks."
