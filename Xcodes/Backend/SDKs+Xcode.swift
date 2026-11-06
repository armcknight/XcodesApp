//
//  SDKs+Xcode.swift
//  Xcodes
//
//  Created by Matt Kiazyk on 2023-06-05.
//  Copyright © 2023 Robots and Pencils. All rights reserved.
//

import SwiftUI
import XcodesKit

/// The SF Symbols for platforms, devices and the sidebar sections.
enum SystemImage: String {
    case xcode = "hammer"
    case platforms = "square.3.layers.3d"
    case simulators = "iphone.gen3"
    case deviceSupport = "cable.connector"
    case runtime = "cpu"
    case folder = "folder"
    case reload = "arrow.clockwise"
    case iPhone = "iphone"
    case iPad = "ipad"
    case watch = "applewatch"
    case tv = "appletv"
    case visionPro = "visionpro"
    case mac = "macwindow"
}

extension Image {
    init(symbol: SystemImage) {
        self.init(systemName: symbol.rawValue)
    }
}

extension DownloadableRuntime.Platform {
    var systemImage: SystemImage {
        switch self {
        case .iOS: return .iPhone
        case .macOS: return .mac
        case .watchOS: return .watch
        case .tvOS: return .tv
        case .visionOS: return .visionPro
        }
    }
}

extension DownloadableRuntime {
    func icon() -> Image {
        Image(symbol: platform.systemImage)
    }
}
