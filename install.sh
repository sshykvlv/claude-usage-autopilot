#!/bin/zsh
# claude-usage-autopilot installer (macOS). Idempotent; everything it touches is
# backed up and uninstall.sh reverts it. What it does:
#   1. copies the tool to ~/.local/share/claude-usage-autopilot + symlinks `cua`
#   2. writes ~/.config/claude-usage-autopilot/config.json (keeps existing)
#   3. registers hooks in ~/.claude/settings.json (backup kept next to it):
#      statusline wrapper (your current statusline is preserved and wrapped),
#      session-inject on UserPromptSubmit; extras (grind detector, agent guard)
#      only when INSTALL_EXTRAS=1
#   4. installs a launchd agent (every 30 min) and runs the first tick
set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

command -v jq >/dev/null || { echo "jq is required: brew install jq"; exit 1 }
[[ "$(uname)" == "Darwin" ]] || { echo "macOS only for now (Keychain/launchd)"; exit 1 }

SRC="${0:A:h}"
DEST="$HOME/.local/share/claude-usage-autopilot"
BIN="$HOME/.local/bin"
CFG_DIR="$HOME/.config/claude-usage-autopilot"
SETTINGS="$HOME/.claude/settings.json"
PLIST="$HOME/Library/LaunchAgents/com.claude-usage-autopilot.watch.plist"

mkdir -p "$DEST" "$BIN" "$CFG_DIR" "$HOME/.cache/claude-usage-autopilot"
cp -R "$SRC/bin" "$SRC/lib" "$SRC/hooks" "$SRC/uninstall.sh" "$DEST/"
chmod +x "$DEST"/bin/* "$DEST"/lib/*.sh "$DEST"/hooks/*.sh "$DEST/uninstall.sh"
ln -sf "$DEST/bin/cua" "$BIN/cua"

# config (never overwrite an existing one)
if [[ ! -f "$CFG_DIR/config.json" ]]; then
  cp "$SRC/config.example.json" "$CFG_DIR/config.json"
fi

# settings.json: backup once per run, then register hooks idempotently
[[ -f "$SETTINGS" ]] || { mkdir -p "$HOME/.claude"; echo '{}' > "$SETTINGS" }
cp "$SETTINGS" "$SETTINGS.cua-backup"

SL="zsh \"$DEST/hooks/statusline.sh\""
IJ="zsh \"$DEST/hooks/session-inject.sh\""
GD="zsh \"$DEST/hooks/grind-detector.sh\""
GU="zsh \"$DEST/hooks/agent-model-guard.sh\""

# wrap existing statusline (idempotent: skip if already ours)
cur_sl=$(jq -r '.statusLine.command // empty' "$SETTINGS")
if [[ "$cur_sl" != *claude-usage-autopilot* ]]; then
  if [[ -n "$cur_sl" ]]; then
    jq --arg w "$cur_sl" '.wrap_command = $w' "$CFG_DIR/config.json" > "$CFG_DIR/config.json.tmp" && mv "$CFG_DIR/config.json.tmp" "$CFG_DIR/config.json"
  fi
  jq --arg c "$SL" '.statusLine = {type:"command", command:$c}' "$SETTINGS" > "$SETTINGS.tmp" && jq -e . "$SETTINGS.tmp" >/dev/null && mv "$SETTINGS.tmp" "$SETTINGS"
fi

add_hook() { # $1=event $2=matcher(optional, "" = none) $3=command
  local ev="$1" m="$2" cmd="$3"
  jq -e --arg c "$cmd" ".hooks.${ev} // [] | map(.hooks[]?.command) | index(\$c)" "$SETTINGS" >/dev/null 2>&1 && return 0
  if [[ -n "$m" ]]; then
    jq --arg m "$m" --arg c "$cmd" ".hooks.${ev} = (.hooks.${ev} // []) + [{matcher:\$m, hooks:[{type:\"command\", command:\$c, timeout:10}]}]" "$SETTINGS" > "$SETTINGS.tmp"
  else
    jq --arg c "$cmd" ".hooks.${ev} = (.hooks.${ev} // []) + [{hooks:[{type:\"command\", command:\$c, timeout:10}]}]" "$SETTINGS" > "$SETTINGS.tmp"
  fi
  jq -e . "$SETTINGS.tmp" >/dev/null && mv "$SETTINGS.tmp" "$SETTINGS"
}

add_hook UserPromptSubmit "" "$IJ"
if [[ "${INSTALL_EXTRAS:-0}" == 1 ]]; then
  add_hook PostToolUse '^(Edit|Write|NotebookEdit|Bash)$' "$GD"
  add_hook PreToolUse '^Agent$' "$GU"
fi

# launchd agent
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.claude-usage-autopilot.watch</string>
  <key>ProgramArguments</key><array><string>/bin/zsh</string><string>$DEST/lib/watch.sh</string></array>
  <key>StartInterval</key><integer>1800</integer>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

zsh "$DEST/lib/watch.sh" || true
echo ""
echo "claude-usage-autopilot installed."
echo "  status:   cua status        (add ~/.local/bin to PATH if needed)"
echo "  snapshot: $HOME/.cache/claude-usage-autopilot/snapshot.txt"
echo "  config:   $CFG_DIR/config.json"
echo "  undo:     cua uninstall"
echo "Restart your Claude Code sessions to pick up the statusline and hooks."
