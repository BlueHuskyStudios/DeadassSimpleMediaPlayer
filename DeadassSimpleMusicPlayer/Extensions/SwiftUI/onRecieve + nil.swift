//
//  onRecieve + nil.swift
//  Dead-Simple Media Player
//
//  Created by Ky on 2024-07-08.
//

import Combine
import SwiftUI



public extension View {
    
    /// Perfocms the given action whenever receiving some output from the given publisher, if the publisher is non-`nil`.
    ///
    /// If the publisher is `nil`, then this function does nothing.
    /// If it isn't `nil`, then this works identically to the one which takes a non-`Optional` publisher.
    ///
    /// The given publisher's output is passed to the input of the given action. If the publisher sends `Void`s, then te given action need not take any input.
    ///
    /// - Parameters:
    ///   - publisher: The publisher to listen to
    ///   - action:    The action to take when receiving any values from the given publisher
    @ViewBuilder
    func onReceive<P>(_ publisher: P?, perform action: @escaping (P.Output) -> Void) -> some View
    where P: Publisher,
          P.Failure == Never
    {
        if let publisher {
            onReceive(publisher, perform: action)
        }
        else {
            self
        }
    }
}
