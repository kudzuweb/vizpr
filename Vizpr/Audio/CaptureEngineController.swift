import Foundation
import Synchronization

/// Which kind of input device an engine is bound to.
enum InputRoute: Sendable {
    case builtIn
    case external
    /// The device could not be read back from the engine.
    case unidentified
}

/// What a mid-session failover left behind.
enum FailoverResult: Sendable {
    /// Capture now runs on the replacement engine.
    case switched
    /// No failover happened; the original engine, if any, still captures.
    case unchanged
    /// The original engine was stopped and the replacement would not start, so
    /// the stream has ended.
    case lost
}

/// The route and sample rate of the engine that is capturing.
struct RunningInput: Sendable {
    let route: InputRoute
    let hardwareSampleRate: Double

    static let none = RunningInput(route: .unidentified, hardwareSampleRate: 0)

    fileprivate init(route: InputRoute, hardwareSampleRate: Double) {
        self.route = route
        self.hardwareSampleRate = hardwareSampleRate
    }

    fileprivate init(_ engine: CaptureEngine) {
        self.init(route: engine.route, hardwareSampleRate: engine.hardwareSampleRate)
    }
}

/// One capture engine as the controller sees it. Only ever touched on the
/// controller's queue.
protocol CaptureEngine: AnyObject {
    var route: InputRoute { get }
    /// Sample rate of the frames the tap delivers.
    var hardwareSampleRate: Double { get }
    func start() throws
    /// Removes the tap and stops. Safe on an engine that never started.
    func stop()
}

/// Builds engines that are configured and prepared but not started, feeding
/// the given continuation. Nil when the input cannot be configured.
protocol CaptureEngineFactory: Sendable {
    func makeEngine(feeding continuation: AsyncStream<[Float]>.Continuation) -> CaptureEngine?
    /// An engine pinned to the built-in microphone; nil when there is none.
    func makeBuiltInEngine(feeding continuation: AsyncStream<[Float]>.Continuation) -> CaptureEngine?
}

/// Owns the capture engine's lifecycle on one private serial queue, never the
/// main thread: a cold `engine.start()` blocks for ~2 s, which would stall the
/// UI and the hotkey tap.
///
/// A generation number, bumped synchronously by `stop()`, orders sessions that
/// the queue alone cannot: a start or failover that was requested before a
/// stop but reaches the queue after it finds the generation moved and does
/// nothing. A stop that reaches the queue after a start has begun tears that
/// start's engine down, because the queue is serial.
final class CaptureEngineController: @unchecked Sendable {
    /// Taken when a session begins asking for capture, before any await.
    struct StartTicket: Sendable {
        fileprivate let generation: Int
    }

    private let queue = DispatchQueue(label: "com.kudzuweb.vizpr.audio-capture", qos: .userInitiated)
    private let factory: any CaptureEngineFactory
    private let generation = Mutex(0)
    private let runningInput = Mutex(RunningInput.none)

    // Touched only on `queue`.
    private var engine: CaptureEngine?
    private var continuation: AsyncStream<[Float]>.Continuation?

    init(factory: any CaptureEngineFactory) {
        self.factory = factory
    }

    /// What the running engine is bound to; `RunningInput.none` when none runs.
    var input: RunningInput { runningInput.withLock { $0 } }
    var route: InputRoute { input.route }

    func makeStartTicket() -> StartTicket {
        StartTicket(generation: generation.withLock { $0 })
    }

    /// Starts capture and returns the sample stream. Throws `CancellationError`,
    /// leaving nothing running, when a `stop()` happened after the ticket was
    /// taken.
    func start(_ ticket: StartTicket) async throws -> AsyncStream<[Float]> {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.startEngine(ticket) })
            }
        }
    }

    /// Returns immediately. Teardown is queued behind any start already queued.
    func stop() {
        generation.withLock { $0 += 1 }
        queue.async { self.stopEngine() }
    }

    /// Mid-session failover to the built-in microphone (field case,
    /// 2026-07-06: a phone call owned the AirPods; macOS kept handing us the
    /// AirPods input route, which delivered pure zeros). Feeds the SAME stream
    /// continuation, so the consumer never notices; only the dead air is lost.
    /// The replacement is fully built before the running engine is touched, so
    /// an unusable built-in device leaves capture exactly as it was. A failover
    /// requested before a `stop()` does nothing once that stop has landed.
    func fallBackToBuiltInMic() async -> FailoverResult {
        let requested = generation.withLock { $0 }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.swapToBuiltInEngine(requestedIn: requested))
            }
        }
    }

    /// Resolves once everything queued so far has run.
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private func startEngine(_ ticket: StartTicket) throws -> AsyncStream<[Float]> {
        guard generation.withLock({ $0 }) == ticket.generation else { throw CancellationError() }
        stopEngine()   // tolerate re-start without leaking a tap

        // The continuation is stored only once the engine runs, so a failed
        // start leaves no half-built state behind.
        let (stream, continuation) = AsyncStream.makeStream(
            of: [Float].self, bufferingPolicy: .bufferingNewest(64)
        )
        guard let engine = factory.makeEngine(feeding: continuation) else {
            continuation.finish()
            throw AudioCaptureError.cannotConfigureInput
        }
        do {
            try engine.start()
        } catch {
            engine.stop()
            continuation.finish()
            throw error
        }
        self.engine = engine
        self.continuation = continuation
        runningInput.withLock { $0 = RunningInput(engine) }
        return stream
    }

    private func swapToBuiltInEngine(requestedIn requested: Int) -> FailoverResult {
        guard generation.withLock({ $0 }) == requested,
              let oldEngine = engine, let continuation,
              let replacement = factory.makeBuiltInEngine(feeding: continuation)
        else { return .unchanged }

        oldEngine.stop()
        do {
            try replacement.start()
        } catch {
            // The old engine is already down, so nothing is left to capture.
            replacement.stop()
            stopEngine()
            return .lost
        }
        engine = replacement
        runningInput.withLock { $0 = RunningInput(replacement) }
        #if DICT_DEV_LOG
        VizprTranscriptLogger.note(
            "capture: FELL BACK to built-in mic (previous route was silent)")
        #endif
        return .switched
    }

    private func stopEngine() {
        engine?.stop()
        engine = nil
        continuation?.finish()
        continuation = nil
        runningInput.withLock { $0 = .none }
    }
}
