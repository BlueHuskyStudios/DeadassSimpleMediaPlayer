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
    
    private let id = UUID()
    
    private let assetMetadata: [AVMetadataItem]
    
    private var __cache: [Key<Any>.ID : MetadataSearchResult<any Sendable>] = [:] {
        didSet {
            publisher.send(Void())
        }
    }
    
    private var publisher = PassthroughSubject<Void, Never>()
    
    
    init(extractingMetadataFromAsset asset: AVAsset) async throws {
        self.assetMetadata = try await asset.load(.metadata)
    }
}



public extension AsyncMetadata {
    func onMetadataDidUpdate() -> AnyPublisher<Void, Never> {
        publisher.eraseToAnyPublisher()
    }
}



public struct AsyncMetadataKey<Value>: Hashable, Identifiable, Sendable {
    public let id: String
    public let identifiers: [AVMetadataIdentifier]
    
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}



public extension AsyncMetadata {
    typealias Key = AsyncMetadataKey
}



public extension AsyncMetadataKey where Value == String {
    static let title = Self(id: "title", identifiers: [
        .quickTimeUserDataTrackName,
        .identifier3GPUserDataTitle,
        .commonIdentifierTitle,
        .iTunesMetadataSongName,
        .id3MetadataTitleDescription,
        .quickTimeMetadataTitle,
        .icyMetadataStreamTitle,
    ])
    
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



public extension AsyncMetadata {
    
    /// Returns the already-found value at the given key, or starts the search and returns `.stillSearching`
    ///
    /// - Parameter key: <#key description#>
    /// - Returns: <#description#>
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
    /// - Parameter key: The key to the metadata value you want
    /// - Returns: <#description#>
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



private extension AsyncMetadata {
    
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



public enum MetadataSearchResult<Value: Sendable>: Sendable {
    case stillSearching
    case found(value: Value)
    case notFound
}



private extension MetadataSearchResult {
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
    
    
    /// Attempts to cast this result's contained value to the given type. If not (yet) found, this always succeeds; if found, this only succeeds if the contaiend value can be safely cast to the given new game
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
    public static func == (lhs: AsyncMetadata, rhs: AsyncMetadata) -> Bool {
        lhs.id == rhs.id
        && lhs.__cache == rhs.__cache
    }
}



extension MetadataSearchResult: Equatable {
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
extension AVMetadataItem: @unchecked Sendable {}
