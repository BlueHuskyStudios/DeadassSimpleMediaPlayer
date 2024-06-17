//
//  AsyncMetadata.swift
//  Dead-Simple Media Player
//
//  Created by Ky on 2024-06-11.
//

import Combine
import Foundation
import AVKit

import LazyContainers
import SimpleLogging



/// An easy-to-use abstraction of fetching metadata from an `AVAsset`
@Observable
public final class AsyncMetadata: @unchecked Sendable { // Pro tip: periodically remove `Sendable` conformance to make sure things are okay. This is only `@unchecked` for `__cache` and `Sendable` for `get(_:)`. We also make Our own checks for race conditions in `__findMetadata(_:)`
    
    /// Aids in determining if a `AsyncMetadata` is unique amongst others
    private let id = UUID()
    
    /// The metadata retrieved from the asset when this was created
    private let assetMetadata: [AVMetadataItem]
    
    /// The metadata that this extracted & parsed from the asset
    private var __cache: [Key<Any>.ID : MetadataSearchResult<any Sendable>] = [:] {
        didSet {
            metadataUpdatePublisher.send(Void())
        }
    }
    
    /// Alerts subscribers when this updates
    private var metadataUpdatePublisher = PassthroughSubject<Void, Never>()
    
    
    init(extractingMetadataFromAsset asset: AVAsset) async throws {
        self.assetMetadata = try await asset.load(.metadata)
    }
}



// MARK: - Observation

public extension AsyncMetadata {
    /// Every time this instance of `AsyncMetadata` starts or concludes a search, this publisher sends a new value.
    ///
    /// The values this publisher sends are only `Void`s; you're expected to then use the ``get`` methods to retrieve any cached value you're interested in
    func onMetadataDidUpdate() -> AnyPublisher<Void, Never> {
        metadataUpdatePublisher.eraseToAnyPublisher()
    }
}



// MARK: - Keys

/// Relates to a metadata value, allowing you to look up a value by its key.
///
/// This also allows one key to map to many different metadata values in order of preference (e.g. common track title vs iTunes song name vs QuickTime user-specified track name vs etc...)
public struct AsyncMetadataKey<Value>: Hashable, Identifiable, Sendable {
    
    /// Uniquely identifies this key amongst all other `AsyncMetadataKey`s
    public let id: String
    
    /// The AVKit metadata identifiers which correspond to this key, sorted with the most-preferred first.
    ///
    /// This allows one key to map to many different metadata values in order of preference (e.g. common track title vs iTunes song name vs QuickTime user-specified track name vs etc...)
    public let identifiers: [AVMetadataIdentifier]
    
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}



public extension AsyncMetadata {
    typealias Key = AsyncMetadataKey
}



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
}



// MARK: - 🌎 API / Retrieving values

public extension AsyncMetadata {
    
    /// Returns the already-found value at the given key, or starts the search and returns `.stillSearching`.
    ///
    /// If no value is cached, then this will spawn off a new `Task` to find the value.
    /// Once that's found (or the search reveals it doesn't exist), that search result will be stored in cache, and further calls to this function will return that search result.
    /// In the meantime, while that search is going on, this will return `.sillSearching`.
    /// When any search completes, the publisher returned by ``onMetadataDidUpdate()`` will be sent a new ping, indicating that you can call this function again to get the result of the search.
    ///
    /// If you just want to call a function and get back your value, see the version of ``get(_:)-6i1hp`` which is `async`.
    ///
    /// - Parameter key: Identifies exactly what metadata you want to retrieve, including its Type
    /// - Returns:       The current state/result of searching for that metadata.
    func get<Value>(_ key: Key<Value>) -> MetadataSearchResult<Value> {
        if let cached = __cache[key.id] {
            return cached.castValue() ?? .notFound
        }
        else {
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.findAndCacheMetadata(key)
                }
                catch {
                    log(error: error)
                }
            }
            
            return .stillSearching
        }
    }
    
    
    /// Returns the already-found value at the given key, or searches for it.
    /// 
    /// If this is the first time this function has been called for this key, it starts a new search, and returns the result to you..
    ///
    /// If this is not the first time this function has been called for this key:
    /// - If a search is currently ongoing, this returns `.stillSearching`
    /// - If a search has concluded, then this returns the result of that previous search: `.found` or `.notFound`
    ///
    /// If you just want to call a synchronous function to get the cached search result or know whether a search is ongoing, see the version of ``get(_:)-2omal`` which is not `async`.
    ///
    /// - Parameter key: Identifies exactly what metadata you want to retrieve, including its Type
    /// - Returns:       The value associated with the given key, or `nil` if that value is not (yet) found
    func get<Value: Sendable>(_ key: Key<Value>) async throws -> Value? {
        let searchResult: MetadataSearchResult<any Sendable>?
        
        if let cached = __cache[key.id] {
            searchResult = cached
        }
        else {
            searchResult = try await self.findAndCacheMetadata(key).erasedToAnyValue()
        }
        
        switch searchResult {
        case .stillSearching:          return nil
        case .found(value: let value): return (value as! Value)
        case .notFound, .none:         return nil
        }
    }
}



// MARK: - Caching & Searching

private extension AsyncMetadata {
    
    /// Finds the metadata associated with the given key, then caches it in the ``__cache``.
    ///
    /// If a search is ongoing, this immediately returns ``MetadataSearchResult.stillSearching``.
    /// If a search has concluded then this saves that result in the cache and returns it.
    ///
    /// - Parameter key: Identifies exactly what metadata you want to retrieve, including its Type
    func findAndCacheMetadata<Value: Sendable>(_ key: Key<Value>)
    async throws -> MetadataSearchResult<Value> {
        let result = try await __findMetadata(key)
        switch result {
        case .stillSearching:
            return .stillSearching
            
        case .found(value: _),
                .notFound:
            __cache[key.id] = result.erasedToAnyValue()
            return result
        }
    }
    
    
    /// Finds the metadata associated with the given key, then caches it in the ``__cache``
    ///
    /// If a search is ongoing, this immediately returns ``MetadataSearchResult.stillSearching``.
    /// **If a search has concluded then this performs the search again.**
    ///
    /// Searching is perfomed on a ``Task`` with `.background` priority
    ///
    /// - Parameter key: Identifies exactly what metadata you want to retrieve, including its Type
    private func __findMetadata<Value: Sendable>(_ key: Key<Value>)
    async throws -> MetadataSearchResult<Value> {
        guard .stillSearching != __cache[key.id] else { return .stillSearching }
        
        return try await Task(priority: .background) {
            guard let desiredMetadata = assetMetadata.first(where: { item in
                guard let identifier = item.identifier else { return false }
                return key.identifiers.contains(identifier)
            })
            else {
                return .notFound
            }
            
            guard let rawValue = try await desiredMetadata.load(.value) else {
                return .notFound
            }
            
            guard let value = rawValue as? Value else {
                log(warning: "Raw value found, but was of type \(type(of: rawValue)), which couldn't be converted to \(Value.self)")
                return .notFound
            }
            
            return .found(value: value)
        }
        .value
    }
}



/// The result of searching for metadata
public enum MetadataSearchResult<Value: Sendable>: Sendable {
    
    /// Some search is still ongoing. Check back later for the result
    case stillSearching
    
    /// A search has concluded; here is the value it found
    /// - Parameter value: The value the search discovered
    case found(value: Value)
    
    /// A search has concluded; no value was found
    case notFound
}



private extension MetadataSearchResult {
    /// Returns a version of this search result where the value remains the same but is re-cast  as any type
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
    /// If not (yet) found, this always succeeds and returns `.stillSearching` or `.notFound`.
    /// If found, this only succeeds if the contaiend value can be safely cast to the given new game; otherwise this returns `nil` instead of a search result.
    ///
    /// - Parameter valueType: _optional_ - The type to cast to. This is implied if possible
    /// - Returns: This search result, with the value cast to a different type if possible
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
    /// Two instances of `AsyncMetadata` are considered equal iff their IDs and caches are both equal
    public static func == (lhs: AsyncMetadata, rhs: AsyncMetadata) -> Bool {
        lhs.id == rhs.id
        && lhs.__cache == rhs.__cache
    }
}



extension MetadataSearchResult: Equatable {
    
    /// Two instances of `MetadataSearchResult` where their `Value`s are _not_ `Equatable`, are considered equal if they're both in the same general state.
    ///
    /// That is to say, if both are `.stillSearching`, if both are `.notFound`, or if both are `.found` regardless of value
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
    
    
    /// Two instances of `MetadataSearchResult` where their `Value`s are `Equatable`, are considered equal if they're both in the same general state and, if that state contains a value, those values are also equal.
    ///
    /// That is to say, if both are `.stillSearching`, if both are `.notFound`, or if both are `.found` where the found values are also equal
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



//// MARK: Dynamic member lookup
//
//public extension AsyncMetadata {
//    subscript<Value>(dynamicMember keyPath: KeyPath<AsyncMetadataKey<Value>.Type, AsyncMetadataKey<Value>>) -> MetadataSearchResult<Value> {
//        let key = AsyncMetadataKey.self[keyPath: keyPath]
//        guard let cache = __cache[key.id] else {
//            Task { [weak self] in
//                guard let self else { return }
//                _ = try await self.findAndCacheMetadata(key, backup: nil)
//            }
//            
//            return .stillSearching
//        }
//    }
//}



// MARK: - extension-style API

public extension AVAsset {
    func asyncMetadata() async throws -> AsyncMetadata {
        try await AsyncMetadata(extractingMetadataFromAsset: self)
    }
}



// MARK: -
extension AVMetadataItem: @unchecked @retroactive Sendable {}
