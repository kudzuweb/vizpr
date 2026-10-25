import AppKit
import Testing
@testable import Vizpr

@MainActor
@Suite("Target app tracking")
struct TargetAppTests {
    private let ownPID: pid_t = 100

    private func info(_ name: String, pid: pid_t) -> TargetApp.Info {
        TargetApp.Info(processID: pid, name: name, icon: nil)
    }

    @Test("Activating another app replaces the target")
    func followsFocus() {
        let target = TargetApp(ownProcessID: ownPID)
        target.adopt(info("Notes", pid: 1))
        target.adopt(info("Mail", pid: 2))
        #expect(target.current?.name == "Mail")
    }

    @Test("Vizpr coming to the front keeps the last other app")
    func ignoresItself() {
        let target = TargetApp(ownProcessID: ownPID)
        target.adopt(info("Notes", pid: 1))
        target.adopt(info("Vizpr", pid: ownPID))
        #expect(target.current?.name == "Notes")
    }

    @Test("An unknown app keeps the last one")
    func ignoresUnknown() {
        let target = TargetApp(ownProcessID: ownPID)
        target.adopt(info("Notes", pid: 1))
        target.adopt(nil)
        #expect(target.current?.name == "Notes")
    }
}
