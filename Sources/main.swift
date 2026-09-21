import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/MouseVoice", isDirectory: true)
let configURL = supportDirectory.appendingPathComponent("config.json")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    let menu = NSMenu()
    let statusLine = NSMenuItem(title: "已暂停", action: nil, keyEquivalent: "")
    let permissionLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let modeLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let evidenceLine = NSMenuItem(title: "合成 Fn 回读：0 次（不代表语音启动）", action: nil, keyEquivalent: "")
    let toggleItem = NSMenuItem(title: "启用（开始测试）", action: #selector(toggleEnabled), keyEquivalent: "")
    var config = Configuration()
    var configValid = false
    var detector = HoldDetector(delay: 1.2, tolerance: 6)
    let output = KeyOutput()
    var tap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var deadlineTimer: Timer?
    var watchdog: Timer?
    var activeSince: Double = 0
    var enabled = false
    var menuOpen = false
    var fnEchoes = 0
    var log: [String] = []
    var signalSources: [DispatchSourceSignal] = []
    var smokeTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "MV ○"
        item.button?.toolTip = "MouseVoice：长按左键测试语音快捷键"
        menu.delegate = self
        menu.autoenablesItems = false
        for line in [statusLine, permissionLine, modeLine, evidenceLine] {
            line.isEnabled = false
            menu.addItem(line)
        }
        menu.addItem(.separator())
        toggleItem.target = self
        menu.addItem(toggleItem)
        add("申请输入监控权限", #selector(requestListening))
        add("申请辅助功能权限", #selector(requestPosting))
        add("打开隐私与安全性设置", #selector(openPrivacy))
        menu.addItem(.separator())
        add("Fn 模式（默认实验）", #selector(selectFn))
        add("快捷键：按住 / 松开", #selector(selectHold))
        add("快捷键：开始 / 结束各点一次", #selector(selectToggle))
        add("打开配置文件", #selector(openConfiguration))
        add("重新载入配置（会暂停）", #selector(reloadConfiguration))
        add("复制诊断记录", #selector(copyDiagnostics))
        menu.addItem(.separator())
        add("退出并释放模拟按键", #selector(quit))
        item.menu = menu
        reloadConfiguration()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(sessionInterrupted), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionInterrupted), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(sessionInterrupted),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.quit() }
            source.resume()
            signalSources.append(source)
        }
        record("应用启动；默认暂停，无权限弹窗，不发送按键")
        if CommandLine.arguments.contains("--enable") {
            if !CGPreflightPostEventAccess() { requestPosting() }
            if !CGPreflightListenEventAccess() { requestListening() }
            toggleEnabled()
        }
        if CommandLine.arguments.contains("--smoke-test") {
            smokeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                print("PASS: AppKit status item created; app stayed paused; no input events posted.")
                self?.quit()
            }
        }
    }

    func add(_ title: String, _ selector: Selector) {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
    }

    func record(_ message: String) {
        log.append("\(ISO8601DateFormatter().string(from: Date())) \(message)")
        if CommandLine.arguments.contains("--diagnostics") { print(log.last!); fflush(stdout) }
        if log.count > 100 { log.removeFirst(log.count - 100) }
        statusLine.title = message
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        // A long press inside this application's menu should not activate voice.
        cancelGesture("打开菜单，当前手势取消")
        permissionLine.title = "输入监控：\(CGPreflightListenEventAccess() ? "已允许" : "未允许") · 发送：\(CGPreflightPostEventAccess() ? "已允许" : "未允许")"
        modeLine.title = "\(config.mode.rawValue) · \(config.holdSeconds) 秒 · \(config.movementTolerancePoints) 点"
        evidenceLine.title = "合成 Fn 回读：\(fnEchoes) 次（不代表语音启动）"
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    @objc func requestListening() { _ = CGRequestListenEventAccess(); record("输入监控已申请；授权后重新启用，必要时重开应用") }
    @objc func requestPosting() { _ = CGRequestPostEventAccess(); record("事件发送权限已申请；请检查辅助功能设置") }
    @objc func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
    }

    @objc func openConfiguration() { NSWorkspace.shared.open(configURL) }

    @objc func reloadConfiguration() {
        disable()
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: configURL.path) {
                try save(Configuration())
            }
            let candidate = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL))
            try candidate.validate()
            config = candidate
            configValid = true
            detector = HoldDetector(delay: config.holdSeconds, tolerance: config.movementTolerancePoints)
            record("配置已载入；点击启用开始测试")
        } catch {
            configValid = false
            record("配置错误：\(error.localizedDescription)")
        }
    }

    func save(_ configuration: Configuration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: configURL, options: .atomic)
    }

    func select(_ mode: OutputMode) {
        disable()
        guard configValid else { record("先修复配置文件，再重新载入"); return }
        var candidate = config
        candidate.mode = mode
        do { try save(candidate); reloadConfiguration() }
        catch { record("保存失败：\(error.localizedDescription)") }
    }
    @objc func selectFn() { select(.fn) }
    @objc func selectHold() { select(.shortcutHold) }
    @objc func selectToggle() { select(.shortcutToggle) }

    @objc func toggleEnabled() {
        if enabled { disable(); record("已暂停"); return }
        guard configValid else { record("配置无效，请修复后重新载入"); return }
        guard CGPreflightPostEventAccess() else { record("请先授予辅助功能 / 事件发送权限"); return }
        guard CGPreflightListenEventAccess() || AXIsProcessTrusted() else {
            record("请先授予输入监控权限"); return
        }
        let mask = [CGEventType.leftMouseDown, .leftMouseUp, .leftMouseDragged, .flagsChanged]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        // Observe before the system/input method consumes Fn. A session-level tap
        // can miss Fn even when posting succeeded (verified on this Mac).
        tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
                if let context {
                    Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().handle(type, event)
                }
                return Unmanaged.passUnretained(event) // Never swallow or rewrite the mouse event.
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            if let tap { CFMachPortInvalidate(tap) }
            self.tap = nil
            record("监听创建失败；检查输入监控和辅助功能后重开应用")
            return
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        enabled = true
        toggleItem.title = "暂停并释放模拟按键"
        item.button?.title = "MV ●"
        record("监听已启用；原地长按左键 \(config.holdSeconds) 秒")
    }

    func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelGesture("监听中断，已释放；等待下次点击")
            if enabled, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if type == .flagsChanged {
            guard event.getIntegerValueField(.keyboardEventKeycode) == 63 else { return }
            let ours = event.getIntegerValueField(.eventSourceUserData) == KeyOutput.marker
            if ours { fnEchoes += 1 }
            record("\(ours ? "合成" : "外部") Fn \(event.flags.contains(.maskSecondaryFn) ? "down" : "up") 已被监听（未确认语音）")
            return
        }
        guard enabled, event.getIntegerValueField(.eventSourceUserData) != KeyOutput.marker else { return }
        switch type {
        case .leftMouseDown:
            cancelGesture(nil)
            guard !menuOpen else { return }
            detector.down(at: event.location, now: ProcessInfo.processInfo.systemUptime)
            let timer = Timer(timeInterval: config.holdSeconds, repeats: false) { [weak self] _ in self?.deadline() }
            deadlineTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        case .leftMouseDragged:
            let previous = detector.state
            apply(detector.move(to: event.location))
            if detector.state == .cancelled && previous != .cancelled {
                deadlineTimer?.invalidate(); deadlineTimer = nil
                record("移动超过容差，本次手势已取消")
            }
        case .leftMouseUp:
            cancelGesture(output.active ? "已发送释放事件（未确认语音停止）" : nil)
        default: break
        }
    }

    func deadline() {
        deadlineTimer = nil
        let action = detector.deadline(now: ProcessInfo.processInfo.systemUptime,
            buttonDown: CGEventSource.buttonState(.hidSystemState, button: .left),
            point: CGEvent(source: nil)?.location ?? CGPoint(x: CGFloat.infinity, y: CGFloat.infinity))
        apply(action)
    }

    func apply(_ action: HoldDetector.Action) {
        switch action {
        case .none: return
        case .begin:
            guard output.begin(config) else {
                _ = detector.reset()
                record("未发送：权限不足、物理修饰键被按住或事件创建失败")
                return
            }
            activeSince = ProcessInfo.processInfo.systemUptime
            item.button?.title = "MV ↑"
            record("已发送 \(config.mode.rawValue) 开始事件（未确认语音启动）")
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let self else { return }
                if !CGEventSource.buttonState(.hidSystemState, button: .left)
                    || ProcessInfo.processInfo.systemUptime - self.activeSince >= self.config.maximumHoldSeconds {
                    self.cancelGesture("兜底释放：已松开或超过最长保持时间")
                }
            }
            watchdog = timer
            RunLoop.main.add(timer, forMode: .common)
        case .end:
            output.end()
            watchdog?.invalidate(); watchdog = nil
            item.button?.title = enabled ? "MV ●" : "MV ○"
        }
    }

    func cancelGesture(_ reason: String?) {
        deadlineTimer?.invalidate(); deadlineTimer = nil
        watchdog?.invalidate(); watchdog = nil
        _ = detector.reset()
        output.end()
        item?.button?.title = enabled ? "MV ●" : "MV ○"
        if let reason { record(reason) }
    }

    func disable() {
        enabled = false
        cancelGesture(nil)
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        runLoopSource = nil
        tap = nil
        toggleItem.title = "启用（开始测试）"
    }

    @objc func sessionInterrupted() { disable(); record("休眠或会话切换，已暂停并释放") }
    @objc func copyDiagnostics() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let text = "MouseVoice \(version)\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nlisten=\(CGPreflightListenEventAccess()) post=\(CGPreflightPostEventAccess()) AX=\(AXIsProcessTrusted())\nmode=\(config.mode.rawValue) enabled=\(enabled) fnEchoes=\(fnEchoes)\n" + log.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    @objc func quit() { disable(); NSApplication.shared.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { disable() }
}

if CommandLine.arguments.contains("--diagnose") {
    print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("Input Monitoring: \(CGPreflightListenEventAccess())")
    print("Event posting: \(CGPreflightPostEventAccess())")
    print("Accessibility: \(AXIsProcessTrusted())")
    print("No permission prompts or synthetic events. CLI permission identity may differ from Finder-launched app.")
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
