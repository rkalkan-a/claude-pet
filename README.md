# Claude Pet

A tiny always-on-top terminal in the corner of your Mac that shows what every Claude Code session is doing, and lets you approve permission requests without switching windows.

- **Folded:** one status line — `✻ 2 working · 1 done ⏺⏺⏺`. Click it to open.
- **Opens by itself** when a session needs approval, asks a question, finishes, or looks stuck (10 min with no activity).
- **Approve from the pet** with Claude Code's own prompt: Yes / Yes and don't ask again / No / Answer in the app (keys 1–4, ↑↓ Return, Esc).
- Live timers, Claude's finish summary, running subagents, sounds and macOS notifications.
- Click a session to jump to it in the Claude desktop app. Click anywhere else to fold it up. Right-click for options.

## How it works

`hook.py` is a Claude Code hook. It writes each session's status to `~/.claude/pet/sessions/`. On a `PermissionRequest` it waits for your answer from the pet, and if you don't answer within 9 minutes, Claude shows its normal prompt. It never approves anything on its own.

`ClaudePet.swift` is a small macOS app: a floating panel with a web view (`pet.html`) that reads those files.

## Install (macOS)

```bash
./build.sh                       # builds ~/.claude/pet/ClaudePet.app and copies the hook + UI there
bash ~/.claude/pet/install.sh    # adds the hooks to ~/.claude/settings.json (backs it up first) and starts the pet at login
```

`build.sh` copies `install.sh` to `~/.claude/pet/` for you. Run `./build.sh` again after any change.

**Uninstall:** restore `~/.claude/settings.json.bak-pet`, delete `~/Library/LaunchAgents/com.claudepet.plist`, then delete `~/.claude/pet`.
