import Foundation

/// Persists the two "quiet the music while dictating" switches in `UserDefaults`.
/// The Settings window's Transcription section flips them. Music bleeding into the
/// microphone is the transcript's problem, not just the listener's.
///
/// Two switches rather than one, because the two mechanisms have genuinely
/// different risk profiles and only the user can judge the second:
///
/// - `isEnabled` (**on** by default) drives the *precise* path. The scriptable
///   players (`MediaPlayerApp`) expose `player state`, so we act only on one that
///   is already playing and resume only what we paused. Nothing can start
///   unbidden, which is what makes it safe to default on.
/// - `includesOtherPlayers` (**off** by default) drives the *imprecise* path: a
///   system play/pause media key, the only thing that reaches a browser playing
///   YouTube. It is a stateless toggle, and macOS offers no public way to ask
///   whether a browser is playing — the device-level CoreAudio flag reads busy
///   even in silence, per-process output state needs system-audio-recording
///   consent, and MediaRemote is gated for unentitled apps. So with nothing
///   actually playing it can *start* a player, and it desyncs if the user touches
///   playback mid-dictation. Off by default so that failure mode is opted into
///   rather than imposed.
///
/// The host reads both at the start of each dictation, so a change applies to the
/// very next one. Same shape as `EnhancedTranscriptsStore` / `DeveloperModeStore`.
public struct MediaPauseStore {
  /// UserDefaults keys. Public so SwiftUI views can observe them directly (e.g.
  /// `@AppStorage`) and re-render on change.
  public static let defaultsKey = "BlurtPauseMediaWhileDictating"
  public static let otherPlayersDefaultsKey = "BlurtPauseOtherMediaWhileDictating"

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

  /// Unset means **off** — the plain `bool(forKey:)` shape. This switch can
  /// misfire (see the type doc), so it must never end up on by accident.
  public var includesOtherPlayers: Bool {
    get { defaults.bool(forKey: Self.otherPlayersDefaultsKey) }
    nonmutating set { defaults.set(newValue, forKey: Self.otherPlayersDefaultsKey) }
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
public enum MediaPlayerApp: String, CaseIterable, Sendable {
  /// The name the scripting interface is addressed by — also the name macOS shows
  /// in its "Blurt wants to control …" consent prompt.
  case spotify = "Spotify"
  case appleMusic = "Music"

  public var applicationName: String { rawValue }
}
