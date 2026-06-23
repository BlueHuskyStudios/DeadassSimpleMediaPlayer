//
//  AsyncMetadata.swift
//  Dead-Simple Media Player
//
//  Created by Ky on 2024-06-11.
//

import Combine
import Foundation
import AVKit

import ConcurrencyTools
import CrossKitTypes
import LazyContainers
import SimpleLogging
import SpecialString



/// An easy-to-use abstraction of fetching metadata from an `AVAsset`.
///
/// Each metadata key has its own lazy search, owned by a `ThrowingAsyncBinding`
/// stored in the per-key cache. The binding handles the loading-state machine,
/// caches both successful and failed outcomes, and fires a change callback at
/// every state transition; this class is responsible only for installing
/// those bindings on first request and for republishing their terminal
/// transitions as a single `Void` change ping on
/// ``onMetadataDidUpdate()``.
#if swift(>=6)
@Observable
#endif
public final class AsyncMetadata: @unchecked Sendable {
    // `@unchecked` covers the cache-dictionary insert in `lazySearch(for:)`,
    // which is racy in the same benign way as the previous implementation:
    // two concurrent first-lookups for the same key may each construct a
    // binding, with the loser orphaned but producing no incorrect result.
    // Fixing this would require a mutex around the insert; see the closing
    // comment in `lazySearch(for:)`.

    /// Aids in determining if an `AsyncMetadata` is unique amongst others.
    private let id = UUID()

    /// The metadata retrieved from the asset at creation time. Immutable for
    /// the lifetime of this instance; per-value extraction is deferred.
    private let assetMetadata: [AVMetadataItem]

    /// Per-key lazy searches. Each entry encapsulates its own loading state
    /// (`.notStarted` / `.loading` / `.success` / `.failure`) and caches the
    /// outcome forever after first resolution.
    private var __cache: [AsyncMetadataKeyId: CachedSearch] = [:]

    /// Republishes a `Void` whenever any cached search transitions into a
    /// terminal state. Backs the public ``onMetadataDidUpdate()`` contract.
    private let metadataUpdatePublisher = PassthroughSubject<Void, Never>()


    /// Creates an `AsyncMetadata` by loading the top-level metadata array
    /// from `asset`.
    ///
    /// Only the asset's `.metadata` property is loaded eagerly; per-value
    /// extraction is deferred until the relevant key is requested.
    init(extractingMetadataFromAsset asset: AVAsset) async throws {
        self.assetMetadata = try await asset.load(.metadata)
    }
}



public extension AsyncMetadata {
    /// Convenience initializer that wraps `url` in an `AVURLAsset` and
    /// extracts metadata from it.
    convenience init(extractingMetadataFrom url: URL) async throws {
        try await self.init(extractingMetadataFromAsset: AVURLAsset(url: url))
    }
}



// MARK: - Observation

public extension AsyncMetadata {
    /// Every time this instance concludes a search, this publisher sends a
    /// new `Void`. Use the ``get`` methods to retrieve actual values once a
    /// ping arrives.
    ///
    /// Delivery is guaranteed to occur on the main actor. SwiftUI consumers
    /// using `.onReceive` and `.sink` blocks that mutate view state can rely
    /// on this without applying a `.receive(on:)` of their own.
    func onMetadataDidUpdate() -> AnyPublisher<Void, Never> {
        metadataUpdatePublisher.eraseToAnyPublisher()
    }
}



// MARK: - Keys

/// Relates to a metadata value, allowing you to look up a value by its key.
///
/// This also allows one key to map to many different metadata values in
/// order of preference (e.g. common track title vs iTunes song name vs
/// QuickTime user-specified track name vs ...).
public struct AsyncMetadataKey<Value: Sendable>: Identifiable, Sendable {

    /// Uniquely identifies this key amongst all other `AsyncMetadataKey`s.
    public let id: Id

    /// The AVKit metadata identifiers which correspond to this key, sorted
    /// with the most-preferred first.
    ///
    /// This allows one key to map to many different metadata values in
    /// order of preference (e.g. common track title vs iTunes song name vs
    /// QuickTime user-specified track name vs ...).
    public let identifiers: [AVMetadataIdentifier]

    public let retrievalApproach: AsyncMetadata.RetrievalApproach<Value> = .justLoadValue
}



public typealias AsyncMetadataKeyId = SpecialString<AsyncMetadataIdSpecialType>
public struct AsyncMetadataIdSpecialType: SpecialStringSpecialType, Sendable {}



public extension AsyncMetadataKey {
    typealias Id = AsyncMetadataKeyId
}



public extension AsyncMetadata {
    typealias Key = AsyncMetadataKey
}



public extension AsyncMetadata {

    /// How to retrieve the metadata from the system.
    enum RetrievalApproach<Value: Sendable>: Sendable {

        /// Just directly loads the value with `AVMetadataItem.load(_:)`
        /// `AVPartialAsyncProperty.value` and attempts to cast it to `Value`.
        case justLoadValue

        /// Loads the value with `AVMetadataItem.load(_:)`
        /// `AVPartialAsyncProperty.dataValue`, and then sends that `Data` to
        /// the given function.
        case loadDataValue(initializer: @Sendable (Data) -> Value)

//        case loadSomethingElse(AVPartialAsyncProperty)
    }
}


// MARK: Default keys

public extension AsyncMetadataKey where Value == String {
    /// The media's title (or name).
    static let title = Self(id: "title", identifiers: [
        .quickTimeUserDataTrackName,
        .identifier3GPUserDataTitle,
        .commonIdentifierTitle,
        .iTunesMetadataSongName,
        .id3MetadataTitleDescription,
        .quickTimeMetadataTitle,
        .icyMetadataStreamTitle,
    ])

    /// The media's creator (or author, or artist, or band, or composer, or ...).
    static let creator = Self(id: "creator", identifiers: [
        .identifier3GPUserDataAuthor,

        .commonIdentifierArtist,
        .commonIdentifierAuthor,
        .iTunesMetadataArtist,
        .id3MetadataBand,
        .iTunesMetadataAuthor,
        .iTunesMetadataAlbumArtist,
        .quickTimeMetadataArtist,
        .quickTimeMetadataAuthor,

        .identifier3GPUserDataPerformer,
        .id3MetadataLyricist,
        .iTunesMetadataSoloist,

        .quickTimeMetadataArranger,
        .quickTimeUserDataComposer,
        .quickTimeMetadataComposer,
        .id3MetadataComposer,
        .iTunesMetadataComposer,
        .iTunesMetadataArranger,
        .id3MetadataConductor,
        .iTunesMetadataDirector,

        .id3MetadataOriginalArtist,
        .id3MetadataPublisher,
    ])
}



public extension AsyncMetadataKey where Value == NativeImage? {

    /// The media's cover art (or thumbnail, or attached picture).
    static let image = Self(id: "image", identifiers: [
        .identifier3GPUserDataThumbnail,
        .iTunesMetadataCoverArt,
        .id3MetadataAttachedPicture,
    ])
}



// MARK: - 🌎 API / Retrieving values

public extension AsyncMetadata {

    /// Returns the already-found value at the given key, or starts the
    /// search and returns ``MetadataSearchResult/stillSearching``.
    ///
    /// Spawning of the search task is delegated to the underlying
    /// `ThrowingAsyncBinding`: reading its `loadingState` is what triggers
    /// loading. The ``onMetadataDidUpdate()`` publisher will ping when the
    /// search reaches a terminal state.
    ///
    /// If the search has previously failed, this returns
    /// ``MetadataSearchResult/notFound`` (the error is logged once when it
    /// first occurs). To surface the underlying error to the caller, use the
    /// `async throws` overload instead.
    ///
    /// - Parameter key: Identifies exactly what metadata to retrieve,
    ///                  including its `Value` type.
    /// - Returns: The current state/result of searching for that metadata.
    func get<Value: Sendable>(_ key: Key<Value>) -> MetadataSearchResult<Value> {
        let search = lazySearch(for: key)
        return MetadataSearchResult(loadingState: search.loadingState)
    }


    /// Returns the already-found value at the given key, or awaits the
    /// search.
    ///
    /// If this is the first time this function has been called for this key,
    /// it starts a new search and awaits its completion. Subsequent calls
    /// return (or re-throw) the cached outcome immediately.
    ///
    /// > Important: Errors are cached. Once a search for a given key throws,
    /// > every subsequent call for that key will re-throw the same error
    /// > rather than retrying. This is a deliberate change from the previous
    /// > implementation, which silently swallowed errors and retried
    /// > forever; the assumption is that AVFoundation extraction failures
    /// > are properties of the asset, not transient conditions.
    ///
    /// - Parameter key: Identifies exactly what metadata to retrieve,
    ///                  including its `Value` type.
    /// - Returns: The value associated with the given key, or `nil` if no
    ///            such value was found in the asset.
    /// - Throws: Any error encountered during the search.
    func get<Value: Sendable>(_ key: Key<Value>) async throws -> Value? {
        let search = lazySearch(for: key)
        let erased = try await search.wrappedValue
        return erased as? Value
    }
}



// MARK: - Caching & Searching

private extension AsyncMetadata {

    /// Returns the existing lazy search for `key`, installing a new one if
    /// none exists.
    ///
    /// On installation, an `onDidChange` callback is attached that
    /// republishes the search's terminal transitions through
    /// ``metadataUpdatePublisher`` and logs any failure exactly once at the
    /// moment of transition (rather than repeatedly on every subsequent
    /// `get`).
    ///
    /// The dictionary insert at the end of this method is not protected by a
    /// mutex; under a true race between two callers for the same key, both
    /// will construct a binding and one will overwrite the other. The
    /// orphaned binding is benign — it produces no incorrect result, just a
    /// wasted background `Task`. If that ever becomes unacceptable, wrap the
    /// read-or-install in a `Mutex.run { ... }` block using the same `Mutex`
    /// type the `ThrowingAsyncBinding` implementation already relies on.
    func lazySearch<Value: Sendable>(for key: Key<Value>) -> CachedSearch {
        if let existing = __cache[key.id] {
            return existing
        }

        let search = CachedSearch(
            { [weak self] in
                guard let self else {
                    // The owning AsyncMetadata has been deallocated;
                    // there's nothing meaningful to return. The binding
                    // caches this failure forever, which is fine — anything
                    // observing it has nothing to observe with.
                    throw CancellationError()
                }
                return try await Self.performSearch(
                    in: self.assetMetadata,
                    matching: key
                )
            },
            set: { @MainActor [weak self] newState in
                // The publisher fires from whatever cooperative executor the
                // binding's loader Task happened to land on. Consumers of
                // `onMetadataDidUpdate()` in this codebase (e.g.
                // SwiftUI's `.onReceive`, view-state mutations) are
                // MainActor-isolated, so a background-thread send traps via
                // `swift_task_checkIsolatedSwift`. Restoring main-actor
                // delivery here matches the original contract from before
                // the migration to `ThrowingAsyncBinding` and keeps the
                // burden off every subscription site.
//                await MainActor.run { [weak self] in
                    switch newState {
                    case .failure(let error):
                        log(error: error)
                        self?.metadataUpdatePublisher.send(())
                        
                    case .success:
                        self?.metadataUpdatePublisher.send(())
                        
                    case .notStarted, .loading:
                        break
                    }
//                }
            }
        )

        __cache[key.id] = search
        return search
    }


    /// Performs the actual AVFoundation lookup for a given key.
    ///
    /// Pure (no `self`) so the closure stored in the binding can capture
    /// only what it actually needs — `assetMetadata` and `key` — rather than
    /// taking ownership of the enclosing `AsyncMetadata` instance.
    ///
    /// Returns the typed value erased to `any Sendable`, or `nil` if either
    /// no matching metadata item exists in the asset or its loaded value
    /// could not be cast to `Value`. A cast failure is logged as a warning
    /// because it likely indicates a key/identifier mismatch rather than a
    /// legitimate "not found".
    static func performSearch<Value: Sendable>(
        in assetMetadata: [AVMetadataItem],
        matching key: Key<Value>
    ) async throws -> (any Sendable)? {
        guard let desiredMetadata = assetMetadata.first(where: { item in
            guard let identifier = item.identifier else { return false }
            return key.identifiers.contains(identifier)
        })
        else {
            return nil
        }

        guard let rawValue = try await desiredMetadata.load(.value) else {
            return nil
        }

        guard let typedValue = rawValue as? Value else {
            log(warning: "Raw value found, but was of type \(type(of: rawValue)), which couldn't be converted to \(Value.self)")
            return nil
        }

        return typedValue as any Sendable
    }
    
    
    /// Type-erased per-key search.
    ///
    /// `Value` is erased to `(any Sendable)?` — `nil` represents
    /// "concluded, not found" — and re-cast to the key's concrete type at
    /// the public API boundary. This matches the value-erasure pattern the
    /// previous implementation used for `__cache`.
    ///
    /// `Failure` is left as `any Error` because the underlying source of
    /// errors (`AVMetadataItem.load(.value)`) doesn't promise a more specific
    /// error type, and `any Error` satisfies the binding's
    /// `Failure: Sendable` constraint via `Error`'s inherited `Sendable`
    /// conformance.
    typealias CachedSearch = ThrowingAsyncBinding<(any Sendable)?, any Error>
}



// MARK: - Bridge from loading state to public result enum

internal extension MetadataSearchResult {

    /// Bridges a `ThrowingAsyncBinding`'s loading state into the public
    /// result enum.
    ///
    /// Errors collapse to ``MetadataSearchResult/notFound`` on the
    /// synchronous path; the async `get(_:)` overload surfaces them as
    /// throws instead. A cast failure from the erased `(any Sendable)?`
    /// payload to `Value` also collapses to `.notFound` — this can only
    /// happen if a key is registered for an identifier whose loaded value
    /// type doesn't match `Value`, which is a programmer error rather than
    /// a runtime condition the caller can act on.
    init(loadingState: FailableLoadingState<(any Sendable)?, any Error>) {
        switch loadingState {
        case .notStarted, .loading:
            self = .stillSearching

        case .success(nil):
            self = .notFound

        case .success(.some(let erased)):
            if let typed = erased as? Value {
                self = .found(value: typed)
            }
            else {
                self = .notFound
            }

        case .failure:
            // The error was already logged when it first occurred (in the
            // binding's `onDidChange` callback). Don't re-log on every read.
            self = .notFound
        }
    }
}



// MARK: - Search result

/// The result of searching for metadata.
public enum MetadataSearchResult<Value: Sendable>: Sendable {

    /// Some search is still ongoing. Check back later for the result.
    case stillSearching

    /// A search has concluded; here is the value it found.
    /// - Parameter value: The value the search discovered.
    case found(value: Value)

    /// A search has concluded; no value was found.
    case notFound
}



public extension MetadataSearchResult {
    var value: Value? {
        switch self {
        case .stillSearching,
             .notFound:
            nil

        case .found(let value):
            value
        }
    }
}



internal extension MetadataSearchResult {
    /// Returns a version of this search result where the value remains the
    /// same but is re-cast as `any Sendable`.
    func erasedToAnyValue() -> MetadataSearchResult<any Sendable> {
        switch self {
        case .stillSearching:
                .stillSearching

        case .found(let value):
                .found(value: value)

        case .notFound:
                .notFound
        }
    }


    /// Attempts to cast this result's contained value to the given type.
    ///
    /// If not (yet) found, this always succeeds and returns
    /// `.stillSearching` or `.notFound`. If found, this only succeeds if
    /// the contained value can be safely cast to the given type; otherwise
    /// this returns `nil` instead of a search result.
    func castValue<NewValue>(to valueType: NewValue.Type = NewValue.self) -> MetadataSearchResult<NewValue>? {
        switch self {
        case .stillSearching:
            return .stillSearching

        case .found(value: let value):
            if let newValue = value as? NewValue {
                return .found(value: newValue)
            }
            else {
                return nil
            }

        case .notFound:
            return .notFound
        }
    }
}



// MARK: - Conformance

// MARK: Equatable

extension AsyncMetadata: Equatable {
    /// Two instances of `AsyncMetadata` are considered equal iff their IDs
    /// are equal — which, since `id` is a freshly-generated UUID per
    /// instance, reduces to identity equality.
    ///
    /// The previous implementation also compared `__cache` for value
    /// equality, but the cache now stores `ThrowingAsyncBinding` values
    /// which are not `Equatable`. In practice this stricter comparison was
    /// only ever true when both instances were the same instance anyway, so
    /// the looser definition matches every case the strict one used to
    /// satisfy.
    public static func == (lhs: AsyncMetadata, rhs: AsyncMetadata) -> Bool {
        lhs.id == rhs.id
    }


    public static func ~= (lhs: AsyncMetadata, rhs: AsyncMetadata) -> Bool {
        lhs.id == rhs.id
    }
}



extension AsyncMetadataKey: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}



extension AsyncMetadataKey: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}



extension MetadataSearchResult: Equatable {

    /// Two instances of `MetadataSearchResult` where their `Value`s are
    /// _not_ `Equatable`, are considered equal if they're both in the same
    /// general state.
    ///
    /// That is to say, if both are `.stillSearching`, if both are
    /// `.notFound`, or if both are `.found` regardless of value.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.stillSearching, .stillSearching),
             (.found, .found),
             (.notFound, .notFound):
            return true

        case (.stillSearching, _),
             (.found, _),
             (.notFound, _):
            return false
        }
    }


    /// Two instances of `MetadataSearchResult` where their `Value`s are
    /// `Equatable`, are considered equal if they're both in the same
    /// general state and, if that state contains a value, those values are
    /// also equal.
    ///
    /// That is to say, if both are `.stillSearching`, if both are
    /// `.notFound`, or if both are `.found` where the found values are
    /// also equal.
    public static func == (lhs: Self, rhs: Self) -> Bool
    where Value: Equatable
    {
        switch (lhs, rhs) {
        case (.found(value: let lhsValue), .found(value: let rhsValue)):
            return lhsValue == rhsValue

        case (.stillSearching, .stillSearching),
             (.notFound, .notFound):
            return true

        case (.stillSearching, _),
             (.found, _),
             (.notFound, _):
            return false
        }
    }
}



// MARK: - extension-style API

public extension AVAsset {
    func asyncMetadata() async throws -> AsyncMetadata {
        try await AsyncMetadata(extractingMetadataFromAsset: self)
    }
}
