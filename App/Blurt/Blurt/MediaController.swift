import BlurtEngine
import Foundation
import os

/// Pauses the user's music while a dictation is recording and resumes it
/// afterward — so you don't talk over your own music. Only the players that were
/// actually *playing* when recording started are paused, and only those are
/// resumed, so a dictation never *starts* music that wasn't already going. Kept
/// out of `AppCoordinator`'s body (like `CueSoundPlayer`) so this behavior can
/// change without churning the session↔UI wiring.
///
/// Scope is Apple Music and Spotify — the two players with stable AppleScript
/// dictionaries (`player state` / `pause` / `play`). Control goes through
/// `/usr/bin/osascript` run on a background queue: AppleScript must never block
/// the recording pill, and shelling out keeps Apple-Event *sending* inside
/// Apple's own already-entitled binary, so Blurt needs no automation entitlement
/// of its own — just the `NSAppleEventsUsageDescription` it already declares. The
/// first pause of a running+playing player surfaces the one-time macOS
/// Automation permission prompt; if the user declines, the script fails
/// harmlessly and nothing is paused.
final class MediaController {
  // `nonisolated` so the off-main pause/resume work (and `MusicPlayer`, same
  // file) can log; `fileprivate` so `MusicPlayer` reaches it. `Logger` is
  // `Sendable`, so sharing one instance across threads is safe.
  fileprivate nonisolated static let logger = Logger(
    subsystem: BlurtIdentity.subsystem, category: "MediaController")

  /// Edge-detector (engine, unit-tested) mapping pipeline phases to pause/resume.
  private var gate = MediaPlaybackGate()

  /// Serializes pause→resume so a resume always observes the pause that preceded
  /// it — a very short recording could otherwise resume before the pause's
  /// state-check finished — and keeps the (blocking) osascript calls off the main
  /// thread. `pausedPlayers` is therefore touched only from work run on it.
  private let queue = DispatchQueue(label: "\(BlurtIdentity.subsystem).media-control")

  /// The players this controller paused on the current recording's start, so
  /// `resumePausedPlayers` restarts exactly those — never a player the user had
  /// already paused themselves. Accessed only on `queue` (hence the unchecked
  /// annotation: the default-MainActor app target can't see that invariant).
  private nonisolated(unsafe) var pausedPlayers: [MusicPlayer] = []

  /// Runs the pause/resume for `phase` on the recording edge; a no-op on every
  /// other phase (the gate returns nil). Called from `AppCoordinator.render`.
  func transition(for phase: PipelinePhase) {
    switch gate.action(for: phase) {
    case .pause: queue.async { [weak self] in self?.pausePlayingPlayers() }
    case .resume: queue.async { [weak self] in self?.resumePausedPlayers() }
    case nil: break
    }
  }

  /// Pauses every player that is running *and* playing, recording which ones so
  /// `resumePausedPlayers` can restart just those. Runs on `queue`.
  private nonisolated func pausePlayingPlayers() {
    let paused = MusicPlayer.allCases.filter { $0.pauseIfPlaying() }
    pausedPlayers = paused
    if !paused.isEmpty {
      Self.logger.info("paused for dictation: \(paused.map(\.rawValue).joined(separator: ", "))")
    }
  }

  /// Resumes exactly the players paused on the last recording start, then clears
  /// the record. Runs on `queue`.
  private nonisolated func resumePausedPlayers() {
    for player in pausedPlayers { player.play() }
    pausedPlayers = []
  }
}

/// A music player Blurt can pause during a recording, addressed by its
/// AppleScript application name. Every command guards on `application "…" is
/// running`, which answers without *launching* the app (and needs no automation
/// permission), so Blurt never starts Music or Spotify just because you dictated.
enum MusicPlayer: String, CaseIterable, Sendable {
  case appleMusic = "Music"
  case spotify = "Spotify"

  /// If this player is running and currently playing, pauses it and returns
  /// true; otherwise leaves it untouched and returns false. One script so the
  /// check-and-pause is atomic from Blurt's side. Runs osascript — off-main only.
  nonisolated func pauseIfPlaying() -> Bool {
    let script = """
      if application "\(rawValue)" is running then
        tell application "\(rawValue)"
          if player state is playing then
            pause
            return "1"
          end if
        end tell
      end if
      return "0"
      """
    return runOSAScript(script) == "1"
  }

  /// Resumes this player if it is still running. Runs osascript — off-main only.
  nonisolated func play() {
    _ = runOSAScript("if application \"\(rawValue)\" is running then tell application \"\(rawValue)\" to play")
  }

  /// Runs an AppleScript via `/usr/bin/osascript` and returns its trimmed stdout,
  /// or nil on any failure (permission declined, app mid-quit, script error).
  /// Blocking — callers must be off the main thread.
  private nonisolated func runOSAScript(_ source: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    let stdout = Pipe()
    process.standardOutput = stdout
    // Swallow stderr: a declined Automation prompt or a not-scriptable app is an
    // expected outcome here, not something to surface to the user.
    process.standardError = Pipe()
    do {
      try process.run()
    } catch {
      MediaController.logger.debug("osascript launch failed: \(error.localizedDescription)")
      return nil
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
