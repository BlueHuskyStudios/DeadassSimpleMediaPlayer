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

---

## Follow-up (2026-08-10) — metadata flashed while scrubbing from Control Center

**Reported:** with the fix in place, scrubbing via Control Center or the Dynamic Island made title/artist blank out and reappear.

**Cause: metadata throttling, self-inflicted.** `setupNowPlaying()` rebuilt and republished the *entire* dictionary from the `timeJumped` subscription. A Control Center scrub fires that notification rapidly, so the title was being rewritten dozens of times per second with an identical value. iOS rate-limits Now Playing **metadata** updates specifically — it logs "Application exceeded audio metadata throttle limit," and an Apple engineer has confirmed on the developer forums that title updates in particular are throttled. A throttled title write is *dropped*, not deferred, which is exactly a blank-then-reappear flash.

Worth noting the irony: the "don't publish on a timer" note earlier in this journal was about the periodic time observer, and I then reintroduced the same hazard through the seek path.

**Fix:** split the two kinds of update, which is a truer model anyway — a seek changes position, not metadata.

- `setupNowPlaying()` — full publish. Called on track change, metadata update, and duration resolution (all genuinely infrequent, once-ish per track).
- `updateNowPlayingPlaybackPosition()` — reads the published dictionary and rewrites *only* elapsed time and rate. Called on seek and on play/pause.
- `addPlaybackPositionInfo(to:)` — shared by both, so a full publish and a position-only update can't disagree about where playback is.

**Watch for, if flashing persists in any form:** `AsyncMetadata.onMetadataDidUpdate()` pings once per key reaching a terminal state, so a track with title + creator + album + trackNumber + image could trigger up to ~5 full publishes as it loads. That's per-track rather than per-scrub-tick, so it should stay well under the throttle, but if it doesn't, the next step is to skip a full publish when the metadata values haven't actually changed.

**Observation at the time, since superseded by Round 2:** `changePlaybackPositionCommand` was not registered, yet Control Center scrubbing worked and produced `timeJumped` notifications — presumably via `AVPlayerViewController`'s own Now Playing integration. Left alone deliberately then, on the grounds that registering a competing handler for something already working risks double-seeking. Round 2 found that this same AVKit integration was the remaining bug, disabled it, and registered the command — which also dissolves the double-seek concern, since there's no longer a competing handler to collide with.

---

## Round 2 (2026-08-10) — the metadata "flash", actual root cause

**Reconciling this with the Follow-up above:** the throttling analysis identified a real hazard and the split it produced (`setupNowPlaying` vs. `updateNowPlayingPlaybackPosition`) is correct architecture worth keeping on its own merits — a seek changes position, not metadata, and rewriting the whole dictionary dozens of times per scrub was genuinely wasteful. But it did not fully fix the flash, because it addressed *our* write frequency while a second, entirely separate writer was also in play. Both changes are in the code; this section is the one that explains the symptom.


**Ky's report after testing round 1:** artist, album, and progress all now appear correctly (causes 2, 3, and 5 confirmed fixed on device). But when scrubbing from Control Center or the Dynamic Island, and when pausing, the title and artist briefly vanish and are replaced by the app's own name ("Dead Simple"), then come back.

**What the app name tells us.** iOS displays the app's name when `nowPlayingInfo` contains no title. So something was *replacing* our dictionary with a minimal one, and then our `setupNowPlaying()` was writing ours back a beat later. Two writers, not one.

**Root cause:** `AVPlayerViewController.updatesNowPlayingInfoCenter` defaults to `true`, meaning AVKit publishes its *own* Now Playing info whenever playback state changes. It knows nothing about this app's `AsyncMetadata`, so its version has no artist/album and no title we'd recognize — hence the app-name fallback. Every pause and every scrub triggers an AVKit write, immediately followed by ours: a visible flash.

Notably this was *latent before round 1* — with our publishing broken, AVKit's minimal dictionary was all there was, which is very likely the original "Track 00 / Unknown Artist / Unknown Album" on Bluetooth connect. So this isn't a regression introduced by the fix; it's the last layer of the same bug, only visible once ours started working.

**Fix (2 files):**
- `UI/Player.swift` — `vc.updatesNowPlayingInfoCenter = false` in `makeUIViewController`. This app publishes strictly richer info than AVKit can derive, so ours should be the only writer.
- `UI/MediaPlayerView.swift` — registered `changePlaybackPositionCommand`. **This pairing is not optional:** disabling AVKit's Now Playing integration also gives up whatever remote-scrub handling it was providing, so without this the Control Center scrubber would move and snap back. The handler seeks the player, which fires `timeJumpedNotification`, which republishes the corrected position through the path already built in round 1.

**Principle worth remembering:** owning the Now Playing dictionary and owning the remote commands are a package deal. Take one, take both.

### Additional verification for Ky

8. Scrub from Control Center → position changes and *sticks* (doesn't snap back), and metadata never flashes to the app name.
9. Pause from anywhere → metadata stays put, only the play/pause glyph changes.
10. Confirm PiP and AirPlay still behave, since `updatesNowPlayingInfoCenter` sits on the same controller.
