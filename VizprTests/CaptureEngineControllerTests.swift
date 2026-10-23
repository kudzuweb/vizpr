import Foundation
import Synchronization
import Testing
@testable import Vizpr

private struct StartFailure: Error {}

/// A capture engine that records what the controller did to it.
private final class FakeEngine: CaptureEngine, Sendable {
    enum StartBehavior: Sendable {
        case succeed
        case fail
        /// Signals `entered`, then waits for `release` before succeeding.
        case blockUntilReleased
    }

    let route: InputRoute
    private let behavior: StartBehavior
    private let entered = Mutex(false)
    private let release = DispatchSemaphore(value: 0)
    private let started = Mutex(false)
    private let stopCalls = Mutex(0)

    init(route: InputRoute, behavior: StartBehavior) {
        self.route = route
        self.behavior = behavior
    }

    var didEnterStart: Bool { entered.withLock { $0 } }
    var isRunning: Bool { started.withLock { $0 } }
    var stopCount: Int { stopCalls.withLock { $0 } }
    func releaseStart() { release.signal() }

    func start() throws {
        switch behavior {
        case .succeed:
            break
        case .fail:
            throw StartFailure()
        case .blockUntilReleased:
            entered.withLock { $0 = true }
            release.wait()
        }
        started.withLock { $0 = true }
    }

    func stop() {
        stopCalls.withLock { $0 += 1 }
        started.withLock { $0 = false }
    }
}

private final class FakeFactory: CaptureEngineFactory, Sendable {
    enum BuiltIn: Sendable {
        case unavailable
        case works
        case failsToStart
    }

    private let regular: FakeEngine.StartBehavior
    private let builtIn: BuiltIn
    private let engines = Mutex<[FakeEngine]>([])
    private let builtInEngines = Mutex<[FakeEngine]>([])

    init(regular: FakeEngine.StartBehavior = .succeed, builtIn: BuiltIn = .works) {
        self.regular = regular
        self.builtIn = builtIn
    }

    var made: [FakeEngine] { engines.withLock { $0 } }
    var madeBuiltIn: [FakeEngine] { builtInEngines.withLock { $0 } }

    func makeEngine(feeding continuation: AsyncStream<[Float]>.Continuation) -> CaptureEngine? {
        let engine = FakeEngine(route: .external, behavior: regular)
        engines.withLock { $0.append(engine) }
        return engine
    }

    func makeBuiltInEngine(feeding continuation: AsyncStream<[Float]>.Continuation) -> CaptureEngine? {
        let behavior: FakeEngine.StartBehavior
        switch builtIn {
        case .unavailable: return nil
        case .works: behavior = .succeed
        case .failsToStart: behavior = .fail
        }
        let engine = FakeEngine(route: .builtIn, behavior: behavior)
        builtInEngines.withLock { $0.append(engine) }
        return engine
    }
}

private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try #require(condition(), "condition never became true")
}

/// True when the stream has ended (no element arrives before it finishes).
private func isFinished(_ stream: AsyncStream<[Float]>) async -> Bool {
    await stream.first { _ in true } == nil
}

@Suite("CaptureEngineController")
struct CaptureEngineControllerTests {

    @Test("a stop that lands before the start reaches the queue leaves no engine")
    func stopBeforeStartIsEnqueued() async throws {
        let factory = FakeFactory()
        let controller = CaptureEngineController(factory: factory)

        let ticket = controller.makeStartTicket()
        controller.stop()

        await #expect(throws: CancellationError.self) { try await controller.start(ticket) }
        await controller.waitUntilIdle()
        #expect(factory.made.isEmpty)
        #expect(controller.route == .unidentified)
    }

    @Test("a stop requested while the engine is starting tears that engine down")
    func stopDuringStart() async throws {
        let factory = FakeFactory(regular: .blockUntilReleased)
        let controller = CaptureEngineController(factory: factory)
        let ticket = controller.makeStartTicket()

        let starting = Task { try await controller.start(ticket) }
        try await waitUntil { factory.made.first?.didEnterStart == true }
        controller.stop()
        factory.made[0].releaseStart()

        let stream = try await starting.value
        await controller.waitUntilIdle()
        #expect(!factory.made[0].isRunning)
        #expect(factory.made[0].stopCount >= 1)
        #expect(await isFinished(stream))
        #expect(controller.route == .unidentified)
    }

    @Test("an older start reaching the queue after a newer one does not end the newer session")
    func backToBackStarts() async throws {
        let factory = FakeFactory()
        let controller = CaptureEngineController(factory: factory)

        let olderTicket = controller.makeStartTicket()
        controller.stop()                               // first session ends
        let newerTicket = controller.makeStartTicket()  // second session begins

        _ = try await controller.start(newerTicket)
        await #expect(throws: CancellationError.self) { try await controller.start(olderTicket) }
        await controller.waitUntilIdle()

        #expect(factory.made.count == 1)
        #expect(factory.made[0].isRunning)
        #expect(factory.made[0].stopCount == 0)
        #expect(controller.route == .external)
    }

    @Test("a second start without a stop replaces the first engine")
    func restartReplacesEngine() async throws {
        let factory = FakeFactory()
        let controller = CaptureEngineController(factory: factory)

        let first = try await controller.start(controller.makeStartTicket())
        _ = try await controller.start(controller.makeStartTicket())

        #expect(await isFinished(first))
        #expect(!factory.made[0].isRunning)
        #expect(factory.made[1].isRunning)
    }

    @Test("a start that throws leaves nothing running")
    func startFailureCleansUp() async throws {
        let factory = FakeFactory(regular: .fail)
        let controller = CaptureEngineController(factory: factory)

        await #expect(throws: StartFailure.self) {
            try await controller.start(controller.makeStartTicket())
        }
        #expect(!factory.made[0].isRunning)
        #expect(factory.made[0].stopCount == 1)
        #expect(controller.route == .unidentified)
    }

    @Test("failover switches to the built-in engine and keeps the stream open")
    func failoverSwitched() async throws {
        let factory = FakeFactory(builtIn: .works)
        let controller = CaptureEngineController(factory: factory)
        let stream = try await controller.start(controller.makeStartTicket())

        let result = await controller.fallBackToBuiltInMic()

        #expect(result == .switched)
        #expect(!factory.made[0].isRunning)
        #expect(factory.madeBuiltIn[0].isRunning)
        #expect(controller.route == .builtIn)
        controller.stop()
        #expect(await isFinished(stream))
    }

    @Test("failover with no usable built-in device leaves the original engine capturing")
    func failoverUnchanged() async throws {
        let factory = FakeFactory(builtIn: .unavailable)
        let controller = CaptureEngineController(factory: factory)
        _ = try await controller.start(controller.makeStartTicket())

        let result = await controller.fallBackToBuiltInMic()

        #expect(result == .unchanged)
        #expect(factory.made[0].isRunning)
        #expect(factory.made[0].stopCount == 0)
        #expect(controller.route == .external)
    }

    @Test("failover whose replacement will not start ends the stream and reports the loss")
    func failoverLost() async throws {
        let factory = FakeFactory(builtIn: .failsToStart)
        let controller = CaptureEngineController(factory: factory)
        let stream = try await controller.start(controller.makeStartTicket())

        let result = await controller.fallBackToBuiltInMic()

        #expect(result == .lost)
        #expect(!factory.made[0].isRunning)
        #expect(!factory.madeBuiltIn[0].isRunning)
        #expect(await isFinished(stream))
        #expect(controller.route == .unidentified)
    }

    @Test("a failover requested after a stop does nothing")
    func failoverAfterStop() async throws {
        let factory = FakeFactory()
        let controller = CaptureEngineController(factory: factory)
        _ = try await controller.start(controller.makeStartTicket())
        controller.stop()

        let result = await controller.fallBackToBuiltInMic()

        #expect(result == .unchanged)
        #expect(factory.madeBuiltIn.isEmpty)
    }

    @Test("a failover queued behind a start does nothing once a stop lands in between")
    func failoverQueuedBeforeStop() async throws {
        let factory = FakeFactory(regular: .blockUntilReleased)
        let controller = CaptureEngineController(factory: factory)
        let ticket = controller.makeStartTicket()

        let starting = Task { try await controller.start(ticket) }
        try await waitUntil { factory.made.first?.didEnterStart == true }
        let failingOver = Task { await controller.fallBackToBuiltInMic() }
        try await Task.sleep(nanoseconds: 50_000_000)
        controller.stop()
        factory.made[0].releaseStart()

        _ = try await starting.value
        #expect(await failingOver.value == .unchanged)
        await controller.waitUntilIdle()
        #expect(factory.madeBuiltIn.isEmpty)
        #expect(!factory.made[0].isRunning)
    }
}
