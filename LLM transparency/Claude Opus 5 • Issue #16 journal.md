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

## Verification steps

1. Play an audio file with embedded art → art appears where the QuickTime glyph was, and on the Lock Screen / Control Center.
2. **No crash on load.** This is the hypothesis under test; if it crashes, the postponement note was right about something not found here, and the static-initialization theory above is where to look next.
3. Play an audio file *without* art → no art, no leftover art from the previous track.
4. Play a video → video plays, no cover art drawn over it, not even briefly at the start.
5. Skip between an art-having track and an art-less one repeatedly → art appears and disappears correctly each time, never stale.
6. Transport controls still receive taps while art is displayed (the `contentOverlayView` layering claim).
7. PiP still works.

**Not compiled in the environment where this was written** — no Xcode available there. Most likely build friction: whether `NativeImage` needs a different import in these two files than `CrossKitTypes`, and the `(try? metadata(.image)?.value) ?? nil` double-optional flattening.

## Outcome

Verified on device 2026-08-14: art displays on the player and on remote controls. No crash on load — the hypothesis above held, and the `@Sendable` fix from #4 was indeed what had been missing.

One cosmetic artifact observed: because the letterbox area is deliberately unfilled, `AVPlayerViewController`'s own audio-only placeholder (a large circle outline) shows through on either side of square cover art. Not a defect in this change — a consequence of the deliberate choice not to paint that region — but it needs an answer, either here or in the transport-controls redesign that will own that region's appearance.

---

## Follow-up (2026-08-14) — cover art in album icons and history rows

Requested after the first pass shipped: show the art that now decodes in more places than just the player — as an album's icon in the Library instead of the generic disc symbol, and in History rows to make the list skimmable.

### The constraint that shaped the design

Getting art for a row means: resolve a bookmark → enter a security scope → open the asset → search its metadata → decode an image. That's expensive per row, and a History list can be hundreds of rows deep.

Worse, embedded cover art is routinely 3000×3000. Decoding one at full size costs roughly 36 MB of bitmap; a scrolling list decoding several at once could plausibly get the app jetsammed. The already-working `.image` key does exactly that full decode, so reusing it here would have been the obvious wrong move.

So the design goal was never "make it fast" — it was **never decode at full size, and never do the work twice.**

### What was built

**`.imageData` key** (`AsyncMetadata.swift`) — the same identifiers as `.image`, handed back as raw undecoded `Data` via a new `justLoadDataValue` retrieval approach. This exists solely so thumbnails can skip the full decode.

**`NativeImage.thumbnail(fromEncoded:maxPixelSize:)`** (new file) — ImageIO's `CGImageSourceCreateThumbnailAtIndex`, which reads encoded bytes and produces a rendition at the requested size *without* ever materializing the full bitmap. `kCGImageSourceThumbnailMaxPixelSize` is load-bearing: Apple's forums document that omitting it makes ImageIO produce a thumbnail the size of the full image, which would defeat the entire exercise.

Note for whoever touches this file: the private `CGImage` → `NativeImage` bridge is deliberately named `fromCoreGraphics(_:)` rather than `init(cgImage:)`. `UIImage` already declares that exact initializer, so an extension of the same name calls itself — an infinite recursion I wrote and caught before it shipped.

**`ArtworkThumbnailCache`** (new file) — `@MainActor @Observable`, keyed by `MediaReference` (already `Hashable`). Rows read synchronously (getting `nil` at first) and load in a `.task`; Observation redraws them when art lands.

It caches **absence as deliberately as presence.** Files without embedded art are common, and without an `alreadyAttempted` set, every art-less file would redo that entire resolve-and-open chain each time its row scrolled back into view.

For albums it stops at the first track that yields art (`loadFirstAvailableThumbnail(among:)`) rather than opening all of them, since an album's tracks share one cover. Well-formed albums resolve on the first track.

**Ownership:** the cache is `@State` on `LibraryView`, not on `PlayerSession`. It's a drawing convenience, not durable state, and letting it die with the sheet keeps decoded art from accumulating for a screen nobody is looking at. The cost is re-decoding on the next open, which is cheap now that everything cached is thumbnail-sized.

### Judgment calls worth revisiting

- **Only albums get art in the playlist list.** A hand-made playlist has no single cover that speaks for it, so it keeps its generic icon. Picking its first track's art would be arbitrary.
- **History rows reserve their art slot even when empty**, showing a neutral glyph, so the list doesn't jitter as thumbnails resolve during a scroll.
- **44pt × 3 default thumbnail size**, expressed in pixels rather than points because this type has no business reaching for the screen it'll be drawn on. Over-decoding slightly is harmless at this size.

### Verification steps

1. Open Library → Albums: albums with embedded art show it; art-less albums keep the disc icon.
2. Open History: rows show per-file art, with a neutral placeholder where there's none.
3. Scroll a long History list rapidly, then scroll back — art should already be there, with no re-loading and no memory growth.
4. A file that's been moved or deleted still shows its row, just without art.
5. Watch memory while scrolling a history list full of large-art files; this whole design exists to keep that flat.

**Not compiled in the environment where this was written.** Most likely build friction: whether `Image(nativeImage:)` collides with something CrossKitTypes already provides, and whether `some Sequence<MediaReference>` needs spelling differently for the array call sites.

---

## Follow-up 2 (2026-08-14) — app placeholder art, and hiding AVKit's

Two requests which turned out to be one change: use the app's own placeholder art (from the asset catalog) for media without cover art, in both the player and remote controls; and stop `AVPlayerViewController`'s default audio placeholder from showing.

They're connected. The AVKit placeholder was visible *because* the artwork overlay had a transparent background and fitted art doesn't fill a 16:9 region — so AVKit's circle showed through the letterbox. Once every audio track has something deliberate to draw (real art or the app's placeholder), that overlay can be opaque, and AVKit's version is covered rather than fought with.

**`NativeImage.placeholderArt`** (new file) — a single lazily-loaded lookup by asset name, with the name itself as a constant so there's one string to change on a rename.

It is `NativeImage?`, not force-unwrapped, on purpose: the asset didn't exist when this was written, and every caller degrades to its previous behavior if it's missing. That means this compiles and runs correctly both before and after the asset lands, and a future rename that misses this constant produces a missing image rather than a crash.

**Player** — `refreshArtwork()` falls back to `.placeholderArt`. Still only for media with no video track; video continues to own that region outright.

**Remote controls** — `setupNowPlaying()` falls back to it too, but *unconditionally*, including for video. Deliberate difference: Control Center and the Lock Screen have no video to put in that slot, so the app's own art beats an empty square there even when the player itself is showing video.

**Library rows** keep their SF symbols, as requested — an album with no art is better served by a disc glyph than by app branding repeated down a list.

**Opaque overlay** — the artwork image view now has a black background, matching the letterboxing convention the region already uses. Black rather than a theme color because that region's visual identity belongs to the upcoming transport-controls redesign; this is the neutral choice, not a design decision.

### Known cosmetic gap

`currentItemHasVideoTrack` starts as `true`, so for the moment between a track loading and its video-track inspection finishing, no overlay exists — meaning audio can briefly show AVKit's placeholder before ours replaces it.

Fixing it by assuming *audio* first would trade this for a worse artifact: the app's placeholder flashing over the opening frames of real videos. The current bias is the correct one; the gap only closes if the track inspection can be made to complete before the first frame draws.

### Verification steps

1. Play audio without embedded art → the app's placeholder shows in the player and in Control Center; AVKit's circle never appears.
2. Play audio *with* embedded art → real art in both places, no placeholder.
3. Play a video → video plays, no placeholder over it; Control Center shows the app placeholder if the video has no art of its own.
4. With the asset catalog entry missing or misnamed → no crash; behavior falls back to showing nothing, exactly as before this change.
5. Library rows still show SF symbols where art is absent.

---

## Follow-up 3 (2026-08-14) — the thumbnail loading was on the main thread

Reported: opening the Playlists tab froze the app for a second or two while art loaded. Correct diagnosis, and the fault was in the design above rather than in tuning.

### What was actually wrong

`ArtworkThumbnailCache` is `@MainActor`. Everything in its load path that wasn't awaiting something else therefore ran on the main thread: bookmark resolution, security-scope entry, and — worst — the ImageIO decode, which is pure synchronous compute. Once per row.

The irony is worth recording: the whole design above exists to avoid blocking on *memory*, and it blocked on the *thread* instead. Getting the expensive work off the main actor was never addressed, only the size of that work.

A first attempt marked the heavy function `nonisolated static`, which was not enough, for two separate reasons.

**Reason one — `nonisolated` is not the guarantee it looks like.** Under Swift 6.2's approachable-concurrency defaults (SE-0461), a `nonisolated async` function runs on its *caller's* actor rather than hopping to the global pool; `@concurrent` is the new way to say "run away from the caller." This project doesn't enable those settings today (no `SWIFT_APPROACHABLE_CONCURRENCY`, no `SWIFT_DEFAULT_ACTOR_ISOLATION` in the pbxproj), so `nonisolated` does still hop here — but new Xcode 26 projects enable them by default, so relying on it plants a regression that would arrive silently, with no diagnostic, the day that setting changes.

**Reason two — the work re-entered the main actor anyway.** The load went through `MediaItem` → `AsyncMetadata`, and `AsyncMetadata.lazySearch(for:)` installs a `Task { @MainActor … }` per key search to republish its update ping. That's correct for its purpose (SwiftUI subscribers mutate view state, so delivery on main is part of that class's contract) — but it means routing thumbnails through it schedules main-actor work once per row, which is exactly what must not happen for a list.

### The fix

A dedicated `private actor ThumbnailRenderer`, for a reason that survives future compiler changes: actor-isolated work runs on the actor's own executor no matter who calls it. Not a style preference over `nonisolated` — a durability one.

It also **reads the asset directly** rather than through `MediaItem`/`AsyncMetadata`: resolve the bookmark, hold the security scope for just this read, `AVURLAsset.load(.metadata)`, find the artwork item, `load(.dataValue)`, downsample. That path is right for playback — per-key caching, SwiftUI republishing, a scope held for the item's lifetime — but every one of those services is a cost here, and one of them is the bug.

To keep the two paths from drifting, the renderer reuses `AsyncMetadataKey.image.identifiers` rather than restating which identifiers hold artwork. One source of truth, two consumers.

The `.imageData` key and `justLoadDataValue` retrieval approach added in the previous follow-up are **removed**: reading the asset directly made them dead code. They were unmerged additions from the same working session, so this deletes only work that never shipped.

### Also worth knowing

Cancellation now releases its claim in `alreadyAttempted`. Without that, a row scrolling away mid-load would leave the file permanently remembered as "has no art" on the strength of a load that never actually ran.

### Verification steps

1. Open the Playlists tab with several art-bearing albums → no freeze; rows fill in progressively while the list stays scrollable.
2. Scroll a long History list hard during loading → stays responsive throughout.
3. Art still appears correctly in both tabs, and still caches (no reload on a second visit).
4. Scroll a row away *while* its art is loading, then back → it loads rather than being stuck art-less forever.

---

## Follow-up 4 (2026-08-14) — the freeze was SwiftUI re-rendering, not thread-blocking

Follow-up 3 moved the loading off the main actor and **it made no difference to the freeze.** Recording that plainly, because the wrong diagnosis is the more useful part of this entry: "the UI froze during expensive work" is not automatically "the expensive work was on the main thread."

### What was actually wrong

`SavedPlaylistRow` called `artworkCache.firstThumbnail(among:)` **inside its `body`**, reading the cache's `@Observable` state. Two consequences compounded:

1. Every row's body became subscribed to the shared `thumbnails` dictionary, so *any* thumbnail arriving invalidated *every* row that used the cache — not just the row it belonged to.
2. Each of those re-renders re-walked that album's entire track list, and every lookup hashed a `MediaReference` whose `bookmarkData` is kilobytes of `Data`.

Scanning one 43-track album produces dozens of insertions; each insertion re-rendered every row; each row re-hashed every one of its tracks. That work is on the main thread by definition — it's view rendering — which is why moving the *loading* off main changed nothing.

### The fix

Rows now own their art as local `@State`, starting `nil` (so the placeholder renders immediately) and set exactly once when the load returns. Nothing reads the cache from a `body` anymore, so one row's art arriving can no longer invalidate any other row.

That removed the reason for the cache to be observable at all, which simplified it considerably: `ArtworkThumbnailCache` and the separate `ThumbnailRenderer` collapsed into **one `actor`** that simply returns values. It keeps the guarantee from follow-up 3 — actor-isolated work runs on the actor's own executor regardless of caller, which `nonisolated async` will stop guaranteeing under Swift 6.2's approachable-concurrency defaults — while dropping the `@MainActor` half that existed only to feed observation.

Cancellation now also stops an album scan early, so a row scrolled away mid-scan doesn't keep opening the rest of that album's tracks.

### The general lesson worth keeping

Reading shared observable state from inside a `body` couples every reader to every writer. For a per-row resource, that coupling turns N independent loads into N² renders. Local `@State` fed by `.task` keeps each row's update to itself — and, incidentally, is what makes a placeholder possible at all, since the row has something to render before the value exists.

### Verification steps

1. Open the tab showing albums with art → the list appears immediately with placeholder icons, art fills in per row, list stays scrollable throughout.
2. Same for History.
3. Revisit a tab → art is still there, no reloading.
4. Scroll a row away mid-load and back → it loads rather than being stuck without art.
