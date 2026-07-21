/// Whether crossing a recording edge should pause or resume the user's music.
/// A pure projection of `PipelinePhase` transitions — the mirror of
/// `RecordingCueGate` — so the edge logic is unit-testable here and the AppKit
/// media controller just runs whichever action this resolves to.
public enum MediaPlaybackAction: Equatable, Sendable {
  case pause
  case resume
}

/// Edge-detector deciding when to pause the user's music for a dictation and
/// hand it back afterward. The host calls `action(for:)` on *every* pipeline
/// phase, so the gate fires `.pause` only on the idle→recording edge and
/// `.resume` only on the recording→not-recording edge, staying silent while a
/// phase repeats and across transitions between two non-recording phases.
///
/// `.resume` fires for *any* exit from recording — a normal stop, a cancel
/// (Escape), or a capture failure — because in each case the recording is over
/// and the music should come back. The controller resumes only what it actually
/// paused, so a spurious resume with nothing paused is a no-op. Value type
/// holding a single edge bit; the host owns one instance for the app's lifetime.
public struct MediaPlaybackGate: Sendable {
  private var wasRecording = false

  public init() {}

  /// The media action for `phase`, or `nil` when the recording edge didn't move.
  public mutating func action(for phase: PipelinePhase) -> MediaPlaybackAction? {
    let isRecording = phase == .recording
    defer { wasRecording = isRecording }
    switch (wasRecording, isRecording) {
    case (false, true): return .pause
    case (true, false): return .resume
    default: return nil
    }
  }
}
