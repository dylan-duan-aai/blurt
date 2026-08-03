import Foundation
import Testing

@testable import BlurtEngine

@Suite("SpotifyPauseStore")
struct SpotifyPauseStoreTests {
  @Test("defaults to on when unset")
  func defaultsToOn() {
    // Pausing the music you're dictating over is the useful default, so an unset
    // key must read as enabled — unlike the bool stores that default to off.
    #expect(SpotifyPauseStore(defaults: freshDefaults()).isEnabled)
  }

  @Test("persists and reads back the switch")
  func roundTrips() {
    let defaults = freshDefaults()
    let store = SpotifyPauseStore(defaults: defaults)
    store.isEnabled = false
    #expect(!SpotifyPauseStore(defaults: defaults).isEnabled)
    store.isEnabled = true
    #expect(SpotifyPauseStore(defaults: defaults).isEnabled)
  }

  @Test("an explicit opt-out survives, rather than reading back as the default")
  func optOutIsNotMistakenForUnset() {
    // The presence check is the whole point of the inverted default: writing
    // `false` must not be indistinguishable from never having chosen.
    let defaults = freshDefaults()
    SpotifyPauseStore(defaults: defaults).isEnabled = false
    #expect(defaults.object(forKey: SpotifyPauseStore.defaultsKey) as? Bool == false)
    #expect(!SpotifyPauseStore(defaults: defaults).isEnabled)
  }
}
