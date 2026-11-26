import AppKit

/// 唤醒 DeepSeek Harness：和 Codex 模块一样的语义——已在运行就切到前台，
/// 没运行就启动，连续点击只会产生一个实例。
///
/// Bundle ID 不硬编码：从已安装的 App bundle 的 Info.plist 里实读，
/// 这样 App 改名或换 ID 时不会静默失效，也不会去打开无关应用。
enum DeepSeekHarnessApp {
    static let displayName = "DeepSeek Harness"

    /// 安装位置的候选；只用于「读 Info.plist」和「按路径启动」，不会用于猜测 ID。
    static let installPaths = [
        "/Applications/DeepSeek Harness.app",
        NSHomeDirectory() + "/Applications/DeepSeek Harness.app"
    ]

    private struct Application {
        let url: URL
        let bundleIdentifier: String
    }

    private static var cached: Application?

    /// 解析已安装的 App：优先按路径读 bundle，其次退回正在运行的进程（README 之外没有可靠来源）。
    static func resolve() -> (url: URL, bundleIdentifier: String)? {
        if let cached { return (cached.url, cached.bundleIdentifier) }
        for path in installPaths {
            guard FileManager.default.fileExists(atPath: path),
                  let bundle = Bundle(url: URL(fileURLWithPath: path)),
                  let identifier = bundle.bundleIdentifier, !identifier.isEmpty else { continue }
            cached = Application(url: URL(fileURLWithPath: path), bundleIdentifier: identifier)
            return (cached!.url, cached!.bundleIdentifier)
        }
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == displayName && $0.bundleIdentifier != nil && $0.bundleURL != nil
        }), let identifier = running.bundleIdentifier, let url = running.bundleURL {
            cached = Application(url: url, bundleIdentifier: identifier)
            return (url, identifier)
        }
        return nil
    }

    static var bundleIdentifier: String? { resolve()?.bundleIdentifier }

    static func isInstalled() -> Bool { resolve() != nil }

    static func isRunning() -> Bool {
        guard let identifier = bundleIdentifier else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
    }

    // MARK: - 重复启动保护

    /// 点击窗口：一个窗口内的连击不会重复调用 openApplication。
    private static var launchWindowUntil: Date = .distantPast

    static func launchAllowed(at now: Date) -> Bool { now >= launchWindowUntil }

    static func noteLaunchStarted(at now: Date) { launchWindowUntil = now.addingTimeInterval(3) }

    // MARK: - 唤醒

    /// 前台/隐藏/最小化/未运行都走这里；失败时回传原因，由调用方记录。
    static func activate(completion: ((String?) -> Void)? = nil) {
        precondition(Thread.isMainThread)
        guard let app = resolve() else {
            completion?("\(displayName) is not installed")
            return
        }

        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).first {
            // 隐藏（Cmd+H）时先取消隐藏，再激活并带上全部窗口。
            if running.isHidden { running.unhide() }
            if running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) {
                completion?(nil)
                return
            }
            // macOS 14+ 会拒绝后台应用自行激活，落到 openApplication（等于 `open -a`）。
        }

        guard launchAllowed(at: Date()) else {
            // 上一次点击已经在唤醒/启动途中，等待它完成即可。
            completion?(nil)
            return
        }
        noteLaunchStarted(at: Date())
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, error in
            let reason = error.map { "could not launch \(displayName): \($0.localizedDescription)" }
            DispatchQueue.main.async {
                // 启动成功后立刻清掉窗口，后续点击可以正常再次前置。
                if reason == nil { launchWindowUntil = .distantPast }
                completion?(reason)
            }
        }
    }
}
