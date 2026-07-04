import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Thin real-IO conformers for the injection seams (PLAN.md §12). No logic
/// beyond the direct system calls — everything decidable lives in
/// TextInjector and is tested against fakes.

/// Private pasteboard type carrying the injection tag (§12.3): lets the
/// ownership guard distinguish "still exactly our write" from any other
/// content, even identical text copied by the user.
private let vizprTagType = NSPasteboard.PasteboardType("com.kudzuweb.vizpr.injection-tag")

/// org.nspasteboard.org conventions honored by clipboard/password managers.
private let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
private let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

@MainActor
final class SystemPasteboard: PasteboardWriting {
    private let pasteboard = NSPasteboard.general

    var changeCount: Int { pasteboard.changeCount }

    var containsConcealedContent: Bool {
        pasteboard.pasteboardItems?.contains {
            $0.types.contains(concealedType)
        } ?? false
    }

    /// Types excluded from snapshots: promise-backed data forces synchronous
    /// IPC to the owning app on the main thread (and a restored promise is a
    /// dead promise anyway), and org.nspasteboard markers describe the
    /// ORIGINAL write's lifecycle, not our restore.
    private static func isSnapshotSafe(_ type: NSPasteboard.PasteboardType) -> Bool {
        let raw = type.rawValue.lowercased()
        if raw.contains("promise") { return false }
        if raw.hasPrefix("org.nspasteboard.") { return false }
        return true
    }

    func snapshot() -> PasteboardContents {
        let items = pasteboard.pasteboardItems ?? []
        return PasteboardContents(items: items.map { item in
            // item.types is fidelity order — preserve it.
            item.types.compactMap { type in
                guard Self.isSnapshotSafe(type),
                      let data = item.data(forType: type) else { return nil }
                return PasteboardEntry(type: type.rawValue, data: data)
            }
        })
    }

    func write(_ text: String, tag: String) -> Int {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(tag, forType: vizprTagType)
        // Transient: dictated text is ephemeral input, not something
        // clipboard managers should record in history (it may be sensitive,
        // and managers that capture-and-rewrite would defeat the restore
        // guard anyway).
        item.setString("", forType: transientType)
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    func hasTag(_ tag: String) -> Bool {
        pasteboard.string(forType: vizprTagType) == tag
    }

    func restore(_ contents: PasteboardContents, expectedChangeCount: Int) -> Bool {
        // Atomic claim: clearContents() takes ownership and returns the
        // post-clear count. If it isn't exactly expected+1, another writer
        // raced in between the caller's guard check and our claim — abort
        // rather than bury their content under stale data. (The razor-thin
        // losing case leaves an empty pasteboard, which is strictly less
        // wrong than resurrecting the pre-dictation clipboard over theirs.)
        guard pasteboard.clearContents() == expectedChangeCount + 1 else { return false }
        let items = contents.items.map { entries in
            let item = NSPasteboardItem()
            for entry in entries {
                item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
            }
            return item
        }
        pasteboard.writeObjects(items)
        return true
    }
}

@MainActor
final class CGEventPoster: EventPosting {

    func postPasteChord() -> Bool {
        // CGEvent.post silently no-ops without Accessibility trust (a
        // separate grant from Input Monitoring, which the app can run on).
        // Reporting success for a paste that never happened would also skip
        // the fallback and then "restore" over the dictation text.
        guard AXIsProcessTrusted() else { return false }
        // Private source: the chord must carry EXACTLY .maskCommand. With a
        // session-state source, physically held modifiers (the user's
        // fingers can still be on the secondary-chord keys at commit) can
        // contaminate the event as apps observe it.
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        let keyCode = Self.keyCodeForV()
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    func fallbackPaste() -> Bool {
        // §12.6: for apps where the synthesized chord doesn't land, and the
        // untrusted-Accessibility path above. First use prompts for
        // Automation (System Events) permission; the synchronous wait is a
        // known cost on this rare path (NOTES: pre-grant during onboarding,
        // PR 12).
        let script = "tell application \"System Events\" to keystroke \"v\" using command down"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        return error == nil
    }

    /// Resolve the virtual keycode producing "v"/"V" under the active
    /// ASCII-capable keyboard layout (§12.4): scan the layout's translation
    /// table so Dvorak, AZERTY, Colemak etc. paste correctly. The
    /// ASCII-capable source (not the raw current source) guarantees layout
    /// data exists even while a CJK input METHOD is active. Falls back to
    /// ANSI V (9).
    static func keyCodeForV() -> CGKeyCode {
        guard
            let inputSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
                .takeRetainedValue(),
            let layoutPointer = TISGetInputSourceProperty(
                inputSource, kTISPropertyUnicodeKeyLayoutData
            )
        else { return 9 }

        // The layout data is an interior pointer owned by inputSource: keep
        // the source alive for the whole scan (ARC may otherwise release it
        // after its last textual use, leaving the CFData dangling).
        return withExtendedLifetime(inputSource) {
            let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer)
                .takeUnretainedValue() as Data
            return layoutData.withUnsafeBytes { raw -> CGKeyCode in
                guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress
                else { return 9 }
                let lower = UniChar(UnicodeScalar("v").value)
                let upper = UniChar(UnicodeScalar("V").value)
                for keyCode: UInt16 in 0..<128 {
                    var deadKeyState: UInt32 = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    var length = 0
                    let status = UCKeyTranslate(
                        layout, keyCode, UInt16(kUCKeyActionDown), 0,
                        UInt32(LMGetKbdType()),
                        OptionBits(kUCKeyTranslateNoDeadKeysMask),
                        &deadKeyState, chars.count, &length, &chars
                    )
                    if status == noErr, length == 1,
                       chars[0] == lower || chars[0] == upper {
                        return CGKeyCode(keyCode)
                    }
                }
                return 9
            }
        }
    }
}

@MainActor
struct SecureInputProbe: SecureInputProbing {
    var isSecureInputActive: Bool { IsSecureEventInputEnabled() }
}
