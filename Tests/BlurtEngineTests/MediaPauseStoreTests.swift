import Foundation
import Testing

@testable import BlurtEngine

@Suite("MediaPauseStore")
struct MediaPauseStoreTests {
  @Test("the pause defaults to on when unset")
  func pauseDefaultsToOn() {
    // Quieting the music you're dictating over is the useful default, and the
    // scripted path can't start anything unbidden, so it's safe to default on.
    #expect(MediaPauseStore(defaults: freshDefaults()).isEnabled)
  }

  @Test("the switch persists and reads back")
  func roundTrips() {
    let defaults = freshDefaults()
    let store = MediaPauseStore(defaults: defaults)
    store.isEnabled = false
    #expect(!MediaPauseStore(defaults: defaults).isEnabled)
    store.isEnabled = true
    #expect(MediaPauseStore(defaults: defaults).isEnabled)
  }

  @Test("an explicit opt-out survives, rather than reading back as the default")
  func optOutIsNotMistakenForUnset() {
    // The presence check is the whole point of the inverted default: writing
    // `false` must not be indistinguishable from never having chosen.
    let defaults = freshDefaults()
    MediaPauseStore(defaults: defaults).isEnabled = false
    #expect(defaults.object(forKey: MediaPauseStore.defaultsKey) as? Bool == false)
    #expect(!MediaPauseStore(defaults: defaults).isEnabled)
  }

  @Test("the scriptable players are the two with a player-state vocabulary")
  func playerRoster() {
    // Each entry costs the user an automation-consent prompt and needs its
    // scripting dictionary verified, so the roster is deliberately closed.
    #expect(MediaPlayerApp.allCases.map(\.applicationName) == ["Spotify", "Music"])
  }
}
