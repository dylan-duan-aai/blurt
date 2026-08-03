import BlurtEngine
import Foundation
import os

/// Pauses Spotify while a dictation is recording and resumes it afterwards, so
/// the music you're talking over doesn't end up in the microphone feed — and in
/// the transcript.
///
/// Driven from `AppCoordinator.render(_:)` on every phase, exactly like
/// `CueSoundPlayer`: the edge logic is the engine's `RecordingEdgeDetector`
/// (shared with the chimes, and unit-tested there), and this type is only the
/// AppKit-side executor. Resume rides the recording→not-recording edge rather
/// than a terminal phase, so the music comes back the moment the mic closes
/// instead of a second later when the paste lands.
///
/// Spotify is driven through its own scripting interface. That means:
/// - **Nothing happens unless Spotify is already running and playing.** The
///   `is running` check is the AppleScript idiom that does *not* launch the app,
///   which matters — a dictation must never boot a music player.
/// - **Resume only fires if we were the one who paused.** Checked on the queue
///   below, not against the setting, so flipping the toggle off mid-dictation
///   can't strand the user's music paused.
/// - The first send triggers the system's "Blurt wants to control Spotify"
///   consent prompt. Denial surfaces as a logged error (-1743) and the feature
///   stays inert; nothing else in the dictation path depends on it.
final class SpotifyPauseController {
  private nonisolated static let logger = Logger(
    subsystem: BlurtIdentity.subsystem, category: "SpotifyPauseController")

  /// Off-pool home for the Apple Events. A Dispatch queue rather than
  /// `Task.detached`, for the same reason `DictationSession` uses one for the AX
  /// field-context read: an Apple Event is a *synchronous* cross-process round
  /// trip bounded only by its timeout, so against a beachballing Spotify it
  /// blocks a thread outright. The Swift cooperative pool is sized to the core
  /// count and does not overcommit, so parking its threads here could stall the
  /// whole non-main runtime — including the dictation actors. Dispatch
  /// overcommits, so a blocked send costs a thread instead of the pool.
  ///
  /// **Serial**, which is load-bearing twice over: `NSAppleScript` is not
  /// thread-safe, and the resume has to observe the pause's outcome. On a
  /// concurrent queue a short dictation's resume could overtake its own pause and
  /// read `didPause` as false — leaving the music stopped, the one failure the
  /// user would actually notice.
  private static let queue = DispatchQueue(
    label: "\(BlurtIdentity.subsystem).SpotifyPause", qos: .userInitiated)

  /// Shared with `CueSoundPlayer`'s gate — same edges, one implementation.
  private var edges = RecordingEdgeDetector()

  /// Whether *we* paused Spotify and therefore owe it a resume.
  ///
  /// `nonisolated(unsafe)` because it is read and written only inside
  /// `Self.queue.async` blocks, and that queue is serial — so the accesses are
  /// mutually exclusive and ordered without a lock. Do not touch it from the main
  /// actor; the ordering guarantee above is the whole reason it lives here rather
  /// than beside the edge detector.
  nonisolated(unsafe) private var didPause = false

  /// Acts on the recording edge. Call once per rendered phase.
  func transition(for phase: PipelinePhase) {
    switch edges.edge(for: phase) {
    case .began:
      // Read the setting on the main actor, at the edge, so a Settings change
      // applies to the very next dictation — the same freshness rule as the
      // press-time key-terms read.
      if SpotifyPauseStore().isEnabled { pauseIfPlaying() }
    case .ended:
      resumeIfWePaused()
    case nil:
      break
    }
  }

  /// Enqueues the pause. Fire-and-forget: the recording has already started and
  /// must never wait on another app's responsiveness, so a slow or wedged Spotify
  /// costs at most some music bleeding into the first moments of the take.
  private func pauseIfPlaying() {
    Self.queue.async { [self] in
      // Assigned, not or-ed, so a stale true from an earlier dictation whose
      // resume was skipped can't make us "resume" music the user had stopped
      // themselves in the meantime.
      didPause = Self.run(Self.pauseScript) == Self.pausedResult
    }
  }

  private func resumeIfWePaused() {
    Self.queue.async { [self] in
      guard didPause else { return }
      didPause = false
      _ = Self.run(Self.resumeScript)
    }
  }

  /// Pauses only a Spotify that is both running and actually playing, reporting
  /// which of those it did. `if application … is running` is deliberate: it reads
  /// the running state *without* launching Spotify, unlike a bare `tell`.
  private nonisolated static let pauseScript = """
    if application "Spotify" is running then
      tell application "Spotify"
        if player state is playing then
          pause
          return "\(pausedResult)"
        end if
      end tell
    end if
    return "no"
    """

  /// Resumes playback, guarded by the same non-launching running check — Spotify
  /// may have quit during the dictation, and reviving it would be absurd.
  private nonisolated static let resumeScript = """
    if application "Spotify" is running then
      tell application "Spotify" to play
    end if
    """

  private nonisolated static let pausedResult = "paused"

  /// Compiles and runs `source`, returning its string result (nil on any
  /// failure). Must be called on `queue` — see `didPause`.
  ///
  /// Compiled per call rather than cached: this runs twice per dictation on a
  /// background queue, so the OSA compile is far too cheap to justify holding
  /// more mutable, queue-confined state.
  ///
  /// The **`autoreleasepool` is required, not hygiene**: `executeAndReturnError`
  /// returns an autoreleased descriptor, and a `DispatchQueue` block drains its
  /// pool at an unspecified time rather than at block exit. `scripts/leaks.sh`
  /// scans the process the instant after exercising the dictation path, so an
  /// undrained descriptor is indistinguishable from a leak and failed the gate
  /// with a backtrace through this function. Draining here makes the lifetime
  /// deterministic — and keeps the transient OSA allocations from outliving a
  /// dictation regardless.
  private nonisolated static func run(_ source: String) -> String? {
    autoreleasepool {
      guard let script = NSAppleScript(source: source) else {
        logger.error("failed to build Spotify script")
        return nil
      }
      var error: NSDictionary?
      let result = script.executeAndReturnError(&error)
      if let error {
        // -1743 is "not authorized to send Apple events", i.e. the user declined
        // the automation prompt (or hasn't been asked yet and the app is not
        // permitted). Logged rather than surfaced: the dictation itself worked, and
        // a modal about the user's music player would be worse than silent.
        let code = error[NSAppleScript.errorNumber] as? Int ?? 0
        logger.error("Spotify script failed (\(code, privacy: .public))")
        return nil
      }
      // Safe to hand out across the drain: the bridged `String` retains its own
      // storage rather than borrowing the descriptor's.
      return result.stringValue
    }
  }
}
