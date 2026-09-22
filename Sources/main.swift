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
    let evidenceLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let toggleItem = NSMenuItem(title: "启用", action: #selector(toggleEnabled), keyEquivalent: "")
    var holdItems: [(Double, NSMenuItem)] = []
    var config = Configuration()
    var configValid = false
    var detector = HoldDetector(delay: 0.5, tolerance: 6)
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
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains(where: { $0.processIdentifier != getpid() }) {
            NSApplication.shared.terminate(nil)
            return
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = makeStatusImage()
        item.button?.toolTip = "MouseVoice · 长按左键开始语音"
        menu.delegate = self
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        toggleItem.target = self
        menu.addItem(toggleItem)
        let speedMenu = NSMenu()
        for seconds in [0.3, 0.5, 0.8, 1.2] {
            let entry = NSMenuItem(title: String(format: "%.1f 秒", seconds),
                                   action: #selector(changeHoldTime(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = seconds
            speedMenu.addItem(entry)
            holdItems.append((seconds, entry))
        }
        let speedItem = NSMenuItem(title: "长按时间", action: nil, keyEquivalent: "")
        speedItem.submenu = speedMenu
        menu.addItem(speedItem)
        menu.addItem(.separator())
        let settingsMenu = NSMenu()
        for line in [permissionLine, modeLine, evidenceLine] {
            line.isEnabled = false
            settingsMenu.addItem(line)
        }
        settingsMenu.addItem(.separator())
        add("申请输入监控权限", #selector(requestListening), to: settingsMenu)
        add("申请辅助功能权限", #selector(requestPosting), to: settingsMenu)
        add("打开系统权限设置", #selector(openPrivacy), to: settingsMenu)
        settingsMenu.addItem(.separator())
        add("Fn 模式", #selector(selectFn), to: settingsMenu)
        add("快捷键：按住 / 松开", #selector(selectHold), to: settingsMenu)
        add("快捷键：开始 / 结束各点一次", #selector(selectToggle), to: settingsMenu)
        add("打开配置文件", #selector(openConfiguration), to: settingsMenu)
        add("重新载入配置", #selector(reloadConfiguration), to: settingsMenu)
        add("复制诊断记录", #selector(copyDiagnostics), to: settingsMenu)
        let settingsItem = NSMenuItem(title: "设置与诊断", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        add("退出 MouseVoice", #selector(quit), to: menu)
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

    func makeStatusImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.black.setStroke()
        let mouse = NSBezierPath(roundedRect: NSRect(x: 4.5, y: 3.5, width: 9, height: 13),
                                 xRadius: 4.5, yRadius: 4.5)
        mouse.lineWidth = 1.5
        mouse.stroke()
        let wheel = NSBezierPath()
        wheel.lineWidth = 1.4
        wheel.lineCapStyle = .round
        wheel.move(to: NSPoint(x: 9, y: 13.1))
        wheel.line(to: NSPoint(x: 9, y: 10.7))
        wheel.stroke()
        let wave = NSBezierPath()
        wave.lineWidth = 1.2
        wave.lineCapStyle = .round
        wave.move(to: NSPoint(x: 6.7, y: 7.5))
        wave.line(to: NSPoint(x: 7.7, y: 8.8))
        wave.line(to: NSPoint(x: 8.7, y: 6.8))
        wave.line(to: NSPoint(x: 9.7, y: 8.8))
        wave.line(to: NSPoint(x: 11.2, y: 7.5))
        wave.stroke()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    func add(_ title: String, _ selector: Selector, to destination: NSMenu) {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        destination.addItem(entry)
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
        statusLine.title = enabled ? "已开启 · 长按 \(config.holdSeconds) 秒" : "已暂停"
        permissionLine.title = "输入监控：\(CGPreflightListenEventAccess() ? "已允许" : "未允许") · 发送：\(CGPreflightPostEventAccess() ? "已允许" : "未允许")"
        modeLine.title = "输出方式：\(config.mode.rawValue)"
        evidenceLine.title = "合成 Fn 回读：\(fnEchoes) 次（不代表语音启动）"
        for (seconds, entry) in holdItems { entry.state = abs(config.holdSeconds - seconds) < 0.001 ? .on : .off }
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    @objc func requestListening() { _ = CGRequestListenEventAccess(); record("输入监控已申请；授权后重新启用，必要时重开应用") }
    @objc func requestPosting() { _ = CGRequestPostEventAccess(); record("事件发送权限已申请；请检查辅助功能设置") }
    @objc func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
    }

    @objc func openConfiguration() { NSWorkspace.shared.open(configURL) }

    @objc func changeHoldTime(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double, configValid else { return }
        let wasEnabled = enabled
        var candidate = config
        candidate.holdSeconds = seconds
        do {
            try save(candidate)
            reloadConfiguration()
            if wasEnabled { toggleEnabled() }
        } catch { record("保存长按时间失败：\(error.localizedDescription)") }
    }

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
        toggleItem.title = "暂停"
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
        }
    }

    func cancelGesture(_ reason: String?) {
        deadlineTimer?.invalidate(); deadlineTimer = nil
        watchdog?.invalidate(); watchdog = nil
        _ = detector.reset()
        output.end()
        if let reason { record(reason) }
    }

    func disable() {
        enabled = false
        cancelGesture(nil)
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        runLoopSource = nil
        tap = nil
        toggleItem.title = "启用"
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
