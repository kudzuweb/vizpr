#if DICT_DEV_LOG
import Foundation

/// Dev-only probe for main-thread stalls: a repeating timer on the main run
/// loop notices when it fires far later than scheduled and logs the duration.
/// Durations only, never any text. Compiled out of Release with the rest of
/// the dev logger.
@MainActor
enum MainStallProbe {
    private static let interval: TimeInterval = 0.05
    private static let reportThreshold: TimeInterval = 0.1
    private static var timer: Timer?

    static func start() {
        guard timer == nil else { return }
        var lastFire = ContinuousClock.now
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            let now = ContinuousClock.now
            let late = (now - lastFire) / .seconds(1) - interval
            lastFire = now
            if late > reportThreshold {
                VizprTranscriptLogger.note("main stall \(Int(late * 1000))ms")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
#endif
