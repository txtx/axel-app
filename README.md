# Axel macOS App

A native macOS todo app built with SwiftUI and SwiftData.

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later

## Building

1. Open `Axel.xcodeproj` in Xcode
2. Select the "Axel" scheme
3. Press Cmd+R to build and run

## Architecture

The app follows MVVM (Model-View-ViewModel) architecture:

- **Models/** - SwiftData models (`TodoItem`)
- **ViewModels/** - Business logic (`TodoViewModel`)
- **Views/** - SwiftUI views

## Features

- Add new todos
- Mark todos as complete/incomplete
- Delete todos
- Persistent storage with SwiftData

## Multi-Platform Ready

The codebase is structured for easy porting to iOS, iPadOS, and visionOS:

- Uses `@Observable` (iOS 17+/macOS 14+) for modern observation
- Avoids platform-specific APIs in shared code
- Uses SwiftUI's adaptive layouts
- Business logic is in ViewModels, not Views
