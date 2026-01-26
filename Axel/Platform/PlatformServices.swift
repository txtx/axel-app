import Foundation

enum PlatformServices {
    #if os(macOS)
    static let urlOpener: any URLOpening = MacURLOpener()
    static let syncMode: SyncMode = .workspaceScoped
    #else
    static let urlOpener: any URLOpening = MobileURLOpener()
    static let syncMode: SyncMode = .global
    #endif
}
