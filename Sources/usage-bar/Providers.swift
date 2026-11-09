import Foundation

struct UsageWindow: Identifiable {
    let id = UUID()
    let label: String
    let percent: Double
    let resetsAt: Date?
}

struct Reading: Identifiable {
    var id: String { name }
    let name: String
    let short: String
    var windows: [UsageWindow] = []
    var facts: [String] = []
    var note: String? = nil
    var error: String? = nil
}

private func parseDate(_ s: String) -> Date? {
    // Server timestamps carry 3 or 6 fractional digits; drop them, second precision is enough.
    let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    return ISO8601DateFormatter().date(from: trimmed)
}

private func keychain(_ service: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", service, "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func getJSON(_ url: String, headers: [String: String]) async throws -> ([String: Any], Int) {
    var req = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    return (obj, code)
}

// MARK: Claude — OAuth token Claude Code keeps in the Keychain

func readClaude() async -> Reading {
    var r = Reading(name: "Claude", short: "CC")
    guard let raw = keychain("Claude Code-credentials"),
          let blob = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
          let token = (blob["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String
    else { r.error = "No Claude Code login in Keychain"; return r }
    do {
        let (j, code) = try await getJSON("https://api.anthropic.com/api/oauth/usage", headers: [
            "Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"])
        if code == 401 { r.error = "Token expired. Run Claude Code once to refresh."; return r }
        guard code == 200 else { r.error = "HTTP \(code)"; return r }
        for (key, label) in [("five_hour", "5 hour"), ("seven_day", "Weekly")] {
            if let w = j[key] as? [String: Any], let u = w["utilization"] as? Double {
                r.windows.append(UsageWindow(label: label, percent: u,
                    resetsAt: (w["resets_at"] as? String).flatMap(parseDate)))
            }
        }
        if r.windows.isEmpty { r.error = "Unexpected response" }
    } catch { r.error = error.localizedDescription }
    return r
}

// MARK: oc — OpenCode Go usage endpoint

func readOpenCode() async -> Reading {
    var r = Reading(name: "OpenCode Go", short: "OC")
    guard let key = keychain("dev.pi.opencode-api-key") else { r.error = "No key in Keychain"; return r }
    do {
        let (j, code) = try await getJSON("https://opencode.ai/zen/go/v1/usage",
                                          headers: ["Authorization": "Bearer \(key)"])
        guard code == 200, let u = j["usage"] as? [String: Any] else { r.error = "HTTP \(code)"; return r }
        for (key, label) in [("rolling", "5 hour"), ("weekly", "Weekly"), ("monthly", "Monthly")] {
            if let w = u[key] as? [String: Any], let p = w["percent"] as? Double {
                r.windows.append(UsageWindow(label: label, percent: p,
                    resetsAt: (w["resetsAt"] as? String).flatMap(parseDate)))
            }
        }
        if r.windows.isEmpty { r.error = "Unexpected response" }
    } catch { r.error = error.localizedDescription }
    return r
}

// MARK: Codex — last rate_limits event written to the newest session log

func readCodex() async -> Reading {
    var r = Reading(name: "Codex", short: "GPT")
    let fm = FileManager.default
    let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")

    func newestChildren(_ dir: URL) -> [URL] {
        ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    // Walk year/month/day newest first; take the newest log that holds a rate_limits event.
    var found: (Date, [String: Any])?
    outer: for y in newestChildren(root) { for m in newestChildren(y) { for d in newestChildren(m) {
        let logs = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for f in logs {
            guard let h = try? FileHandle(forReadingFrom: f) else { continue }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
            let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                let payload = o["payload"] as? [String: Any]
                if let rl = payload?["rate_limits"] as? [String: Any], rl["primary"] is [String: Any] {
                    let ts = (o["timestamp"] as? String).flatMap(parseDate)
                        ?? ((try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date())
                    found = (ts, rl); break outer
                }
            }
        }
    } } }
    guard let (asOf, rl) = found else { r.error = "No Codex rate-limit data yet"; return r }
    for (key, label) in [("primary", "5 hour"), ("secondary", "Weekly")] {
        guard let w = rl[key] as? [String: Any], let used = w["used_percent"] as? Double else { continue }
        let reset = (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        // A window that has already reset since the last log line is back at zero.
        let expired = reset.map { $0 < Date() } ?? false
        r.windows.append(UsageWindow(label: label, percent: expired ? 0 : used, resetsAt: expired ? nil : reset))
    }
    let age = Date().timeIntervalSince(asOf)
    if age > 600 { r.note = "As of \(Self_ago(age)); Codex only updates while it runs" }
    return r
}

func Self_ago(_ s: TimeInterval) -> String {
    s < 3600 ? "\(Int(s / 60)) min ago" : s < 86400 ? "\(Int(s / 3600)) h ago" : "\(Int(s / 86400)) d ago"
}

// MARK: DeepSeek — prepaid balance

func readDeepSeek() async -> Reading {
    var r = Reading(name: "DeepSeek", short: "DS")
    guard let key = keychain("dev.pi.deepseek-api-key") else { r.error = "No key in Keychain"; return r }
    do {
        let (j, code) = try await getJSON("https://api.deepseek.com/user/balance",
                                          headers: ["Authorization": "Bearer \(key)"])
        guard code == 200, let infos = j["balance_infos"] as? [[String: Any]] else { r.error = "HTTP \(code)"; return r }
        for i in infos {
            if let cur = i["currency"] as? String, let bal = i["total_balance"] as? String {
                r.facts.append("Balance \(cur == "USD" ? "$" : cur + " ")\(bal)")
            }
        }
        if (j["is_available"] as? Bool) == false { r.error = "Balance too low to serve requests" }
        if r.facts.isEmpty && r.error == nil { r.error = "Unexpected response" }
    } catch { r.error = error.localizedDescription }
    return r
}

// MARK: DeepInfra — billing state (no usage endpoint exists)

func readDeepInfra() async -> Reading {
    var r = Reading(name: "DeepInfra", short: "DI")
    guard let key = keychain("dev.pi.deepinfra-api-key") else { r.error = "No key in Keychain"; return r }
    do {
        let (j, code) = try await getJSON("https://api.deepinfra.com/payment/checklist",
                                          headers: ["Authorization": "Bearer \(key)"])
        guard code == 200 else { r.error = "HTTP \(code)"; return r }
        if let recent = j["recent"] as? Double { r.facts.append(String(format: "Recent spend $%.2f", recent)) }
        if (j["suspended"] as? Bool) == true {
            r.error = "Suspended: \((j["suspend_reason"] as? String) ?? "unknown")"
        }
        if r.facts.isEmpty && r.error == nil { r.error = "Unexpected response" }
    } catch { r.error = error.localizedDescription }
    return r
}
