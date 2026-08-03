/// Which record cue chime a pipeline-phase change should fire, if any. A pure
/// projection of `PipelinePhase` transitions — owned here (rather than in the
/// AppKit `CueSoundPlayer`) so the edge logic is unit-testable, the same split
/// as `OverlayUIState` and `MenuBarStatus`. The AppKit side just plays whichever
/// sound this resolves to.
public enum RecordingCue: Equatable, Sendable {
  case start
  case stop
}

/// Which record cue chime fires on each recording edge. The host calls
/// `cue(for:)` on *every* pipeline phase, so the gate fires `.start` only on the
/// idle→recording edge and `.stop` only on the recording→not-recording edge,
/// staying silent while a phase repeats and across transitions between two
/// non-recording phases. Value type holding a single edge bit; the host owns one
/// instance for the app's lifetime.
///
/// The edge detection itself is `RecordingEdgeDetector` — shared with the media
/// pause/resume, which keys off the identical transitions. This type is the chime
/// half of that: which sound, on which edge.
public struct RecordingCueGate: Sendable {
  private var edges = RecordingEdgeDetector()

  public init() {}

  /// The cue to play for `phase`, or `nil` when the recording edge didn't move.
  public mutating func cue(for phase: PipelinePhase) -> RecordingCue? {
    switch edges.edge(for: phase) {
    case .began: return .start
    case .ended: return .stop
    case nil: return nil
    }
  }
}
