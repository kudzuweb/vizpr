import Foundation
import Testing
@testable import Vizpr

/// Model-independent behavior of the cleanup engine's load path. (End-to-end
/// generation is exercised live — loading the 2.1 GB weights in unit tests is
/// not worth the wall clock; SmartCleanup's logic is covered with a fake.)
@Suite("MLXCleanup")
struct MLXCleanupTests {

    @Test("clean() attempts the model load itself instead of failing not-prepared")
    func cleanTriggersPrepare() async {
        // Cleanup is not gated on the launch warm: clean() awaits the
        // single-flight prepare internally. With a missing model directory
        // that surfaces as the load error (bundledModelMissing) — before this
        // change, an un-warmed engine reported not-prepared and SmartCleanup's
        // try? silently skipped the span.
        let engine = MLXCleanup(
            modelDirectory: URL(fileURLWithPath: "/nonexistent/cleanup-llm")
        )
        let request = CleanupRequest(text: "helo wrld", context: .empty)
        await #expect(throws: MLXCleanupError.self) {
            _ = try await engine.clean(request)
        }
    }
}
