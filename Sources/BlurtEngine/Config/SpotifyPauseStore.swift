import Foundation

/// Persists the "pause Spotify while dictating" switch in `UserDefaults`. On by
/// default; the Settings window's Transcription section flips it. While on, a
/// dictation that starts while Spotify is playing pauses it for the duration and
/// resumes it when the recording stops — music bleeding into the microphone is
/// the transcript's problem, not just the listener's.
///
/// The host reads this at the start of each dictation, so a change applies to the
/// very next one. Deliberately named for Spotify rather than "music": the control
/// path is Spotify's own scripting interface, so it does nothing for Apple Music
/// or a browser tab, and a generic name would promise otherwise.
/// Same shape as `EnhancedTranscriptsStore` / `DeveloperModeStore`.
public struct SpotifyPauseStore {
  /// UserDefaults key holding the switch. Public so SwiftUI views can observe it
  /// directly (e.g. `@AppStorage`) and re-render on change.
  public static let defaultsKey = "BlurtPauseSpotifyWhileDictating"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Unset means **on** — pausing the music you're talking over is the useful
  /// default, so only an explicit opt-out disables it. That inverts the usual
  /// `bool(forKey:)` shape (which reads a missing key as false), hence the
  /// presence check.
  ///
  /// Public, unlike `EnhancedTranscriptsStore.isEnabled`: the consumer here is
  /// the app-side pause controller, not an engine type, so it reads the rule from
  /// here rather than re-deriving "unset means on" against the raw key.
  public var isEnabled: Bool {
    get { defaults.object(forKey: Self.defaultsKey) as? Bool ?? true }
    nonmutating set { defaults.set(newValue, forKey: Self.defaultsKey) }
  }
}
