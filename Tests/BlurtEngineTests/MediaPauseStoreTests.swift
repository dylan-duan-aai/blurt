import Foundation
import Testing

@testable import BlurtEngine

@Suite("MediaPauseStore")
struct MediaPauseStoreTests {
  @Test("defaults to on when unset")
  func defaultsToOn() {
    // Quieting the music you're dictating over is the useful default, and the
    // scripted path can't start anything unbidden, so it's safe to default on.
    #expect(MediaPauseStore(defaults: freshDefaults()).isEnabled)
  }

  /// The store is read-only, so what it has to agree with is the slot the Settings
  /// toggle writes through `@AppStorage` — which is what this seeds, rather than a
  /// setter no production code calls.
  @Test("reads back the switch the Settings toggle writes")
  func readsBackTheToggledSlot() {
    let defaults = freshDefaults()
    let store = MediaPauseStore(defaults: defaults)
    defaults.set(false, forKey: MediaPauseStore.defaultsKey)
    #expect(!store.isEnabled)
    // Same instance: the store reads through to `defaults` on every access, which is
    // what lets the pause controller pick a change up on the very next dictation.
    defaults.set(true, forKey: MediaPauseStore.defaultsKey)
    #expect(store.isEnabled)
  }

  @Test("an explicit opt-out is distinguishable from unset")
  func optOutIsNotMistakenForUnset() {
    // The presence check is the whole point of the inverted default: writing `false`
    // must not read back the same as never having chosen.
    let defaults = freshDefaults()
    defaults.set(false, forKey: MediaPauseStore.defaultsKey)
    #expect(defaults.object(forKey: MediaPauseStore.defaultsKey) as? Bool == false)
    #expect(!MediaPauseStore(defaults: defaults).isEnabled)
  }

  @Test("the scriptable players are the two with a player-state vocabulary")
  func playerRoster() {
    // Each entry costs the user an automation-consent prompt and needs its scripting
    // dictionary verified, so the roster is deliberately closed. Browsers are
    // excluded on purpose — see MediaPlayerApp's doc.
    #expect(MediaPlayerApp.allCases.map(\.applicationName) == ["Spotify", "Music"])
  }
}
