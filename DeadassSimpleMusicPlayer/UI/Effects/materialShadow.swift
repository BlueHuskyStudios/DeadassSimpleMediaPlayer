//
//  materialShadow.swift
//  Dead-Simple Media Player
//
//  Created by Ky on 2026-09-06.
//

import SwiftUI

import BasicMathTools



/// Each case of this enum is a specific elevation step in Material Design
public enum MaterialShadowElevation: UInt8 {
    case z1 = 1
    case z2 = 2
    case z3 = 3
    case z4 = 4
    case z6 = 6
    case z8 = 8
    case z9 = 9
    case z12 = 12
    case z16 = 16
    case z24 = 24
}



public extension View {
    func materialShadow(_ elevation: MaterialShadowElevation, lightFrom lightingDirection: Angle) -> some View {
        let yOffsetMod: (CGFloat) -> CGFloat
        
        // First-pass simple version: If the lighting direction is upside-down, just invert the default y offset
        if (90...270).contains(lightingDirection.degrees.wrapped(within: 0..<360)) {
            yOffsetMod = { -$0 }
        }
        else {
            yOffsetMod = { $0 }
        }
        
        return self
            .shadow(color: .init(white: 0, opacity: elevation.umbra.alpha),
                    radius: .init(elevation.umbra.radius),
                    y: yOffsetMod(elevation.umbra.yOffset))
            .shadow(color: .init(white: 0, opacity: elevation.penumbra.alpha),
                    radius: .init(elevation.penumbra.radius),
                    y: yOffsetMod(elevation.penumbra.yOffset))
            .shadow(color: .init(white: 0, opacity: elevation.ambient.alpha),
                    radius: .init(elevation.ambient.radius),
                    y: yOffsetMod(elevation.ambient.yOffset))
    }
}



private extension MaterialShadowElevation {
    
    struct ShadowComponentMetrics {
        let yOffset: CGFloat
        let radius: CGFloat
        let spread: CGFloat
        let alpha: CGFloat
    }
    
    
    var umbra: ShadowComponentMetrics {
        switch self {
        case .z1: return .init(yOffset: 0, radius: 2, spread: 0, alpha: 0.14)
        case .z2: return .init(yOffset: 0, radius: 4, spread: 0, alpha: 0.14)
        case .z3: return .init(yOffset: 3, radius: 3, spread: 0, alpha: 0.14)
        case .z4: return .init(yOffset: 2, radius: 4, spread: 0, alpha: 0.14)
        case .z6: return .init(yOffset: 6, radius: 10, spread: 0, alpha: 0.14)
        case .z8: return .init(yOffset: 8, radius: 10, spread: 1, alpha: 0.14)
        case .z9: return .init(yOffset: 9, radius: 12, spread: 1, alpha: 0.14)
        case .z12: return .init(yOffset: 12, radius: 17, spread: 2, alpha: 0.14)
        case .z16: return .init(yOffset: 16, radius: 24, spread: 2, alpha: 0.14)
        case .z24: return .init(yOffset: 24, radius: 38, spread: 3, alpha: 0.14)
        }
    }
    
    
    var penumbra: ShadowComponentMetrics {
        switch self {
        case .z1: .init(yOffset: 2, radius: 2, spread: 0, alpha: 0.12)
        case .z2: .init(yOffset: 3, radius: 4, spread: 0, alpha: 0.12)
        case .z3: .init(yOffset: 3, radius: 4, spread: 0, alpha: 0.12)
        case .z4: .init(yOffset: 4, radius: 5, spread: 0, alpha: 0.12)
        case .z6: .init(yOffset: 1, radius: 18, spread: 0, alpha: 0.12)
        case .z8: .init(yOffset: 3, radius: 14, spread: 3, alpha: 0.12)
        case .z9: .init(yOffset: 3, radius: 16, spread: 2, alpha: 0.12)
        case .z12: .init(yOffset: 5, radius: 22, spread: 4, alpha: 0.12)
        case .z16: .init(yOffset: 6, radius: 30, spread: 5, alpha: 0.12)
        case .z24: .init(yOffset: 9, radius: 46, spread: 8, alpha: 0.12)
        }
    }
    
    
    var ambient: ShadowComponentMetrics {
        switch self {
        case .z1: .init(yOffset: 1, radius: 3, spread: 0, alpha: 0.20)
        case .z2: .init(yOffset: 1, radius: 5, spread: 0, alpha: 0.20)
        case .z3: .init(yOffset: 1, radius: 8, spread: 0, alpha: 0.20)
        case .z4: .init(yOffset: 1, radius: 10, spread: 0, alpha: 0.20)
        case .z6: .init(yOffset: 3, radius: 5, spread: 0, alpha: 0.20)
        case .z8: .init(yOffset: 4, radius: 15, spread: 0, alpha: 0.20)
        case .z9: .init(yOffset: 5, radius: 6, spread: 0, alpha: 0.20)
        case .z12: .init(yOffset: 7, radius: 8, spread: 0, alpha: 0.20)
        case .z16: .init(yOffset: 8, radius: 10, spread: 0, alpha: 0.20)
        case .z24: .init(yOffset: 11, radius: 15, spread: 0, alpha: 0.20)
        }
    }
}
