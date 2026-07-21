import Testing

@testable import BlurtEngine

/// Music is paused on the *edges* of the recording phase, not on every phase
/// tick. `AppCoordinator.render` calls the gate on every pipeline phase, so it
/// must fire `.pause` only on the idle→recording edge and `.resume` only on the
/// recording→not-recording edge (any exit — stop, cancel, or failure), staying
/// silent on repeats and on transitions between two non-recording phases. Same
/// edge-detection split as `RecordingCueGate`.
@Suite("MediaPlaybackGate")
struct MediaPlaybackGateTests {
  @Test("entering recording from idle pauses music")
  func pauseOnRisingEdge() {
    var gate = MediaPlaybackGate()
    #expect(gate.action(for: .recording) == .pause)
  }

  @Test("leaving recording resumes music")
  func resumeOnFallingEdge() {
    var gate = MediaPlaybackGate()
    _ = gate.action(for: .recording)
    #expect(gate.action(for: .transcribing) == .resume)
  }

  @Test("a cancelled recording still resumes music")
  func resumeOnCancel() {
    var gate = MediaPlaybackGate()
    _ = gate.action(for: .recording)
    // Escape-cancel moves recording → .cancelled: the music must still come back.
    #expect(gate.action(for: .cancelled) == .resume)
  }

  @Test("a failed recording still resumes music")
  func resumeOnFailure() {
    var gate = MediaPlaybackGate()
    _ = gate.action(for: .recording)
    #expect(gate.action(for: .failed(.audioCaptureFailed(underlying: TestError.boom))) == .resume)
  }

  @Test("staying in recording does not re-pause")
  func noRepeatWhileRecording() {
    var gate = MediaPlaybackGate()
    #expect(gate.action(for: .recording) == .pause)
    #expect(gate.action(for: .recording) == nil)
  }

  @Test("transitions between two non-recording phases are silent")
  func silentBetweenNonRecordingPhases() {
    var gate = MediaPlaybackGate()
    #expect(gate.action(for: .idle) == nil)
    #expect(gate.action(for: .transcribing) == nil)
    #expect(gate.action(for: .injecting) == nil)
    #expect(gate.action(for: .pasted) == nil)
    #expect(gate.action(for: .noTarget) == nil)
  }

  @Test("a full record→stop→record cycle pauses, resumes, pauses again")
  func fullCycle() {
    var gate = MediaPlaybackGate()
    #expect(gate.action(for: .recording) == .pause)
    #expect(gate.action(for: .injecting) == .resume)
    #expect(gate.action(for: .idle) == nil)
    #expect(gate.action(for: .recording) == .pause)
  }

  private enum TestError: Error { case boom }
}
