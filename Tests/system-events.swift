setbuf(stdout,nil)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
let window = NSWindow(contentRect: NSRect(x: 100,y: 100,width: 500,height: 260), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "MouseVoice · 鼠标事件实测"
let note = NSTextField(labelWithString: "正在自动检查短按、长按、拖动取消和松开释放。\n此窗口将在测试后关闭。")
note.frame = NSRect(x: 20,y: 120,width: 460,height: 80)
window.contentView?.addSubview(note)
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps:true)
let screenHeight = NSScreen.screens[0].frame.height
let base = CGPoint(x:window.frame.midX,y:screenHeight-window.frame.midY)
var failures = 0
func check(_ condition: Bool,_ name:String) {
    print("\(condition ? "PASS" : "FAIL"): \(name) state=\(delegate.detector.state) FnEvents=\(delegate.fnEchoes) active=\(delegate.output.active)")
    if !condition { failures += 1 }
}
func later(_ seconds:Double,_ action: @escaping ()->Void) { DispatchQueue.main.asyncAfter(deadline:.now()+seconds,execute:action) }
func mouse(_ type:CGEventType,_ offset:CGFloat=0) {
    let point=CGPoint(x:base.x+offset,y:base.y)
    let event=CGEvent(mouseEventSource:CGEventSource(stateID:.hidSystemState),mouseType:type,mouseCursorPosition:point,mouseButton:.left)!
    event.setIntegerValueField(.eventSourceUserData,value:0x4D5654455354)
    print("MOUSE t=\(ProcessInfo.processInfo.systemUptime) type=\(type.rawValue)"); event.post(tap:.cghidEventTap)
}

func finish(_ code: Int32) {
    mouse(.leftMouseUp)
    delegate.disable()
    print("RESULT \(code == 0 ? "PASS" : "FAIL"): sequential global-event integration test")
    window.orderOut(nil)
    exit(code)
}
func after(_ interval: Double, _ action: @escaping () -> Void) {
    let timer=Timer(timeInterval:interval,repeats:false) { _ in action() }
    RunLoop.main.add(timer,forMode:.common)
}
func waitFor(_ name:String, timeout:Double=2.5, _ condition:@escaping ()->Bool, then next:@escaping ()->Void) {
    let start=ProcessInfo.processInfo.systemUptime
    let timer=Timer(timeInterval:0.02,repeats:true) { timer in
        if condition() {
            timer.invalidate()
            print("PASS: \(name) FnEvents=\(delegate.fnEchoes) elapsed=\(ProcessInfo.processInfo.systemUptime-start)")
            next()
        } else if ProcessInfo.processInfo.systemUptime-start > timeout {
            timer.invalidate()
            print("FAIL: \(name) state=\(delegate.detector.state) FnEvents=\(delegate.fnEchoes)")
            finish(1)
        }
    }
    RunLoop.main.add(timer,forMode:.common)
}
func activeDragTest() {
    mouse(.leftMouseDown)
    waitFor("second hold emits Fn down", { delegate.output.active && delegate.fnEchoes == 3 }) {
        mouse(.leftMouseDragged,20)
        waitFor("active drag is swallowed without releasing Fn",timeout:1,{ delegate.output.active && delegate.fnEchoes == 3 }) {
            mouse(.leftMouseUp,20)
            waitFor("mouse up releases swallowed drag",{ !delegate.output.active && delegate.fnEchoes == 4 && delegate.detector.state == .idle }) { finish(0) }
        }
    }
}
func longHoldTest() {
    mouse(.leftMouseDown)
    waitFor("stationary 1.2-second hold emits Fn down",{delegate.output.active && delegate.fnEchoes == 1}) {
        mouse(.leftMouseUp)
        waitFor("mouse up emits Fn up",timeout:1,{!delegate.output.active && delegate.fnEchoes == 2}) {
            after(0.3) { activeDragTest() }
        }
    }
}
func dragTest() {
    mouse(.leftMouseDown)
    waitFor("drag gesture armed",{delegate.detector.state == .pending}) {
        mouse(.leftMouseDragged,20)
        waitFor("drag cancelled",{delegate.detector.state == .cancelled}) {
            mouse(.leftMouseDragged)
            after(1.4) {
                if delegate.fnEchoes != 0 { print("FAIL: drag rearmed"); finish(1) }
                print("PASS: drag out and back never emits Fn")
                mouse(.leftMouseUp)
                waitFor("drag released",{delegate.detector.state == .idle}) { after(0.2) { longHoldTest() } }
            }
        }
    }
}
after(0.5) {
    delegate.config=Configuration()
    delegate.detector=HoldDetector(delay:1.2,tolerance:6)
    delegate.toggleEnabled()
    print("TEST started listener=\(delegate.enabled) post=\(CGPreflightPostEventAccess())")
    if !delegate.enabled { finish(2) }
    mouse(.leftMouseDown)
    waitFor("short click armed",{delegate.detector.state == .pending}) {
        after(0.2) {
            mouse(.leftMouseUp)
            waitFor("short click released",{delegate.detector.state == .idle}) {
                after(1.3) {
                    if delegate.fnEchoes != 0 { print("FAIL: short click triggered"); finish(1) }
                    print("PASS: short click never emits Fn")
                    dragTest()
                }
            }
        }
    }
}
after(25) { print("FAIL: overall timeout"); finish(3) }
app.run()
