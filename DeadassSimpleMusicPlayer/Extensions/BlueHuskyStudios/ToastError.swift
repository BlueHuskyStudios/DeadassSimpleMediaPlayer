//
//  ToastError.swift
//  Dead-Simple Media Player
//
//  Created by Ky on 2026-07-15.
//

import Foundation

import CollectionTools
import Howl



/// An error fit to show in a toast
public struct ToastError: LocalizedError, Identifiable {
    
    public var id = UUID()
    
    /// A brief description of the error, which will be presented to the user
    public var errorDescription: String
    
    /// Optional - a brief suggestion for error recovery, which will be presented to the user
    public var recoverySuggestion: String? = nil
    
    /// The name for the system SF Symbol which will appear on the toast itself
    public var systemImage: String?
}



public extension ToastError {
    init(id: UUID = UUID(),
         errorDescription: String,
         cause: Error,
         systemImage: String?,
    ) {
        self.init(
            id: id,
            errorDescription: errorDescription,
            recoverySuggestion: (cause as? LocalizedError)?.recoverySuggestion,
            systemImage: systemImage,
        )
    }
}



public extension ToastError {
    /// Text which is fit to present to the user in the toast itself
    var textForToast: String {
        if let recoverySuggestion = recoverySuggestion?.nonEmptyOrNil {
            return """
                \(errorDescription)
                \(recoverySuggestion)
                """
        }
        else {
            return errorDescription
        }
    }
}
