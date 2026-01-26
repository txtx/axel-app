import Foundation

/// Determines how sync operations behave per platform.
/// - `global`: iOS/visionOS — sync all data in one container
/// - `workspaceScoped`: macOS — per-workspace sync, skip global push/pull
enum SyncMode: Equatable {
    case global
    case workspaceScoped
}
