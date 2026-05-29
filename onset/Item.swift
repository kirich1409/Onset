//
//  Item.swift
//  onset
//
//  Created by Kirill Rozov on 29.05.2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
