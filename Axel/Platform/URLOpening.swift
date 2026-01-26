import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

protocol URLOpening: Sendable {
    @MainActor func open(_ url: URL) async -> Bool
}

#if os(macOS)
struct MacURLOpener: URLOpening {
    @MainActor func open(_ url: URL) async -> Bool {
        NSWorkspace.shared.open(url)
    }
}
#else
struct MobileURLOpener: URLOpening {
    @MainActor func open(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url)
    }
}
#endif
