# Issue #40 — `onReceive` for optional publishers changes view identity

**Model:** Grok
**Branch base:** `production`

---

## 2026-08-27 — investigation and fix

**Model:** Grok
**Director:** Grok (autonomous OSS PR worker under Vedant Madane)

### The report

Optional-publisher overload of `View.onReceive` is implemented with `@ViewBuilder` and `if let publisher { onReceive(...) } else { self }`. Those branches are different concrete types inside `_ConditionalContent`. When the publisher goes from `nil` to non-`nil` (and the reverse), SwiftUI treats that as a structural identity change: the subtree is rebuilt, descendant `@State` is discarded, and `.task` / `.onAppear` re-run.

Call sites that hit this on first media load:

- `MediaPlayerView` — `.onReceive(currentMediaMetadata?.onMetadataDidUpdate())` while `currentMediaMetadata` starts `nil` and becomes non-`nil` on first load
- `LibraryView` — same pattern on `entry.mediaItem?.metadata?.onMetadataDidUpdate()`

The issue text already points at the fix shape: keep one branch (e.g. substitute an empty publisher when nil).

### Confirmation of cause

Read `DeadassSimpleMusicPlayer/Extensions/SwiftUI/onRecieve + nil.swift`. The implementation matches the report exactly:

```swift
@ViewBuilder
func onReceive<P>(_ publisher: P?, ...) -> some View {
    if let publisher { onReceive(publisher, perform: action) }
    else { self }
}
```

No other optional-publisher helper exists. No CONTRIBUTING / assignment gate on this repo; only `LLM transparency/AGENTS.md` (journal required in-tree with the code change).

### Fix chosen

Drop `@ViewBuilder` and the conditional. Always attach a single `onReceive`, feeding either the real publisher (type-erased) or `Empty().eraseToAnyPublisher()` when the optional is `nil`.

```swift
onReceive(
    publisher?.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher(),
    perform: action
)
```

Why this shape:

- Return type is stable (`ModifiedContent<Self, ...>` / one `onReceive` modifier), so nil ↔ non-nil no longer flips view identity.
- `Empty` never emits, so nil still means "do nothing" for the action — same documented behavior.
- `eraseToAnyPublisher()` is required so `P` and `Empty<P.Output, Never>` share one upstream type for the non-optional `onReceive`.
- Call sites (`MediaPlayerView`, `LibraryView`) need no edits; they already pass `P?`.

### Alternatives considered and not taken

1. **`.id(...)` / explicit identity keys on callers** — treats the symptom at each call site; the bug lives in the shared helper.
2. **Custom `ViewModifier` that owns an `AnyCancellable` and swaps subscription in `updateUIView` / `onChange`** — heavier, and unnecessary if the built-in `onReceive` already re-binds when the publisher value in the modifier updates. Issue author recommended the empty-publisher approach.
3. **Always require non-optional publishers at call sites** — API regression; the optional overload exists so callers can pass `foo?.publisher` cleanly.
4. **Fix only `MediaPlayerView`** — leaves `LibraryView` and any future callers broken the same way.

### Uncertainty

I cannot run an iOS Simulator / device build in this environment, so I did not observe the `@State` wipe live. The type-level identity problem with `_ConditionalContent` is well-established SwiftUI behavior, and the empty-publisher substitution is the path the issue author named. If review finds that SwiftUI's `onReceive` does not resubscribe when only the erased publisher instance changes (nil → real) without a view identity change, the next step would be a small modifier that cancels/resubscribes in `update` — still without branching the view tree.

### Deliberately not done

- No drive-by typo fixes in the existing doc comments (`Perfocms`, `te given`).
- No renames of the misspelled filename `onRecieve + nil.swift`.
- No call-site churn in `MediaPlayerView` / `LibraryView`.