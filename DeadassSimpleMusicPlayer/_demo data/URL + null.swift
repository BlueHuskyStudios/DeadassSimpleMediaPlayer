//
//  URL + null.swift
//  Dead-Simple Media Player
//
//  Created by Ky on 2026-07-14.
//

import Foundation



extension URL {
    static var null: URL { URL(fileURLWithPath: "/dev/null") }
}
