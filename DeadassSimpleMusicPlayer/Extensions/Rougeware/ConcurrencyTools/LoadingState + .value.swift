//
//  LoadingState + .value.swift
//  Dead-Simple Media Player
//
//  Created by Ky on 2026-07-01.
//

import ConcurrencyTools



public extension LoadingState {
    var value: Value? {
        get {
            switch self {
            case .notStarted,
                    .loading:
                nil
                
            case .success(let value):
                value
            }
        }
    }
}



public extension FailableLoadingState {
    var value: Success? {
        get throws {
            switch self {
            case .notStarted,
                    .loading:
                return nil
                
            case .success(let value):
                return value
                
            case .failure(let error):
                throw error
            }
        }
    }
}
