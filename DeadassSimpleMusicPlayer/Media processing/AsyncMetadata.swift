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



public typealias Metadata = Sendable & Equatable



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
    /// Every time this instance concludes a search, this publisher sends a new `Void`. Use the ``get`` methods to retrieve actual values once a
    /// ping arrives.
    ///
    /// Delivery is guaranteed to occur on the main actor. SwiftUI consumers
    /// using `.onReceive` and `.sink` blocks that mutate view state can rely
    /// on this without applying a `.receive(on:)` of their own.
    func onMetadataDidUpdate() -> AnyPublisher<Void, Never> {
        metadataUpdatePublisher.receive(on: RunLoop.main).eraseToAnyPublisher()
    }
}



// MARK: - Keys

/// Relates to a metadata value, allowing you to look up a value by its key.
///
/// This also allows one key to map to many different metadata values in order of preference (e.g. common track title vs iTunes song name vs QuickTime user-specified track name vs etc...)
public struct AsyncMetadataKey<Value: Sendable>: Identifiable, Sendable {
    
    /// Uniquely identifies this key amongst all other `AsyncMetadataKey`s
    public let id: Id
    
    /// The loading/parsing approach that will be used when retrieving metadata associated with this key
    public var retrievalApproach: AsyncMetadata.RetrievalApproach<Value> = .justLoadValue
    
    /// The AVKit metadata identifiers which correspond to this key, sorted with the most-preferred first.
    ///
    /// This allows one key to map to many different metadata values in order of preference (e.g. common track title vs iTunes song name vs QuickTime user-specified track name vs etc...)
    public let identifiers: [AVMetadataIdentifier]
}



public typealias AsyncMetadataKeyId = SpecialString<AsyncMetadataIdSpecialType>
public struct AsyncMetadataIdSpecialType: SpecialStringSpecialType, Sendable {}



public extension AsyncMetadataKey {
    typealias Id = AsyncMetadataKeyId
}



extension AsyncMetadataKey: CustomDebugStringConvertible {
    public var debugDescription: String {
        id.withoutTypeSafety()
    }
}



public extension AsyncMetadata {
    typealias Key = AsyncMetadataKey
}



public extension AsyncMetadata {
    
    /// How to retrieve the metadata from the system
    enum RetrievalApproach<Value: Sendable>: Sendable {
        
        /// Just directly loads the value with ``AVMetadataItem.load(_:)`` ``AVPartialAsyncProperty.value`` and attempts to cast it to `Value`
        case justLoadValue
        
        /// Loads the value with ``AVMetadataItem.load(_:)`` ``AVPartialAsyncProperty.value``, and then sends that value to the given function, which might return `nil` if conversion failed
        case parseLoadedValue(initializer: @Sendable (Any) -> Value?)
        
        /// Loads the value with ``AVMetadataItem.load(_:)`` ``AVPartialAsyncProperty.dataValue``, and then sends that `Data` to the given function, which might return `nil` if conversion failed
        case loadDataValue(initializer: @Sendable (Data) -> Value?)
    }
}



public extension AsyncMetadata.RetrievalApproach where Value == Int {
    static let stringToInt: Self = parseLoadedValue { unparsedData in
        guard let string = unparsedData as? String else { return nil }
        let filtered = string
            .prefix(while: { "/" != $0 })
            .filter { CharacterSet.decimalDigits.contains($0.unicodeScalars.first!) }
        
        return Int(filtered)
    }
}



public extension AsyncMetadata.RetrievalApproach where Value == DateComponents {
    static let stringToDateComponents: Self = parseLoadedValue { unparsedData in
        guard let string = unparsedData as? String else { return nil }
        if nil != string.firstMatch(of: /^\d{4}$/) { return DateComponents(year: Int(string)) }
        return try? DateComponents(string, strategy: .iso8601)
    }
}



public extension AsyncMetadata.RetrievalApproach where Value == UIImage {
    static let dataToUiImage: Self = loadDataValue { unparsedData in
        UIImage(data: unparsedData)
    }
}


// MARK: Default keys

public extension AsyncMetadataKey where Value == String {
    /// The media's title (or name)
    static let title = Self(id: "title", identifiers: [
        .quickTimeUserDataTrackName,
        .identifier3GPUserDataTitle,
        .commonIdentifierTitle,
        .iTunesMetadataSongName,
        .id3MetadataTitleDescription,
        .quickTimeMetadataTitle,
        .icyMetadataStreamTitle,
    ])
    
    /// The media's creator (or author, or artist, or band, or composer, or...)
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
    
    /// The album (or collection, or compilation) the media belongs to.
    static let album = Self(id: "album", identifiers: [
        .commonIdentifierAlbumName,
        .iTunesMetadataAlbum,
        .id3MetadataAlbumTitle,
        .quickTimeMetadataAlbum,
        .quickTimeUserDataAlbum,
    ])
}



public extension AsyncMetadataKey where Value == Int {
    
    /// Which disc the track is on within its album (e.g. `3` from a tag written as "3" or "3/4").
    static let discNumber = Self(id: "discNumber", retrievalApproach: .stringToInt, identifiers: [
        .iTunesMetadataDiscNumber,
    ])
    
    /// The track's position within its album (e.g. `3` from a tag written as "3" or "3/12").
    static let trackNumber = Self(id: "trackNumber", retrievalApproach: .stringToInt, identifiers: [
        .id3MetadataTrackNumber,
        .init("id3/TRCK"), // Why isn't this in Apple's presets 😭
        .iTunesMetadataTrackNumber,
    ])
}



public extension AsyncMetadataKey where Value == NativeImage {
    
    /// The media's cover art (or thumbnail, or attached picture).
    static let image = Self(id: "image", /*retrievalApproach: .dataToUiImage,*/ identifiers: [ // TODO: This is where we will fix #16, but uncommenting this right now causes crash-on-load. Postponing for its own branch – Ky, 2026-08-07
        .identifier3GPUserDataThumbnail,
        .iTunesMetadataCoverArt,
        .id3MetadataAttachedPicture,
    ])
}



public extension AsyncMetadataKey where Value == DateComponents {
    
    /// The date when this was originally published, regardless of when the file was created.
    ///
    /// This may be as coarse as just the year component, which is why this decodes as components instead of a `Date` value.
    static let publishedDate = Self(id: "publishedDate", retrievalApproach: .stringToDateComponents, identifiers: [
        .commonIdentifierCreationDate,
        .iTunesMetadataReleaseDate,
        .id3MetadataRecordingDates,
        
        .identifier3GPUserDataRecordingYear,
        .quickTimeMetadataYear,
        .id3MetadataOriginalReleaseYear,
        .id3MetadataYear,
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
        
        let search = CachedSearch { [weak self] in
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
            }
        
        
        // Observe the search's completion (terminal state) and republish a
        // single Void ping on the main actor.
        //
        // Pinned to `@MainActor` for two reasons: (1) `metadataUpdatePublisher`
        // is consumed by SwiftUI subscribers that mutate view state, so
        // delivery on main is part of this class's contract; (2) the
        // observation Task is unstructured and detached from any caller
        // isolation, so we have to be explicit about where the ping lands
        // rather than inheriting it from whoever called `lazySearch(for:)`.
        //
        // The Task captures `search` strongly. That's fine — the binding is
        // a value type whose internal storage is reference-typed, so the
        // copy held here shares state with the copy stored in `__cache`,
        // and the Task is short-lived (one await, then a send, then done).
        Task { @MainActor [weak self] in
            do {
                _ = try await search.wrappedValue
            }
            catch {
                log(error: error)
            }
            self?.metadataUpdatePublisher.send(())
        }
        
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
        let uuid = "\(key): \(UUID())"
        print(uuid, "Entering"); defer { print(uuid, "Exiting") }
        
        let theSearchForDesiredMetadata = assetMetadata.first(where: { item in
            guard let identifier = item.identifier else { return false }
            return key.identifiers.contains(identifier)
        })
        print(uuid, "nil != \(key.id):", nil != theSearchForDesiredMetadata)
        guard let desiredMetadata = theSearchForDesiredMetadata else {
            print(uuid, "Desired metadata not found")
            print(uuid, "nil == \(key.id):", nil == theSearchForDesiredMetadata)
            return nil
        }
        
        let typedValue: Value
        
        switch key.retrievalApproach {
        case .justLoadValue:
            print(uuid, "Getting rawValue")
            guard let rawValue = try await desiredMetadata.load(.value) else {
                log(warning: "Raw value not found for \(key.id)")
                return nil
            }
            
            print(uuid, "Getting typedValue")
            guard let _typedValue = rawValue as? Value else {
                log(warning: "Raw value found for \(key.id), but was of type \(type(of: rawValue)), which couldn't be converted to \(Value.self)")
                return nil
            }
            typedValue = _typedValue
            
        case .loadDataValue(let initializer):
            print(uuid, "Getting dataValue")
            guard let dataValue: Data = try await desiredMetadata.load(.dataValue) else {
                log(warning: "Data value not found for \(key.id)")
                return nil
            }
            
            print(uuid, "Initializing typedValue")
            guard let _typedValue = initializer(dataValue) else {
                log(warning: "Data value found for \(key.id), but couldn' convert it to \(Value.self)")
                return nil
            }
            typedValue = _typedValue
            
        case .parseLoadedValue(initializer: let initializer):
            print(uuid, "Loading rawValue")
            guard let rawValue = try await desiredMetadata.load(.value) else {
                log(warning: "Unparsed value not found for \(key.id)")
                return nil
            }
            
            print(uuid, "Parsing rawValue")
            guard let _typedValue = initializer(rawValue) else {
                log(warning: "Raw value found for \(key.id), but was of type \(type(of: rawValue)), which couldn't be converted to \(Value.self)")
                return nil
            }
            typedValue = _typedValue
        }
        
        print(uuid, "Returning typedValue")
        return typedValue as any Sendable
    }
}



internal extension AsyncMetadata {
    
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
    typealias CachedSearch = ThrowingAsyncLazy<(any Sendable)?, any Error>
}



// MARK: - Search result

/// The result of searching for metadata.
public typealias MetadataSearchResult<Value: Metadata> = FailableLoadingState<Value, NotFound>



public extension MetadataSearchResult where Failure == NotFound {
    
    /// Some search is still ongoing. Check back later for the result.
    @available(*, renamed: "loading")
    static var stillSearching: Self {
        .loading
    }
    
    
    /// A search has concluded; here is the value it found.
    /// - Parameter value: The value the search discovered.
    @available(*, deprecated, renamed: "success(_:)", message:  "Use .success(value) instead")
    static func found(value: Success) -> Self {
        .success(value)
    }
    
    
    /// A search has concluded; no value was found.
    @available(*, renamed: "failure(_:)", message: "Use .failure(NotFound()) instead")
    static var notFound: Self {
        .failure(Failure())
    }
}



// MARK: - Bridge from loading state to public result enum

internal extension MetadataSearchResult where Failure == NotFound {
    
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
    init(loadingState: AsyncMetadata.CachedSearch.LoadingState) {
        switch loadingState {
        case .notStarted, .loading:
            self = .stillSearching
            
        case .success(nil):
            self = .notFound
            
        case .success(.some(let erased)):
            if let typed = erased as? Success {
                self = .success(typed)
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



public extension LoadingState {
    
    /// Attempts to cast this result's contained value to the given type.
    ///
    /// If not (yet) found, this always succeeds and returns
    /// `.stillSearching` or `.notFound`. If found, this only succeeds if
    /// the contained value can be safely cast to the given type; otherwise
    /// this returns `nil` instead of a search result.
    func castValue<OldValue, NewValue>(to valueType: NewValue.Type = NewValue.self) -> LoadingState<NewValue?>?
    where Value == Optional<OldValue>
    {
        switch self {
        case .notStarted:   return .notStarted
        case .loading:      return .loading
        case .success(nil): return .success(nil)
            
        case .success(let value):
            if let newValue = value as? NewValue {
                return .success(newValue)
            }
            else {
                return nil
            }
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



// MARK: - extension-style API

public extension AVAsset {
    func asyncMetadata() async throws -> AsyncMetadata {
        try await AsyncMetadata(extractingMetadataFromAsset: self)
    }
}
