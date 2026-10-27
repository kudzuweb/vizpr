import Testing
@testable import Vizpr

@Suite("BundleIdentity")
struct BundleIdentityTests {

    private let file = BundleIdentity.FileID(device: 1, inode: 100)

    private func probe(
        executable: BundleIdentity.FileID?? = nil,
        process: BundleIdentity.FileID?? = nil,
        missingResource: String? = nil
    ) -> BundleIdentity.Probe {
        let intact = file
        return BundleIdentity.Probe(
            executableFileID: { executable ?? intact },
            processFileID: { process ?? intact },
            resourceExists: { $0 != missingResource }
        )
    }

    @Test("An intact bundle has no failure")
    func intact() {
        #expect(BundleIdentity.firstFailure(probe()) == nil)
    }

    @Test("A missing executable is reported first")
    func executableMissing() {
        #expect(BundleIdentity.firstFailure(probe(executable: .some(nil), process: .some(nil))) == .executableMissing)
    }

    @Test("A process whose path does not resolve is reported")
    func processPathUnresolved() {
        #expect(BundleIdentity.firstFailure(probe(process: .some(nil))) == .processPathUnresolved)
    }

    @Test("A process running from a different file than the bundle's executable is reported")
    func processPathDiffers() {
        let other = BundleIdentity.FileID(device: 1, inode: 200)
        #expect(BundleIdentity.firstFailure(probe(process: .some(other))) == .processPathDiffers)
    }

    @Test("The same file on a different device is a different file")
    func sameInodeOtherDevice() {
        let other = BundleIdentity.FileID(device: 2, inode: 100)
        #expect(BundleIdentity.firstFailure(probe(process: .some(other))) == .processPathDiffers)
    }

    @Test("Each required resource is checked and named when missing")
    func resourceMissing() {
        for name in BundleIdentity.requiredResources {
            #expect(BundleIdentity.firstFailure(probe(missingResource: name)) == .resourceMissing(name))
        }
    }

    @Test("Identity is checked before resources")
    func identityBeforeResources() {
        #expect(
            BundleIdentity.firstFailure(probe(process: .some(nil), missingResource: "Models"))
                == .processPathUnresolved
        )
    }

    @Test("The real process and bundle pass the system probe's identity checks")
    func systemProbeResolvesThisProcess() {
        #expect(BundleIdentity.firstFailure(.system, resources: []) == nil)
    }
}
