#if os(macOS)
import os
import SwiftUI
import AppKit
import SwiftTermWrapper

// MARK: - TerminalEmulator Namespace

/// SwiftTerm-based terminal emulator wrapper
/// Provides the same API surface as the previous Ghostty wrapper for easy migration
enum TerminalEmulator {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "md.axel.Axel",
        category: "terminal"
    )
}

// MARK: - Terminal Theme

extension TerminalEmulator {
    /// Theme configuration for the embedded terminal
    struct TerminalTheme {
        var background: String = "18262F"
        var foreground: String = "e4e4e7"
        var cursorColor: String = "22d3ee"
        var selectionBackground: String = "3f3f46"
        var fontFamily: String = "JetBrains Mono"
        var fontSize: CGFloat = 13

        // ANSI colors (0-15)
        var palette: [String] = [
            "27272a", // black
            "f87171", // red
            "4ade80", // green
            "facc15", // yellow
            "60a5fa", // blue
            "c084fc", // magenta
            "22d3ee", // cyan
            "e4e4e7", // white
            "52525b", // bright black
            "fca5a5", // bright red
            "86efac", // bright green
            "fde047", // bright yellow
            "93c5fd", // bright blue
            "d8b4fe", // bright magenta
            "67e8f9", // bright cyan
            "fafafa", // bright white
        ]

        /// Default dark theme
        static let dark = TerminalTheme()

        /// Convert hex string to NSColor
        static func colorFromHex(_ hex: String) -> NSColor {
            var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

            guard hexSanitized.count == 6 else {
                return NSColor.white
            }

            var rgb: UInt64 = 0
            Scanner(string: hexSanitized).scanHexInt64(&rgb)

            return NSColor(
                red: CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
                green: CGFloat((rgb & 0x00FF00) >> 8) / 255.0,
                blue: CGFloat(rgb & 0x0000FF) / 255.0,
                alpha: 1.0
            )
        }

        /// Convert hex string to SwiftTerm.Color
        static func swiftTermColorFromHex(_ hex: String) -> SwiftTerm.Color {
            var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

            guard hexSanitized.count == 6 else {
                return SwiftTerm.Color(red: 255, green: 255, blue: 255)
            }

            var rgb: UInt64 = 0
            Scanner(string: hexSanitized).scanHexInt64(&rgb)

            return SwiftTerm.Color(
                red: UInt16((rgb & 0xFF0000) >> 16) * 257,
                green: UInt16((rgb & 0x00FF00) >> 8) * 257,
                blue: UInt16(rgb & 0x0000FF) * 257
            )
        }
    }
}

// MARK: - Surface Configuration

extension TerminalEmulator {
    struct SurfaceConfiguration {
        var fontSize: CGFloat? = nil
        var workingDirectory: String? = nil
        var command: String? = nil

        init(workingDirectory: String? = nil, command: String? = nil) {
            self.workingDirectory = workingDirectory
            self.command = command
        }
    }
}

// MARK: - App State

extension TerminalEmulator {
    /// Main app state for managing terminal surfaces - singleton pattern
    @MainActor
    final class App: ObservableObject {
        enum Readiness: String {
            case loading, error, ready
        }

        /// Shared singleton instance
        static let shared = App()

        @Published var readiness: Readiness = .ready  // SwiftTerm is always ready

        /// Theme to apply to terminals
        static var theme: TerminalTheme = .dark

        /// Shared surface view that persists across task switches
        private(set) var sharedSurface: SurfaceView?

        private init() {}

        /// Get or create the shared surface view
        func getOrCreateSurface(config: SurfaceConfiguration? = nil) -> SurfaceView? {
            if let existing = sharedSurface {
                return existing
            }

            let surface = SurfaceView(config: config)
            sharedSurface = surface
            return surface
        }

        /// Create a new independent surface (not shared)
        func createSurface(config: SurfaceConfiguration? = nil) -> SurfaceView {
            return SurfaceView(config: config)
        }

        /// Reset the shared surface
        func resetSharedSurface() {
            sharedSurface = nil
        }
    }
}

// MARK: - Surface View

extension TerminalEmulator {
    /// NSView that hosts a SwiftTerm terminal
    class SurfaceView: NSView, ObservableObject, LocalProcessTerminalViewDelegate {
        let terminalView: LocalProcessTerminalView

        @Published var title: String = ""
        @Published var healthy: Bool = true
        @Published var processRunning: Bool = false

        private var hasStartedProcess = false

        override var acceptsFirstResponder: Bool { true }

        private var pendingConfig: SurfaceConfiguration?

        init(config: SurfaceConfiguration? = nil) {
            terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

            self.pendingConfig = config
            setupTerminalView()
            applyTheme(App.theme)
            terminalView.processDelegate = self

            // Defer shell start until view is in window hierarchy
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.startShell(config: self.pendingConfig)
                self.pendingConfig = nil
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) not supported")
        }

        private func setupTerminalView() {
            // Add terminal view as subview - let theme handle colors
            terminalView.translatesAutoresizingMaskIntoConstraints = true
            terminalView.autoresizingMask = [.width, .height]
            terminalView.frame = bounds
            addSubview(terminalView)
        }

        private func applyTheme(_ theme: TerminalTheme) {
            // Apply colors - terminal will handle its own background
            terminalView.nativeBackgroundColor = TerminalTheme.colorFromHex(theme.background)
            terminalView.nativeForegroundColor = TerminalTheme.colorFromHex(theme.foreground)
            terminalView.caretColor = TerminalTheme.colorFromHex(theme.cursorColor)
            terminalView.selectedTextBackgroundColor = TerminalTheme.colorFromHex(theme.selectionBackground)

            // Apply font
            let fontSize = theme.fontSize
            if let font = NSFont(name: theme.fontFamily, size: fontSize) {
                terminalView.font = font
            } else {
                // Fallback to system monospace font
                terminalView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            }

            // Build palette with background color as color 0 (default background)
            var colors: [SwiftTerm.Color] = []
            // Use our background color as the first color (ANSI black/background)
            colors.append(TerminalTheme.swiftTermColorFromHex(theme.background))
            // Rest of the palette (skip index 0)
            for hex in theme.palette.dropFirst().prefix(15) {
                colors.append(TerminalTheme.swiftTermColorFromHex(hex))
            }

            // SwiftTerm uses installColors to set the ANSI palette
            if colors.count == 16 {
                terminalView.installColors(colors)
            }

            // Set terminal's default background/foreground colors
            let terminal = terminalView.getTerminal()
            terminal.backgroundColor = TerminalTheme.swiftTermColorFromHex(theme.background)
            terminal.foregroundColor = TerminalTheme.swiftTermColorFromHex(theme.foreground)

            // Force redraw
            terminalView.setNeedsDisplay(terminalView.bounds)
        }

        private func startShell(config: SurfaceConfiguration?) {
            guard !hasStartedProcess else { return }
            hasStartedProcess = true

            // Determine working directory
            let workingDir = config?.workingDirectory ?? NSHomeDirectory()

            // Get user's default shell
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let shellName = (shell as NSString).lastPathComponent

            // Change to working directory first
            FileManager.default.changeCurrentDirectoryPath(workingDir)

            // Start the process
            terminalView.startProcess(
                executable: shell,
                args: ["-l"],  // Login shell
                environment: nil,
                execName: shellName
            )

            processRunning = true
        }

        // MARK: - Send Command

        /// Send a command to the terminal (appends newline to execute)
        func sendCommand(_ command: String) {
            let commandWithNewline = command + "\n"
            terminalView.send(txt: commandWithNewline)
        }

        /// Send raw text to the terminal (no newline appended)
        func sendText(_ text: String) {
            terminalView.send(txt: text)
        }

        // MARK: - Size Updates

        func sizeDidChange(_ size: CGSize) {
            terminalView.frame = NSRect(origin: .zero, size: size)
        }

        // MARK: - Focus

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result {
                terminalView.window?.makeFirstResponder(terminalView)
            }
            return result
        }

        // MARK: - Copy/Paste Support

        /// Copy selected text to clipboard
        @objc func copy(_ sender: Any?) {
            terminalView.copy(sender)
        }

        /// Paste from clipboard
        @objc func paste(_ sender: Any?) {
            terminalView.paste(sender)
        }

        /// Select all text in terminal
        @objc override func selectAll(_ sender: Any?) {
            terminalView.selectAll(sender)
        }

        /// Get the currently selected text
        func getSelectedText() -> String? {
            return terminalView.getSelection()
        }

        /// Check if there's a selection
        var hasSelection: Bool {
            return terminalView.getSelection() != nil
        }

        // MARK: - LocalProcessTerminalViewDelegate

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async { [weak self] in
                self?.processRunning = false
                self?.healthy = exitCode == 0
            }
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
            // Terminal size changed
        }

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            DispatchQueue.main.async { [weak self] in
                self?.title = title
            }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // Current directory updated
        }

        func scrolled(source: TerminalView, position: Double) {
            // Scrollback position changed
        }
    }
}

// MARK: - SwiftUI Integration

/// Container view that hosts the terminal - SwiftUI manages this, we manage the terminal inside
class TerminalContainerView: NSView {
    weak var hostedTerminal: LocalProcessTerminalView?

    override var acceptsFirstResponder: Bool { true }

    func hostTerminal(_ terminal: LocalProcessTerminalView) {
        hostedTerminal?.removeFromSuperview()

        terminal.translatesAutoresizingMaskIntoConstraints = true
        terminal.autoresizingMask = [.width, .height]
        terminal.frame = bounds
        addSubview(terminal)
        hostedTerminal = terminal

        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(terminal)
        }
    }

    override func layout() {
        super.layout()
        hostedTerminal?.frame = bounds
    }
}

/// View controller that hosts a terminal - adds it in viewDidAppear to avoid blocking
class TerminalHostViewController: NSViewController, NSMenuItemValidation {
    let terminalView: LocalProcessTerminalView
    private var hasAddedTerminal = false

    init(terminalView: LocalProcessTerminalView) {
        self.terminalView = terminalView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func loadView() {
        let container = TerminalContainerViewWithDrop(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.terminalView = terminalView
        self.view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        if !hasAddedTerminal {
            hasAddedTerminal = true
            terminalView.translatesAutoresizingMaskIntoConstraints = true
            terminalView.autoresizingMask = [.width, .height]
            terminalView.frame = view.bounds

            view.addSubview(terminalView)

            // Configure scrollback buffer for better scrolling
            terminalView.getTerminal().options.scrollback = 10000
        }

        // Always focus terminal when view appears
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(self?.terminalView)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if hasAddedTerminal {
            terminalView.frame = view.bounds
        }
    }

    // MARK: - Responder Chain for Copy/Paste/SelectAll

    @IBAction func copy(_ sender: Any?) {
        if let selection = terminalView.getSelection(), !selection.isEmpty {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(selection, forType: .string)
        }
    }

    @IBAction func paste(_ sender: Any?) {
        if let string = NSPasteboard.general.string(forType: .string) {
            terminalView.send(txt: string)
        }
    }

    @IBAction override func selectAll(_ sender: Any?) {
        terminalView.selectAll(sender)
    }

    // Enable menu items when appropriate (NSMenuItemValidation)
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return terminalView.getSelection() != nil
        case #selector(paste(_:)):
            return NSPasteboard.general.string(forType: .string) != nil
        case #selector(selectAll(_:)):
            return true
        default:
            return true
        }
    }

    // Make sure we're in the responder chain
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Drag and Drop Container View

/// Container view that handles drag and drop for the terminal
class TerminalContainerViewWithDrop: NSView {
    weak var terminalView: LocalProcessTerminalView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let terminalView = terminalView else { return false }

        let pasteboard = sender.draggingPasteboard

        // Handle file URLs
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            // Escape paths and join with spaces
            let paths = urls.map { url -> String in
                let path = url.path
                // Escape special characters for shell
                return path.replacingOccurrences(of: " ", with: "\\ ")
                          .replacingOccurrences(of: "'", with: "\\'")
                          .replacingOccurrences(of: "\"", with: "\\\"")
                          .replacingOccurrences(of: "(", with: "\\(")
                          .replacingOccurrences(of: ")", with: "\\)")
            }
            let text = paths.joined(separator: " ")
            terminalView.send(txt: text)
            return true
        }

        // Handle plain strings
        if let string = pasteboard.string(forType: .string) {
            terminalView.send(txt: string)
            return true
        }

        return false
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // Optional: remove highlight
    }

    override var acceptsFirstResponder: Bool { true }
}

/// NSViewControllerRepresentable wrapper for terminal
struct TerminalSurfaceRepresentable: NSViewControllerRepresentable {
    typealias NSViewControllerType = TerminalHostViewController

    let view: TerminalEmulator.SurfaceView
    let size: CGSize

    func makeNSViewController(context: NSViewControllerRepresentableContext<TerminalSurfaceRepresentable>) -> TerminalHostViewController {
        return TerminalHostViewController(terminalView: view.terminalView)
    }

    func updateNSViewController(_ nsViewController: TerminalHostViewController, context: NSViewControllerRepresentableContext<TerminalSurfaceRepresentable>) {
        // Size is handled by viewDidLayout
    }

    static func dismantleNSViewController(_ nsViewController: TerminalHostViewController, coordinator: ()) {
        // Remove terminal view from the container when SwiftUI tears down this representable.
        // This prevents the terminal NSView from being stranded in a SwiftUI hosting window
        // that can appear as a chromeless, detached window. The offscreen screenshot timer
        // will reclaim the terminal view on its next tick.
        nsViewController.terminalView.removeFromSuperview()
    }
}

// MARK: - Focusable Terminal View for SwiftUI

/// A SwiftUI wrapper that ensures the terminal can receive keyboard focus and copy/paste commands
struct FocusableTerminalView: View {
    @ObservedObject var surfaceView: TerminalEmulator.SurfaceView
    let size: CGSize

    var body: some View {
        TerminalSurfaceRepresentable(view: surfaceView, size: size)
            .focusable()
            .onTapGesture {
                // Ensure terminal gets focus when tapped
                surfaceView.terminalView.window?.makeFirstResponder(surfaceView.terminalView)
            }
    }
}

extension TerminalEmulator {
    /// Convenience typealias for the surface representable
    typealias SurfaceRepresentable = TerminalSurfaceRepresentable
}

#endif
