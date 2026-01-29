# Axel - AI Agent Task Manager for macOS

A native macOS application (with iOS/visionOS support) that serves as the GUI companion to the Axel CLI and Claude Code. Manages AI agent workflows, terminal sessions, real-time inbox events, and cross-device synchronization.

## What This App Does

Axel bridges terminal-based AI agents with a native GUI, enabling:

- **Task Management**: Create, queue, and track AI agent tasks with status tracking (queued → running → completed/aborted)
- **Terminal Session Control**: Launch Claude Code in managed terminal panes, monitor execution in real-time
- **Inbox & Permissions**: Receive Server-Sent Events (SSE) from Claude Code hooks, display permission requests, relay user responses
- **Skills & Contexts**: Load reusable prompts from `~/.config/axel/skills/` and workspace `./skills/` directories
- **Multi-device Sync**: Automerge CRDT + Supabase for conflict-free synchronization
- **Team Collaboration**: Workspace-level organization and member management

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        macOS App (SwiftUI)                       │
├─────────────────────────────────────────────────────────────────┤
│  Views (MVVM)           │  Services               │  Models     │
│  - WorkspaceContentView │  - InboxService (SSE)   │  SwiftData  │
│  - RunningView          │  - SyncService (CRDT)   │  15 entities│
│  - InboxView            │  - AuthService (OAuth)  │             │
│  - SkillsView           │  - TerminalManager      │             │
└─────────────────────────┴───────────────────────┴───────────────┘
         │                         │
         ▼                         ▼
┌─────────────────┐     ┌─────────────────────────┐
│   Axel CLI      │◄───►│      Supabase           │
│ (tmux + Claude) │     │  (Auth + Sync Storage)  │
└─────────────────┘     └─────────────────────────┘
```

## Project Structure

```
Axel/
├── AxelApp.swift              # Entry point, SwiftData schema setup
├── App/
│   ├── macOS/                 # AppDelegate, MacScenes (window management)
│   └── iOS/                   # MobileScene
├── Models/                    # SwiftData entities (18 files)
│   ├── WorkTask.swift         # Task with status, priority, completion
│   ├── Terminal.swift         # Terminal sessions with pane IDs
│   ├── Workspace.swift        # Isolated environments with tasks/skills
│   ├── Skill.swift            # Reusable prompts loaded from filesystem
│   ├── Hint.swift             # Permission requests from Claude Code
│   └── InboxEvent.swift       # Real-time events from hook system
├── Views/
│   ├── macOS/                 # macOS-specific views (~6700 lines)
│   │   ├── WorkspaceContentView.swift  # Main 5-column layout
│   │   ├── RunningView.swift           # Terminal session UI
│   │   ├── InboxView.swift             # Event viewer, permission handling
│   │   └── KeyboardShortcuts.swift     # Cmd+N, Cmd+R, Cmd+K, etc.
│   ├── iOS/                   # iOS-specific views
│   └── Shared/                # Cross-platform views
├── Services/
│   ├── InboxService.swift     # SSE streaming, event parsing (~30KB)
│   ├── SyncService.swift      # Automerge CRDT sync (~100KB)
│   └── AuthService.swift      # GitHub OAuth via Supabase
├── Supabase/                  # Backend integration
├── ViewModels/                # Observable state management
└── Platform/                  # Platform abstraction (URLOpening, etc.)

Packages/
├── AutomergeWrapper/          # CRDT document wrapper
├── SwiftTermWrapper/          # Terminal integration
└── SwiftDiffs/                # Diff visualization library

scripts/
├── create-dmg.sh              # DMG creation for distribution
└── test-sparkle-locally.sh    # Local Sparkle updater testing

docs/
└── ci-setup.md                # CI/CD setup documentation
```

## Key Files

| File | Purpose |
|------|---------|
| `AxelApp.swift` | SwiftData schema (15 models), platform scenes, storage config |
| `MacScenes.swift` | Window management, keyboard shortcuts, menu commands |
| `WorkspaceContentView.swift` | Main content: queue, inbox, terminals, skills, team columns |
| `RunningView.swift` | Terminal session management, TerminalSessionManager |
| `InboxService.swift` | SSE event streaming, OTEL metrics parsing, permission relay |
| `SyncService.swift` | Automerge merge logic, Supabase sync, conflict resolution |
| `WorkTask.swift` | Core task model with status enum, relationships to workspace |

## Technologies

- **Swift 5.9+** with modern concurrency (async/await)
- **SwiftUI** for declarative UI
- **SwiftData** for persistence (iOS 17+ / macOS 14+)
- **Automerge** for CRDT-based sync
- **Supabase** for auth and cloud storage
- **SwiftTerm** for terminal emulation
- **Sparkle** for macOS auto-updates
- **SSE** for real-time event streaming

## Key Patterns

### MVVM with Observable
```swift
@Observable class WorkspaceViewModel {
    var tasks: [WorkTask] = []
    // ...
}
```

### Singleton Services
```swift
InboxService.shared    // SSE streaming
SyncService.shared     // CRDT sync
AuthService.shared     // OAuth
```

### SwiftData Models
```swift
@Model class WorkTask {
    var title: String
    var status: TaskStatus  // .queued, .running, .completed, .aborted
    var workspace: Workspace?
    var syncId: UUID?       // For Automerge sync
}
```

### Platform Conditionals
```swift
#if os(macOS)
    // macOS-specific code
#elseif os(iOS)
    // iOS-specific code
#endif
```

## Data Flow

1. **User creates task** → SwiftData persists locally
2. **User runs task** → Status → `.running`, terminal spawned:
   ```bash
   axel claude --tmux --pane-id=<uuid> --port=<port> --prompt="..."
   ```
3. **Claude Code executes** → Sends SSE events to InboxService
4. **Permission request** → Hint displayed in InboxView
5. **User responds** → Transmitted back to Claude Code
6. **Task completes** → Status → `.completed`, syncs to Supabase

## Storage Locations

- **macOS SQLite**: `~/.config/axel/shared.sqlite` (main) + per-workspace DBs
- **Skills directory**: `~/.config/axel/skills/` (user) + `./skills/` (workspace)
- **Automerge docs**: Stored in Supabase for sync

## Common Tasks

### Adding a New Model
1. Create `@Model` class in `Models/`
2. Add to schema in `AxelApp.swift`
3. Add `syncId: UUID?` for sync support
4. Update `SyncService` if needed

### Adding a New View
1. Create SwiftUI view in `Views/macOS/` or `Views/Shared/`
2. Use `@Environment(\.modelContext)` for data access
3. Add keyboard shortcuts in `MacScenes.swift` if needed

### Modifying Inbox Events
1. Update `InboxEvent.swift` model
2. Modify SSE parsing in `InboxService.swift`
3. Update `InboxView.swift` display logic

## Development

**Requirements**: macOS 14.0+, Xcode 15.0+, Swift 5.9+

```bash
# Open in Xcode
open Axel.xcodeproj

# Build and run via script
./run.sh

# Manual build (Debug)
xcodebuild -project Axel.xcodeproj -scheme Axel \
  -destination 'platform=macOS' -configuration Debug build

# Build targets: Axel (macOS), Axel-iOS, Axel-visionOS
```

## Building for Release

```bash
# Build release version
xcodebuild -scheme Axel -project Axel.xcodeproj -configuration Release \
  -destination "platform=macOS" build

# Create DMG installer (requires: brew install create-dmg)
./scripts/create-dmg.sh "build/Build/Products/Release/Axel.app" "Axel.dmg"
```

## Auto-Updates

The app uses **Sparkle** for automatic updates on macOS:
- Update feed: `https://txtx-public.s3.amazonaws.com/releases/axel/appcast.xml`
- Automatic checking enabled by default
- Updates menu available in app

## CI/CD

GitHub Actions workflow triggers on:
- Git tags matching `v*`
- Manual dispatch

Features:
- Automated code signing and notarization
- DMG creation and S3 publishing
- See [docs/ci-setup.md](./docs/ci-setup.md) for required secrets

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘N` | New task |
| `⌘R` | Run selected task |
| `⌘K` | Command palette |
| `⌘,` | Preferences |

## Integration with Axel CLI

The app launches and communicates with the Axel CLI:
- **Launch**: `axel claude --tmux --pane-id=<uuid> --port=<port>`
- **Events**: SSE from `http://localhost:<port>/inbox`
- **Skills**: Loaded from filesystem, injected as context
- **Sync**: Task state shared via Supabase

---

See [CLAUDE.md](./CLAUDE.md) for workspace-specific instructions.
