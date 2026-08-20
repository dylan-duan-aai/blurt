import Foundation

/// Persists the "pause music while dictating" switch in `UserDefaults`. On by
/// default; the Settings window's Transcription section flips it. Music bleeding
/// into the microphone is the transcript's problem, not just the listener's.
///
/// Scoped to the players that can be paused *precisely*: `MediaPlayerApp` entries
/// expose `player state`, so a dictation acts only on one that is already playing
/// and resumes only what it paused. Nothing can start unbidden, which is what makes
/// it safe to default on.
///
/// **Browsers are deliberately not covered** — see `MediaPlayerApp` for the three
/// detection routes that were measured and rejected, and for the blind media-key
/// fallback that was built, tested, and removed. Don't add a switch for it back.
///
/// The host reads this at the start of each dictation, so a change applies to the
/// very next one. Same shape as `EnhancedTranscriptsStore` / `DeveloperModeStore`.
public struct MediaPauseStore {
  /// UserDefaults key holding the switch. Public so SwiftUI views can observe it
  /// directly (e.g. `@AppStorage`) and re-render on change.
  public static let defaultsKey = "BlurtPauseMediaWhileDictating"

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Unset means **on** — pausing the music you're talking over is the useful
  /// default, so only an explicit opt-out disables it. That inverts the usual
  /// `bool(forKey:)` shape (which reads a missing key as false), hence the
  /// presence check.
  ///
  /// Public, unlike `EnhancedTranscriptsStore.isEnabled`: the consumer is the
  /// app-side pause controller, not an engine type, so it reads the rule from here
  /// rather than re-deriving "unset means on" against the raw key.
  public var isEnabled: Bool {
    get { defaults.object(forKey: Self.defaultsKey) as? Bool ?? true }
    nonmutating set { defaults.set(newValue, forKey: Self.defaultsKey) }
  }
}

/// A media player Blurt can pause *precisely*, because it exposes playback state
/// over its scripting interface. Listed in the order the pause is attempted.
///
/// Both entries share one vocabulary — `player state`, `pause`, `play` — so a
/// single script shape covers them and only the application name differs.
/// Deliberately a closed enum rather than a configurable list: each addition needs
/// its scripting dictionary verified (Spotify's command codes are
/// `spfyPaus`/`spfyPlay`, Apple Music's `hookPaus`/`hookPlay`, both exposing
/// `player state` as `pPlS`), and each one costs the user another
/// automation-consent prompt.
///
/// ## Why browsers (YouTube) are not here, and shouldn't be added
///
/// Pausing safely requires *knowing* something is playing — otherwise "pause"
/// starts music the user never asked for. No public API answers that for a browser.
/// All three routes were measured on macOS 26 and rejected:
///
/// - **CoreAudio, device level** (`kAudioDevicePropertyDeviceIsRunningSomewhere`):
///   read `true` with the app quit and total silence. Useless.
/// - **CoreAudio, per process** (`kAudioProcessPropertyIsRunningOutput`, public
///   since macOS 14.4): enumerates processes, but reports nothing for *other*
///   processes without system-audio-recording consent — a far heavier permission
///   than the feature is worth, and worse UX than the automation prompt.
/// - **MediaRemote** (`MRMediaRemoteGetNowPlayingApplicationIsPlaying`): private,
///   and now gated — it returned `false` while Spotify was demonstrably playing.
///
/// A blind system play/pause media key (the only thing that *reaches* a browser)
/// was therefore built as an opt-in fallback, tested, and **removed**: with no way
/// to check state it toggles rather than pauses, so it starts playback that wasn't
/// running and desyncs on resume. That was confirmed in real use, not just in
/// theory. Don't reintroduce it without a state source that actually works.
public enum MediaPlayerApp: String, CaseIterable, Sendable {
  /// The name the scripting interface is addressed by — also the name macOS shows
  /// in its "Blurt wants to control …" consent prompt.
  case spotify = "Spotify"
  case appleMusic = "Music"

  public var applicationName: String { rawValue }
}
