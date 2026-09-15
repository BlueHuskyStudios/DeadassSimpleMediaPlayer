# Claude Fable 5.1 • Issues #60 & #62 journal

## 2026-09-06 — plan: move `AVPlayer` ownership out of `MediaPlayerView`, split `PlayerSession`

**Model:** Claude Fable 5.1 (design discussion earlier in the same session was Claude Sonnet 5; Ky confirmed the model switched before implementation began)
**Director:** Ky

### Where this came from

Not from the automated review. Ky is designing the v1.0 main screen (pinned metadata header, always-visible transport bar, expandable middle section), and wants `MediaPlayerView` to render only the media itself, with metadata and transport controls drawn by sibling views. That immediately raises: where does the play state live so siblings can read it, and how do transport controls command the player?

Read the actual code before answering. `MediaPlayerView` owns the `AVPlayer` as `@State`, and `isPlaying`, `currentMediaMetadata`, `currentArtwork`, `currentItemDuration`, `pipStatus` are all `private @State` inside it. `isPlaying` is fed by `player.publisher(for: \.rate).sink` and then consumed by `.onChange(of: isPlaying)` to command the player — which is #60 in concrete form. `PlayerSession` is `@MainActor @Observable` and already passed into `MediaPlayerView` by reference, so it's the natural home for the facts; but it doesn't own the player, which is why `requestPlaybackOnNextLoad()` / `takePlaybackIntent()` exist (its own doc comment: "the session doesn't own the player — so intent … is parked here … and claimed by whoever performs the load").

Ky chose option (1): move `AVPlayer` ownership into the model layer. That adds a fourth domain to the three #62 already names (now-playing/queue, history, saved-playlist library), so doing the #62 split at the same time is the only way to not make the god-object worse while trying to fix it.

### Decisions settled with Ky before starting

- **`MediaPlayerView` must remain a batteries-included drop-in.** The promise is behavioral (remote commands, Now Playing info, PIP, position restore all just work), not about where the code physically sits. Moving the mechanics into the model makes the promise more robust: batteries no longer depend on a specific View staying alive in the hierarchy.
- **"Batteries included, but replaceable."** Existing `MediaPlayerView(currentPlaylist:session:)` initializer stays for library-integrated use. Add a convenience path that takes just a file and builds a self-contained default session internally. The convenience path gets playback batteries (remote commands, Now Playing info, PIP) but does *not* silently persist history or library to disk — a host app embedding the view for one file shouldn't find it quietly writing to stores it never asked for.
- **Naming family, endorsed by Ky:** a `Store` is durable data with a lifecycle independent of any player instance, and persists itself; an `Engine` is live machinery that exists only while something is loaded, and persists nothing. So: `PlaybackEngine` (owns exactly one `AVPlayer` + everything for it to be a good citizen on its own; knows nothing of playlists), `NowPlayingStore` (queue, current entry, `RepeatMode`; `NowPlayingSnapshot` already names this domain), `HistoryStore`, `PlaylistLibraryStore`. `PlayerSession` stays as the thin facade composing all four — still the one object views hold, so the drop-in surface doesn't change shape.
- **Concrete payoff expected:** `requestPlaybackOnNextLoad()` / `takePlaybackIntent()` should disappear. Once `NowPlayingStore` and `PlaybackEngine` are composed in the same object graph, "change the current entry" and "load it into the player" are no longer separated by a SwiftUI round-trip.
- `Player` (the existing `UIViewControllerRepresentable` around `AVPlayerViewController`) keeps its name and role; it just receives the engine's player instead of the view's.

### Constraints I'm working under

- No Xcode here. Everything below is verified by reading, not compiling. I'll say which is which.
- Snapshot is the `nightly` branch as of 2026-09-04 19:34 Ky's local time, plus the #58 change already made in this session (`RepeatMode + display.swift`, `LibraryView.swift` tail).
- Sandbox clock is unreliable (reported Sep 5, then Sep 7, within one session). Dates here are from Ky's stated current date, 2026-09-06.

### Findings from reading the code (before writing any)

- `PlayerSession`'s own MARK sections already show the seams #62 predicted: "Restoring the previous session", "Loading indication", "Playback events", "Playback intent", "History management", "Saved playlists", "Saving". Persistence is two `JSONDocumentStore`s: `"Player"` (holding the `"Now Playing"` and `"History"` documents) and `"Playlists"` (one document per saved playlist). **I'm keeping that on-disk layout exactly** — no migration, existing users' data keeps loading — which means `NowPlayingStore` and `HistoryStore` each get their own `JSONDocumentStore(subfolder: "Player")`. `JSONDocumentStore` is a value type wrapping a folder URL, so two instances over one folder is fine.
- Cross-store operations exist and have to live in the facade: `saveQueueAsPlaylist` (queue → library), `loadIntoQueue` (library → queue), `replay(_:)` (history → queue), `recordCurrentEntryInHistoryIfNeeded` (queue → history), and `importPlaylist(fromM3U8:)`'s filename-matching pool which reads all three. These stay on `PlayerSession`. Everything single-domain moves down.
- `MediaPlayerView` currently drives everything off `.onChange(of: currentMediaItem)`, where `currentMediaItem` is `currentPlaylist.currentEntry?.mediaItem` from a `Binding<Playlist>` that `ContentView` passes as `$session.queue`. Once the store drives the engine, the view has no use for that binding.
- #65 names the three paradigms: `@Observable` for app state, Combine for bridging `NotificationCenter`/KVO publishers, raw KVO for item readiness (with Ky's comment explaining why). I'm moving all three into `PlaybackEngine` **unchanged** — this PR relocates the AVFoundation adapter, it doesn't re-litigate how it's written. Not touching #65.
- `MediaPlayerView` has two `@State` vars nothing reads: `currentPlaylistItemIndex` and `previousMediaItem` (the latter already marked deprecated). They go, since the struct is being rewritten around them. Not in #66's list; noting here.
- `forceUpdateBodge` is a `@State` toggled after each Now Playing publish, so the view re-renders after metadata resolves (`AsyncMetadata.get` doesn't touch anything Observation tracks). Replacing it with an observable `metadataRevision` on the engine that `metadata(_:)` reads internally — so any `body` that calls `engine.metadata(.title)` picks up the dependency automatically, without a sibling view needing to know the trick.

### Design, concretely

**`PlaybackEngine`** (`@MainActor @Observable final class`, `Media Player/PlaybackEngine.swift`). Owns `let player: AVPlayer`. Observable facts, all `private(set)`: `currentItem: MediaItem?`, `isPlaying`, `currentTime`, `duration`, `artwork`, `hasVideoTrack`, `metadataRevision`. Commands: `load(_:resumingAt:autoplay:)`, `play()`, `pause()`, `togglePlayPause()`, `seek(to:)`, `replayFromStart()`. `isPlaying` is written in exactly one place — the `player.rate` sink — which is what closes #60. Owns the remote command center handlers, Now Playing info publishing, the periodic time observer, the per-item end/time-jump sinks, and the readiness KVO for restored seeks. Reports upward through a small `PlaybackEngineDelegate` protocol (`didFinishPlaying`, `playbackPositionDidChange`, `didPause`) — chosen over closure properties because it parallels `AVPlayerViewControllerDelegate` already in `Player.swift`, is one typed surface rather than three optionals, and makes #28-style testing a matter of a recording delegate. It's not a fourth reactivity paradigm in #65's sense: it's synchronous method dispatch on `MainActor`.

**`NowPlayingStore`** (`Library/NowPlayingStore.swift`): `queue`, `repeatMode`, the debounced/throttled snapshot saving that used to live in `PlayerSession`, restore-from-snapshot, and the restored-seek handoff. Holds the engine and drives it: `queue`'s `didSet` compares the current entry's identity before/after and loads the engine when it changed. `play(entryWithID:)` becomes "set current entry, then `engine.load(…, autoplay: true)`" — no parked intent.

**`HistoryStore`** (`Library/HistoryStore.swift`): `history`, `record(_:displayName:)`, retention, clear, immediate saves.

**`PlaylistLibraryStore`** (`Library/PlaylistLibraryStore.swift`): `savedPlaylists`, `upsert`, `delete`, `importPlaylist(fromExportedJSON:)`, M3U8 parsing (given a filename pool by the caller), `autoGroupAlbums`, `loadAll`.

**`PlayerSession`** stays: composes the four, is the engine's delegate, routes events, keeps the cross-store methods and `loadingMessage`. Public API shape for views: `session.engine`, `session.nowPlaying`, `session.history`, `session.library`, plus the cross-store methods. Call sites like `session.queue` become `session.nowPlaying.queue` — that's the price #62 itself predicted for splitting later.

**`MediaPlayerView`** keeps its current visual output (video/artwork + the title/creator block) so `nightly` doesn't regress while Ky builds the new header; the difference is it reads everything from `session.engine` and owns nothing. Dropping `currentPlaylist:` from its initializer — I told Ky the initializer would stay as-is, but keeping a parameter the view no longer reads would be worse than a one-line call-site change, so I'm flagging the deviation rather than shipping a dead parameter. Adds `init(playing url: URL)` and `init(playing urls: [URL])` which build a `PlayerSession(persisting: false)` (playback batteries on, nothing written to disk) and enqueue on first appearance. That forces `session` to be `@State` rather than `let` so the view-owned session survives re-init.

### What I actually did

New files: `Media Player/PlaybackEngine.swift`, `Library/NowPlayingStore.swift`, `Library/HistoryStore.swift`, `Library/PlaylistLibraryStore.swift`. Rewritten: `Media Player/PlayerSession.swift` (779 → 336 lines; the loading-message list was carried over byte-for-byte via `sed`, not retyped), `UI/MediaPlayerView.swift` (634 → 238). Call-site-only edits: `UI/ContentView.swift`, `UI/LibraryView.swift` (28 lines, every one a `session.x` → `session.store.x` token change plus one comment that became inaccurate), `_demo data/PlayerSession + data.swift` (3 lines).

Code moved into the engine was moved, not rewritten: the rate sink, periodic time observer, interruption observer, per-item end/time-jump sinks, readiness KVO, remote command handlers, and all three Now Playing functions are the view's code with `self` re-homed. Same for the store methods lifted from `PlayerSession`. Where I changed wording it was because a comment referred to "this view" or to the parked-intent flow that no longer exists.

### Things that changed behavior, deliberately

- **Tapping the already-current queue entry now plays it if paused.** Old `play(entryWithID:)` no-op'd for the current entry, and its own doc comment said why: a load wouldn't follow, so the parked intent would be stranded for some unrelated later load to claim. That reason is gone. Without it, "tap the current song → it plays" is the obviously right behavior, so I didn't preserve the no-op. `LibraryView`'s call-site comment updated to match.
- **Remote-control-event registration no longer ends when `MediaPlayerView` disappears.** The old `.onDisappear { endReceivingRemoteControlEvents() }` tied the batteries to the view; the engine now begins on play and ends on unload. This is the "batteries don't depend on a View staying alive" point, made concrete.
- **`MediaPlayerView.init` lost `currentPlaylist:`.** The view has no use for the binding once the store drives the engine. One call site (`ContentView`) changed. I'd said the initializer would stay as-is; a dead parameter would have been worse.
- `loadIfNeeded()` on a non-persisting session now sets and immediately clears `loadingMessage` (three synchronous no-op loads in between) instead of returning before setting it. Nothing can render in that window, but it's a difference, and the old early-return was slightly tidier. Left it because the alternative was exposing an `isPersisting` flag for an invisible effect.

### Things I could not verify (no compiler here)

- That `@Observable` accepts `private var metadataRevision` being read from a `public` method for tracking purposes — I'm confident it does (tracking is dynamic, based on accesses during `body`), but I haven't run it.
- The `MainActor.assumeIsolated { guard let self … }` shape in `installPeriodicTimeObserver`: I moved the existing pattern and swapped `[session]` for `[weak self]`. `PlaybackEngine` is `@MainActor`-isolated and therefore implicitly `Sendable`, so a weak capture in the `@Sendable` block should be fine.
- `Task { [self] in … }` in a `@MainActor` class method — the original was in a struct where implicit `self` is allowed; classes need the explicit capture. Added it; haven't compiled it.
- Whether Xcode's synchronized folder groups pick up four new files without project edits. They should; that's what synchronized groups are for.

### Not done, on purpose

- No unit tests. This refactor is what makes #28 *possible* (a `PlaybackEngine` with a recording delegate is trivially testable), but writing them is a separate PR against #28, and I'd want the design to survive Ky's review first.
- `MediaPlayerView` still draws the title/creator block. Ky is building the real header; deleting the old one before the new one exists would regress `nightly`. Once the pinned header lands, `metadataView`, `titleView`, and `creatorText` can be removed from this file wholesale.
- #65 untouched. The Combine/KVO/`@Observable` mix inside the engine is exactly what it was inside the view.
