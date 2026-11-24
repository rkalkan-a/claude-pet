// Claude Pet — floating AI characters showing what each Claude Code session is doing.
// UI lives in pet.html + critters.js (one web view); this file reads hook status files and talks to it.
// Build: swiftc -O -parse-as-library ClaudePet.swift -o ClaudePet
import AppKit
import UserNotifications
import WebKit

let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/pet")

struct Agent: Codable { let desc: String }
struct Session: Codable {
    let id, project, state, text: String; let ts: Double; let local: String?; let started, finished: Double?; let agents: [Agent]?
    /// "stuck" = says working, but no hook activity for 10 min and no subagents it could be waiting on
    var live: String {
        state == "working" && (agents ?? []).isEmpty && Date().timeIntervalSince1970 - ts > 600 ? "stuck" : state
    }
}
struct Request: Codable { let id, session, project, tool, summary, detail: String; let ts: Double; let always: String?; let questions: String? }

func loadDir<T: Decodable>(_ dir: String) -> [T] {
    let url = root.appendingPathComponent(dir)
    let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }
        .compactMap { try? JSONDecoder().decode(T.self, from: Data(contentsOf: $0)) }
}

final class Panel: NSPanel { override var canBecomeKey: Bool { true } }

/// Clicks land immediately even though the panel never activates the app.
final class PetWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, UNUserNotificationCenterDelegate {
    static func main() { let app = NSApplication.shared; let d = AppDelegate(); app.delegate = d; app.run() }

    var panel: Panel!
    var web: PetWebView!
    var anchor = NSPoint.zero  // top-right corner of the pet; moves when the user drags it
    var size = NSSize(width: 60, height: 60)
    var lastJSON = ""
    var sessions: [Session] = []
    var seenReqs = Set<String>(), lastState = [String: String](), primed = false
    var muted: Bool {
        get { UserDefaults.standard.bool(forKey: "muted") }
        set { UserDefaults.standard.set(newValue, forKey: "muted") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)  // no Dock icon
        for d in ["sessions", "requests", "responses"] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        let nc = UNUserNotificationCenter.current()
        nc.delegate = self
        nc.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let vf = NSScreen.main!.visibleFrame
        anchor = NSPoint(x: vf.maxX - 6, y: vf.maxY - 6)

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "pet")
        web = PetWebView(frame: .zero, configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self

        panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = web
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        place()
        panel.orderFrontRegardless()

        web.loadFileURL(root.appendingPathComponent("pet.html"), allowingReadAccessTo: root)
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        // clicks in other apps/windows never reach us, so a global monitor tells the pet to fold up (no extra permission needed for mouse)
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.web.evaluateJavaScript("collapse()")
        }
    }

    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) { lastJSON = ""; tick() }

    func tick() {
        let reqs: [Request] = loadDir("requests")
        let now = Date().timeIntervalSince1970
        // shortcut: a session silent for 2 h is treated as gone (crashed sessions never send SessionEnd)
        sessions = loadDir("sessions").filter { s in now - s.ts < 7200 || reqs.contains { $0.session == s.id } }
        let rows: [[String: Any]] = sessions.sorted { $0.id < $1.id }.map { s in
            var r: [String: Any] = ["id": s.id, "title": s.project, "state": s.live, "text": s.text, "ts": s.ts,
                                    "agents": (s.agents ?? []).map(\.desc)]
            if let v = s.started { r["started"] = v }
            if let v = s.finished { r["finished"] = v }
            if let q = reqs.first(where: { $0.session == s.id }) {
                r["req"] = ["id": q.id, "tool": q.tool, "summary": q.summary, "detail": q.detail, "always": q.always ?? "",
                            "questions": q.questions ?? ""]
            }
            return r
        }
        alertOnChanges(reqs)
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: .sortedKeys),
              let json = String(data: data, encoding: .utf8), json != lastJSON else { return }
        lastJSON = json
        web.evaluateJavaScript("update(\(json))")
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let msg = m.body as? [String: Any], let type = msg["type"] as? String else { return }
        switch type {
        case "size":
            size = NSSize(width: msg["w"] as? Double ?? 60, height: msg["h"] as? Double ?? 60)
            place()
        case "drag":
            anchor.x += msg["dx"] as? Double ?? 0
            anchor.y -= msg["dy"] as? Double ?? 0  // screen y is flipped vs. web y
            place()
        case "answer":
            guard let id = msg["id"] as? String, let b = msg["behavior"] as? String,
                  ["allow", "always", "deny", "ask"].contains(b) else { return }
            let url = root.appendingPathComponent("responses/\(id).json")
            var resp: [String: Any] = ["behavior": b]
            if let answers = msg["answers"] as? [String: String], !answers.isEmpty { resp["answers"] = answers }
            try? JSONSerialization.data(withJSONObject: resp).write(to: url, options: .atomic)
            if b == "ask" { openSession(msg["session"] as? String) }
        case "open":
            openSession(msg["session"] as? String)
        case "menu":
            let menu = NSMenu()
            menu.addItem(withTitle: "Show / hide all sessions", action: #selector(toggleAll), keyEquivalent: "").target = self
            let m = menu.addItem(withTitle: "Sounds & notifications", action: #selector(toggleMute), keyEquivalent: "")
            m.target = self; m.state = muted ? .off : .on
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Claude Pet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        default: break
        }
    }

    /// Sound + notification when a session newly needs approval, asks something, or finishes.
    func alertOnChanges(_ reqs: [Request]) {
        defer { primed = true }  // first pass only records what's already there
        for q in reqs where !seenReqs.contains(q.id) {
            seenReqs.insert(q.id)
            if primed { alert(sound: "Funk", title: "\(q.project) \(q.questions?.isEmpty == false ? "has a question" : "needs approval")",
                             body: q.summary, session: q.session) }
        }
        for s in sessions {
            let state = s.live, old = lastState[s.id]
            lastState[s.id] = state
            guard primed, old != nil, old != state else { continue }
            if state == "stuck" {
                alert(sound: "Tink", title: "\(s.project) may be stuck", body: "No activity for 10 minutes. Last: \(s.text)", session: s.id)
            } else if state == "done" {
                let took = s.started.flatMap { st in s.finished.map { " in \(Int(($0 - st) / 60))m" } } ?? ""
                alert(sound: "Glass", title: "\(s.project) finished\(took)", body: s.text, session: s.id)
            } else if state == "attention" {
                alert(sound: "Tink", title: "\(s.project) needs you", body: s.text, session: s.id)
            }
        }
    }

    func alert(sound: String, title: String, body: String, session: String) {
        guard !muted else { return }
        NSSound(named: sound)?.play()
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.userInfo = ["session": session]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // show banners even though we're "running", and clicking one opens that session
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list])
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        openSession(r.notification.request.content.userInfo["session"] as? String)
        done()
    }

    @objc func toggleMute() { muted.toggle() }

    @objc func toggleAll() { web.evaluateJavaScript("toggleAll()") }

    func openSession(_ id: String?) {
        // claude://code/continue?session=local_… is the desktop app's own deep link to a Code session
        if let local = sessions.first(where: { $0.id == id })?.local, !local.isEmpty,
           let url = URL(string: "claude://code/continue?session=\(local)") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Claude.app"))
        }
    }

    /// Size the panel to the content, pinned at its top-right corner and kept fully on screen.
    func place() {
        let vf = (panel.screen ?? NSScreen.main!).visibleFrame
        let x = min(max(anchor.x - size.width, vf.minX), vf.maxX - size.width)
        let y = min(max(anchor.y - size.height, vf.minY), vf.maxY - size.height)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        anchor = NSPoint(x: x + size.width, y: y + size.height)
    }
}
