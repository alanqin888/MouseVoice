import AppKit
import CoreGraphics

enum OutputMode: String, Codable { case fn, shortcutHold, shortcutToggle }

struct Configuration: Codable {
    var holdSeconds: Double = 0.5
    var movementTolerancePoints: Double = 6
    var maximumHoldSeconds: Double = 60
    var mode: OutputMode = .fn
    var shortcutKeyCode: UInt16 = 79 // F18, independent of keyboard layout.
    var shortcutModifiers: [String] = []

    func validate() throws {
        guard holdSeconds.isFinite, (0.3...5).contains(holdSeconds),
              movementTolerancePoints.isFinite, (1...30).contains(movementTolerancePoints),
              maximumHoldSeconds.isFinite, (5...300).contains(maximumHoldSeconds),
              shortcutKeyCode <= 126,
              ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 66, 70, 72, 74].contains(shortcutKeyCode),
              Set(shortcutModifiers).count == shortcutModifiers.count,
              shortcutModifiers.allSatisfy({ Modifier.named($0) != nil }) else {
            throw NSError(domain: "MouseVoice", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "配置无效：长按 0.3–5 秒，移动容差 1–30 点，最长保持 5–300 秒；快捷键须为普通键，修饰键仅 command/option/control/shift。"])
        }
    }
}

struct Modifier {
    let name: String
    let code: CGKeyCode
    let flag: CGEventFlags
    static let all = [Modifier(name: "control", code: 59, flag: .maskControl),
                      Modifier(name: "option", code: 58, flag: .maskAlternate),
                      Modifier(name: "shift", code: 56, flag: .maskShift),
                      Modifier(name: "command", code: 55, flag: .maskCommand)]
    static func named(_ name: String) -> Modifier? { all.first { $0.name == name } }
}

/// Builds complete pairs before posting. CGEvent.post has no delivery acknowledgement.
final class KeyOutput {
    static let marker: Int64 = 0x4D_56_4F_49_43_45
    private let source = CGEventSource(stateID: .privateState)
    private(set) var active = false
    private var releaseEvents: [CGEvent] = []
    private var toggle = false

    func event(code: CGKeyCode, down: Bool, flags: CGEventFlags, modifier: Bool = false) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return nil }
        if modifier { event.type = .flagsChanged }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        return event
    }

    func sequences(_ config: Configuration, baseline: CGEventFlags = []) -> (down: [CGEvent], up: [CGEvent])? {
        if config.mode == .fn {
            guard let down = event(code: 63, down: true, flags: baseline.union(.maskSecondaryFn), modifier: true),
                  let up = event(code: 63, down: false, flags: baseline, modifier: true) else { return nil }
            return ([down], [up])
        }
        let modifiers = Modifier.all.filter { config.shortcutModifiers.contains($0.name) }
        var flags = baseline
        var down: [CGEvent] = []
        var up: [CGEvent] = []
        for modifier in modifiers {
            flags.insert(modifier.flag)
            guard let e = event(code: modifier.code, down: true, flags: flags, modifier: true) else { return nil }
            down.append(e)
        }
        guard let keyDown = event(code: config.shortcutKeyCode, down: true, flags: flags),
              let keyUp = event(code: config.shortcutKeyCode, down: false, flags: flags) else { return nil }
        down.append(keyDown)
        up.append(keyUp)
        for modifier in modifiers.reversed() {
            flags.remove(modifier.flag)
            guard let e = event(code: modifier.code, down: false, flags: flags, modifier: true) else { return nil }
            up.append(e)
        }
        return (down, up)
    }

    func begin(_ config: Configuration) -> Bool {
        guard !active, CGPreflightPostEventAccess() else { return false }
        // Avoid merging this synthetic gesture with a physically held keyboard shortcut.
        let physical = CGEventSource.flagsState(.hidSystemState)
        let shortcutFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        guard physical.intersection(shortcutFlags).isEmpty,
              !CGEventSource.keyState(.hidSystemState, key: config.mode == .fn ? 63 : config.shortcutKeyCode),
              let pair = sequences(config, baseline: physical.intersection(.maskAlphaShift)) else { return false }
        toggle = config.mode == .shortcutToggle
        releaseEvents = toggle ? pair.down + pair.up : pair.up
        active = true
        (toggle ? pair.down + pair.up : pair.down).forEach { $0.post(tap: .cghidEventTap) }
        return true
    }

    func end() {
        guard active else { return }
        // Refresh timestamps: the release may be many seconds after event construction.
        let timestamp = DispatchTime.now().uptimeNanoseconds
        for event in releaseEvents {
            event.timestamp = timestamp
            event.post(tap: .cghidEventTap)
        }
        active = false
        releaseEvents.removeAll()
    }
}
