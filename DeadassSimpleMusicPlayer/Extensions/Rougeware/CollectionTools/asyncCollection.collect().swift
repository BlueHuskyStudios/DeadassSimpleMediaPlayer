//
//  asyncCollection.collect().swift
//  Dead-Simple Media Player
//
//  Created by Ky on 2026-06-22.
//

//import AsyncAlgorithms
import Foundation



public extension AsyncSequence where Element: Sendable {
    
    private func _collect() async throws(Failure) -> [Element] {
        var result: [Element] = []
        result.reserveCapacity(10)
        for try await element in self {
            result.append(element)
        }
        return result
    }
    
    
    func collect() async throws(Failure) -> [Element] {
        try await _collect()
    }
    
    
    func collect() async -> [Element]
    where Failure == Never
    {
        await _collect()
    }
}
