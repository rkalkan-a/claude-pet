#!/bin/bash
# Hooks Claude Code up to Claude Pet and starts it at login. Backs up settings.json first.
set -e
cp ~/.claude/settings.json ~/.claude/settings.json.bak-pet
rm -f ~/.claude/pet/sessions/t*.json
/opt/homebrew/bin/python3 - <<'EOF'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
s = json.load(open(p))
cmd = "/opt/homebrew/bin/python3 ~/.claude/pet/hook.py"
hooks = s.setdefault("hooks", {})
for ev in ["UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SubagentStop", "SessionEnd", "PermissionRequest"]:
    if any(cmd in h.get("command", "") for e in hooks.get(ev, []) for h in e.get("hooks", [])):
        continue  # already installed
    h = {"type": "command", "command": cmd}
    if ev == "PermissionRequest": h["timeout"] = 600
    entry = {"hooks": [h]}
    if ev in ("PreToolUse", "PermissionRequest"): entry["matcher"] = "*"
    hooks.setdefault(ev, []).append(entry)
json.dump(s, open(p, "w"), indent=2)
print("hooks added:", list(hooks))
EOF
cat > ~/Library/LaunchAgents/com.claudepet.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.claudepet</string>
<key>ProgramArguments</key><array><string>$HOME/.claude/pet/ClaudePet</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
PLIST
pkill ClaudePet || true
launchctl unload ~/Library/LaunchAgents/com.claudepet.plist 2>/dev/null || true
launchctl load ~/Library/LaunchAgents/com.claudepet.plist
echo "Claude Pet installed. New Claude sessions will show up top-right."
