import AppKit
import BlurtEngine
import Foundation
import os

/// Quiets the user's music while a dictation is recording and restores it
/// afterwards, so what you're listening to doesn't end up in the microphone feed —
/// and in the transcript.
///
/// Driven from `AppCoordinator.render(_:)` on every phase, exactly like
/// `CueSoundPlayer`: the edge logic is the engine's `RecordingEdgeDetector` (shared
/// with the chimes, unit-tested there), and this type is only the AppKit-side
/// executor. Restore rides the recording→not-recording edge rather than a terminal
/// phase, so playback returns the moment the mic closes instead of a second later
/// when the paste lands.
///
/// Two mechanisms, deliberately unequal (see `MediaPauseStore` for the switches):
///
/// 1. **Scriptable players** (`MediaPlayerApp`: Spotify, Apple Music) — precise.
///    Each exposes `player state`, so we pause only one that is *already playing*
///    and resume only what we actually paused. `if application … is running` is the
///    scripting idiom that reads the running state *without* launching the app,
///    which matters: a dictation must never boot a music player. On by default,
///    because it cannot start anything unbidden.
/// 2. **A system play/pause media key** — imprecise, off by default. The only thing
///    that reaches a browser playing YouTube, but a stateless toggle: macOS exposes
///    no public way to ask whether a browser is playing, so this can *start*
///    something when nothing was. Gated behind `includesOtherPlayers` so the user
///    opts into that.
///
/// The first Apple Event triggers the system's "Blurt wants to control …" consent
/// prompt, once per target app. Declining surfaces as a logged `-1743` and leaves
/// the feature inert; nothing in the dictation path depends on it.
final class MediaPauseController {
  private nonisolated static let logger = Logger(
    subsystem: BlurtIdentity.subsystem, category: "MediaPauseController")

  /// Off-pool home for the Apple Events. A Dispatch queue rather than
  /// `Task.detached`, for the same reason `DictationSession` uses one for the AX
  /// field-context read: an Apple Event is a *synchronous* cross-process round trip
  /// bounded only by its timeout, so against a beachballing player it blocks a
  /// thread outright. The Swift cooperative pool is sized to the core count and
  /// does not overcommit, so parking its threads here could stall the whole
  /// non-main runtime — including the dictation actors. Dispatch overcommits, so a
  /// blocked send costs a thread instead of the pool.
  ///
  /// **Serial**, which is load-bearing twice over: `NSAppleScript` is not
  /// thread-safe, and the restore has to observe what the pause actually did. On a
  /// concurrent queue a short dictation's restore could overtake its own pause and
  /// see an empty `pausedPlayers` — leaving the music stopped, the one failure the
  /// user would actually notice.
  private static let queue = DispatchQueue(
    label: "\(BlurtIdentity.subsystem).MediaPause", qos: .userInitiated)

  /// Shared with `CueSoundPlayer`'s gate — same edges, one implementation.
  private var edges = RecordingEdgeDetector()

  /// Exactly the players *we* paused, so the restore puts back only what we took
  /// away and never starts something the user had stopped themselves.
  ///
  /// `nonisolated(unsafe)` because it is read and written only inside
  /// `Self.queue.async` blocks, and that queue is serial — so the accesses are
  /// mutually exclusive and ordered without a lock. Do not touch it from the main
  /// actor; the ordering guarantee is the whole reason it lives here rather than
  /// beside the edge detector.
  nonisolated(unsafe) private var pausedPlayers: [MediaPlayerApp] = []

  /// Whether we sent the imprecise media key and therefore owe a second one. Same
  /// queue-confinement contract as `pausedPlayers`.
  nonisolated(unsafe) private var sentMediaKey = false

  /// Acts on the recording edge. Call once per rendered phase.
  func transition(for phase: PipelinePhase) {
    switch edges.edge(for: phase) {
    case .began:
      // Read the settings on the main actor, at the edge, so a Settings change
      // applies to the very next dictation — the same freshness rule as the
      // press-time key-terms read.
      let settings = MediaPauseStore()
      guard settings.isEnabled else { return }
      pause(includingOtherPlayers: settings.includesOtherPlayers)
    case .ended:
      restore()
    case nil:
      break
    }
  }

  /// Enqueues the pause. Fire-and-forget: recording has already started and must
  /// never wait on another app's responsiveness, so a slow or wedged player costs
  /// at most some music bleeding into the first moments of the take.
  private func pause(includingOtherPlayers: Bool) {
    Self.queue.async { [self] in
      // Assigned, not appended: a stale entry from an earlier dictation whose
      // restore was skipped must not resurrect playback the user has since stopped.
      pausedPlayers = MediaPlayerApp.allCases.filter { Self.pauseIfPlaying($0) }
      // Only worth a media key if the precise path found nothing. If Spotify was
      // the thing playing we already handled it exactly, and firing a toggle on top
      // would resume it mid-dictation.
      sentMediaKey = includingOtherPlayers && pausedPlayers.isEmpty
      if sentMediaKey { Self.postPlayPauseKey() }
    }
  }

  private func restore() {
    Self.queue.async { [self] in
      for player in pausedPlayers { Self.resume(player) }
      pausedPlayers = []
      if sentMediaKey {
        sentMediaKey = false
        Self.postPlayPauseKey()
      }
    }
  }

  /// Pauses `player` only if it is both running and actually playing, reporting
  /// whether it did. Must be called on `queue`.
  private nonisolated static func pauseIfPlaying(_ player: MediaPlayerApp) -> Bool {
    let name = player.applicationName
    return run(
      """
      if application "\(name)" is running then
        tell application "\(name)"
          if player state is playing then
            pause
            return "\(pausedResult)"
          end if
        end tell
      end if
      return "no"
      """) == pausedResult
  }

  /// Resumes `player`, guarded by the same non-launching running check — it may
  /// have quit during the dictation, and reviving it would be absurd.
  private nonisolated static func resume(_ player: MediaPlayerApp) {
    let name = player.applicationName
    _ = run(
      """
      if application "\(name)" is running then
        tell application "\(name)" to play
      end if
      """)
  }

  private nonisolated static let pausedResult = "paused"

  /// Virtual keycode for the system play/pause media key (`NX_KEYTYPE_PLAY`).
  private nonisolated static let playPauseKey: Int = 16

  /// Posts a system play/pause media key: a `systemDefined` event with subtype 8,
  /// which is how the hardware media keys are represented — a plain `CGEvent`
  /// keycode cannot express them. It reaches whichever app owns the current media
  /// session, which is exactly why it covers browsers.
  ///
  /// Needs no permission Blurt lacks: it already posts synthetic events for the
  /// clipboard paste (see `KeyInjector`), so the Accessibility grant covers this.
  private nonisolated static func postPlayPauseKey() {
    for isDown in [true, false] {
      let data1 = (playPauseKey << 16) | (isDown ? 0x0A00 : 0x0B00)
      guard
        let event = NSEvent.otherEvent(
          with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0,
          windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
      else {
        logger.error("failed to build media key event")
        return
      }
      event.cgEvent?.post(tap: .cghidEventTap)
    }
  }

  /// Compiles and runs `source`, returning its string result (nil on any failure).
  /// Must be called on `queue` — see `pausedPlayers`.
  ///
  /// Compiled per call rather than cached: this runs a handful of times per
  /// dictation on a background queue, so the OSA compile is far too cheap to
  /// justify holding more mutable, queue-confined state.
  ///
  /// The **`autoreleasepool` is required, not hygiene**: `executeAndReturnError`
  /// returns an autoreleased descriptor, and a `DispatchQueue` block drains its
  /// pool at an unspecified time rather than at block exit. `scripts/leaks.sh`
  /// scans the process the instant after exercising the dictation path, so an
  /// undrained descriptor is indistinguishable from a leak and failed that gate
  /// with a backtrace through this function. Draining here makes the lifetime
  /// deterministic.
  private nonisolated static func run(_ source: String) -> String? {
    autoreleasepool {
      guard let script = NSAppleScript(source: source) else {
        logger.error("failed to build media script")
        return nil
      }
      var error: NSDictionary?
      let result = script.executeAndReturnError(&error)
      if let error {
        // -1743 is "not authorized to send Apple events", i.e. the user declined
        // the automation prompt. Logged rather than surfaced: the dictation itself
        // worked, and a modal about the user's music player would be worse than
        // silent.
        let code = error[NSAppleScript.errorNumber] as? Int ?? 0
        logger.error("media script failed (\(code, privacy: .public))")
        return nil
      }
      // Safe to hand out across the drain: the bridged `String` retains its own
      // storage rather than borrowing the descriptor's.
      return result.stringValue
    }
  }
}
