import SwiftUI

#if os(macOS)
import AppKit
import SwiftTermWrapper

// MARK: - Public SwiftUI Views

struct SimpleTerminalView: View {
    let workspace: Workspace

    var body: some View {
        // Create terminal directly - no session management
        DirectTerminalView()
    }
}

/// View controller that hosts the terminal with drag/drop and copy/paste support
class TerminalViewController: NSViewController, NSMenuItemValidation {
    var terminalView: LocalProcessTerminalView!
    private var hasStartedShell = false
    private var containerView: TerminalDropContainerView!

    override func loadView() {
        containerView = TerminalDropContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        terminalView = LocalProcessTerminalView(frame: containerView.bounds)
        // Let the terminal set its own background color
        terminalView.nativeForegroundColor = NSColor.white
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.translatesAutoresizingMaskIntoConstraints = true
        terminalView.autoresizingMask = [.width, .height]

        containerView.terminalView = terminalView
        containerView.addSubview(terminalView)

        self.view = containerView
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        if !hasStartedShell {
            hasStartedShell = true
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            terminalView.startProcess(executable: shell, args: ["-l"], environment: nil, execName: (shell as NSString).lastPathComponent)

            // Configure scrollback buffer for better scrolling
            terminalView.getTerminal().options.scrollback = 10000
        }

        // Focus terminal when view appears
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(self?.terminalView)
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

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Drag and Drop Container View

/// Container view that handles drag and drop for the terminal
class TerminalDropContainerView: NSView {
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

/// SwiftUI wrapper using NSViewControllerRepresentable
struct DirectTerminalView: NSViewControllerRepresentable {
    typealias NSViewControllerType = TerminalViewController

    func makeNSViewController(context: NSViewControllerRepresentableContext<DirectTerminalView>) -> TerminalViewController {
        return TerminalViewController()
    }

    func updateNSViewController(_ nsViewController: TerminalViewController, context: NSViewControllerRepresentableContext<DirectTerminalView>) {
        // Nothing to update
    }
}

struct StandaloneTerminalView: View {
    let paneId: String
    let workspaceId: UUID

    @State private var session: TerminalSession?

    init(paneId: String = UUID().uuidString, workspaceId: UUID) {
        self.paneId = paneId
        self.workspaceId = workspaceId
    }

    var body: some View {
        Group {
            if let surface = session?.surfaceView, session?.isReady == true {
                TerminalFullViewSimple(surfaceView: surface)
            } else {
                ProgressView("Starting terminal...")
            }
        }
        .onAppear {
            if session == nil {
                session = TerminalSessionManager.shared.session(forPaneId: paneId, workingDirectory: nil, workspaceId: workspaceId)
            }
        }
    }
}

// MARK: - Terminal Display View

struct TerminalFullViewSimple: View {
    @ObservedObject var surfaceView: TerminalEmulator.SurfaceView

    var body: some View {
        TerminalSurfaceRepresentable(view: surfaceView, size: CGSize(width: 800, height: 600))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#else

struct SimpleTerminalView: View {
    let workspace: Workspace
    var body: some View {
        Text("Terminal is only available on macOS")
    }
}

struct StandaloneTerminalView: View {
    var body: some View {
        Text("Terminal is only available on macOS")
    }
}

#endif
