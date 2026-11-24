#!/bin/bash
# Hooks Claude Code up to Claude Pet and starts it at login. Backs up settings.json first. Safe to run again.
set -e
mkdir -p ~/.claude
[ -f ~/.claude/settings.json ] || echo '{}' > ~/.claude/settings.json
cp ~/.claude/settings.json ~/.claude/settings.json.bak-pet
python3 - <<'EOF'
import json, os, sys
p = os.path.expanduser("~/.claude/settings.json")
s = json.load(open(p))
cmd = f"{sys.executable} ~/.claude/pet/hook.py"  # the python3 that ran this installer
hooks = s.setdefault("hooks", {})
for ev in ["UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SubagentStop", "SessionEnd", "PermissionRequest"]:
    if any("pet/hook.py" in h.get("command", "") for e in hooks.get(ev, []) for h in e.get("hooks", [])):
        continue  # already installed
    h = {"type": "command", "command": cmd}
    if ev == "PermissionRequest": h["timeout"] = 600
    entry = {"hooks": [h]}
    if ev in ("PreToolUse", "PermissionRequest"): entry["matcher"] = "*"
    hooks.setdefault(ev, []).append(entry)
json.dump(s, open(p, "w"), indent=2)
print("Claude Code hooks installed:", ", ".join(hooks))
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
pkill -f ClaudePet.app || true
launchctl unload ~/Library/LaunchAgents/com.claudepet.plist 2>/dev/null || true
launchctl load ~/Library/LaunchAgents/com.claudepet.plist
echo "Claude Pet installed. Sessions you start from now on show up in the bottom-right corner."
