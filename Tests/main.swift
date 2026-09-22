import Foundation
import CoreGraphics

var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    assertions += 1
    guard condition() else { fatalError("FAIL: \(name)") }
}
let origin = CGPoint(x: 100, y: 100)
func fresh() -> HoldDetector {
    var d = HoldDetector(delay: 1.2, tolerance: 6)
    d.down(at: origin, now: 0)
    return d
}
var d = fresh()
check(d.deadline(now: 1.19, buttonDown: true, point: origin) == .none, "No premature trigger")
check(d.reset() == .none, "Short click never emits release")
check(d.deadline(now: 2, buttonDown: false, point: origin) == .none, "Cancelled timer cannot fire")
d = fresh()
check(d.move(to: CGPoint(x: 106, y: 100)) == .none, "Tolerance boundary allowed")
check(d.deadline(now: 1.2, buttonDown: true, point: origin) == .begin, "Threshold emits down")
check(d.deadline(now: 2, buttonDown: true, point: origin) == .none, "No repeated down")
check(d.reset() == .end, "Mouse up releases once")
check(d.reset() == .none, "No duplicate release")
d = fresh()
_ = d.move(to: CGPoint(x: 107, y: 100))
_ = d.move(to: origin)
check(d.deadline(now: 2, buttonDown: true, point: origin) == .none, "Drag out and back stays cancelled")
check(d.state == .cancelled, "Drag cancellation is sticky")
d = fresh()
check(d.deadline(now: 2, buttonDown: false, point: origin) == .none, "Missed mouse-up cannot activate")
d = fresh()
check(d.deadline(now: 2, buttonDown: true, point: CGPoint(x: 120, y: 100)) == .none, "Pointer rechecked at deadline")
d = fresh()
_ = d.deadline(now: 1.2, buttonDown: true, point: origin)
check(d.move(to: CGPoint(x: 107, y: 100)) == .end, "Dragging after trigger releases")
check(d.reset() == .none, "No extra release after active drag")
d = fresh()
_ = d.deadline(now: 1.2, buttonDown: true, point: origin)
check(d.reset() == .end, "Interruption releases active gesture")
d.down(at: origin, now: 5)
check(d.deadline(now: 6.3, buttonDown: true, point: origin) == .begin, "Fresh click re-arms")

let output = KeyOutput()
var config = Configuration()
try config.validate()
let fn = output.sequences(config)!
check(fn.down.count == 1 && fn.up.count == 1, "Fn pair")
check(fn.down[0].type == .flagsChanged && fn.up[0].type == .flagsChanged, "Fn modifier events")
check(fn.down[0].getIntegerValueField(.keyboardEventKeycode) == 63, "Fn virtual key")
check(fn.down[0].flags.contains(.maskSecondaryFn), "Fn down flag set")
check(!fn.up[0].flags.contains(.maskSecondaryFn), "Fn up flag cleared")
check(fn.up[0].getIntegerValueField(.eventSourceUserData) == KeyOutput.marker, "Tagged event")
config.mode = .shortcutHold
config.shortcutModifiers = ["control", "option"]
let chord = output.sequences(config, baseline: .maskAlphaShift)!
check(chord.down.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [59, 58, 79], "Modifiers precede F18")
check(chord.up.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [79, 58, 59], "Reverse release order")
check(chord.down.last!.type == .keyDown && chord.up.first!.type == .keyUp, "Shortcut key pair")
check(chord.up.last!.flags == .maskAlphaShift, "Restore initial caps lock")
config.shortcutModifiers = ["typo"]
check((try? config.validate()) == nil, "Invalid modifier rejected")
config = Configuration(); config.holdSeconds = 0
check((try? config.validate()) == nil, "Invalid duration rejected")
config = Configuration(); config.shortcutKeyCode = 63
check((try? config.validate()) == nil, "Fn must use dedicated mode")
let roundtrip = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(Configuration()))
check(roundtrip.mode == .fn && roundtrip.holdSeconds == 0.5, "Configuration round trip")
print("PASS: \(assertions) assertions; no synthetic input posted and no permissions requested.")
