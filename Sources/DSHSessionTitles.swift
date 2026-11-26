import Foundation

/// 会话标题的只读来源。
///
/// DSH 的 `/api/usage-stats/usage` 只给 `sessionId`，`title` 字段恒为 null；真实标题存在
/// 会话缓存里：`~/.dsh/storages/session_projcache/sessions/<uuid>.json`
/// 的 `record.rows.title.val`（DSH 自己侧栏显示的就是这一条）。
///
/// 这里只做三件事：按 id 找到那一个文件、只读解析 `title.val`、缓存 60 秒。
/// 文件不存在、超过大小上限、JSON 结构不符、标题为空都返回 nil —— 界面如实退回短 id，
/// 不多猜、不读别的字段、不写任何文件。
final class DSHSessionTitles {
    static let shared = DSHSessionTitles()

    /// 单个缓存文件的上限。正常会话缓存是几十 KB，超过这个数说明结构变了，直接放弃。
    static let maximumBytes = 8 * 1024 * 1024
    static let cacheTTL: TimeInterval = 60
    static let maximumTitleLength = 40

    private struct Entry {
        let title: String?
        let at: Date
    }

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private let root: URL?

    init(root: URL? = DSHSessionTitles.defaultRoot()) {
        self.root = root
    }

    static func defaultRoot() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidate = home.appendingPathComponent(".dsh/storages/session_projcache/sessions",
                                                    isDirectory: true)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// 只接受 UUID 形态（可带 `session-` 前缀），防止把任意字符串拼进路径。
    static func key(_ id: String) -> String? {
        var value = id
        if value.hasPrefix("session-") { value = String(value.dropFirst("session-".count)) }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5 else { return nil }
        let lengths = [8, 4, 4, 4, 12]
        for (part, length) in zip(parts, lengths) where part.count != length {
            return nil
        }
        guard value.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        return value.lowercased()
    }

    /// 一次取多个会话的标题；没有标题的 id 不出现在结果里。
    func titles(for ids: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for id in ids {
            if let title = title(for: id) { result[id] = title }
        }
        return result
    }

    func title(for id: String) -> String? {
        guard let key = Self.key(id), let root else { return nil }
        lock.lock()
        if let entry = cache[key], Date().timeIntervalSince(entry.at) < Self.cacheTTL {
            lock.unlock()
            return entry.title
        }
        lock.unlock()

        // DSH 两种命名都出现过：<uuid>.json 与 session-<uuid>.json，先试前者。
        let title = Self.readTitle(at: root.appendingPathComponent(key + ".json"))
            ?? Self.readTitle(at: root.appendingPathComponent("session-" + key + ".json"))

        lock.lock()
        cache[key] = Entry(title: title, at: Date())
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        lock.unlock()
        return title
    }

    static func readTitle(at url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0, size.intValue <= maximumBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return decodeTitle(data)
    }

    /// `record.rows.title.val`；结构不符或不合法一律 nil。
    static func decodeTitle(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = root["record"] as? [String: Any],
              let rows = record["rows"] as? [String: Any] else { return nil }
        let raw: String?
        if let title = rows["title"] as? [String: Any], let value = title["val"] as? String {
            raw = value
        } else if let input = rows["titleInput"] as? [String: Any],
                  let first = input["first"] as? [String: Any],
                  let text = first["text"] as? String {
            raw = text
        } else {
            raw = nil
        }
        return normalise(raw)
    }

    /// 去掉换行与多余空白，过长截断并补省略号；空串返回 nil。
    static func normalise(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maximumTitleLength else { return collapsed }
        let cut = collapsed.prefix(maximumTitleLength)
        return cut + "…"
    }
}