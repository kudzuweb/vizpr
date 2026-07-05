import CoreGraphics
import Testing
@testable import Vizpr

@Suite("CodeDetector")
struct CodeDetectorTests {
    @Test("Bundle-id table: code surfaces flip code mode")
    func table() {
        for id in ["com.microsoft.VSCode", "com.apple.Terminal", "com.apple.dt.Xcode",
                   "com.googlecode.iterm2", "com.jetbrains.intellij", "dev.zed.Zed"] {
            #expect(CodeDetector.isCodeSurface(bundleID: id), "\(id) should be code")
        }
        for id in ["com.apple.TextEdit", "com.apple.Safari", "com.apple.mail", "com.tinyspeck.slackmacgap"] {
            #expect(!CodeDetector.isCodeSurface(bundleID: id), "\(id) should be prose")
        }
        #expect(!CodeDetector.isCodeSurface(bundleID: nil))
    }
}

@Suite("FieldContextReader bounds")
struct FieldContextBoundsTests {
    @Test("Bounded read: property over random lengths")
    func boundedProperty() {
        var seed: UInt64 = 0x5eed
        func rand(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33) % bound
        }
        for _ in 0..<200 {
            let length = rand(2_000)
            let text = String(repeating: "ab, ", count: (length / 4) + 1).prefix(length)
            let bounded = FieldContextReader.bounded(String(text), limit: 500)
            #expect(bounded.count <= 500)
            #expect(text.hasSuffix(bounded), "bound must keep the TAIL (caret vicinity)")
            if length <= 500 { #expect(bounded == String(text)) }
        }
    }

    @Test("Bounded read never splits a grapheme")
    func graphemeSafe() {
        let text = String(repeating: "👍🏽é\u{301}", count: 300)
        let bounded = FieldContextReader.bounded(text, limit: 500)
        #expect(bounded.count <= 500)
        #expect(text.hasSuffix(bounded))
    }
}

@Suite("Overlay multi-display placement")
struct TargetScreenTests {
    // Primary 1920x1080 at origin; secondary to the right.
    private let screens = [
        CGRect(x: 0, y: 0, width: 1920, height: 1080),
        CGRect(x: 1920, y: 0, width: 1440, height: 900),
    ]

    @Test("AX frame on the secondary display picks the secondary screen")
    func secondary() {
        // AX coords: top-left origin of primary. A window at x=2200.
        let ax = CGRect(x: 2200, y: 200, width: 800, height: 600)
        let picked = OverlayLayout.targetScreenFrame(
            axFrame: ax, screenFrames: screens, primaryHeight: 1080
        )
        #expect(picked == screens[1])
    }

    @Test("AX frame on the primary picks the primary; nil falls through")
    func primaryAndNil() {
        let ax = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(OverlayLayout.targetScreenFrame(
            axFrame: ax, screenFrames: screens, primaryHeight: 1080
        ) == screens[0])
        #expect(OverlayLayout.targetScreenFrame(
            axFrame: nil, screenFrames: screens, primaryHeight: 1080
        ) == nil)
    }
}
