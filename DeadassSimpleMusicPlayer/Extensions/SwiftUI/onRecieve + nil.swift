//
//  onRecieve + nil.swift
//  Dead-Simple Media Player
//
//  Created by Ky on 2024-07-08.
//

import Combine
import SwiftUI



public extension View {
    
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
