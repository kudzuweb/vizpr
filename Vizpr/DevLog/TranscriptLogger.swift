#if DICT_DEV_LOG
import Foundation

/// Dev-only transcript logger (PLAN.md Part III §14).
///
/// Compiled **only** when `DICT_DEV_LOG` is defined (Debug builds), so it is
/// physically absent from Release — there is no toggle, no runtime flag, no
/// dead code in the shipping binary. The full JSONL appender lands in PR 7;
/// this PR establishes the compile gate and proves Release excludes it.
enum VizprTranscriptLogger {
    /// Distinctive marker string used by scripts/check-devlog-absent.sh to assert
    /// this code is absent from Release binaries. Must not appear in Release.
    static let buildMarker = "VIZPR_DEV_LOG_BUILD_MARKER"

    /// Placeholder behavior: report where the dev transcript log will be written.
    /// Real append-on-dictation logic arrives in PR 7.
    static func announce() {
        let path = ("~/Documents/dictation-dev/transcripts.jsonl" as NSString)
            .expandingTildeInPath
        print("[\(buildMarker)] dev transcript log target: \(path)")
    }

    /// Emit a one-off developer breadcrumb. A stand-in until PR 7's structured
    /// JSONL records; useful for eyeballing the pipeline during bring-up.
    static func note(_ message: String) {
        print("[\(buildMarker)] \(message)")
    }
}
#endif
