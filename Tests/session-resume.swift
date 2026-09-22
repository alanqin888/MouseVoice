final class ResumeProbe: AppDelegate {
    var starts = 0
    override func toggleEnabled() { starts += 1; enabled = true }
}
let probe = ResumeProbe()
func expect(_ value: Bool, _ label: String) {
    if !value { fatalError(label) }
    print("PASS: \(label)")
}
probe.enabled = true
probe.sessionInterrupted(Notification(name: NSWorkspace.willSleepNotification))
probe.sessionInterrupted(Notification(name: NSNotification.Name("com.apple.screenIsLocked")))
probe.sessionInterrupted(Notification(name: NSWorkspace.sessionDidResignActiveNotification))
expect(!probe.enabled && probe.resumeAfterInterruption, "overlapping interruptions remember enabled state")
probe.sessionResumed(Notification(name: NSWorkspace.didWakeNotification))
expect(probe.starts == 0, "waking while locked does not resume")
probe.sessionResumed(Notification(name: NSNotification.Name("com.apple.screenIsUnlocked")))
expect(probe.starts == 0, "inactive session does not resume")
probe.sessionResumed(Notification(name: NSWorkspace.sessionDidBecomeActiveNotification))
expect(probe.starts == 1 && probe.enabled, "active unlocked session resumes once")
probe.sessionResumed(Notification(name: NSWorkspace.didWakeNotification))
expect(probe.starts == 1, "duplicate wake never toggles enabled off")
probe.enabled = false
probe.sessionInterrupted(Notification(name: NSWorkspace.willSleepNotification))
probe.sessionResumed(Notification(name: NSWorkspace.didWakeNotification))
expect(probe.starts == 1 && !probe.enabled, "manual pause survives sleep")
