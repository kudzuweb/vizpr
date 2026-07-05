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
    private let hotkeyMonitor = HotkeyMonitor()
    private let permissionProbe = PermissionProbe()
    private var actionsTask: Task<Void, Never>?
    private var audioPipeline: AudioPipeline?
    private var asrEngine: FluidAudioASR?
    private let tokenStream = TokenStream()
    private let textInjector = TextInjector(
        pasteboard: SystemPasteboard(),
        poster: CGEventPoster(),
        secureInput: SecureInputProbe()
    )
    private var smartCleanup: SmartCleanup?
    private var snapshotTask: Task<Void, Never>?
    private let overlay = OverlayController()
    private let settleGate = SettleGate()
    private let fieldReader = FieldContextReader()
    private let settingsStore = SettingsStore()
    /// The focused field's context, captured at session start (PR 10).
    private var currentField: FieldContext = .empty
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

        // LSUIElement already implies accessory; set it explicitly so the policy
        // is unambiguous regardless of how the process was launched.
        NSApp.setActivationPolicy(.accessory)
        setUpStatusItem()
        setUpAudioPipeline()
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

    /// Build the capture→VAD→ASR→auto-stop pipeline against the bundled models.
    /// Load failures mean a broken bundle: fail loudly (invariant — never limp
    /// along without a model).
    private func setUpAudioPipeline() {
        let engine = FluidAudioASR()
        asrEngine = engine

        // The cleanup leg (PR 6): events flow ASR -> SmartCleanup (vocab
        // pre-pass + confidence gate) -> TokenStream (regions + generation
        // gate); commit/cancel drive the stream's atomic gate below. In dev
        // builds the same event stream and outcome seam feed the §14 JSONL
        // records; Release leaves both hooks unset.
        let vocabulary = (try? VocabularyStore().load()) ?? .empty
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
            engine: MLXCleanup(),
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

        audioPipeline = AudioPipeline.makeDefault(
            engine: engine,
            onTokenEvent: onTokenEvent,
            onSessionDrained: onSessionDrained,
            onAutoStop: { [hotkeyMonitor] in hotkeyMonitor.injectAutoStop() }
        )
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
        warmEngine(devLogLabel: "asr engine prepared") { try await engine.prepare() }
        warmEngine(devLogLabel: "cleanup engine prepared") { try await cleanup.prepareEngine() }

        // The display path: every snapshot renders on the overlay (§13); the
        // dev logger observes the same stream.
        snapshotTask = Task { @MainActor [tokenStream, overlay] in
            for await snapshot in await tokenStream.makeSnapshotStream() {
                overlay.apply(snapshot)
                #if DICT_DEV_LOG
                if snapshot != .empty {
                    VizprTranscriptLogger.note("display: \(snapshot.displayed)")
                }
                #endif
            }
        }
    }

    /// Push settings into every live consumer (PR 11: everything applies
    /// without relaunch; timing values take effect at the next session).
    private func applySettings(_ settings: VizprSettings) {
        hotkeyMonitor.setHoldThreshold(.milliseconds(settings.holdThresholdMs))
        audioPipeline?.setAutoStopTimeout(.seconds(settings.autoStopSeconds))
        textInjector.setRestoreEnabled(settings.restoreClipboard)
        overlay.setTheme(OverlayTheme.from(settings))
        Task { [tokenStream, smartCleanup, asrEngine] in
            await tokenStream.setSettleSentences(settings.settleSentences)
            await smartCleanup?.setRuntime(
                enabled: settings.cleanupEnabled,
                codeModeOverride: settings.codeModeOverride
            )
            await asrEngine?.setDraftMinTail(milliseconds: settings.draftMinTailMs)
        }
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

    private func beginDictationRecord() async {
        pendingInjection = nil
        sessionDrained = false
        await dictationTracker.reset()
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
    /// never shows.
    private func warmEngine(
        devLogLabel: String, _ prepare: @escaping @Sendable () async throws -> Void
    ) {
        Task { @MainActor in
            do {
                try await prepare()
                #if DICT_DEV_LOG
                VizprTranscriptLogger.note(devLogLabel)
                #endif
            } catch {
                self.failLoudly(
                    "Vizpr's speech models failed to load.",
                    detail: "Run scripts/fetch-models.sh and rebuild, or reinstall. (\(error))"
                )
            }
        }
    }

    private func failLoudly(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: Hotkey wiring

    /// Start the tap if capability allows; otherwise leave it idle and let the
    /// menu surface the grant action. We never prompt on launch — the user opts
    /// in from the menu, so an unprompted Accessibility sheet never appears.
    private func startHotkeyIfPermitted() {
        if permissionProbe.evaluate() == .ready {
            hotkeyMonitor.start()
        }
        refreshMenu()
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
                    await self?.tokenStream.beginSession()
                    let sessionEpoch = self?.settleGate.beginSession() ?? 0
                    // Read the focused field BEFORE the overlay appears —
                    // read-only AX, one shot per session (PR 10).
                    let field = self?.fieldReader.read() ?? .empty
                    self?.currentField = field
                    await self?.smartCleanup?.beginSession(field: field)
                    self?.overlay.show(targetWindowFrame: field.focusedWindowFrame)
                    #if DICT_DEV_LOG
                    await self?.beginDictationRecord()
                    #endif
                    self?.audioPipeline?.start(sessionEpoch: sessionEpoch)
                case .commit:
                    self?.audioPipeline?.stop()
                    // Flush-settle window (§15 amendment): let the ASR flush
                    // land on the display — in the mutable color — before
                    // snapshotting, bounded so a hung engine can't hold the
                    // commit hostage. WYSIWYG holds: displayed==injected,
                    // "at stop" is now "at stop + settle".
                    let cap = self?.settingsStore.settings.settleCapMs ?? 350
                    await self?.settleGate.awaitDrain(cap: .milliseconds(cap))
                    // Atomic WYSIWYG gate: snapshot displayed text, cancel
                    // in-flight cleanup. The injector receives exactly this
                    // string and transforms nothing (§12).
                    let committed = await self?.tokenStream.commit() ?? ""
                    self?.overlay.dismiss()
                    let outcome = await self?.textInjector.inject(committed)
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

        menu.addItem(
            NSMenuItem(
                title: "Quit Vizpr",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        statusItem?.menu = menu
    }
}
