# Issue #4 — Metadata doesn't display (correctly) with remote controls

**Status:** Investigating
**Baseline:** 0.0.6 (TestFlight)
**Started:** 2026-08-09

---

## The reported symptoms

From [issue #4](https://github.com/BlueHuskyStudios/DeadassSimpleMediaPlayer/issues/4):

1. On initial connect → "Track 00", "Unknown Artist", "Unknown Album"
2. On track change → track name appears, artist & album still unknown, **track progress gone**
3. Control Center & Live Activities behave the same as Bluetooth

Ky also reports it's inconsistent: the same track may or may not exhibit this.

## What these symptoms tell us before reading any code

- "Unknown Artist"/"Unknown Album"/"Track 00" are the *head unit's* placeholders, not strings this app produces. They mean the corresponding `MPNowPlayingInfoCenter` keys were absent, not wrong.
- Symptom 2 (title arrives, artist/album never do) points at a **partial** dictionary being published, not a total failure — consistent with the app only ever setting *some* keys.
- "Track progress gone" is separate from the metadata keys and points at elapsed-time/duration/rate keys never being published.
- Behaving identically across Bluetooth, Control Center, and Live Activities means the fault is upstream of any one transport: they all read the same `MPNowPlayingInfoCenter.default().nowPlayingInfo`.

## Investigation log

*(appended as I go)*
### 2026-08-09 — Code read complete; five distinct root causes found

All in `UI/MediaPlayerView.swift` unless noted. These are independent bugs that happen to share one symptom cluster; fixing any one alone would leave the issue partly open.

**Cause 1 — `setupNowPlaying()` is never called on track load.**
Its only call site is `.onReceive(currentMediaMetadata?.onMetadataDidUpdate())` (line 136). Nothing calls it from `prepareNewMedia`. So the *only* thing that ever publishes Now Playing info is a metadata-update ping. If a file's metadata resolves before SwiftUI's `onReceive` subscription is live, or the file has no metadata to ping about, **nothing is ever published at all** → head unit shows its own placeholders ("Track 00", "Unknown Artist", "Unknown Album"). This is the *inconsistency* Ky observed: it's a race between metadata-resolution speed and subscription setup, so identical code produces different results per track.

**Cause 2 — artist and album are never set. At all.**
`setupNowPlaying()` writes only `MPMediaItemPropertyTitle` and `MPMediaItemPropertyArtwork`. There is no `MPMediaItemPropertyArtist`, no `MPMediaItemPropertyAlbumTitle`. This explains symptom 2 exactly: once a metadata ping does fire, the title appears (it's set) while artist and album stay "Unknown" forever (they're never set, no matter how many pings arrive). Both `.creator` and `.album` keys already exist in `AsyncMetadata` — they're simply not wired to the Now Playing dictionary.

**Cause 3 — elapsed time, duration, and playback rate are commented out** (lines 447-449). Directly explains "track progress gone." Per WWDC22's media-metadata session, with manual publishing the system *cannot* derive these; the app must supply them. Rate is the load-bearing one: Apple engineers confirm on the developer forums that the system extrapolates elapsed time from the last-provided elapsed time × playback rate, so with no rate published there's nothing to extrapolate from and no progress bar.

**Cause 4 — `setupRemoteTransportControls()` is never called,** so `MPRemoteCommandCenter` play/pause targets are never registered. WWDC22 is explicit that responding to remote commands is required even when publishing metadata manually.

**Cause 5 — the command handlers' return values are inverted, and both always fail.**
```swift
commandCenter.playCommand.addTarget { event in
    isPlaying = true
    return isPlaying ? .commandFailed : .success   // isPlaying is now true → always .commandFailed
}
```
Pause has the same shape and also always returns `.commandFailed`. Dormant today only because cause 4 means they're never registered.

### Secondary findings (not causing #4, noted while reading)

- **Stale-value leakage:** `setupNowPlaying()` starts from `MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]`, i.e. the *previous track's* dictionary. Any key not overwritten survives across a track change. Title is explicitly removed when absent, but artwork isn't — so once #16 lands, a track without art would display the previous track's art. Building fresh each time removes the whole class of bug.
- **`MPMediaItemArtwork` closure is missing `@Sendable`** (line 442). This is the same crash Apple DTS diagnosed for us in July; it's dormant only because `.image` never resolves. It will fire the moment #16 is fixed. Cheap to fix defensively now.
- **`forceUpdateBodge` is written but never read** — its `toggle()` is the last line of `setupNowPlaying`. Possibly vestigial.
- **Don't publish elapsed time from the periodic time observer.** A well-documented failure mode (jubishop's writeup) is that iOS silently throttles/drops frequent `nowPlayingInfo` writes during long background playback, and the staleness only becomes visible on pause. Apple's own engineers say frequent updates aren't necessary. Publish on track change, play/pause, and seek — not on a timer.

### Open design question for Ky

Where should the Now Playing wiring live? It needs metadata (session's domain) *and* live player state (view's domain), and `MediaPlayerView` is about to be substantially rewritten for the pinned-controls redesign. Options: fix in place; or extract a `NowPlayingPublisher` that takes both and survives the overhaul. Asked Ky before proceeding.

---

## The fix (2026-08-09)

**Placement decision:** kept in `MediaPlayerView`, not extracted. There is exactly *one* consumer of Now Playing info today, so extracting a `NowPlayingPublisher` would be abstracting on an instance count of one — and any seam guessed at now would be guessed *before* the pinned-controls redesign reveals where the real seam is. The view legitimately owns both halves this needs (metadata via the session, live rate/elapsed/duration via the player it owns). When the redesign produces a second consumer, the extraction will have evidence behind it.

One file touched: `UI/MediaPlayerView.swift`.

### Changes, mapped to the causes above

| Cause | Fix |
|---|---|
| 1 — never called on load | `setupNowPlaying()` now called from `prepareNewMedia` (both the loaded and the nil branch), from `.onChange(of: isPlaying)`, from the new seek subscription, and from the duration load. The metadata-ping call site stays, but is now a *refinement* rather than the only path. |
| 2 — artist/album never set | Added `MPMediaItemPropertyArtist` (from `.creator`), `MPMediaItemPropertyAlbumTitle` (from `.album`), and `MPMediaItemPropertyAlbumTrackNumber` (from `.trackNumber`). |
| 3 — progress keys commented out | Restored elapsed / rate / duration. Elapsed is guarded on `.isFinite`. |
| 4 — commands never registered | `setupRemoteTransportControls()` now called from `.onAppear`. |
| 5 — handlers always failed | Rewritten to guard on current rate and return `.success` after acting. Added `togglePlayPauseCommand`, which is what headphone buttons and many head units actually send. |

### Supporting changes

- **Dictionary is built fresh** instead of read-modify-write on the existing one, killing stale-value carryover across tracks.
- **`currentItemDuration` loaded explicitly** via `asset.load(.duration)` rather than read from `AVPlayerItem.duration`, which is `.indefinite` until the item is ready — publishing *that* is what yields a track with no progress bar. Guarded against the queue moving on mid-load by an identity check against `player.currentItem`.
- **New `itemTimeJumpSink`** on `AVPlayerItem.timeJumpedNotification` (documented as posted "when a player item's time changes discontinuously"). A seek changes elapsed time without changing rate, so it's invisible to the system's extrapolation until something republishes. Scoped per-item, mirroring the existing `itemEndSink` pattern.
- **Command handlers capture `player`, not `isPlaying`.** They outlive any given value of this view struct, and driving the player directly lets the existing `rate` observer sync `isPlaying` back exactly as an in-app tap would. Registration clears prior targets first, since the command center is a long-lived shared singleton.
- **`@Sendable` added to the artwork closure** (per Ky's "sneak it in if it doesn't balloon" — it was one word).

### Deliberately *not* done

- **No publishing from the periodic time observer.** Apple's engineers state elapsed time needn't be updated frequently, and there's a documented failure mode where iOS silently throttles frequent `nowPlayingInfo` writes during long background playback, going stale invisibly until pause. Publishing on discrete events only is both cheaper and more correct.
- **No next/previous track commands.** Genuinely valuable for head units, and the queue already supports the operations — but mutating `currentPlaylist` (a `@Binding`) from a closure owned by a global singleton is a different design problem than this ticket. Filed as follow-up.
- **`forceUpdateBodge` and the `Task { @MainActor }` wrapper left alone.** Both are Ky's deliberate choices; the bodge is written-but-never-read and *may* be load-bearing for on-screen refresh, so removing it belongs in its own change with a device test.

### Verification checklist for Ky

1. Play a tagged track → Control Center shows title, artist, album, and a moving progress bar.
2. Skip to next track → all four update; nothing carries over from the previous track.
3. Pause → the remote progress bar stops advancing (this is the `rate` fix).
4. Scrub in-app → the remote progress bar jumps to match (this is the `timeJumped` fix).
5. Press play/pause on a Bluetooth head unit or headphone button → playback responds (causes 4 & 5).
6. Play an *untagged* file → title falls back to the filename; artist/album absent rather than stale.
7. Launch with a restored queue and don't press play → Control Center shows the restored track, paused.

**Not compiled here** (no Xcode in this environment). Risk areas if something fails to build: `removeTarget(nil)` overload resolution, and the `(try? metadata(.trackNumber)?.value) ?? nil` double-optional flattening for a non-`String` value type.
