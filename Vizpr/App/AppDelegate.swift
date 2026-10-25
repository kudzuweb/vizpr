import AppKit
import FluidAudio

/// Application entry point and menu-bar lifecycle owner.
///
/// Vizpr is an `LSUIElement` agent: no Dock icon, no main window, a single
/// `NSStatusItem` in the menu bar. This PR establishes only the skeleton; the
/// hotkey monitor, pipeline, and real menu land in later PRs.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let hotkeyMonitor: HotkeyMonitor
    private let permissionProbe = PermissionProbe()
    private var actionsTask: Task<Void, Never>?
    private var audioPipeline: AudioPipeline?
    private var asrEngine: FluidAudioASR?
    private let tokenStream = TokenStream()
    private let textInjector = TextInjector(
        pasteboard: SystemPasteboard(),
        poster: CGEventPoster(),
        secureInput: SecureInputProbe(),
        focusProbe: FocusedFieldProbe()
    )
    private var smartCleanup: SmartCleanup?
    private var snapshotTask: Task<Void, Never>?
    private let overlay = OverlayController()
    private let settleGate = SettleGate()
    private let fieldReader = FieldContextReader()
    private let settingsStore: SettingsStore
    /// Hierarchical vocabulary (PR 11): global + named buckets + app
    /// assignments; resolved per session against the focused bundle id.
    private let vocabularyModel = VocabularyModel()
    /// Model discovery for the Models pane; also resolves the selected model
    /// ids into directories at pipeline build (PR 11).
    private let modelsModel = ModelsModel()
    /// The model ids the running pipeline was built with — a settings change
    /// away from these triggers a live pipeline rebuild (engine swap).
    private var appliedASRModelID: String?
    private var appliedCleanupModelID: String?
    private let settingsWindow = SettingsWindowController()
    /// The focused field's context, captured at session start (PR 10).
    private var currentField: FieldContext = .empty
    /// Set when the last session's mic delivered pure silence (AirPods
    /// held-route trap); shown in the menu until a session gets real audio.
    private var lastSessionWasSilent = false
    #if DICT_DEV_LOG
    private let dictationTracker = DevDictationTracker()
    /// Dictation-record handshake: the record needs the committed text (known
    /// at the commit action) AND the full raw ASR text (complete only when the
    /// session drains — flush finals arrive after commit). Commit and drain
    /// race in either order; whichever lands second writes. Main-actor state.
    private var pendingInjection: String?
    private var sessionDrained = false
    #endif

    /// NSApplication holds its delegate weakly, and a local would be releasable
    /// by the optimizer after its last use even though app.run() never returns —
    /// deallocating the delegate (and the hotkey tap with it) mid-flight in
    /// Release builds. A static keeps ownership unambiguous.
    private static var retainedDelegate: AppDelegate?

    /// The store loads first so the hotkey monitor starts with the saved hold
    /// threshold and chord, not a second copy of their defaults.
    override init() {
        let store = SettingsStore()
        settingsStore = store
        hotkeyMonitor = HotkeyMonitor(
            holdThreshold: .milliseconds(store.settings.holdThresholdMs),
            secondaryMask: Self.modifierMask(store.settings.secondaryModifiers)
        )
        super.init()
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // FIRST, before any FluidAudio API is touched: hard-disable its download
        // paths. Every fetch/download entry point throws from here on — the
        // app can only load models that shipped in its bundle (invariant 1).
        DownloadUtils.enforceOffline = true

        // Before the overlay can render: a look may name a font from the Fonts folder.
        FontLibrary.registerAll()

        // LSUIElement already implies accessory; set it explicitly so the policy
        // is unambiguous regardless of how the process was launched.
        NSApp.setActivationPolicy(.accessory)
        setUpStatusItem()
        modelsModel.startWatching()
        setUpAudioPipeline()
        overlay.onAnchorChange = { [weak self] displayID, anchor in
            self?.settingsStore.update { $0.overlayAnchors[displayID] = anchor }
        }
        applySettings(settingsStore.settings)
        settingsStore.onChange { [weak self] settings in
            self?.applySettings(settings)
        }
        consumeHotkeyActions()
        startHotkeyIfPermitted()

        #if DICT_DEV_LOG
        // Present only in Debug; proves the compile gate (verified absent from
        // Release by scripts/check-devlog-absent.sh).
        VizprTranscriptLogger.announce()
        MainStallProbe.start()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Unpark any commit waiting in the settle window (the continuation is
        // cancellation-blind) and drop the overlay before tasks die.
        settleGate.releaseAll()
        overlay.dismiss()
        snapshotTask?.cancel()
        actionsTask?.cancel()
        audioPipeline?.stop()
        hotkeyMonitor.stop()
    }

    /// Build the capture→VAD→ASR→auto-stop pipeline against the selected
    /// models (bundled by default). Bundled load failures mean a broken
    /// bundle: fail loudly (invariant — never limp along without a model).
    /// A failed USER model instead reverts the selection to bundled.
    private func setUpAudioPipeline() {
        let settings = settingsStore.settings
        appliedASRModelID = settings.asrModelID
        appliedCleanupModelID = settings.cleanupModelID
        let asrDirectory = modelsModel.directory(forID: settings.asrModelID, kind: .asr)
        let cleanupDirectory = modelsModel.directory(
            forID: settings.cleanupModelID, kind: .cleanup
        )

        let engine = FluidAudioASR(modelsDirectory: asrDirectory)
        asrEngine = engine

        // The cleanup leg (PR 6): events flow ASR -> SmartCleanup (vocab
        // pre-pass + confidence gate) -> TokenStream (regions + generation
        // gate); commit/cancel drive the stream's atomic gate below. In dev
        // builds the same event stream and outcome seam feed the §14 JSONL
        // records; Release leaves both hooks unset.
        let vocabulary = vocabularyModel.library.resolved(bundleID: nil)
        #if DICT_DEV_LOG
        let tracker = dictationTracker
        let onOutcome: (@Sendable (CleanupOutcome) async -> Void)? = { outcome in
            await VizprDevLogWriter.shared.append(DevCleanupRecord(outcome))
        }
        #else
        let onOutcome: (@Sendable (CleanupOutcome) async -> Void)? = nil
        #endif
        // Ungated: the drain signal now also drives the flush-settle window
        // (SettleGate), not just the dev logger.
        let onSessionDrained: (@Sendable (Int) async -> Void)? = { [weak self] epoch in
            await self?.sessionDrained(epoch: epoch)
        }
        let cleanup = SmartCleanup(
            tokenStream: tokenStream,
            engine: MLXCleanup(modelDirectory: cleanupDirectory),
            vocabulary: vocabulary,
            onOutcome: onOutcome
        )
        smartCleanup = cleanup

        #if DICT_DEV_LOG
        let onTokenEvent: @Sendable (TokenEvent) async -> Void = { [cleanup] event in
            await tracker.observe(event)
            await cleanup.ingest(event)
        }
        #else
        let onTokenEvent: @Sendable (TokenEvent) async -> Void = { [cleanup] event in
            await cleanup.ingest(event)
        }
        #endif

        defer {
            // The pipeline reports only for its live session (a stopped
            // session's task is cancelled first), so a late failure cannot
            // cancel the next session.
            audioPipeline?.onCaptureFailure = { [weak self] in
                NSSound.beep()
                self?.hotkeyMonitor.injectCaptureFailure()
                #if DICT_DEV_LOG
                VizprTranscriptLogger.note("CAPTURE FAILED: microphone could not start or was lost")
                #endif
            }
            audioPipeline?.onSilentSession = { [weak self] in
                self?.lastSessionWasSilent = true
                NSSound.beep()
                #if DICT_DEV_LOG
                VizprTranscriptLogger.note(
                    "SILENT SESSION: mic delivered zero audio — check input device")
                #endif
            }
        }
        audioPipeline = AudioPipeline.makeDefault(
            engine: engine,
            autoStopTimeout: .seconds(settings.autoStopSeconds),
            onTokenEvent: onTokenEvent,
            onSessionDrained: onSessionDrained,
            onAutoStop: { [hotkeyMonitor] in hotkeyMonitor.injectAutoStop() }
        )
        #if DICT_DEV_LOG
        audioPipeline?.onDevTimingMark = { [tracker] mark, instant in
            Task { await tracker.mark(mark, at: instant) }
        }
        #endif
        guard audioPipeline != nil else {
            failLoudly(
                "Vizpr's bundled voice-detection model failed to load.",
                detail: "The app bundle is damaged — rebuild or reinstall Vizpr."
            )
            return
        }

        // Warm both engines concurrently at launch (their loads are
        // independent; serial warming paid ASR + LLM back to back). Dictation
        // is NOT gated on this: both engines single-flight their prepare, so a
        // session begun mid-warm awaits the same load instead of failing.
        // Missing models = broken build. (Two plain Tasks, not a task group —
        // the Swift 6 region-isolation checker rejects @MainActor addTask
        // closures here as an unanalyzable pattern.)
        // A user-selected model that fails to load reverts its selection to
        // bundled (which rebuilds the pipeline) instead of terminating; only
        // a bundled failure is a broken build.
        var revertASR: (@MainActor @Sendable () -> Void)?
        if asrDirectory != nil {
            revertASR = { [weak self] in self?.settingsStore.update { $0.asrModelID = nil } }
        }
        var revertCleanup: (@MainActor @Sendable () -> Void)?
        if cleanupDirectory != nil {
            revertCleanup = { [weak self] in self?.settingsStore.update { $0.cleanupModelID = nil } }
        }
        warmEngine(
            devLogLabel: "asr engine prepared",
            failureMessage: "Vizpr's speech recognition model failed to load.",
            revertOnFailure: revertASR
        ) {
            try await engine.prepare()
        }
        warmEngine(
            devLogLabel: "cleanup engine prepared",
            failureMessage: "Vizpr's cleanup model failed to load.",
            revertOnFailure: revertCleanup
        ) {
            try await cleanup.prepareEngine()
        }

        startSnapshotRenderer()
    }

    /// The display path: every snapshot renders on the overlay (§13); the
    /// dev logger observes the same stream. On a rebuild the previous
    /// loop is cancelled first — exactly one renderer at a time.
    private func startSnapshotRenderer() {
        snapshotTask?.cancel()
        #if DICT_DEV_LOG
        let tracker = dictationTracker
        snapshotTask = Task { @MainActor [tokenStream, overlay, tracker] in
            for await snapshot in await tokenStream.makeSnapshotStream() {
                overlay.apply(snapshot)
                if !snapshot.displayed.isEmpty {
                    let renderedAt = ContinuousClock.now
                    Task { await tracker.mark(.firstPreview, at: renderedAt) }
                }
                if !snapshot.settled.isEmpty {
                    let renderedAt = ContinuousClock.now
                    Task { await tracker.mark(.firstSettled, at: renderedAt) }
                }
                if snapshot != .empty {
                    VizprTranscriptLogger.note("display: \(snapshot.displayed)")
                }
            }
        }
        #else
        snapshotTask = Task { @MainActor [tokenStream, overlay] in
            for await snapshot in await tokenStream.makeSnapshotStream() {
                overlay.apply(snapshot)
            }
        }
        #endif
    }

    /// Push settings into every live consumer (PR 11: everything applies
    /// without relaunch; timing values take effect at the next session).
    private func applySettings(_ settings: VizprSettings) {
        // Model selection changed → live engine swap (PR 11 Models pane).
        // Rebuild FIRST so the rest of this method configures the new
        // pipeline, not the one being torn down.
        if settings.asrModelID != appliedASRModelID
            || settings.cleanupModelID != appliedCleanupModelID {
            rebuildPipeline()
        }
        hotkeyMonitor.setHoldThreshold(.milliseconds(settings.holdThresholdMs))
        hotkeyMonitor.setSecondaryMask(Self.modifierMask(settings.secondaryModifiers))
        if settings.hotkeyEnabled {
            if permissionProbe.evaluate() == .ready { _ = hotkeyMonitor.start() }
        } else {
            hotkeyMonitor.stop()
        }
        audioPipeline?.setAutoStopTimeout(.seconds(settings.autoStopSeconds))
        audioPipeline?.silentInputFallback = settings.silentInputFallback
        textInjector.setRestoreEnabled(settings.restoreClipboard)
        overlay.setAnchors(settings.overlayAnchors)
        overlay.setLook(settings.activeLook)
        overlay.setInviz(settings.invizMode)
        overlay.setTargetAppDisplay(settings.targetAppDisplay)
        Task { [smartCleanup] in
            await smartCleanup?.setRuntime(
                enabled: settings.cleanupEnabled,
                codeModeOverride: settings.codeModeOverride
            )
        }
    }

    /// Live engine swap: tear the pipeline down and rebuild it against the
    /// newly selected models. Any in-flight session is cancelled (nothing is
    /// injected — same contract as Escape); selection normally happens from
    /// the Settings window, not mid-dictation.
    private func rebuildPipeline() {
        audioPipeline?.stop()
        settleGate.releaseAll()
        overlay.dismiss()
        Task { [tokenStream] in await tokenStream.cancelSession() }
        setUpAudioPipeline()
        #if DICT_DEV_LOG
        VizprTranscriptLogger.note(
            "pipeline rebuilt: asr=\(settingsStore.settings.asrModelID ?? "bundled") "
                + "cleanup=\(settingsStore.settings.cleanupModelID ?? "bundled")")
        #endif
    }

    static func modifierMask(_ names: [String]) -> CGEventFlags {
        var mask: CGEventFlags = []
        for name in names {
            switch name {
            case "control": mask.insert(.maskControl)
            case "option": mask.insert(.maskAlternate)
            case "shift": mask.insert(.maskShift)
            case "command": mask.insert(.maskCommand)
            default: break
            }
        }
        return mask
    }

    /// Session drain (AudioPipeline hook): releases the settle window, then
    /// the dev logger's half of the record handshake.
    private func sessionDrained(epoch: Int) async {
        settleGate.noteDrained(epoch: epoch)
        #if DICT_DEV_LOG
        await handleSessionDrained()
        #endif
    }

    #if DICT_DEV_LOG
    // MARK: Dictation-record handshake (§14)

    private func beginDictationRecord(startedAt: ContinuousClock.Instant) async {
        pendingInjection = nil
        sessionDrained = false
        await dictationTracker.begin(at: startedAt)
    }

    /// Commit half: stash the injected text; write now if the drain already
    /// happened (the flush can outrun the commit action's actor hops).
    private func noteCommitted(_ text: String) async {
        pendingInjection = text
        if sessionDrained { await writeDictationRecord() }
    }

    /// Drain half (from AudioPipeline.onSessionDrained): every event including
    /// flush finals has reached the tracker. Write if the commit text is
    /// already stashed; a cancelled session leaves it nil — no record.
    private func handleSessionDrained() async {
        sessionDrained = true
        if pendingInjection != nil { await writeDictationRecord() }
    }

    private func abandonDictationRecord() async {
        pendingInjection = nil
        await dictationTracker.reset()
    }

    private func writeDictationRecord() async {
        guard let injected = pendingInjection else { return }
        pendingInjection = nil
        let record = await dictationTracker.makeRecord(
            injectedText: injected,
            surroundingText: currentField.surroundingText,
            bundleID: currentField.bundleID,
            mode: CodeDetector.isCodeSurface(bundleID: currentField.bundleID)
                ? "code" : "default",
            modelTier: MLXCleanup.modelTier
        )
        await VizprDevLogWriter.shared.append(record)
    }
    #endif

    /// One warm leg: run the prepare, dev-log readiness, fail loudly on error.
    /// If both legs fail, the first alert's termination wins; the second modal
    /// never shows. With `revertOnFailure` set (the engine was built from a
    /// USER model folder), a load failure alerts and reverts the selection to
    /// bundled instead of terminating — a bad drop-in must never brick the app.
    private func warmEngine(
        devLogLabel: String,
        failureMessage: String,
        revertOnFailure: (@MainActor @Sendable () -> Void)? = nil,
        _ prepare: @escaping @Sendable () async throws -> Void
    ) {
        Task { @MainActor in
            do {
                try await prepare()
                #if DICT_DEV_LOG
                VizprTranscriptLogger.note(devLogLabel)
                #endif
            } catch {
                if let revertOnFailure {
                    self.presentAlert(
                        "The selected model failed to load.",
                        detail: "Reverting to the bundled model. (\(error))"
                    )
                    revertOnFailure()
                } else {
                    self.failLoudly(
                        failureMessage,
                        detail: "Run scripts/fetch-models.sh and rebuild, or reinstall. (\(error))"
                    )
                }
            }
        }
    }

    private func failLoudly(_ message: String, detail: String) {
        presentAlert(message, detail: detail)
        // A test host that quit mid-run would fail the whole test run.
        guard !Self.isHostedByTests else { return }
        NSApp.terminate(nil)
    }

    /// `xcodebuild test` sets this (to an empty string) in the app that hosts the tests.
    nonisolated static let isHostedByTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Modal alert, except under a test host, where a dialog would block the run: log instead.
    private func presentAlert(_ message: String, detail: String) {
        if Self.isHostedByTests {
            NSLog("Vizpr alert suppressed under test: %@ %@", message, detail)
            return
        }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    // MARK: Hotkey wiring

    /// Start the tap if capability allows; otherwise leave it idle and let the
    /// menu surface the grant action. We never prompt on launch — the user opts
    /// in from the menu, so an unprompted Accessibility sheet never appears.
    private func startHotkeyIfPermitted() {
        if permissionProbe.evaluate() == .ready {
            hotkeyMonitor.start()
            preGrantAutomationIfNeeded()
        }
        refreshMenu()
    }

    /// One-time Automation (System Events) pre-grant (PR 12, NOTES "accepted
    /// risks"): the injection fallback's first NSAppleScript use raises the
    /// Automation TCC prompt SYNCHRONOUSLY mid-paste, freezing the run loop
    /// under the user's dictated text. Trigger the same prompt once here — at
    /// hotkey readiness, an explicit-consent moment the user just opted into —
    /// with an innocuous no-op script, so the mid-injection path never blocks
    /// on consent. Not a permission escalation: the exact same prompt, moved
    /// to a controlled moment. Declined is remembered by TCC and never re-asked
    /// by us (the fallback then fails soft, clipboard still holds the text).
    private func preGrantAutomationIfNeeded() {
        let key = "AutomationPreGrantAnswered"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        // AEDeterminePermissionToAutomateTarget, NOT NSAppleScript: the
        // prompt blocks its calling thread until answered, and blocking the
        // main run loop would stall the event tap callback long enough for
        // the system to disable the tap. A detached task waits instead.
        Task.detached(priority: .utility) {
            var target = AEAddressDesc()
            let bundleID = "com.apple.systemevents"
            let created = bundleID.utf8CString.withUnsafeBufferPointer { buffer in
                AECreateDesc(
                    typeApplicationBundleID, buffer.baseAddress, buffer.count - 1, &target
                )
            }
            guard created == noErr else { return }
            defer { AEDisposeDesc(&target) }
            let status = AEDeterminePermissionToAutomateTarget(
                &target, typeWildCard, typeWildCard, true
            )
            // Only a definitive answer (granted 0 / declined -1743) ends the
            // attempts; transient states (System Events not running) retry at
            // the next hotkey readiness.
            if status == noErr || status == -1743 {
                UserDefaults.standard.set(true, forKey: key)
            }
            #if DICT_DEV_LOG
            VizprTranscriptLogger.note("automation pre-grant status: \(status)")
            #endif
        }
    }

    /// Drain dictation actions. There is no pipeline yet (PRs 3–9); for now this
    /// keeps the stream live and records intent in the dev logger.
    private func consumeHotkeyActions() {
        // Explicit MainActor isolation: the stream payload is the only thing this
        // task touches, and keeping it on main avoids ever reading monitor state
        // off-thread through the @unchecked Sendable escape hatch.
        actionsTask = Task { @MainActor [hotkeyMonitor, weak self] in
            for await action in hotkeyMonitor.actions {
                #if DICT_DEV_LOG
                VizprTranscriptLogger.note("hotkey action: \(action)")
                #endif
                switch action {
                case .startDictation:
                    #if DICT_DEV_LOG
                    let startedAt = ContinuousClock.now
                    #endif
                    self?.lastSessionWasSilent = false
                    await self?.tokenStream.beginSession()
                    let sessionEpoch = self?.settleGate.beginSession() ?? 0
                    #if DICT_DEV_LOG
                    await self?.beginDictationRecord(startedAt: startedAt)
                    #endif
                    // Capture starts FIRST (PR 13): the AX field read is
                    // blocking IPC into the target app, and serializing the
                    // mic behind it cost ~250 ms of lost speech onset. The
                    // pipeline needs nothing from the field context.
                    self?.audioPipeline?.start(sessionEpoch: sessionEpoch)
                    // Read the focused field BEFORE the overlay appears —
                    // read-only AX, one shot per session (PR 10), off-main so
                    // the capture spin-up isn't queued behind the IPC. The
                    // session's first token event is bounded below by the
                    // draft floor (~1.5 s), so cleanup's session begin (which
                    // needs the field) always wins this race by an order of
                    // magnitude.
                    let field = await self?.fieldReader.readOffMain() ?? .empty
                    self?.currentField = field
                    let vocab = self?.vocabularyModel.library.resolved(bundleID: field.bundleID)
                    let style = self?.vocabularyModel.library.resolvedStyleRules(bundleID: field.bundleID)
                    await self?.smartCleanup?.beginSession(
                        field: field, vocabulary: vocab, styleRules: style
                    )
                    self?.overlay.show(targetWindowFrame: field.focusedWindowFrame)
                case .commit:
                    #if DICT_DEV_LOG
                    let commitAt = ContinuousClock.now
                    #endif
                    self?.audioPipeline?.stop()
                    // Tail-settle window (§15 amendment): let the ASR tail
                    // final land on the display — in the mutable color — before
                    // snapshotting, bounded so a hung engine can't hold the
                    // commit hostage. WYSIWYG holds: displayed==injected,
                    // "at stop" is now "at stop + settle".
                    let cap = Tuning.settleCapMs
                    #if DICT_DEV_LOG
                    let settleStart = ContinuousClock.now
                    let settle = await self?.settleGate.awaitDrain(cap: .milliseconds(cap))
                    if let settle {
                        let waited = ContinuousClock.now - settleStart
                        let waitedMs = Int(waited.components.seconds) * 1000
                            + Int(waited.components.attoseconds / 1_000_000_000_000_000)
                        VizprTranscriptLogger.note(
                            "settle: \(settle == .drained ? "drained" : "capped") after \(waitedMs) ms"
                        )
                    }
                    #else
                    await self?.settleGate.awaitDrain(cap: .milliseconds(cap))
                    #endif
                    // Atomic WYSIWYG gate: snapshot displayed text, cancel
                    // in-flight cleanup. The injector receives exactly this
                    // string and transforms nothing (§12).
                    let committed = await self?.tokenStream.commit() ?? ""
                    self?.overlay.dismiss()
                    let outcome = await self?.textInjector.inject(committed)
                    #if DICT_DEV_LOG
                    let injectedAt = ContinuousClock.now
                    #endif
                    switch outcome {
                    case .skippedSecureInput:
                        // §12.1's quiet notice, headless edition — the
                        // overlay (PR 9) upgrades this to a visible one. The
                        // user is at a different field than last time, so the
                        // spacing memory no longer applies.
                        NSSound.beep()
                        self?.textInjector.resetSpacing()
                    case .failed:
                        // Total failure is no quieter: the text is on the
                        // clipboard for a manual paste.
                        NSSound.beep()
                    case .injected(_, .keptNoTextField):
                        // The paste may have landed nowhere; the transcript
                        // stays on the clipboard, so tell the user.
                        NSSound.beep()
                    case .injected, .skippedEmpty, nil:
                        break
                    }
                    #if DICT_DEV_LOG
                    if outcome == .skippedSecureInput {
                        // Never log text dictated at a password field — not
                        // in the JSONL record NOR the breadcrumb (field
                        // catch: the first cut leaked it into debug.log).
                        VizprTranscriptLogger.note("COMMIT skippedSecureInput: [redacted]")
                        await self?.abandonDictationRecord()
                    } else {
                        VizprTranscriptLogger.note(
                            "COMMIT \(String(describing: outcome)): \(committed)"
                        )
                        await self?.dictationTracker.mark(.commit, at: commitAt)
                        await self?.dictationTracker.mark(.injected, at: injectedAt)
                        await self?.noteCommitted(committed)
                    }
                    #endif
                case .cancel:
                    self?.audioPipeline?.stop()
                    await self?.tokenStream.cancelSession()
                    self?.overlay.dismiss()
                    self?.textInjector.resetSpacing()
                    #if DICT_DEV_LOG
                    await self?.abandonDictationRecord()
                    #endif
                }
            }
        }
    }

    @objc private func openSettings() {
        settingsWindow.show(
            settings: settingsStore, vocabulary: vocabularyModel, models: modelsModel
        )
    }

    @objc private func cycleLook() {
        settingsStore.cycleLook()
        refreshMenu()
    }

    @objc private func resetOverlayPosition() {
        settingsStore.resetOverlayPositions()
    }

    @objc private func cycleVocabulary() {
        let name = vocabularyModel.cycle()
        #if DICT_DEV_LOG
        VizprTranscriptLogger.note("vocabulary cycled to: \(name)")
        #endif
        refreshMenu()
    }

    @objc private func grantAccessibility() {
        let capability = permissionProbe.evaluate()
        switch capability {
        case .needsAccessibility:
            permissionProbe.requestAccessibility()
        case .needsInputMonitoring:
            permissionProbe.requestInputMonitoring()
            permissionProbe.openSettings(for: capability)
        case .grantedButDead:
            // Permission is present but the tap won't deliver until relaunch.
            permissionProbe.openSettings(for: capability)
        case .ready:
            hotkeyMonitor.start()
            preGrantAutomationIfNeeded()
        }
        refreshMenu()
    }

    // MARK: Menu

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Template image: AppKit tints it automatically for light/dark menu bars.
        let image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Vizpr")
        image?.isTemplate = true
        item.button?.image = image

        statusItem = item
        refreshMenu()
    }

    private func cycleItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func refreshMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Vizpr", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let capability = permissionProbe.evaluate()
        if capability != .ready || !hotkeyMonitor.isTapHealthy {
            let title: String
            switch capability {
            case .grantedButDead: title = "Permission granted — relaunch to enable"
            case .needsInputMonitoring: title = "Enable Input Monitoring…"
            default: title = "Grant Accessibility…"
            }
            let grant = NSMenuItem(title: title, action: #selector(grantAccessibility), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
            menu.addItem(.separator())
        }

        if lastSessionWasSilent {
            let warning = NSMenuItem(
                title: "⚠ Mic delivered silence — check Sound input",
                action: nil, keyEquivalent: ""
            )
            warning.isEnabled = false
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        menu.addItem(cycleItem(
            "Dictionary: \(vocabularyModel.library.activeDisplayName)", #selector(cycleVocabulary)
        ))
        menu.addItem(cycleItem(
            "Look: \(settingsStore.settings.activeLook.name)", #selector(cycleLook)
        ))
        menu.addItem(cycleItem("Reset Overlay Position", #selector(resetOverlayPosition)))

        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        menu.addItem(
            NSMenuItem(
                title: "Quit Vizpr",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        // PR 2 review carry: re-evaluate capability every time the menu
        // opens, so an external grant in System Settings reflects without
        // clicking anything.
        menu.delegate = self
        statusItem?.menu = menu
    }
}


extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenu()
    }
}
