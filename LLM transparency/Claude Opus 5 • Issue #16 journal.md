# Issue #16 — Album art isn't displayed anywhere

**Model:** Claude Opus 5, directed by Ky
**Branch base:** `nightly`, after the #4 merge
**Started:** 2026-08-14 (checked via `date`)

---

## The report

Songs with album art should display that art on the player and on remote controls. It appears in neither.

## First finding: this is two separate problems wearing one symptom

Read the whole artwork path before touching anything. The two surfaces fail for entirely different reasons, and fixing one does nothing for the other.

**Remote controls** — the publishing code already exists and is correct. `setupNowPlaying()` reads `metadata(.image)` and builds an `MPMediaItemArtwork` from it. It never runs, because `metadata(.image)` never resolves a value. So this surface needs no new code at all; it needs the metadata key to start working.

**On-screen player** — there is no artwork display code. Not broken, absent. `AVPlayerViewController` shows the QuickTime glyph for audio-only media because nothing is drawn over it. This surface needs to be built.

## Second finding: the crash Ky hit may already be fixed

The `.image` key currently has its retrieval approach commented out, with a note (2026-08-07) saying uncommenting causes crash-on-load, postponed to its own branch.

I believe that crash was the `MPMediaItemArtwork` request-handler crash Apple DTS diagnosed for this project back in July: the closure passed to `MPMediaItemArtwork(boundsSize:)` is retained by the system and invoked on an arbitrary thread, so without `@Sendable` it inherits MainActor isolation and traps in `dispatch_assert_queue_fail`.

Timeline supports this:
- 2026-08-07 — Ky comments out `.dataToUiImage`, observing crash-on-load.
- Later, in the #4 work — `@Sendable` added to that exact closure, and merged.

The crash was only ever reachable when `.image` resolved a real image, which is precisely what uncommenting does. So the fix for it landed *after* the observation that led to the postponement. **Hypothesis: uncommenting now simply works.** Ky's device build is the test; I can't run one.

Recording this as a hypothesis rather than a conclusion because I can't reproduce the original crash to confirm that's what it was. If a crash-on-load still occurs after this change, that hypothesis is wrong and the real cause is still unfound — the next place I'd look is static-initialization order between the two constrained-extension `static let`s (`AsyncMetadataKey<NativeImage>.image` referencing `RetrievalApproach<…>.dataToUiImage`), since Swift initializes those lazily via `swift_once` and this project has a documented history of compiler-level surprises.

## Third finding: the commented-out code would break the macOS door

`dataToUiImage` was written as `extension AsyncMetadata.RetrievalApproach where Value == UIImage`, using `UIImage(data:)`.

`UIImage` doesn't exist on macOS. Every other image-typed thing in this file goes through `NativeImage` (CrossKitTypes), which is `UIImage` on iOS and `NSImage` on macOS — and the `.image` key itself is already declared `where Value == NativeImage`. On iOS the two constraints resolve to the same type, so this compiles today and would silently fail to compile the day the project targets macOS.

Since `NSImage` also has `init?(data:)`, writing it against `NativeImage` costs nothing and keeps the door open. Renaming to `dataToNativeImage` accordingly.

---

## Changes

### 1. `Media processing/AsyncMetadata.swift` — enable artwork retrieval

Uncommented the retrieval approach, rewritten against `NativeImage`, and wired to the `.image` key.

- Removed the commented-out `dataToUiImage` and the `// TODO` postponement note, replacing them with a working `dataToNativeImage`.
- `.image` now passes `retrievalApproach: .dataToNativeImage`.

This alone should fix the **remote controls** half, since `setupNowPlaying()` was already waiting on this value.

### 2. `UI/Player.swift` — a surface to draw art on

`Player` gains an `artwork: NativeImage?` parameter, hosted in `AVPlayerViewController.contentOverlayView` — the layer between the video content and the playback controls, so art can never cover the transport controls nor swallow touches meant for them.

Reconciliation (`syncArtwork(in:)`) runs in `updateUIViewController` and is idempotent: it creates the image view on first need, updates it when the image changes, and removes it when art goes away. The view is located by tag rather than held in a property, because a `UIViewControllerRepresentable` is a value type recreated on every update and can't retain it.

Aspect-fit, no background fill. Letterboxing shows whatever `AVPlayerViewController` draws behind it rather than a black box of my choosing — the visual identity of that region belongs to the upcoming transport-controls redesign, not to this bugfix.

### 3. `UI/MediaPlayerView.swift` — deciding when art appears

Two pieces of state: `currentArtwork`, and `currentItemHasVideoTrack` which gates it.

**Art only shows for media with no video track of its own.** A music video should show its video, not its cover art. The check is `asset.loadTracks(withMediaType: .video)`, and it's guarded by an identity check against `player.currentItem` in case the queue advanced while it loaded.

**`currentItemHasVideoTrack` defaults to `true`**, i.e. assumes video until proven otherwise. Backwards-seeming, but deliberate: the alternative default would briefly permit art during the window before inspection finishes, making cover art flash over the opening frames of an actual video. Assuming video costs an audio track a few frames of nothing; assuming audio costs a video a visible artifact.

`refreshArtwork()` is called from both the track inspection and the metadata-update hook, because either can be the last to arrive — the image search and the track load race, and whichever finishes second is the one that completes the picture.

## Things deliberately not done

- **No blurred full-bleed backdrop.** Discussed with Ky earlier as a possible direction, but it belongs to the pinned-controls redesign, where Reduce Transparency and Reduce Motion also need answering. This ticket restores the missing art; it doesn't design around it.
- **No artwork in the Library's queue/album rows.** Would be nice, but it's a feature, not this bug, and it needs a thumbnail-caching story before a long queue starts decoding dozens of full-size images.
- **No caching or downsampling.** Cover art is decoded per track and held only for the current one. If large embedded art turns out to cost noticeable memory, downsampling at decode time is the fix — deliberately not pre-optimized.

## For Ky to verify on device

1. Play an audio file with embedded art → art appears where the QuickTime glyph was, and on the Lock Screen / Control Center.
2. **No crash on load.** This is the hypothesis under test; if it crashes, the postponement note was right about something I haven't found, and the static-initialization theory above is where to look next.
3. Play an audio file *without* art → no art, no leftover art from the previous track.
4. Play a video → video plays, no cover art drawn over it, not even briefly at the start.
5. Skip between an art-having track and an art-less one repeatedly → art appears and disappears correctly each time, never stale.
6. Confirm transport controls still receive taps while art is displayed (the `contentOverlayView` layering claim).
7. Confirm PiP still works.

**Not compiled here** — no Xcode in this environment. Most likely build friction: whether `NativeImage` needs a different import in these two files than `CrossKitTypes`, and the `(try? metadata(.image)?.value) ?? nil` double-optional flattening.
