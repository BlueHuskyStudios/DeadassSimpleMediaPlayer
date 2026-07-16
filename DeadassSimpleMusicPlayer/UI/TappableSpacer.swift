//
//  TappableSpacer.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2026-07-15.
//

import SwiftUI



/// A spacer which still allows the user to tap the space it fills
public struct TappableSpacer: View {
    
    private let minLength: CGFloat
    private let fallbackColor: Color
    
    init(minLength: CGFloat? = nil, fallbackColor: Color? = nil) {
        self.minLength = minLength ?? 12
        self.fallbackColor = fallbackColor ?? Color(.systemGroupedBackground)
    }
    
    
    public var body: some View {
        Rectangle()
            .fill(fallbackColor.opacity(0.001))
            .layoutPriority(-1)
    }
}



#Preview {
    TappableSpacer()
}
