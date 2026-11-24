#!/usr/bin/env python3
"""Claude Code hook -> writes session status for the desktop pet; blocks on PermissionRequest until the pet answers."""
import json, os, sys, time, uuid

ROOT = os.path.expanduser("~/.claude/pet")
SESS, REQ, RESP = (os.path.join(ROOT, d) for d in ("sessions", "requests", "responses"))
for d in (SESS, REQ, RESP):
    os.makedirs(d, exist_ok=True)

WAIT_SECONDS = 540  # must stay under the hook timeout in settings.json (600); after it, Claude's normal prompt shows


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)  # atomic so the app never reads half a file


def describe(tool, inp):
    inp = inp or {}
    if tool == "Bash":
        return "Running: " + (inp.get("description") or inp.get("command", ""))
    if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        return "Editing " + os.path.basename(inp.get("file_path", "") or inp.get("notebook_path", ""))
    if tool == "Read":
        return "Reading " + os.path.basename(inp.get("file_path", ""))
    if tool in ("Grep", "Glob"):
        return "Searching " + str(inp.get("pattern", ""))
    if tool in ("Task", "Agent"):
        return "Agent: " + str(inp.get("description", "subagent"))
    if tool in ("WebFetch", "WebSearch"):
        return "Web: " + str(inp.get("url") or inp.get("query", ""))
    return tool.replace("mcp__", "").split("__")[-1]


def last_reply(ev):
    """First line of Claude's final message, for the 'finished' row. Newer versions pass it; else read the transcript tail."""
    import re
    text = ev.get("last_assistant_message") or ""
    path = ev.get("transcript_path")
    if not text and path and os.path.exists(path):
        with open(path, "rb") as f:
            f.seek(max(0, os.path.getsize(path) - 400_000))
            for line in f.read().decode("utf-8", "ignore").splitlines():
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if d.get("type") == "assistant":
                    parts = [c.get("text", "") for c in d.get("message", {}).get("content", [])
                             if isinstance(c, dict) and c.get("type") == "text"]
                    if any(parts):
                        text = " ".join(parts)
    for line in text.splitlines():
        line = re.sub(r"[*_`#>]+", "", line).strip(" -•")
        if line:
            return line[:200]
    return ""


def rule_label(sugs):
    """Human label for Claude's own 'always allow' suggestions, e.g. 'Bash(npm test:*) for this session'."""
    where = {"session": "this session", "localSettings": "this project", "projectSettings": "this project",
             "userSettings": "everywhere"}
    out = []
    for s in sugs or []:
        if s.get("type") == "addRules" and s.get("behavior", "allow") == "allow":
            rules = ", ".join(r.get("toolName", "") + (f"({r['ruleContent']})" if r.get("ruleContent") else "")
                              for r in s.get("rules", []))
            out.append(f"{rules} in {where.get(s.get('destination'), s.get('destination', ''))}")
        elif s.get("type") == "addDirectories":
            out.append("access to " + ", ".join(s.get("directories", [])))
        elif s.get("type") == "setMode":
            out.append("switch to " + str(s.get("mode")) + " mode")
    return "; ".join(out)


def find_desktop_session(cli_id):
    """Map a Claude Code session id to the desktop app's local_ id (for the claude:// deep link) and its title."""
    import glob
    pattern = os.path.expanduser("~/Library/Application Support/Claude/claude-code-sessions/*/*/local_*.json")
    for p in sorted(glob.glob(pattern), key=os.path.getmtime, reverse=True):
        try:
            d = json.load(open(p))
        except Exception:
            continue
        if cli_id in (d.get("cliSessionId"), d.get("lastAssistantCliSessionId")):
            return d.get("sessionId", ""), d.get("title", "")
    return "", ""  # terminal (CLI) session: no desktop page to open


def main():
    ev = json.load(sys.stdin)
    name = ev.get("hook_event_name", "")
    sid = ev.get("session_id", "unknown")
    spath = os.path.join(SESS, sid + ".json")
    project = os.path.basename(ev.get("cwd", "").rstrip("/")) or "Claude"

    # desktop-app session id + title, looked up once per session and kept in the status file
    prev = {}
    if os.path.exists(spath):
        try:
            prev = json.load(open(spath))
        except Exception:
            pass
    if not prev.get("local") and prev.get("tries", 0) < 5:  # new desktop sessions may not be on disk yet
        prev["tries"] = prev.get("tries", 0) + 1
        prev["local"], title = find_desktop_session(sid)
        if title:
            prev["title"] = title
    project = prev.get("title") or project

    # running subagents ("moons"); entries older than an hour are assumed finished in case a SubagentStop was missed
    agents = [a for a in prev.get("agents", []) if time.time() - a.get("t", 0) < 3600]

    def status(state, text, **extra):
        if ev.get("agent_id") and not text.startswith("↳"):
            text = "↳ " + text  # this event came from a subagent, not the main conversation
        data = {"agents": agents, "id": sid, "project": project, "state": state, "text": text[:200], "ts": time.time(),
                "local": prev.get("local", ""), "title": prev.get("title", ""), "tries": prev.get("tries", 0),
                "started": prev.get("started"), "finished": None}
        data.update(extra)
        write_json(spath, data)

    if name == "SessionEnd":
        if os.path.exists(spath):
            os.remove(spath)
    elif name == "UserPromptSubmit":
        status("working", "Thinking…", started=time.time())  # start of this stretch of work, for the live timer
    elif name == "PreToolUse":
        tool = ev.get("tool_name", "")
        if tool in ("Task", "Agent"):
            agents.append({"desc": str((ev.get("tool_input") or {}).get("description", "subagent"))[:80], "t": time.time()})
        status("working", describe(tool, ev.get("tool_input")))
    elif name == "SubagentStop":
        # shortcut: SubagentStop doesn't say which launch it matches, so drop the oldest; fine for a count
        if agents:
            agents.pop(0)
        status(prev.get("state", "working"), prev.get("text", ""), finished=prev.get("finished"))
    elif name == "Stop":
        status("done", last_reply(ev) or "Finished — your turn", finished=time.time())
    elif name == "Notification":
        # permission prompts are handled by PermissionRequest below; this covers "waiting for input" etc.
        if ev.get("notification_type") != "permission_prompt":
            status("attention", ev.get("message", "Needs your attention"))
    elif name == "PermissionRequest":
        rid = uuid.uuid4().hex
        tool = ev.get("tool_name", "")
        inp = ev.get("tool_input") or {}
        detail = inp.get("command") or inp.get("file_path") or inp.get("url") or json.dumps(inp)[:400]
        sugs = ev.get("permission_suggestions") or []
        write_json(os.path.join(ROOT, "last-permission-request.json"), ev)  # for debugging the format
        status("approval", "Wants to use " + tool)
        rpath, apath = os.path.join(REQ, rid + ".json"), os.path.join(RESP, rid + ".json")
        write_json(rpath, {"id": rid, "session": sid, "project": project, "tool": tool,
                           "summary": describe(tool, inp), "detail": str(detail)[:400], "ts": time.time(),
                           "always": rule_label(sugs)})
        answer = None
        try:
            end = time.time() + WAIT_SECONDS
            while time.time() < end:
                if os.path.exists(apath):
                    with open(apath) as f:
                        answer = json.load(f).get("behavior")
                    os.remove(apath)
                    break
                time.sleep(0.3)
        finally:
            if os.path.exists(rpath):
                os.remove(rpath)
        if answer in ("allow", "always", "deny"):
            status("working", "Denied" if answer == "deny" else "Approved — continuing")
            decision = {"behavior": "deny" if answer == "deny" else "allow"}
            if answer == "always" and sugs:
                decision["updatedPermissions"] = sugs  # apply Claude's own suggested rule, same as its "don't ask again"
            if answer == "deny":
                decision["message"] = "The user denied this from the desktop pet."
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}))
        # no answer ("ask" / timeout): print nothing, Claude shows its normal approval prompt


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # never break Claude because the pet failed
        print(f"claude-pet hook error: {e}", file=sys.stderr)
    sys.exit(0)
