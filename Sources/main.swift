// 薰子 · 桌面桌宠
// 一个透明、无边框、永远浮在最上层的小窗口。立绘来自之前 GPT 做的网页版（8 张：常服/睡衣 × 睁眼/闭眼/看书/抱衣服）。
// 额度只读 forai/额度记录.csv（quota-log 插件写的那张表），不碰任何登录信息。

import AppKit
import ServiceManagement

// MARK: - 偏好

enum Outfit: String { case day, night }
enum Pose: String { case idle, blink, read, hold }
enum Mode { case idle, reading, napping, studying }

final class Prefs {
    private static let d = UserDefaults.standard
    static var scale: Double {
        get { let v = d.double(forKey: "scale"); return v > 0 ? v : 1.0 }
        set { d.set(newValue, forKey: "scale") }
    }
    static var quiet: Bool { get { d.bool(forKey: "quiet") } set { d.set(newValue, forKey: "quiet") } }
    /// all = 每次变化都说，five = 每过 5% 才说，off = 不说
    static var quotaAlert: String {
        get { d.string(forKey: "quotaAlert") ?? "all" }
        set { d.set(newValue, forKey: "quotaAlert") }
    }
    static var dayAt: String { get { d.string(forKey: "dayAt") ?? "08:00" } set { d.set(newValue, forKey: "dayAt") } }
    static var nightAt: String { get { d.string(forKey: "nightAt") ?? "22:00" } set { d.set(newValue, forKey: "nightAt") } }
    static var outfitOverride: String? { get { d.string(forKey: "outfitOverride") } set { d.set(newValue, forKey: "outfitOverride") } }
    static var overrideUntil: Double { get { d.double(forKey: "overrideUntil") } set { d.set(newValue, forKey: "overrideUntil") } }
    /// 脚底中心点在屏幕上的位置（换大小时脚不动）
    static var foot: NSPoint? {
        get { guard d.object(forKey: "footX") != nil else { return nil }
              return NSPoint(x: d.double(forKey: "footX"), y: d.double(forKey: "footY")) }
        set { if let p = newValue { d.set(p.x, forKey: "footX"); d.set(p.y, forKey: "footY") }
              else { d.removeObject(forKey: "footX"); d.removeObject(forKey: "footY") } }
    }
    /// 今天一起学了几轮（日期|轮数）
    static var studyLog: String { get { d.string(forKey: "studyLog") ?? "" } set { d.set(newValue, forKey: "studyLog") } }
    static var debug: Bool { d.bool(forKey: "debug") }
    /// 省电：关掉头发裙摆的风、身体轻晃、花瓣星星和小动作
    static var lowMotion: Bool { get { d.bool(forKey: "lowMotion") } set { d.set(newValue, forKey: "lowMotion") } }
    static var useClaude: Bool { get { d.object(forKey: "useClaude") as? Bool ?? true } set { d.set(newValue, forKey: "useClaude") } }
    /// 主动查询：Claude 要读本机登录凭证，默认关；Codex 用它自带的本地接口，默认开
    static var liveClaude: Bool { get { d.bool(forKey: "liveClaude") } set { d.set(newValue, forKey: "liveClaude") } }
    static var liveCodex: Bool { get { d.object(forKey: "liveCodex") as? Bool ?? true } set { d.set(newValue, forKey: "liveCodex") } }
    static var useCodex: Bool { get { d.object(forKey: "useCodex") as? Bool ?? true } set { d.set(newValue, forKey: "useCodex") } }
    /// 额度文件夹里被关掉的来源（按 name）
    static var mutedSources: [String] { get { d.stringArray(forKey: "mutedSources") ?? [] } set { d.set(newValue, forKey: "mutedSources") } }
    static var codexHome: String { d.string(forKey: "codexHome") ?? (NSHomeDirectory() + "/.codex") }
    static var csvPath: String {
        d.string(forKey: "csvPath") ?? (NSHomeDirectory() + "/Documents/forai/额度记录.csv")
    }
}

// MARK: - 立绘

struct Frame {
    let image: CGImage
    let alpha: [UInt8]
    var w: Int { image.width }
    var h: Int { image.height }
    /// 点在图里（0~1，从左上角算）是否落在她身上
    func solid(_ u: CGFloat, _ v: CGFloat) -> Bool {
        let x = Int(u * CGFloat(w)), y = Int(v * CGFloat(h))
        guard x >= 0, y >= 0, x < w, y < h else { return false }
        return alpha[y * w + x] > 24
    }
}

func loadFrame(_ name: String) -> Frame {
    guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "frames"),
          let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("缺少图片 \(name)") }
    let w = img.width, h = img.height
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    rgba.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var alpha = [UInt8](repeating: 0, count: w * h)
    for i in 0..<(w * h) { alpha[i] = rgba[i * 4 + 3] }
    return Frame(image: img, alpha: alpha)
}

// MARK: - 额度表

struct QuotaRow {
    let time: String, kind: String, used: Double, change: String, isReset: Bool, reset: String
    var key: String { time + "|" + kind + "|" + String(used) }
}

/// 39.0 → "39"，39.5 → "39.5"
func pct(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

final class QuotaWatcher {
    /// 认“上次看到的最后一行”而不是行数：quota-log 只留最近 3000 行，满了以后行数不再变
    private var lastKey: String?
    private var lastModified: Date?
    private(set) var latest: [String: QuotaRow] = [:]
    /// 读不到表格（没文件 / 没给“文稿”权限）时的原因
    private(set) var problem: String?
    var onChange: (([(QuotaRow, Double?)]) -> Void)?   // (新的一行, 之前的已用%)

    func poll(force: Bool = false) {
        let path = Prefs.csvPath
        guard FileManager.default.fileExists(atPath: path) else {
            problem = "还没有额度记录表。\n开着 Claude Code 会话时 quota-log 才会记。"; return
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if !force, let m = modified, m == lastModified { return }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            problem = "读不到额度表格，可能没给我“文稿”权限。\n系统设置 → 隐私与安全性 → 文件和文件夹 → 薰子，打开“文稿”。"
            return
        }
        problem = nil
        lastModified = modified
        let rows = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .split(whereSeparator: \.isNewline).dropFirst().compactMap { parse(String($0)) }
        guard let seen = lastKey, let idx = rows.lastIndex(where: { $0.key == seen }) else {
            // 第一次读，或表格被整个换掉：只记下现状，不冒泡
            for r in rows { latest[r.kind] = r }
            lastKey = rows.last?.key
            return
        }
        let fresh = rows[(idx + 1)...]
        lastKey = rows.last?.key
        var changed: [String: (QuotaRow, Double?)] = [:]
        for r in fresh {
            let before = changed[r.kind]?.1 ?? latest[r.kind]?.used
            latest[r.kind] = r
            if r.isReset || (Double(r.change) ?? 0) != 0 { changed[r.kind] = (r, before) }
        }
        let list = ["5小时", "每周"].compactMap { changed[$0] }
        if !list.isEmpty { onChange?(list) }
    }

    private func parse(_ line: String) -> QuotaRow? {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 6, let used = Double(f[2]) else { return nil }
        return QuotaRow(time: f[0], kind: f[1], used: used, change: f[3], isReset: f[4] == "额度重置", reset: f[5])
    }
}

// MARK: - Codex 额度
// Codex 每次对话都会在 ~/.codex/sessions/年/月/日/rollout-*.jsonl 里记 token_count 事件，
// 里面带 rate_limits：primary = 5 小时（300 分钟），secondary = 每周（10080 分钟）。只读本机文件，不碰登录信息。

struct CodexWindow { let used: Double; let resetsAt: Date? }

final class CodexWatcher {
    private(set) var five: CodexWindow?
    private(set) var week: CodexWindow?
    private(set) var seenAt: Date?          // 这份数据是 Codex 什么时候记下的
    private var lastFile = "", lastSize: UInt64 = 0
    var onChange: (([(QuotaRow, Double?)]) -> Void)?

    /// 最近几天里最新的那份对话记录
    private func newestLog() -> String? {
        let fm = FileManager.default, root = Prefs.codexHome + "/sessions"
        let cal = Calendar.current
        var best: (String, Date)?
        for back in 0..<4 {
            guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = String(format: "%@/%04d/%02d/%02d", root, c.year!, c.month!, c.day!)
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".jsonl") {
                let path = dir + "/" + name
                if let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date, m > (best?.1 ?? .distantPast) {
                    best = (path, m)
                }
            }
            if best != nil { break }
        }
        return best?.0
    }

    func poll(force: Bool = false) {
        guard Prefs.useCodex, let path = newestLog() else { return }
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
        if !force && path == lastFile && size == lastSize { return }
        lastFile = path; lastSize = size
        // 只读文件末尾一段，记录很长也不费事
        guard let h = FileHandle(forReadingAtPath: path) else { return }
        defer { try? h.close() }
        let start = size > 262_144 ? size - 262_144 : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return }
        guard let line = text.split(separator: "\n").last(where: { $0.contains("\"rate_limits\"") }),
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let rl = payload["rate_limits"] as? [String: Any] else { return }
        if let id = rl["limit_id"] as? String, id != "codex" { return }
        func window(_ key: String, minutes: Int) -> CodexWindow? {
            for k in ["primary", "secondary"] {
                guard let w = rl[k] as? [String: Any], (w["window_minutes"] as? NSNumber)?.intValue == minutes,
                      let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
                let r = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                return CodexWindow(used: used, resetsAt: r)
            }
            return nil
        }
        let newFive = window("primary", minutes: 300), newWeek = window("secondary", minutes: 10080)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let at = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) }
        let first = five == nil && week == nil
        var changes: [(QuotaRow, Double?)] = []
        for (kind, old, new) in [("Codex·5小时", five, newFive), ("Codex·每周", week, newWeek)] {
            guard let n = new, let o = old, !first else { continue }
            let resetMoved = (n.resetsAt?.timeIntervalSince1970 ?? 0) - (o.resetsAt?.timeIntervalSince1970 ?? 0) > 600
            let delta = n.used - o.used
            if delta == 0 && !resetMoved { continue }
            let tag = delta > 0 ? "+" + pct(delta) : pct(delta)
            changes.append((QuotaRow(time: "", kind: kind, used: n.used, change: tag, isReset: delta < 0 || resetMoved,
                                     reset: ""), o.used))
        }
        five = newFive ?? five; week = newWeek ?? week; seenAt = at ?? seenAt
        if !changes.isEmpty { onChange?(changes) }
    }
}

// MARK: - 通用额度文件夹（DIY 入口）
// 任何工具只要往 ~/.pet-quota/<名字>.json 写这样一个文件，薰子就会认：
// {"name": "豆包", "updated_at": 1791550000, "windows": [{"label": "每天", "used_percent": 42, "resets_at": 1791600000}]}
// 格式说明写在 docs/额度来源.md（写给 AI 看的）。

struct SourceWindow { let label: String; let used: Double; let resetsAt: Date? }
struct SourceFile { let name: String; let updatedAt: Date?; let windows: [SourceWindow] }

final class FolderWatcher {
    static var dir: String { NSHomeDirectory() + "/.pet-quota" }
    private(set) var sources: [String: SourceFile] = [:]     // 文件名 → 内容
    private var mtimes: [String: Date] = [:]
    var onChange: (([(QuotaRow, Double?)]) -> Void)?

    /// 名字叫 Claude、并且 6 小时内更新过的文件（主动查询或状态栏脚本写的）
    var freshClaude: SourceFile? { fresh("claude", within: 6 * 3600) }
    /// 主动查询写的 Codex 文件；15 分钟内更新过才算数，否则退回读 Codex 的对话记录
    var freshCodex: SourceFile? { fresh("codex", within: 15 * 60) }
    func fresh(_ name: String, within: TimeInterval) -> SourceFile? {
        sources.values.first { $0.name.lowercased() == name && Date().timeIntervalSince($0.updatedAt ?? .distantPast) < within }
    }

    /// 前后两次比，每个窗口变了就记一条
    static func compare(_ old: SourceFile, _ new: SourceFile) -> [(QuotaRow, Double?)] {
        new.windows.compactMap { n in
            guard let o = old.windows.first(where: { $0.label == n.label }) else { return nil }
            let moved = (n.resetsAt?.timeIntervalSince1970 ?? 0) - (o.resetsAt?.timeIntervalSince1970 ?? 0) > 600
            let delta = n.used - o.used
            if delta == 0 && !moved { return nil }
            return (QuotaRow(time: "", kind: new.name + "·" + n.label, used: n.used,
                             change: delta > 0 ? "+" + pct(delta) : pct(delta),
                             isReset: delta < 0 || moved, reset: ""), o.used)
        }
    }

    /// 读 Claude Usage Tracker 的缓存；超过 15 分钟没更新（它没在跑）就不算
    static func readTracker() -> SourceFile? {
        guard let text = try? String(contentsOfFile: NSHomeDirectory() + "/.claude/.statusline-usage-cache", encoding: .utf8) else { return nil }
        var kv: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { kv[parts[0]] = parts[1] }
        }
        guard let ts = kv["TIMESTAMP"].flatMap(Double.init), Date().timeIntervalSince1970 - ts < 15 * 60 else { return nil }
        var windows: [SourceWindow] = []
        for (u, r, label) in [("UTILIZATION", "RESETS_AT", "5 小时"), ("WEEKLY_UTILIZATION", "WEEKLY_RESETS_AT", "每周")] {
            guard let used = kv[u].flatMap(Double.init) else { continue }
            windows.append(SourceWindow(label: label, used: used,
                                        resetsAt: LiveFetcher.epoch(kv[r]).map { Date(timeIntervalSince1970: $0) }))
        }
        return windows.isEmpty ? nil : SourceFile(name: "Claude", updatedAt: Date(timeIntervalSince1970: ts), windows: windows)
    }

    func poll(force: Bool = false) {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: Self.dir)) ?? []).filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
        for gone in Set(sources.keys).subtracting(names) where !gone.hasPrefix("@") { sources[gone] = nil; mtimes[gone] = nil }
        var changes: [(QuotaRow, Double?)] = []
        // Claude Usage Tracker（第三方 Mac 应用）开了状态栏功能后，每次刷新会写 ~/.claude/.statusline-usage-cache，
        // 只有几行数字（不含登录信息）。读它，当成一个叫 Claude 的来源
        let trackerKey = "@claude-usage-tracker"
        if let t = Self.readTracker() {
            if let old = sources[trackerKey] { changes += Self.compare(old, t) }
            sources[trackerKey] = t
        } else { sources[trackerKey] = nil }
        for file in names.sorted() {
            let path = Self.dir + "/" + file
            let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            if !force, let m, m == mtimes[file] { continue }
            mtimes[file] = m
            guard let data = fm.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["windows"] as? [[String: Any]] else { continue }
            let name = (obj["name"] as? String) ?? String(file.dropLast(5))
            let windows = list.compactMap { w -> SourceWindow? in
                guard let label = w["label"] as? String, let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                return SourceWindow(label: label, used: used,
                                    resetsAt: (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
            }
            let new = SourceFile(name: name, updatedAt: (obj["updated_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                                 windows: windows)
            if let old = sources[file] { changes += Self.compare(old, new) }
            sources[file] = new
        }
        let muted = Set(Prefs.mutedSources)
        changes.removeAll { muted.contains(String($0.0.kind.split(separator: "·").first ?? "")) }
        if !changes.isEmpty { onChange?(changes) }
    }
}

// MARK: - 主动查询（每 5 分钟），结果写进 ~/.pet-quota/，由 FolderWatcher 发现变化
// Claude：和 Claude Code 里 /usage 用的同一个接口（api.anthropic.com/api/oauth/usage，没有公开文档，
//         官方改了就会失效，到时候再重做）。登录凭证从钥匙串或 ~/.claude/.credentials.json 读，
//         只在内存里用这一下，不保存、不写文件、不打日志；过期了不替它刷新（免得把 Claude Code 挤下线）。
// Codex：ChatGPT 应用自带的 codex 命令有官方本地接口 app-server，问 account/rateLimits/read，不耗额度，登录由 Codex 自己管。

final class LiveFetcher {
    private(set) var claudeNote: String?       // 查不到时的原因，给“看看额度”用
    private(set) var codexNote: String?
    private var lastClaude = Date.distantPast, lastCodex = Date.distantPast
    private var claudeWaitUntil = Date.distantPast
    private let queue = DispatchQueue(label: "kaoruko.live-quota")
    var onWrite: (() -> Void)?                 // 写完文件后让 FolderWatcher 马上看一眼

    func poll(force: Bool = false) {
        let now = Date(), gap: TimeInterval = force ? 60 : 300
        if Prefs.useClaude && Prefs.liveClaude && now.timeIntervalSince(lastClaude) >= gap && now >= claudeWaitUntil {
            lastClaude = now; queue.async { self.fetchClaude() }
        }
        if Prefs.useCodex && Prefs.liveCodex && now.timeIntervalSince(lastCodex) >= gap {
            lastCodex = now; queue.async { self.fetchCodex() }
        }
    }

    // MARK: Claude

    private func claudeToken() -> (token: String?, note: String?) {
        var raw: String?
        // 用系统自带的 security 命令读钥匙串：第一次会弹窗问你，点“始终允许”以后重新编译也不用再点
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 { raw = String(data: data, encoding: .utf8) }
        }
        if raw == nil { raw = try? String(contentsOfFile: NSHomeDirectory() + "/.claude/.credentials.json", encoding: .utf8) }
        guard let raw, let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String else {
            return (nil, "没找到 Claude Code 的登录信息（要在这台电脑上登录过 Claude Code）")
        }
        if let exp = (oauth["expiresAt"] as? NSNumber)?.doubleValue, exp / 1000 < Date().timeIntervalSince1970 {
            return (nil, "Claude 登录信息过期了，打开 Claude Code 用一下就会自己更新")
        }
        return (token, nil)
    }

    private func fetchClaude() {
        let (token, note) = claudeToken()
        guard let token else { setNote(claude: note); return }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                if code == 429 { DispatchQueue.main.async { self.claudeWaitUntil = Date().addingTimeInterval(900) } }
                self.setNote(claude: code == 401 || code == 403 ? "Claude 登录信息失效了，打开 Claude Code 用一下就好"
                                    : code == 0 ? "暂时连不上 Claude，稍后再试" : "Claude 用量接口返回了 \(code)，可能官方改了")
                return
            }
            var windows: [[String: Any]] = []
            for (key, label) in [("five_hour", "5 小时"), ("seven_day", "每周")] {
                guard let w = obj[key] as? [String: Any], let used = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
                var row: [String: Any] = ["label": label, "used_percent": used]
                if let r = Self.epoch(w["resets_at"]) { row["resets_at"] = r }
                windows.append(row)
            }
            guard !windows.isEmpty else { self.setNote(claude: "Claude 用量接口没给出 5 小时 / 每周的数字"); return }
            self.write("claude", name: "Claude", windows: windows)
            self.setNote(claude: nil)
        }.resume()
    }

    // MARK: Codex

    private func codexBinary() -> String? {
        let fm = FileManager.default
        let candidates = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                          "/Applications/Codex.app/Contents/Resources/codex",
                          "/opt/homebrew/bin/codex", "/usr/local/bin/codex", NSHomeDirectory() + "/.local/bin/codex"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    private func fetchCodex() {
        guard let bin = codexBinary() else { setNote(codex: nil); return }   // 没装就继续读对话记录，不算错
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["app-server"]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
        defer { killer.cancel(); if p.isRunning { p.terminate() } }
        let msgs = [#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"kaoruko-pet","version":"1"}}}"#,
                    #"{"method":"initialized"}"#,
                    #"{"id":2,"method":"account/rateLimits/read","params":null}"#]
        inPipe.fileHandleForWriting.write((msgs.joined(separator: "\n") + "\n").data(using: .utf8)!)
        var buffer = Data()
        while true {
            let chunk = outPipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }                     // 进程结束或被 20 秒超时关掉
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<nl]; buffer = buffer[(nl + 1)...]
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      (obj["id"] as? NSNumber)?.intValue == 2 else { continue }
                guard let result = obj["result"] as? [String: Any], let rl = result["rateLimits"] as? [String: Any] else {
                    setNote(codex: "Codex 没给出额度（可能没登录）"); return
                }
                var windows: [[String: Any]] = []
                for key in ["primary", "secondary"] {
                    guard let w = rl[key] as? [String: Any], let used = (w["usedPercent"] as? NSNumber)?.doubleValue else { continue }
                    let mins = (w["windowDurationMins"] as? NSNumber)?.intValue ?? 0
                    let label = mins == 300 ? "5 小时" : mins == 10080 ? "每周" : "\(mins / 60) 小时"
                    var row: [String: Any] = ["label": label, "used_percent": used]
                    if let r = Self.epoch(w["resetsAt"]) { row["resets_at"] = r }
                    windows.append(row)
                }
                if !windows.isEmpty { write("codex", name: "Codex", windows: windows) }
                setNote(codex: nil)
                return
            }
        }
    }

    // MARK: 共用

    static func epoch(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { let d = n.doubleValue; return d > 1e12 ? d / 1000 : d }
        if let s = v as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d.timeIntervalSince1970 }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)?.timeIntervalSince1970
        }
        return nil
    }

    private func write(_ file: String, name: String, windows: [[String: Any]]) {
        let dir = FolderWatcher.dir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let obj: [String: Any] = ["name": name, "updated_at": Int(Date().timeIntervalSince1970), "windows": windows,
                                  "source": "薰子主动查询"]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        let tmp = dir + "/." + file + ".tmp", final = dir + "/" + file + ".json"
        guard FileManager.default.createFile(atPath: tmp, contents: data) else { return }
        _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: final), withItemAt: URL(fileURLWithPath: tmp))
        if FileManager.default.fileExists(atPath: tmp) { try? FileManager.default.moveItem(atPath: tmp, toPath: final) }
        DispatchQueue.main.async { self.onWrite?() }
    }

    private func setNote(claude: String?) { DispatchQueue.main.async { self.claudeNote = claude } }
    private func setNote(codex: String?) { DispatchQueue.main.async { self.codexNote = codex } }
}

func kindName(_ k: String) -> String {
    switch k {
    case "5小时": return "Claude 5 小时"
    case "每周": return "Claude 这周"
    case "Codex·5小时": return "Codex 5 小时"
    case "Codex·每周": return "Codex 这周"
    default: return k.replacingOccurrences(of: "·每周", with: " 这周").replacingOccurrences(of: "·", with: " ")
    }
}

func resetText(_ d: Date) -> String {
    let cal = Calendar.current
    let hm = DateFormatter(); hm.dateFormat = "HH:mm"
    if cal.isDateInToday(d) { return "今天 \(hm.string(from: d))" }
    if cal.isDateInTomorrow(d) { return "明天 \(hm.string(from: d))" }
    let md = DateFormatter(); md.dateFormat = "M月d日 HH:mm"
    return md.string(from: d)
}

func agoText(_ d: Date) -> String {
    let m = Int(Date().timeIntervalSince(d) / 60)
    if m < 60 { return "\(max(m, 1)) 分钟前" }
    if m < 60 * 24 { return "\(m / 60) 小时前" }
    return "\(m / 60 / 24) 天前"
}

func resetText(_ s: String) -> String {
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return fmt.date(from: s).map(resetText) ?? ""
}

// MARK: - 菜单项

final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, on: Bool = false, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = on ? .on : .off
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let m = NSMenu(); items.forEach(m.addItem); item.submenu = m
    return item
}

// MARK: - 气泡

final class BubbleView: NSView {
    let label = NSTextField(wrappingLabelWithString: "")
    let shape = CAShapeLayer()
    private var full = NSAttributedString()
    private var titleLength = 0
    private(set) var shown = 0
    var length: Int { full.length }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        shape.fillColor = NSColor(calibratedRed: 1, green: 0.985, blue: 0.975, alpha: 0.97).cgColor
        shape.strokeColor = NSColor(calibratedRed: 0.93, green: 0.72, blue: 0.80, alpha: 1).cgColor
        shape.lineWidth = 1
        shape.shadowColor = NSColor.black.cgColor
        shape.shadowOpacity = 0.16
        shape.shadowRadius = 5
        shape.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(shape)
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(title: String?, body: String, maxWidth: CGFloat) {
        let ink = NSColor(calibratedRed: 0.29, green: 0.22, blue: 0.31, alpha: 1)
        let para = NSMutableParagraphStyle(); para.lineSpacing = 2; para.alignment = .center
        let s = NSMutableAttributedString()
        if let t = title {
            s.append(NSAttributedString(string: t + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor(calibratedRed: 0.80, green: 0.38, blue: 0.55, alpha: 1),
                .paragraphStyle: para]))
        }
        titleLength = s.length
        s.append(NSAttributedString(string: body, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink, .paragraphStyle: para]))
        full = s
        label.attributedStringValue = s
        label.preferredMaxLayoutWidth = maxWidth - 24
        let size = label.fittingSize
        label.frame = NSRect(x: 12, y: 8, width: ceil(size.width), height: ceil(size.height))
        let w = ceil(size.width) + 24, h = ceil(size.height) + 16
        setFrameSize(NSSize(width: w, height: h))
        shape.frame = bounds
        shape.path = Self.outline(w: w, h: h)
        shape.shadowPath = shape.path
        reveal(titleLength)
    }

    /// 只显示前 n 个字；后面的字先透明占位，排版不跳
    func reveal(_ n: Int) {
        shown = min(max(n, titleLength), full.length)
        let s = NSMutableAttributedString(attributedString: full)
        if shown < full.length {
            s.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: shown, length: full.length - shown))
        }
        label.attributedStringValue = s
    }

    /// 下一个完整的字（emoji 不会被拆开）
    func nextStop() -> Int {
        guard shown < full.length else { return full.length }
        let r = (full.string as NSString).rangeOfComposedCharacterSequence(at: shown)
        return r.location + r.length
    }

    /// 圆角框，下边中间伸出一个小尾巴指向她
    static func outline(w: CGFloat, h: CGFloat) -> CGPath {
        let r: CGFloat = 12, tail: CGFloat = 7, cx = w / 2
        let p = CGMutablePath()
        p.move(to: CGPoint(x: cx - tail, y: 0))
        p.addLine(to: CGPoint(x: cx, y: -tail))
        p.addLine(to: CGPoint(x: cx + tail, y: 0))
        p.addArc(tangent1End: CGPoint(x: w, y: 0), tangent2End: CGPoint(x: w, y: h), radius: r)
        p.addArc(tangent1End: CGPoint(x: w, y: h), tangent2End: CGPoint(x: 0, y: h), radius: r)
        p.addArc(tangent1End: CGPoint(x: 0, y: h), tangent2End: CGPoint(x: 0, y: 0), radius: r)
        p.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: cx, y: 0), radius: r)
        p.closeSubpath()
        return p
    }
}

// MARK: - 小图（花瓣、星星），开机画一次

func drawImage(_ size: CGFloat, _ draw: (CGContext) -> Void) -> CGImage {
    let px = Int(size * 2)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: 2, y: 2)
    draw(ctx)
    return ctx.makeImage()!
}

let petalImage = drawImage(16) { c in
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 8, y: 1))
    p.addCurve(to: CGPoint(x: 6, y: 15), control1: CGPoint(x: 15, y: 5), control2: CGPoint(x: 12, y: 13))
    p.addLine(to: CGPoint(x: 8, y: 12.5))
    p.addLine(to: CGPoint(x: 10, y: 15))
    p.addCurve(to: CGPoint(x: 8, y: 1), control1: CGPoint(x: 4, y: 13), control2: CGPoint(x: 1, y: 5))
    c.addPath(p)
    c.setFillColor(NSColor(calibratedRed: 1, green: 0.76, blue: 0.84, alpha: 0.95).cgColor)
    c.fillPath()
    c.addEllipse(in: CGRect(x: 6.5, y: 3, width: 3, height: 5))
    c.setFillColor(NSColor(calibratedRed: 1, green: 0.93, blue: 0.95, alpha: 0.9).cgColor)
    c.fillPath()
}

let starImage = drawImage(16) { c in
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 8, y: 0))
    for (x, y) in [(9.3, 6.7), (16, 8), (9.3, 9.3), (8, 16), (6.7, 9.3), (0, 8), (6.7, 6.7)] { p.addLine(to: CGPoint(x: x, y: y)) }
    p.closeSubpath()
    c.addPath(p)
    c.setFillColor(NSColor(calibratedRed: 1, green: 0.95, blue: 0.72, alpha: 1).cgColor)
    c.setShadow(offset: .zero, blur: 3, color: NSColor(calibratedRed: 1, green: 0.9, blue: 0.5, alpha: 0.9).cgColor)
    c.fillPath()
}

// MARK: - 画布

final class PetView: NSView {
    weak var pet: Pet?
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { pet?.mouseDown(e) }
    override func mouseDragged(with e: NSEvent) { pet?.mouseDragged(e) }
    override func mouseUp(with e: NSEvent) { pet?.mouseUp(e) }
    override func rightMouseDown(with e: NSEvent) { pet?.rightMouseDown(e, in: self) }
}

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 薰子

final class Pet: NSObject {
    let frames: [Outfit: [Pose: Frame]]
    let window: PetPanel
    let view = PetView()
    // 立绘分几层，各管一种动作，互不打架：
    // mover（跳、压扁拉伸、转圈）› swing（被拎起来时绕头顶摆）› lean（歪头、侧身）› body（呼吸、轻晃）› 横条（头发裙摆的风）
    let mover = CALayer(), swing = CALayer(), lean = CALayer(), body = CALayer()
    var bands: [(layer: CALayer, amp: CGFloat, u: CGFloat)] = []
    static let bandCount = 36
    var swingAngle: CGFloat = 0, swingVel: CGFloat = 0, swingTarget: CGFloat = 0
    var swingTimer: Timer?
    var lastDragX: CGFloat = 0, lastDragT: TimeInterval = 0
    var hovering = false, hoverSince = Date.distantPast, lastHoverNote = Date.distantPast
    var typeTimer: Timer?
    let floor = CAShapeLayer()
    let bubble = BubbleView()
    let quota = QuotaWatcher()
    let codex = CodexWatcher()
    let folder = FolderWatcher()
    let live = LiveFetcher()

    var outfit: Outfit = .day
    var mode: Mode = .idle
    var transient: Pose?
    var transientToken = 0
    var busyUntil = Date.distantPast
    var changing = false
    var bubbleToken = 0
    var bubbleIsQuota = false
    var nextChat = Date().addingTimeInterval(Double.random(in: 900...1800))
    var lastTouch = Date()

    // 拖动
    var dragging = false, dragged = false
    var dragStartMouse = NSPoint.zero, dragStartOrigin = NSPoint.zero

    // 布局
    let headroom: CGFloat = 120
    var spriteRect = NSRect.zero
    var zTimer: Timer?
    var studyEnd: Date?
    var studyMinutes = 25

    override init() {
        var f: [Outfit: [Pose: Frame]] = [:]
        for o in [Outfit.day, .night] {
            var m: [Pose: Frame] = [:]
            for p in [Pose.idle, .blink, .read, .hold] { m[p] = loadFrame("\(o.rawValue)_\(p.rawValue)") }
            f[o] = m
        }
        frames = f
        window = PetPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = view
        view.pet = self
        view.wantsLayer = true

        floor.fillColor = NSColor(calibratedWhite: 0, alpha: 0.16).cgColor
        view.layer?.addSublayer(floor)
        view.layer?.addSublayer(mover)
        mover.addSublayer(swing); swing.addSublayer(lean); lean.addSublayer(body)
        bubble.isHidden = true
        view.addSubview(bubble)

        outfit = desiredOutfit()
        layout(keepFoot: Prefs.foot)
        render()
        idleMotion()
        window.orderFrontRegardless()

        // Claude 有两个来源：状态栏脚本写的 ~/.pet-quota/claude.json（新的、优先），没有时退回 quota-log 的表格
        quota.onChange = { [weak self] rows in
            guard let self, Prefs.useClaude, self.folder.freshClaude == nil else { return }
            self.quotaChanged(rows)
        }
        folder.onChange = { [weak self] rows in
            guard let self else { return }
            self.quotaChanged(rows.filter {
                let k = $0.0.kind.lowercased()
                return (!k.hasPrefix("claude·") || Prefs.useClaude) && (!k.hasPrefix("codex·") || Prefs.useCodex)
            })
        }
        folder.poll()
        quota.poll()
        // 主动查询成功时，Codex 以查询结果为准，不再按对话记录重复提醒
        codex.onChange = { [weak self] rows in
            guard let self, self.folder.freshCodex == nil else { return }
            self.quotaChanged(rows)
        }
        codex.poll()
        live.onWrite = { [weak self] in self?.folder.poll() }
        live.poll()

        // 鼠标在她身上才接收点击，其余透明处直接点到下面的软件
        trackLoop()
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.live.poll(); self?.folder.poll(); self?.quota.poll(); self?.codex.poll() }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
        scheduleBlink()
        scheduleAmbient()
        scheduleFidget()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.ensureOnScreen() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.hello() }
    }

    // MARK: 布局

    var spriteSize: NSSize {
        let w = 140 * CGFloat(Prefs.scale)
        let f = frames[.day]![.idle]!
        return NSSize(width: w, height: w * CGFloat(f.h) / CGFloat(f.w))
    }

    func layout(keepFoot: NSPoint?) {
        let s = spriteSize
        let winW = max(s.width + 24, 290), winH = s.height + 10 + headroom
        let foot: NSPoint
        if let k = keepFoot { foot = k } else {
            let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            foot = NSPoint(x: vf.maxX - winW / 2 - 20, y: vf.minY + 4)
        }
        window.setFrame(NSRect(x: foot.x - winW / 2, y: foot.y - 6, width: winW, height: winH), display: true)
        view.frame = NSRect(x: 0, y: 0, width: winW, height: winH)
        spriteRect = NSRect(x: (winW - s.width) / 2, y: 6, width: s.width, height: s.height)

        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [mover, swing, lean, body] { l.bounds = CGRect(origin: .zero, size: s) }
        mover.anchorPoint = CGPoint(x: 0.5, y: 0); mover.position = CGPoint(x: spriteRect.midX, y: spriteRect.minY)
        swing.anchorPoint = CGPoint(x: 0.5, y: 1); swing.position = CGPoint(x: s.width / 2, y: s.height)
        lean.anchorPoint = CGPoint(x: 0.5, y: 0); lean.position = CGPoint(x: s.width / 2, y: 0)
        body.anchorPoint = CGPoint(x: 0.5, y: 0); body.position = CGPoint(x: s.width / 2, y: 0)
        let fw = s.width * 0.55
        floor.frame = CGRect(x: spriteRect.midX - fw / 2, y: 2, width: fw, height: 10)
        floor.path = CGPath(ellipseIn: floor.bounds, transform: nil)
        buildBands(s)
        CATransaction.commit()
        if !bubble.isHidden { placeBubble() }
        ensureOnScreen()
    }

    var footPoint: NSPoint { NSPoint(x: window.frame.midX, y: window.frame.minY + 6) }

    func ensureOnScreen() {
        let f = window.frame
        let body = NSRect(x: f.minX + spriteRect.minX, y: f.minY + spriteRect.minY, width: spriteRect.width, height: spriteRect.height)
        if NSScreen.screens.contains(where: { $0.frame.intersection(body).width > 40 && $0.frame.intersection(body).height > 40 }) { return }
        Prefs.foot = nil
        layout(keepFoot: nil)
    }

    // MARK: 画面

    func render() {
        let pose = transient ?? (mode == .reading || mode == .studying ? .read : mode == .napping ? .blink : .idle)
        let img = frames[outfit]![pose]!.image
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for b in bands { b.layer.contents = img }
        CATransaction.commit()
    }

    /// 把立绘横切成细条，每条共用同一张图（不多占内存），只显示自己那一段
    func buildBands(_ s: NSSize) {
        bands.forEach { $0.layer.removeFromSuperlayer() }
        bands = []
        let n = Pet.bandCount
        var top: CGFloat = 0
        for i in 0..<n {
            let bottom = i == n - 1 ? s.height : (s.height * CGFloat(i + 1) / CGFloat(n)).rounded()
            let h = bottom - top
            let l = CALayer()
            l.anchorPoint = .zero
            // 每条往下多盖 1 点，接缝处就不会漏出细线
            let ext = i == n - 1 ? 0 : min(1, s.height - bottom)
            l.frame = CGRect(x: 0, y: s.height - bottom - ext, width: s.width, height: h + ext)
            l.contentsRect = CGRect(x: 0, y: (s.height - bottom - ext) / s.height, width: 1, height: (h + ext) / s.height)
            l.contentsGravity = .resize
            l.minificationFilter = .trilinear
            l.magnificationFilter = .linear
            l.contentsScale = window.backingScaleFactor
            body.addSublayer(l)
            let u = (top + h / 2) / s.height              // 0 = 头顶，1 = 脚底
            // 头发梢、袖口和裙摆（0.35~0.85）摆得最多，头和脚不动
            let amp: CGFloat = u > 0.35 && u < 0.85 ? sin((u - 0.35) / 0.5 * .pi) : 0
            bands.append((l, amp, u))
            top = bottom
        }
        startWave()
    }

    /// 头发裙摆的风：一道很轻的波从上往下传
    func startWave() {
        for b in bands {
            b.layer.removeAnimation(forKey: "wave")
            guard b.amp > 0.02, !Prefs.lowMotion else { continue }
            let a = CABasicAnimation(keyPath: "position.x")
            let A = b.amp * 1.4 * CGFloat(Prefs.scale)
            a.fromValue = -A; a.toValue = A
            a.isAdditive = true
            a.duration = 1.8; a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.timeOffset = Double(1 - b.u) * 2.4
            b.layer.add(a, forKey: "wave")
        }
    }

    /// 呼吸 + 很轻的左右晃；睡着时呼吸更慢更深
    func idleMotion() {
        let napping = mode == .napping
        let by = CABasicAnimation(keyPath: "transform.scale.y")
        by.fromValue = 1.0; by.toValue = napping ? 1.02 : 1.012
        let bx = CABasicAnimation(keyPath: "transform.scale.x")
        bx.fromValue = 1.0; bx.toValue = napping ? 0.993 : 0.996
        for a in [by, bx] {
            a.duration = napping ? 2.9 : 1.9; a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        }
        body.add(by, forKey: "breatheY"); body.add(bx, forKey: "breatheX")
        body.removeAnimation(forKey: "sway")
        guard !Prefs.lowMotion else { return }
        let sway = CABasicAnimation(keyPath: "transform.rotation.z")
        sway.fromValue = -0.006; sway.toValue = 0.006
        sway.duration = napping ? 5.5 : 3.7; sway.autoreverses = true; sway.repeatCount = .infinity
        sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        body.add(sway, forKey: "sway")
    }

    /// 歪头 / 侧身（平滑过去）
    func setLean(_ angle: CGFloat, _ duration: Double = 0.45) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        lean.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        CATransaction.commit()
    }

    var restingLean: CGFloat { mode == .napping ? 0.035 : 0 }

    func show(_ pose: Pose?, for seconds: Double) {
        transientToken += 1
        let token = transientToken
        transient = pose
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.transientToken == token else { return }
            self.transient = nil
            self.render()
        }
    }

    /// 蹲一下 → 跳起来拉长 → 落地压扁 → 弹回；影子跟着变小变淡
    func hop(_ height: CGFloat = 16) {
        let y = mover.position.y
        let t: [NSNumber] = [0, 0.16, 0.42, 0.66, 0.8, 1]
        let ease = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeOut),
                    CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        let pos = CAKeyframeAnimation(keyPath: "position.y")
        pos.values = [y, y - 1, y + height, y, y + height * 0.22, y]
        let sy = CAKeyframeAnimation(keyPath: "transform.scale.y")
        sy.values = [1, 0.93, 1.05, 0.94, 1.01, 1]
        let sx = CAKeyframeAnimation(keyPath: "transform.scale.x")
        sx.values = [1, 1.05, 0.97, 1.05, 0.995, 1]
        for a in [pos, sy, sx] { a.keyTimes = t; a.timingFunctions = ease }
        let g = CAAnimationGroup(); g.animations = [pos, sy, sx]; g.duration = 0.62
        mover.add(g, forKey: "hop")
        let f = CAKeyframeAnimation(keyPath: "transform.scale")
        f.values = [1, 1.06, 1 - height / 40, 1.06, 1, 1]
        let fo = CAKeyframeAnimation(keyPath: "opacity")
        fo.values = [1, 1, 0.5, 1, 0.85, 1]
        for a in [f, fo] { a.keyTimes = t }
        let fg = CAAnimationGroup(); fg.animations = [f, fo]; fg.duration = 0.62
        floor.add(fg, forKey: "hop")
    }

    /// 被摸头：歪一下头再晃回来
    func tilt() {
        let a = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        a.values = [0, 0.07, -0.03, 0.035, -0.01, 0]
        a.keyTimes = [0, 0.25, 0.5, 0.7, 0.85, 1]
        a.duration = 1.3
        a.isAdditive = true
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        lean.add(a, forKey: "tilt")
    }

    func squish() {
        let a = CAKeyframeAnimation(keyPath: "transform.scale.x")
        a.values = [1, 1.04, 0.98, 1.01, 1]
        a.duration = 0.7
        mover.add(a, forKey: "squish")
    }

    /// 嚼东西：一下一下轻轻点头
    func chew() {
        let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
        a.values = [1, 0.985, 1, 0.985, 1, 0.985, 1]
        a.duration = 1.8
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        mover.add(a, forKey: "chew")
    }

    func scheduleBlink() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 3.2...6.8)) { [weak self] in
            guard let self else { return }
            if self.mode == .idle, self.transient == nil, !self.changing, Date() > self.busyUntil {
                self.show(.blink, for: 0.13)
                if Bool.random() && Bool.random() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self, self.transient == nil, self.mode == .idle else { return }
                        self.show(.blink, for: 0.12)
                    }
                }
            }
            self.scheduleBlink()
        }
    }

    // MARK: 环境与小动作

    func scheduleAmbient() {
        let night = outfit == .night
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: night ? 2.5...5.5 : 5...10)) { [weak self] in
            guard let self else { return }
            if self.window.isVisible && !Prefs.lowMotion && !self.dragging {
                if self.outfit == .night { self.twinkle() } else { self.petal() }
            }
            self.scheduleAmbient()
        }
    }

    /// 一片花瓣从上面飘下来，左右荡着转着
    func petal() {
        guard let root = view.layer else { return }
        let W = view.bounds.width, H = view.bounds.height
        let l = CALayer()
        let size = CGFloat.random(in: 9...13)
        l.contents = petalImage
        l.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        l.contentsScale = 2
        let x0 = CGFloat.random(in: W * 0.1...W * 0.9)
        l.position = CGPoint(x: x0, y: H + 10)
        l.opacity = 0
        root.insertSublayer(l, below: mover)
        let dur = Double.random(in: 7...10)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x0, y: H + 10))
        let swayW = CGFloat.random(in: 18...30), dir: CGFloat = Bool.random() ? 1 : -1
        let steps = 4
        for i in 1...steps {
            let y = H + 10 - (H + 10) * CGFloat(i) / CGFloat(steps)
            let x = x0 + dir * CGFloat(i) * 6
            path.addQuadCurve(to: CGPoint(x: x, y: y),
                              control: CGPoint(x: x + (i % 2 == 0 ? swayW : -swayW) * dir, y: y + (H + 10) / CGFloat(steps * 2)))
        }
        let move = CAKeyframeAnimation(keyPath: "position"); move.path = path
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0; spin.toValue = CGFloat.random(in: 3...6) * dir
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.95, 0.95, 0]; fade.keyTimes = [0, 0.1, 0.8, 1]
        let g = CAAnimationGroup(); g.animations = [move, spin, fade]; g.duration = dur
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        l.add(g, forKey: "fall")
        CATransaction.commit()
    }

    /// 晚上：她身边一闪一闪的小星星
    func twinkle(at point: CGPoint? = nil, size: CGFloat? = nil) {
        guard let root = view.layer else { return }
        let l = CALayer()
        let sz = size ?? CGFloat.random(in: 8...14)
        l.contents = starImage
        l.contentsScale = 2
        l.bounds = CGRect(x: 0, y: 0, width: sz, height: sz)
        l.position = point ?? CGPoint(
            x: spriteRect.midX + CGFloat.random(in: -spriteRect.width * 0.62...spriteRect.width * 0.62),
            y: spriteRect.minY + CGFloat.random(in: spriteRect.height * 0.25...spriteRect.height * 1.02))
        l.opacity = 0
        root.addSublayer(l)
        let sc = CAKeyframeAnimation(keyPath: "transform.scale")
        sc.values = [0.2, 1.1, 0.85, 1, 0.2]
        let rot = CABasicAnimation(keyPath: "transform.rotation.z")
        rot.fromValue = 0; rot.toValue = CGFloat.pi / 2
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0.7, 1, 0]
        let g = CAAnimationGroup(); g.animations = [sc, rot, fade]; g.duration = 1.6
        g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        l.add(g, forKey: "twinkle")
        CATransaction.commit()
    }

    /// 闲着的时候偶尔做点小动作：东张西望、伸懒腰、哼歌；看书时会点点头翻页
    func scheduleFidget() {
        let busy = mode == .reading || mode == .studying
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: busy ? 7...13 : 40...90)) { [weak self] in
            guard let self else { return }
            if self.window.isVisible, !Prefs.lowMotion, !self.changing, !self.dragging, !self.hovering,
               Date() > self.busyUntil, self.transient == nil {
                switch self.mode {
                case .idle: self.fidget()
                case .reading, .studying: self.pageNod()
                case .napping: break
                }
            }
            self.scheduleFidget()
        }
    }

    func fidget() {
        busyUntil = Date().addingTimeInterval(3)
        switch Int.random(in: 0..<3) {
        case 0:   // 东张西望
            setLean(0.04, 0.6)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.setLean(-0.04, 0.8) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) { [weak self] in self?.setLean(self?.restingLean ?? 0, 0.6) }
        case 1:   // 伸懒腰
            show(.blink, for: 1.4)
            let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
            a.values = [1, 1.045, 1.045, 0.97, 1.01, 1]
            a.keyTimes = [0, 0.3, 0.6, 0.78, 0.9, 1]
            a.duration = 1.6
            mover.add(a, forKey: "stretch")
            floatText("~", from: CGPoint(x: headPoint.x + spriteRect.width * 0.3, y: headPoint.y + 12), size: 16,
                      color: NSColor(calibratedRed: 0.62, green: 0.52, blue: 0.80, alpha: 1), rise: 18, drift: 8, duration: 1.4)
        default:  // 哼歌
            let lilac = NSColor(calibratedRed: 0.62, green: 0.52, blue: 0.80, alpha: 1)
            for i in 0..<3 {
                floatText(i == 1 ? "♫" : "♪", from: CGPoint(x: headPoint.x + spriteRect.width * 0.32, y: headPoint.y - 4),
                          size: CGFloat.random(in: 12...16), color: lilac, rise: 34, drift: CGFloat(10 + i * 6), duration: 1.6, delay: Double(i) * 0.45)
            }
            let a = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            a.values = [0, 0.025, -0.025, 0.025, 0]; a.duration = 1.8; a.isAdditive = true
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            lean.add(a, forKey: "hum")
        }
    }

    /// 看书时轻轻点头，像在翻页
    func pageNod() {
        let y = mover.position.y
        let a = CAKeyframeAnimation(keyPath: "position.y")
        a.values = [y, y - 1.8, y, y - 1.2, y]; a.duration = 1.2
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        mover.add(a, forKey: "nod")
        if Int.random(in: 0..<3) == 0 {
            floatText(mode == .studying ? "✎" : "♪", from: CGPoint(x: handPoint.x + spriteRect.width * 0.28, y: handPoint.y + 14),
                      size: 13, color: NSColor(calibratedRed: 0.62, green: 0.52, blue: 0.80, alpha: 1), rise: 20, drift: 6, duration: 1.3)
        }
    }

    var headPoint: CGPoint { CGPoint(x: spriteRect.midX, y: spriteRect.minY + spriteRect.height * 0.80) }
    var handPoint: CGPoint { CGPoint(x: spriteRect.midX, y: spriteRect.minY + spriteRect.height * 0.42) }

    func floatText(_ s: String, from p: CGPoint, size: CGFloat, color: NSColor,
                   rise: CGFloat = 46, drift: CGFloat = 0, duration: Double = 1.2, delay: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let root = self.view.layer else { return }
            let t = CATextLayer()
            t.string = s
            t.fontSize = size
            t.foregroundColor = color.cgColor
            t.alignmentMode = .center
            t.contentsScale = self.window.backingScaleFactor
            t.bounds = CGRect(x: 0, y: 0, width: size * 2, height: size * 1.4)
            t.position = p
            root.addSublayer(t)
            CATransaction.begin()
            CATransaction.setCompletionBlock { t.removeFromSuperlayer() }
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: p)
            move.toValue = NSValue(point: CGPoint(x: p.x + drift, y: p.y + rise))
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]; fade.keyTimes = [0, 0.15, 0.6, 1]
            let g = CAAnimationGroup()
            g.animations = [move, fade]; g.duration = duration
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            t.opacity = 0
            t.add(g, forKey: "float")
            CATransaction.commit()
        }
    }

    func hearts(_ n: Int) {
        let pink = NSColor(calibratedRed: 1, green: 0.52, blue: 0.67, alpha: 1)
        for i in 0..<n {
            let p = CGPoint(x: headPoint.x + CGFloat.random(in: -spriteRect.width * 0.32...spriteRect.width * 0.32),
                            y: headPoint.y + CGFloat.random(in: -6...14))
            floatText(i % 2 == 0 ? "♥" : "♡", from: p, size: CGFloat.random(in: 12...18), color: pink,
                      drift: CGFloat.random(in: -10...10), delay: Double(i) * 0.12)
        }
    }

    func sparkles() {
        let gold = NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.40, alpha: 1)
        for i in 0..<6 {
            let p = CGPoint(x: spriteRect.midX + CGFloat.random(in: -spriteRect.width * 0.45...spriteRect.width * 0.45),
                            y: spriteRect.minY + CGFloat.random(in: spriteRect.height * 0.1...spriteRect.height * 0.9))
            floatText("✧", from: p, size: CGFloat.random(in: 12...20), color: gold, rise: 18, duration: 0.9, delay: Double(i) * 0.06)
        }
    }

    // MARK: 气泡

    func say(_ body: String, title: String? = nil, seconds: Double = 5, quota: Bool = false, force: Bool = false) {
        if !force && !quota && Prefs.quiet { return }
        if bubbleIsQuota && !quota && !bubble.isHidden { return }   // 额度提醒优先，别被闲聊盖掉
        bubbleToken += 1
        let token = bubbleToken
        bubbleIsQuota = quota
        bubble.set(title: title, body: body, maxWidth: min(view.bounds.width - 8, 286))
        placeBubble()
        let wasHidden = bubble.isHidden || bubble.alphaValue < 0.5
        if bubble.isHidden { bubble.alphaValue = 0; bubble.isHidden = false }
        // 正在淡出时也要重新淡入，不然新的话会跟着一起消失
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; bubble.animator().alphaValue = 1 }
        if wasHidden { popBubble() }
        typeOut()
        let typing = Double(bubble.length) * 0.032
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + typing) { [weak self] in
            guard let self, self.bubbleToken == token else { return }
            self.hideBubble()
        }
    }

    /// 气泡从尾巴那里“啵”地弹出来
    func popBubble() {
        guard let l = bubble.layer else { return }
        let cx = bubble.bounds.width / 2
        func m(_ s: CGFloat) -> NSValue {
            var t = CATransform3DMakeTranslation(cx, 0, 0)
            t = CATransform3DScale(t, s, s, 1)
            return NSValue(caTransform3D: CATransform3DTranslate(t, -cx, 0, 0))
        }
        let a = CAKeyframeAnimation(keyPath: "transform")
        a.values = [m(0.55), m(1.07), m(0.97), m(1)]
        a.keyTimes = [0, 0.45, 0.75, 1]
        a.duration = 0.32
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.add(a, forKey: "pop")
    }

    /// 一个字一个字打出来
    func typeOut() {
        typeTimer?.invalidate()
        typeTimer = Timer.scheduledTimer(withTimeInterval: 0.032, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let next = self.bubble.nextStop()
            self.bubble.reveal(next)
            if next >= self.bubble.length { t.invalidate() }
        }
    }

    func hideBubble() {
        bubbleToken += 1
        let token = bubbleToken
        bubbleIsQuota = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; bubble.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
            guard let self, self.bubbleToken == token else { return }
            self.bubble.isHidden = true
            self.fitHeadroom(0)
        })
    }

    /// 话多的时候窗口往上长，不让气泡挡脸；脚的位置不变
    func fitHeadroom(_ need: CGFloat) {
        let want = max(headroom, need)
        let h = spriteRect.maxY + 4 + want
        guard abs(window.frame.height - h) > 1 else { return }
        var f = window.frame; f.size.height = h
        window.setFrame(f, display: true)
        view.frame = NSRect(x: 0, y: 0, width: f.width, height: h)
    }

    func placeBubble() {
        let s = bubble.frame.size
        fitHeadroom(s.height + 14)
        var y = spriteRect.maxY - spriteRect.height * 0.03
        y = min(y, view.bounds.height - s.height - 4)
        bubble.setFrameOrigin(NSPoint(x: round((view.bounds.width - s.width) / 2), y: round(y)))
    }

    // MARK: 鼠标

    func isHit(_ p: NSPoint) -> Bool {
        if !bubble.isHidden && bubble.frame.contains(p) { return true }
        guard spriteRect.contains(p) else { return false }
        let u = (p.x - spriteRect.minX) / spriteRect.width
        let v = (spriteRect.maxY - p.y) / spriteRect.height
        return frames[outfit]![.idle]!.solid(u, v) || frames[outfit]![transient ?? .idle]!.solid(u, v)
    }

    /// 鼠标靠近时每 0.05 秒查一次，离得远就 0.3 秒查一次
    func trackLoop() {
        var near = false
        if window.isVisible {
            let m = NSEvent.mouseLocation
            near = dragging || window.frame.insetBy(dx: -80, dy: -80).contains(m)
            let p = NSPoint(x: m.x - window.frame.minX, y: m.y - window.frame.minY)
            let hit = near && isHit(p)
            let want = dragging || hit
            if window.ignoresMouseEvents == want { window.ignoresMouseEvents = !want }
            updateHover(hit && !dragging && bubble.frame.contains(p) == false, mouseX: p.x)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (near ? 0.05 : 0.3)) { [weak self] in self?.trackLoop() }
    }

    /// 鼠标停在她身上：往鼠标那边歪一点头，偶尔冒个小音符
    func updateHover(_ on: Bool, mouseX: CGFloat) {
        let canLean = !changing && (mode == .idle || mode == .reading) && !Prefs.lowMotion
        if on && !hovering {
            hovering = true; hoverSince = Date()
        } else if !on && hovering {
            hovering = false
            if canLean { setLean(restingLean, 0.6) }
            return
        }
        guard on, canLean, Date().timeIntervalSince(hoverSince) > 0.35 else { return }
        let side: CGFloat = mouseX < spriteRect.midX ? 1 : -1
        let target = 0.035 * side
        if abs((lean.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat ?? 0) - target) > 0.01 {
            setLean(target, 0.5)
        }
        if Date().timeIntervalSince(lastHoverNote) > 25 {
            lastHoverNote = Date()
            floatText("?", from: CGPoint(x: headPoint.x - side * spriteRect.width * 0.3, y: headPoint.y + 10), size: 15,
                      color: NSColor(calibratedRed: 1, green: 0.52, blue: 0.67, alpha: 1), rise: 14, duration: 1.2)
        }
    }

    // 拎起来：绕头顶的钟摆，按拖动速度甩，松手后慢慢停
    func startSwing() {
        guard swingTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.stepSwing() }
        RunLoop.main.add(t, forMode: .common)
        swingTimer = t
    }

    func stepSwing() {
        let dt: CGFloat = 1.0 / 60
        swingTarget *= 0.9
        let acc = -55 * (swingAngle - swingTarget) - 5.5 * swingVel
        swingVel += acc * dt
        swingAngle += swingVel * dt
        CATransaction.begin(); CATransaction.setDisableActions(true)
        swing.transform = CATransform3DMakeRotation(swingAngle, 0, 0, 1)
        CATransaction.commit()
        if !dragging && abs(swingAngle) < 0.002 && abs(swingVel) < 0.01 {
            swingTimer?.invalidate(); swingTimer = nil
            swingAngle = 0; swingVel = 0
            CATransaction.begin(); CATransaction.setDisableActions(true)
            swing.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    func mouseDown(_ e: NSEvent) {
        let p = view.convert(e.locationInWindow, from: nil)
        if !bubble.isHidden && bubble.frame.contains(p) { hideBubble(); return }
        if changing { return }   // 换衣服的时候别拎她
        dragging = true; dragged = false
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window.frame.origin
    }

    func mouseDragged(_ e: NSEvent) {
        guard dragging else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - dragStartMouse.x, dy = m.y - dragStartMouse.y
        if !dragged && hypot(dx, dy) > 3 {
            dragged = true
            show(.blink, for: 3600)
            setLean(0, 0.2)
            lastDragX = m.x; lastDragT = e.timestamp
            CATransaction.begin(); CATransaction.setAnimationDuration(0.2)
            mover.setValue(1.03, forKeyPath: "transform.scale.y")   // 被拎起来，身子拉长一点
            CATransaction.commit()
            startSwing()
        }
        if dragged {
            window.setFrameOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
            let dtm = max(e.timestamp - lastDragT, 0.008)
            let vx = (m.x - lastDragX) / CGFloat(dtm)
            lastDragX = m.x; lastDragT = e.timestamp
            swingTarget = max(-0.5, min(0.5, -vx * 0.0006))
        }
    }

    func mouseUp(_ e: NSEvent) {
        guard dragging else { return }
        dragging = false
        lastTouch = Date()
        if dragged {
            CATransaction.begin(); CATransaction.setAnimationDuration(0.15)
            mover.setValue(1.0, forKeyPath: "transform.scale.y")
            CATransaction.commit()
            show(nil, for: 0)
            hop(8)
            Prefs.foot = footPoint
            if Bool.random() { say(["好啦，就待在这儿。", "这里视野不错。", "嘿咻。"].randomElement()!, seconds: 2.5) }
        } else {
            poke()
        }
    }

    func rightMouseDown(_ e: NSEvent, in v: NSView) {
        NSMenu.popUpContextMenu(buildMenu(), with: e, for: v)
    }

    // MARK: 互动
    // 台词按官网设定写：做什么都直率认真；最爱吃（蛋糕、炖菜）；喜欢看书、和弟弟看剧；
    // 吃饭和午睡的时候最幸福；成绩一直第一的努力家。都是自己写的，不照搬原作台词。

    var isBirthday: Bool {
        let c = Calendar.current.dateComponents([.month, .day], from: Date())
        return c.month == 7 && c.day == 22
    }

    func poke() {
        guard !changing else { return }
        lastTouch = Date()
        if mode == .napping {
            mode = .idle; stopZzz(); render(); idleMotion(); setLean(0, 0.5)
            say(["唔……我醒啦。", "啊，睡着了……刚才有说梦话吗？", "午睡果然最幸福了。"].randomElement()!, seconds: 3)
            hop(6); return
        }
        if mode == .studying {
            hearts(1)
            let left = max(1, Int(ceil((studyEnd ?? Date()).timeIntervalSinceNow / 60)))
            say(["还剩 \(left) 分钟，一起加油。", "专心专心，学完这轮再休息。", "我也在认真看书哦。"].randomElement()!, seconds: 3)
            return
        }
        if Bool.random() { greet() } else { pat() }
    }

    func greet() {
        busyUntil = Date().addingTimeInterval(1.4)
        if mode == .idle { show(.blink, for: 1.2) }
        hop(); hearts(2)
        var lines = ["我在这里呢。", "嗯？找我吗？", "今天也辛苦啦。", "嘿嘿。", "要不要歇一会儿？",
                     "复习累了就看看我。", "不懂的地方，我们一起想。", "认真的样子很帅气哦。"]
        if isBirthday { lines = ["今天是我的生日！你记得吗？", "生日的时候，蛋糕可以多吃一块吧？"] }
        var weekly: [(String, Double)] = []
        if Prefs.useClaude, let w = quota.latest["每周"] { weekly.append(("Claude", w.used)) }
        if Prefs.useCodex, let w = codex.week, (w.resetsAt ?? .distantFuture) > Date() { weekly.append(("Codex", w.used)) }
        if let (name, used) = weekly.randomElement(), Int.random(in: 0..<3) == 0 {
            let left = pct(100 - used)
            lines.append(used >= 85 ? "\(name) 这周只剩 \(left)% 了，悠着点用哦。" : "\(name) 这周还剩 \(left)% 呢。")
        }
        say(lines.randomElement()!, seconds: 3.2)
    }

    func pat() {
        busyUntil = Date().addingTimeInterval(1.8)
        if mode == .idle { show(.blink, for: 1.6) }
        squish(); tilt(); hearts(4)
        say(["嗯？……嘿嘿。", "头发要被揉乱啦。", "再、再摸一下也可以。", "被夸了的感觉。"].randomElement()!, seconds: 3)
    }

    func cake() {
        guard !changing else { return }
        if mode == .napping { mode = .idle; stopZzz() }
        lastTouch = Date()
        busyUntil = Date().addingTimeInterval(3)
        show(.blink, for: 2.6)
        chew()
        let treat = isBirthday ? "🎂" : ["🍰", "🍰", "🍰", "🧁", "🌰"].randomElement()!
        floatText(treat, from: CGPoint(x: handPoint.x, y: handPoint.y - 6), size: 26, color: .white, rise: 10, duration: 2.4)
        hearts(5)
        let lines: [String]
        switch treat {
        case "🎂": lines = ["生日蛋糕！谢谢你，我会全部吃完的。"]
        case "🌰": lines = ["栗子的！我的名字里也有栗子哦。", "蒙布朗……好幸福。"]
        default: lines = ["谢谢！吃蛋糕的时候最幸福了。", "是草莓的！", "再来一块也没问题哦。", "好吃到想转圈。"]
        }
        say(lines.randomElement()!, seconds: 3.5, force: true)
    }

    func toggleReading() {
        guard !changing else { return }
        if mode == .studying { stopStudy(early: true); return }
        stopZzz()
        mode = mode == .reading ? .idle : .reading
        render()
        say(mode == .reading ? "我也看会儿书，慢慢来。" : "这本看完啦，下次换一本。", seconds: 3)
    }

    func toggleNap(auto: Bool = false) {
        guard !changing else { return }
        if mode == .studying { return }
        if mode == .napping { mode = .idle; stopZzz(); render(); idleMotion(); setLean(0, 0.6); say("醒啦。", seconds: 2.5); return }
        mode = .napping
        render()
        idleMotion()
        setLean(restingLean, 1.6)
        say(auto ? ["吃饱了……有点困。", "我先眯一会儿，你点我就醒。"].randomElement()! : "我在这里小憩一会儿。", seconds: 3.5)
        startZzz()
    }

    // MARK: 一起学习（番茄钟）

    var studiedToday: Int {
        let parts = Prefs.studyLog.split(separator: "|")
        return parts.count == 2 && parts[0] == todayString ? Int(parts[1]) ?? 0 : 0
    }
    var todayString: String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }

    func startStudy(_ minutes: Int) {
        guard !changing else { return }
        stopZzz()
        studyMinutes = minutes
        studyEnd = Date().addingTimeInterval(Double(minutes) * 60)
        mode = .studying
        render()
        hop(6)
        say("好，一起学 \(minutes) 分钟！\n时间到了我叫你。", seconds: 4, force: true)
    }

    func stopStudy(early: Bool) {
        studyEnd = nil
        mode = .idle
        render()
        if early { say("先学到这儿也好，休息一下吧。", seconds: 3, force: true); return }
        let n = studiedToday + 1
        Prefs.studyLog = "\(todayString)|\(n)"
        hop(); hearts(5); sparkles()
        let food = Calendar.current.component(.hour, from: Date()) >= 16 ? "要是有炖菜就好了" : "吃块蛋糕奖励自己"
        say("学完一轮啦！今天第 \(n) 轮。\n休息 5 分钟，\(food)。", title: "一起学习", seconds: 9, force: true)
    }

    func startZzz() {
        stopZzz()
        zTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            let p = CGPoint(x: self.headPoint.x + self.spriteRect.width * 0.28, y: self.headPoint.y + 10)
            self.floatText("z", from: p, size: CGFloat.random(in: 13...19),
                           color: NSColor(calibratedRed: 0.55, green: 0.47, blue: 0.80, alpha: 1),
                           rise: 34, drift: 16, duration: 2.2)
        }
        zTimer?.fire()
    }

    func stopZzz() { zTimer?.invalidate(); zTimer = nil }

    // MARK: 换装

    func minutes(_ s: String) -> Int {
        let p = s.split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? p[0] * 60 + p[1] : 0
    }

    func scheduledOutfit(at date: Date = Date()) -> Outfit {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let day = minutes(Prefs.dayAt), night = minutes(Prefs.nightAt)
        if day < night { return (now >= day && now < night) ? .day : .night }
        return (now >= night && now < day) ? .night : .day   // 睡衣时间过了零点
    }

    func desiredOutfit() -> Outfit {
        if let o = Prefs.outfitOverride, let v = Outfit(rawValue: o), Prefs.overrideUntil > Date().timeIntervalSince1970 { return v }
        return scheduledOutfit()
    }

    func tick() {
        if mode == .studying, let end = studyEnd, Date() >= end { stopStudy(early: false) }
        // 吃饭和午睡最幸福：午后或深夜很久没理她，她就自己睡一会儿
        let h = Calendar.current.component(.hour, from: Date())
        if mode == .idle, !changing, (h == 13 || h == 14 || (1...4).contains(h)),
           Date().timeIntervalSince(lastTouch) > 20 * 60 { toggleNap(auto: true) }
        let want = desiredOutfit()
        if want != outfit && !changing && Date() > busyUntil && !dragging { changeOutfit(to: want) }
        if Date() > nextChat {
            nextChat = Date().addingTimeInterval(Double.random(in: 1500...2700))
            if mode != .napping && bubble.isHidden { chatter() }
        }
    }

    func changeOutfit(to target: Outfit, manual: Bool = false) {
        guard target != outfit, !changing else { return }
        changing = true
        let wasNapping = mode == .napping
        if wasNapping { stopZzz() }
        say(target == .night ? "换好睡衣，再来陪你。" : "换身常服，开始新的一天。", seconds: 3.2, force: manual)
        show(.hold, for: 3600)     // 先抱起要换的衣服
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self else { return }
            self.spin()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.675) {   // 第二次侧身到看不见的那一刻换掉
                self.outfit = target
                self.transient = nil
                self.transientToken += 1
                if self.mode == .napping { self.mode = .idle; self.idleMotion(); self.setLean(0, 0.3) }
                self.render()
                self.burst()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.hop(10) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { self.changing = false }
        }
    }

    /// 原地转一圈（左右翻过去再翻回来），同时轻轻飘起
    func spin() {
        let sx = CAKeyframeAnimation(keyPath: "transform.scale.x")
        sx.values = [1, 0, -1, 0, 1]
        sx.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        sx.timingFunctions = [CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .easeOut),
                              CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .easeOut)]
        let y = mover.position.y
        let up = CAKeyframeAnimation(keyPath: "position.y")
        up.values = [y, y + 10, y + 12, y + 6, y]
        up.keyTimes = [0, 0.3, 0.5, 0.8, 1]
        let g = CAAnimationGroup(); g.animations = [sx, up]; g.duration = 0.9
        mover.add(g, forKey: "spin")
        sparkles()
    }

    /// 一圈星星往外散开
    func burst() {
        let c = CGPoint(x: spriteRect.midX, y: spriteRect.minY + spriteRect.height * 0.55)
        for i in 0..<10 {
            let a = CGFloat(i) / 10 * 2 * .pi
            let r = spriteRect.width * CGFloat.random(in: 0.45...0.65)
            twinkle(at: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r * 1.3), size: CGFloat.random(in: 9...15))
        }
    }

    func manualOutfit(_ o: Outfit) {
        // 手动换装保持到下一个作息时间点
        var t = Date()
        let start = scheduledOutfit(at: t)
        for _ in 0..<(48 * 60 / 5) { t = t.addingTimeInterval(300); if scheduledOutfit(at: t) != start { break } }
        Prefs.outfitOverride = o.rawValue
        Prefs.overrideUntil = t.timeIntervalSince1970
        if o == outfit { say(o == .day ? "已经穿着常服啦。" : "已经是睡衣啦。", seconds: 2.5, force: true) }
        else { changeOutfit(to: o, manual: true) }
    }

    // MARK: 闲聊

    func chatter() {
        let h = Calendar.current.component(.hour, from: Date())
        var lines = ["记得喝口水。", "坐久了，起来伸个懒腰吧。", "我在这儿陪你。", "眼睛也要休息一下哦，看看远处。",
                     "累了就歇一会儿，不着急。", "这一页看完就休息五分钟吧。", "今天想吃什么？我想吃炖菜。",
                     "最近在看一本书，看完讲给你听。", "周末想去买东西，顺便……吃点甜的。",
                     "一点一点来，不会的地方多看两遍就好。", "我弟弟昨天又拉我一起追剧了。"]
        switch h {
        case 6..<9: lines += ["早上好，今天也一起加油吧。", "早饭要好好吃哦。"]
        case 11..<13: lines = ["该吃午饭啦！吃饭的时候最幸福了。", "午饭吃什么？吃饱了才有力气学。"]
        case 15: lines += ["下午茶时间……要不要来点甜的？"]
        case 17..<19: lines = ["晚饭吃了吗？", "今天晚饭要是炖菜就好了。"]
        case 23, 0: lines = ["很晚啦，早点休息好不好？", "今天就到这里吧，明天再继续。"]
        case 1..<5: lines = ["已经这么晚了……我陪你，但明天要补觉哦。"]
        default: break
        }
        if studiedToday >= 2 && Bool.random() { lines = ["今天已经一起学了 \(studiedToday) 轮，好厉害。"] }
        if mode == .idle { show(.blink, for: 0.9) }
        say(lines.randomElement()!, seconds: 5)
    }

    func hello() {
        hop(); hearts(2)
        let h = Calendar.current.component(.hour, from: Date())
        var greet = h < 5 ? "这么晚还没睡呀。" : h < 11 ? "早上好，我来啦。" : h < 18 ? "下午好，我来陪你啦。" : "晚上好，我来陪你啦。"
        if isBirthday { greet = "今天是 7 月 22 日……是我的生日哦！" }
        say(greet, seconds: 4)
    }

    // MARK: 额度

    func quotaChanged(_ rows: [(QuotaRow, Double?)]) {
        guard !rows.isEmpty else { return }
        let level = Prefs.quotaAlert
        if level == "off" { return }
        var lines: [String] = []
        var reset = false, high = false
        for (r, before) in rows {
            let name = kindName(r.kind)
            if r.isReset || (before.map { r.used < $0 } ?? r.change.hasPrefix("-")) {
                reset = true
                lines.append("\(name)额度刷新啦，现在用了 \(pct(r.used))%")
                continue
            }
            if r.used >= 90 { high = true }
            if level == "five", let b = before, Int(b) / 5 == Int(r.used) / 5, r.used < 90 { continue }
            let tag = r.change.hasPrefix("+") ? "\(r.change)%" : r.change
            lines.append("\(name)额度用了 \(pct(r.used))%（\(tag)）")
        }
        guard !lines.isEmpty else { return }
        var body = lines.joined(separator: "\n")
        if reset { body += "\n又可以放心用啦。" } else if high { body += "\n快见底了，省着点用哦。" }
        if mode == .idle && !changing { show(.blink, for: 0.9) }
        if reset { hop(); hearts(3) } else { hop(6) }
        say(body, title: "额度变化", seconds: 6.5, quota: true)
    }

    func showQuota() {
        live.poll(force: true)
        folder.poll(force: true); quota.poll(force: true); codex.poll(force: true)
        var lines: [String] = [], resets: [String] = [], notes: [String] = []
        func cell(_ name: String, _ used: Double?, _ resetAt: Date?) -> String? {
            guard let used else { return nil }
            if let r = resetAt, r < Date() { return "\(name) 已重置" }
            return "\(name) \(pct(used))%"
        }
        func addFolder(_ src: SourceFile) {
            let cells = src.windows.map { cell($0.label == "每周" ? "这周" : $0.label, $0.used, $0.resetsAt) ?? "" }
            lines.append(src.name + "　" + cells.joined(separator: "　"))
            if let r = src.windows.compactMap(\.resetsAt).filter({ $0 > Date() }).min(), r.timeIntervalSinceNow < 86400 {
                resets.append("\(src.name) \(resetText(r).replacingOccurrences(of: "今天 ", with: ""))")
            }
        }
        if Prefs.useClaude, let c = folder.freshClaude {
            addFolder(c)
        } else if Prefs.useClaude {
            let f = quota.latest["5小时"], w = quota.latest["每周"]
            let fr = f.flatMap { r -> Date? in let d = DateFormatter(); d.dateFormat = "yyyy-MM-dd HH:mm:ss"; return d.date(from: r.reset) }
            if f == nil && w == nil {
                notes.append("Claude：" + (quota.problem ?? "还没有记录，开着 Claude Code 时才会记。"))
            } else {
                lines.append("Claude　" + [cell("5 小时", f?.used, fr), cell("这周", w?.used, nil)].compactMap { $0 }.joined(separator: "　"))
                if let fr, fr > Date() { resets.append("Claude \(resetText(fr).replacingOccurrences(of: "今天 ", with: ""))") }
            }
        }
        if Prefs.useClaude, Prefs.liveClaude, let n = live.claudeNote { notes.append(n) }
        if Prefs.useCodex, let c = folder.freshCodex {
            addFolder(c)
        } else if Prefs.useCodex {
            if codex.five == nil && codex.week == nil {
                notes.append("Codex：还没读到，用一次 Codex 就有了。")
            } else {
                lines.append("Codex　" + [cell("5 小时", codex.five?.used, codex.five?.resetsAt),
                                          cell("这周", codex.week?.used, codex.week?.resetsAt)].compactMap { $0 }.joined(separator: "　"))
                if let r = codex.five?.resetsAt, r > Date() { resets.append("Codex \(resetText(r).replacingOccurrences(of: "今天 ", with: ""))") }
            }
        }
        let muted = Set(Prefs.mutedSources)
        for src in folder.sources.values.sorted(by: { $0.name < $1.name })
        where !["claude", "codex"].contains(src.name.lowercased()) && !muted.contains(src.name) { addFolder(src) }
        if lines.isEmpty && notes.isEmpty { say("额度来源都关掉啦，在右键菜单“额度来源”里打开。", seconds: 5, force: true); return }
        if !resets.isEmpty { lines.append("最近重置：" + resets.joined(separator: "，")) }
        if let at = codex.seenAt, Prefs.useCodex, folder.freshCodex == nil, Date().timeIntervalSince(at) > 3600 { lines.append("（Codex 是\(agoText(at))的数据）") }
        hop(6)
        say((lines + notes).joined(separator: "\n"), title: "已用额度", seconds: 9, quota: true)
    }

    // MARK: 菜单

    func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(ActionItem("摸摸头") { [weak self] in self?.pat() })
        m.addItem(ActionItem("喂蛋糕") { [weak self] in self?.cake() })
        m.addItem(ActionItem("一起看书", on: mode == .reading) { [weak self] in self?.toggleReading() })
        m.addItem(ActionItem("小睡一会儿", on: mode == .napping) { [weak self] in self?.toggleNap() })
        m.addItem(.separator())
        if mode == .studying, let end = studyEnd {
            let left = max(1, Int(ceil(end.timeIntervalSinceNow / 60)))
            m.addItem(ActionItem("结束学习（还剩 \(left) 分钟）") { [weak self] in self?.stopStudy(early: true) })
        } else {
            m.addItem(ActionItem("一起学习 25 分钟") { [weak self] in self?.startStudy(25) })
            m.addItem(ActionItem("一起学习 50 分钟") { [weak self] in self?.startStudy(50) })
        }
        if studiedToday > 0 {
            let done = NSMenuItem(title: "今天一起学了 \(studiedToday) 轮", action: nil, keyEquivalent: "")
            done.isEnabled = false
            m.addItem(done)
        }
        m.addItem(.separator())
        m.addItem(ActionItem("看看额度") { [weak self] in self?.showQuota() })
        m.addItem(submenu("额度来源", [
            ActionItem("Claude", on: Prefs.useClaude) { Prefs.useClaude.toggle() },
            ActionItem("Codex", on: Prefs.useCodex) { [weak self] in Prefs.useCodex.toggle(); self?.codex.poll(force: true) },
        ] + [NSMenuItem.separator(),
             ActionItem("实时查询 Claude（读本机登录信息）", on: Prefs.liveClaude) { [weak self] in
                 Prefs.liveClaude.toggle()
                 if Prefs.liveClaude { self?.live.poll(force: true) }
                 self?.say(Prefs.liveClaude ? "好，每 5 分钟帮你看一次 Claude 额度。\n第一次系统会问能不能读钥匙串，点“始终允许”。"
                                            : "好，Claude 额度只在用 Claude Code 时更新。", seconds: 6, force: true)
             },
             ActionItem("实时查询 Codex", on: Prefs.liveCodex) { [weak self] in
                 Prefs.liveCodex.toggle(); if Prefs.liveCodex { self?.live.poll(force: true) }
             },
             NSMenuItem.separator(),
        ] + folder.sources.values.map(\.name).filter { !["claude", "codex"].contains($0.lowercased()) }.sorted().map { name in
            ActionItem(name, on: !Prefs.mutedSources.contains(name)) {
                var m = Prefs.mutedSources
                if let i = m.firstIndex(of: name) { m.remove(at: i) } else { m.append(name) }
                Prefs.mutedSources = m
            }
        } + [NSMenuItem.separator(), ActionItem("打开额度文件夹") {
            try? FileManager.default.createDirectory(atPath: FolderWatcher.dir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(URL(fileURLWithPath: FolderWatcher.dir))
        }]))
        let a = Prefs.quotaAlert
        m.addItem(submenu("额度提醒", [
            ActionItem("每次变化都说", on: a == "all") { Prefs.quotaAlert = "all" },
            ActionItem("每用掉 5% 说一次", on: a == "five") { Prefs.quotaAlert = "five" },
            ActionItem("不提醒", on: a == "off") { Prefs.quotaAlert = "off" },
        ]))
        m.addItem(.separator())
        m.addItem(ActionItem("换常服", on: outfit == .day) { [weak self] in self?.manualOutfit(.day) })
        m.addItem(ActionItem("换睡衣", on: outfit == .night) { [weak self] in self?.manualOutfit(.night) })
        var timeItems: [NSMenuItem] = []
        let dayHeader = NSMenuItem(title: "早上换常服", action: nil, keyEquivalent: ""); dayHeader.isEnabled = false
        timeItems.append(dayHeader)
        for t in ["06:00", "07:00", "08:00", "09:00"] {
            timeItems.append(ActionItem("   " + t, on: Prefs.dayAt == t) { [weak self] in
                Prefs.dayAt = t; Prefs.outfitOverride = nil; self?.tick() })
        }
        timeItems.append(.separator())
        let nightHeader = NSMenuItem(title: "晚上换睡衣", action: nil, keyEquivalent: ""); nightHeader.isEnabled = false
        timeItems.append(nightHeader)
        for t in ["21:00", "22:00", "23:00", "00:00"] {
            timeItems.append(ActionItem("   " + t, on: Prefs.nightAt == t) { [weak self] in
                Prefs.nightAt = t; Prefs.outfitOverride = nil; self?.tick() })
        }
        m.addItem(submenu("换装时间", timeItems))
        let sc = Prefs.scale
        m.addItem(submenu("大小", [("小", 0.75), ("中", 1.0), ("大", 1.25), ("特大", 1.5)].map { name, v in
            ActionItem(name, on: abs(sc - v) < 0.01) { [weak self] in
                guard let self else { return }
                Prefs.scale = v
                self.layout(keepFoot: self.footPoint)
            }
        }))
        m.addItem(ActionItem("安静陪伴（少说话）", on: Prefs.quiet) { [weak self] in
            Prefs.quiet.toggle()
            if !Prefs.quiet { self?.say("那我多陪你说说话。", seconds: 3) }
        })
        m.addItem(ActionItem("省电模式（动作少一点）", on: Prefs.lowMotion) { [weak self] in
            guard let self else { return }
            Prefs.lowMotion.toggle()
            self.startWave(); self.idleMotion()
            self.say(Prefs.lowMotion ? "那我安安静静站着。" : "风吹起来啦。", seconds: 2.5, force: true)
        })
        let login = SMAppService.mainApp.status == .enabled
        m.addItem(ActionItem("开机自动出来", on: login) { [weak self] in self?.toggleLogin(!login) })
        m.addItem(.separator())
        m.addItem(ActionItem("回到屏幕右下角") { [weak self] in Prefs.foot = nil; self?.layout(keepFoot: nil) })
        m.addItem(ActionItem(window.isVisible ? "先藏起来" : "叫她出来") { [weak self] in self?.toggleVisible() })
        m.addItem(ActionItem("退出") { NSApp.terminate(nil) })
        return m
    }

    func toggleVisible() {
        if window.isVisible { window.orderOut(nil) }
        else { window.orderFrontRegardless(); hello() }
    }

    func toggleLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            say(on ? "好，以后开机我就自己出来。" : "好，开机就不自己出来了。", seconds: 3, force: true)
        } catch {
            say("没设成功……\n可以在 系统设置 → 通用 → 登录项 里手动加上「薰子」。", seconds: 7, force: true)
        }
    }

    // 调试用：动作名来自 ~/Library/Caches/kaoruko/cmd
    func debug(_ cmd: String) {
        switch cmd {
        case "greet": greet()
        case "pat": pat()
        case "cake": cake()
        case "read": toggleReading()
        case "nap": toggleNap()
        case "day": manualOutfit(.day)
        case "night": manualOutfit(.night)
        case "quota": showQuota()
        case "chat": chatter()
        case "study": startStudy(25)
        case "studydone": studyEnd = Date(); tick()
        case "codexpoll": codex.poll()
        case "folderpoll": folder.poll()
        case "livepoll": live.poll(force: true)
        case "hop": hop()
        case "spin": spin(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.675) { self.burst() }
        case "fidget": fidget()
        case "petal": petal()
        case "twinkle": twinkle()
        case "swing": swingTarget = 0.35; swingAngle = 0.3; startSwing()
        case "autonap": lastTouch = .distantPast; toggleNap(auto: true)
        case "fakequota": quotaChanged([(QuotaRow(time: "", kind: "5小时", used: 41, change: "+1", isReset: false, reset: ""), 40),
                                        (QuotaRow(time: "", kind: "每周", used: 91, change: "+1", isReset: false, reset: ""), 90)])
        case let c where c.hasPrefix("snap:"):
            // snap:名字 或 snap:名字@0.3（0.3 秒后再拍）
            let parts = String(c.dropFirst(5)).split(separator: "@")
            let name = String(parts[0]).replacingOccurrences(of: "/", with: "_")
            let delay = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.snapshot(to: NSHomeDirectory() + "/Library/Caches/kaoruko/" + name + ".png")
            }
        default: break
        }
    }

    /// 把自己的窗口画成 PNG（调试用，不需要录屏权限）
    func snapshot(to path: String) {
        guard let root = view.layer else { return }
        let scale = window.backingScaleFactor
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.19, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        root.presentation()?.render(in: ctx) ?? root.render(in: ctx)
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        let info = "frame=\(window.frame) visible=\(window.isVisible) ignores=\(window.ignoresMouseEvents) outfit=\(outfit) mode=\(mode) codex5=\(codex.five?.used ?? -1) codexWeek=\(codex.week?.used ?? -1) claudeNote=\(live.claudeNote ?? "-") codexNote=\(live.codexNote ?? "-") sources=\(folder.sources.values.map { "\($0.name):" + $0.windows.map { "\($0.label)=\(pct($0.used))" }.joined(separator: ",") }.sorted())"
        try? info.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
    }
}

// MARK: - 程序入口

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var pet: Pet!
    var status: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != me.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        pet = Pet()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "✿"
        status.button?.toolTip = "薰子"
        let menu = NSMenu(); menu.delegate = self
        status.menu = menu
        // 调试口（默认关）：defaults write com.emma.kaoruko-pet debug -bool true 后，
        // 往 ~/Library/Caches/kaoruko/cmd 写一行动作名，她一秒内执行
        guard Prefs.debug else { return }
        let cmdPath = NSHomeDirectory() + "/Library/Caches/kaoruko/cmd"
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let text = try? String(contentsOfFile: cmdPath, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(atPath: cmdPath)
            for line in text.split(whereSeparator: \.isNewline) { self?.pet.debug(String(line)) }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in pet.buildMenu().items { item.menu?.removeItem(item); menu.addItem(item) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
