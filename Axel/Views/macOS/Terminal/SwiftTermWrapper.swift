#if os(macOS)
import os
import SwiftUI
import AppKit
import GhosttyKit
import Darwin

// MARK: - TerminalEmulator Namespace

enum TerminalEmulator {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "md.axel.Axel",
        category: "terminal"
    )
}

// MARK: - Terminal Theme

extension TerminalEmulator {
    struct TerminalTheme {
        var background: String = "18262F"
        var foreground: String = "e4e4e7"
        var cursorColor: String = "22d3ee"
        var selectionBackground: String = "3f3f46"
        var fontFamily: String = "JetBrains Mono"
        var fontSize: CGFloat = 13

        static let dark = TerminalTheme()

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
    }
}

// MARK: - Surface Configuration

extension TerminalEmulator {
    struct SurfaceConfiguration {
        var fontSize: CGFloat? = nil
        var workingDirectory: String? = nil
        var command: String? = nil
        var initialInput: String? = nil
        var waitAfterCommand: Bool = false

        init(workingDirectory: String? = nil, command: String? = nil) {
            self.workingDirectory = workingDirectory
            self.command = command
        }
    }
}

// MARK: - App State

extension TerminalEmulator {
    @MainActor
    final class App: ObservableObject {
        enum Readiness: String {
            case loading, error, ready
        }

        static let shared = App()

        @Published var readiness: Readiness = .loading

        static var theme: TerminalTheme = .dark

        private(set) var app: ghostty_app_t?
        private(set) var config: ghostty_config_t?

        private(set) var sharedSurface: SurfaceView?

        private init() {
            initialize()
        }

        deinit {
            if let app {
                ghostty_app_free(app)
            }
            if let config {
                ghostty_config_free(config)
            }
        }

        func getOrCreateSurface(config: SurfaceConfiguration? = nil) -> SurfaceView? {
            if let existing = sharedSurface {
                return existing
            }

            guard let app else { return nil }
            let surface = SurfaceView(app: app, config: config)
            sharedSurface = surface
            return surface
        }

        func createSurface(config: SurfaceConfiguration? = nil) -> SurfaceView {
            guard let app else {
                return SurfaceView(app: nil, config: config)
            }
            return SurfaceView(app: app, config: config)
        }

        func resetSharedSurface() {
            sharedSurface = nil
        }

        private func initialize() {
            let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
            guard initResult == GHOSTTY_SUCCESS else {
                logger.error("ghostty_init failed")
                readiness = .error
                return
            }

            guard let cfg = ghostty_config_new() else {
                logger.error("ghostty_config_new failed")
                readiness = .error
                return
            }

            ghostty_config_load_default_files(cfg)
            ghostty_config_load_recursive_files(cfg)
            ghostty_config_finalize(cfg)
            config = cfg

            var runtime = ghostty_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                supports_selection_clipboard: true,
                wakeup_cb: { userdata in App.wakeup(userdata) },
                action_cb: { app, target, action in App.action(app!, target: target, action: action) },
                read_clipboard_cb: { userdata, loc, state in App.readClipboard(userdata, location: loc, state: state) },
                confirm_read_clipboard_cb: { userdata, str, state, request in
                    App.confirmReadClipboard(userdata, string: str, state: state, request: request)
                },
                write_clipboard_cb: { userdata, loc, content, len, confirm in
                    App.writeClipboard(userdata, location: loc, content: content, len: len, confirm: confirm)
                },
                close_surface_cb: { userdata, processAlive in App.closeSurface(userdata, processAlive: processAlive) }
            )

            guard let app = ghostty_app_new(&runtime, cfg) else {
                logger.error("ghostty_app_new failed")
                readiness = .error
                return
            }

            self.app = app
            ghostty_app_set_focus(app, NSApp.isActive)
            readiness = .ready
        }

        func appTick() {
            guard let app else { return }
            ghostty_app_tick(app)
        }

        private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
            guard let userdata else { return }
            let state = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async { state.appTick() }
        }

        private static func action(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            action: ghostty_action_s
        ) -> Bool {
            _ = app
            _ = target
            _ = action
            return false
        }

        private static func surfaceView(from userdata: UnsafeMutableRawPointer?) -> SurfaceView? {
            guard let userdata else { return nil }
            return Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        }

        private static func readClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            state: UnsafeMutableRawPointer?
        ) {
            guard let surfaceView = surfaceView(from: userdata),
                  let surface = surfaceView.surface
            else { return }

            let pasteboard = NSPasteboard.general
            let text = pasteboard.string(forType: .string) ?? ""
            completeClipboardRequest(surface, data: text, state: state)
        }

        private static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            string: UnsafePointer<CChar>?,
            state: UnsafeMutableRawPointer?,
            request: ghostty_clipboard_request_e
        ) {
            _ = request
            guard let surfaceView = surfaceView(from: userdata),
                  let surface = surfaceView.surface,
                  let string
            else { return }

            let text = String(cString: string)
            completeClipboardRequest(surface, data: text, state: state, confirmed: true)
        }

        private static func writeClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            content: UnsafePointer<ghostty_clipboard_content_s>?,
            len: Int,
            confirm: Bool
        ) {
            _ = userdata
            _ = location
            _ = confirm
            guard let content, len > 0 else { return }

            var text: String?
            for i in 0..<len {
                let item = content.advanced(by: i).pointee
                guard let mime = item.mime, let data = item.data else { continue }
                if String(cString: mime) == "text/plain" {
                    text = String(cString: data)
                    break
                }
            }

            guard let text else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
            _ = userdata
            _ = processAlive
        }

        private static func completeClipboardRequest(
            _ surface: ghostty_surface_t,
            data: String,
            state: UnsafeMutableRawPointer?,
            confirmed: Bool = false
        ) {
            data.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, confirmed)
            }
        }
    }
}

// MARK: - Input Helpers

extension TerminalEmulator {
    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue

        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        let rawFlags = flags.rawValue
        if (rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0) { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if (rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0) { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if (rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0) { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if (rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0) { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

        return ghostty_input_mods_e(mods)
    }
}

extension NSEvent {
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var keyEv = ghostty_input_key_s()
        keyEv.action = action
        keyEv.keycode = UInt32(keyCode)
        keyEv.text = nil
        keyEv.composing = false
        keyEv.mods = TerminalEmulator.ghosttyMods(modifierFlags)
        keyEv.consumed_mods = TerminalEmulator.ghosttyMods(
            (translationMods ?? modifierFlags).subtracting([.control, .command])
        )

        keyEv.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp {
            if let chars = characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first
            {
                keyEv.unshifted_codepoint = codepoint.value
            }
        }

        return keyEv
    }

    var ghosttyCharacters: String? {
        guard let characters else { return nil }

        if characters.count == 1,
           let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }

            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}

// MARK: - Surface View

extension TerminalEmulator {
    class SurfaceView: NSView, ObservableObject {
        @Published var title: String = ""
        @Published var healthy: Bool = true
        @Published var processRunning: Bool = true

        fileprivate private(set) var surface: ghostty_surface_t?

        private var workingDirectoryCString: UnsafeMutablePointer<CChar>?
        private var commandCString: UnsafeMutablePointer<CChar>?
        private var initialInputCString: UnsafeMutablePointer<CChar>?

        override var acceptsFirstResponder: Bool { true }

        init(app: ghostty_app_t?, config: SurfaceConfiguration?) {
            super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

            wantsLayer = true
            layer?.backgroundColor = TerminalEmulator.TerminalTheme.colorFromHex(App.theme.background).cgColor

            if let app {
                createSurface(app: app, config: config)
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) not supported")
        }

        deinit {
            if let surface {
                ghostty_surface_free(surface)
            }
            if let workingDirectoryCString { free(workingDirectoryCString) }
            if let commandCString { free(commandCString) }
            if let initialInputCString { free(initialInputCString) }
        }

        private func createSurface(app: ghostty_app_t, config: SurfaceConfiguration?) {
            var cfg = ghostty_surface_config_new()
            cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
            cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(self).toOpaque()
            ))
            cfg.userdata = Unmanaged.passUnretained(self).toOpaque()

            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
            cfg.scale_factor = scale

            let fontSize = config?.fontSize ?? App.theme.fontSize
            cfg.font_size = Float(fontSize)

            if let workingDirectory = config?.workingDirectory {
                workingDirectoryCString = strdup(workingDirectory)
                cfg.working_directory = UnsafePointer(workingDirectoryCString)
            }

            if let command = config?.command {
                commandCString = strdup(command)
                cfg.command = UnsafePointer(commandCString)
            }

            if let initialInput = config?.initialInput {
                initialInputCString = strdup(initialInput)
                cfg.initial_input = UnsafePointer(initialInputCString)
            }

            cfg.wait_after_command = config?.waitAfterCommand ?? false
            cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

            guard let surface = ghostty_surface_new(app, &cfg) else {
                TerminalEmulator.logger.error("ghostty_surface_new failed")
                healthy = false
                return
            }

            self.surface = surface
            updateSurfaceSize()
        }

        // MARK: - Commands

        func sendCommand(_ command: String) {
            sendText(command + "\n")
        }

        func sendText(_ text: String) {
            guard let surface else { return }
            let length = text.lengthOfBytes(using: .utf8)
            text.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(length))
            }
        }

        // MARK: - Selection

        func getSelectedText() -> String? {
            guard let surface else { return nil }
            var text = ghostty_text_s()
            guard ghostty_surface_read_selection(surface, &text) else { return nil }
            defer { ghostty_surface_free_text(surface, &text) }
            guard let ptr = text.text else { return nil }
            return String(bytesNoCopy: UnsafeMutableRawPointer(mutating: ptr), length: Int(text.text_len), encoding: .utf8, freeWhenDone: false)
        }

        var hasSelection: Bool {
            guard let surface else { return false }
            return ghostty_surface_has_selection(surface)
        }

        // MARK: - Size Updates

        override func layout() {
            super.layout()
            updateSurfaceSize()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            guard let surface else { return }

            let fbFrame = convertToBacking(bounds)
            let xScale = bounds.width > 0 ? fbFrame.size.width / bounds.width : 1.0
            let yScale = bounds.height > 0 ? fbFrame.size.height / bounds.height : 1.0
            ghostty_surface_set_content_scale(surface, xScale, yScale)
            updateSurfaceSize()
        }

        private func updateSurfaceSize() {
            guard let surface else { return }
            let fbFrame = convertToBacking(bounds)
            let width = max(1, UInt32(fbFrame.size.width))
            let height = max(1, UInt32(fbFrame.size.height))
            ghostty_surface_set_size(surface, width, height)
        }

        func sizeDidChange(_ size: CGSize) {
            frame = NSRect(origin: .zero, size: size)
            updateSurfaceSize()
        }

        // MARK: - Focus

        /// Programmatically set focus on the Ghostty surface without requiring the view to be first responder
        func focus() {
            guard let surface else { return }
            ghostty_surface_set_focus(surface, true)
        }

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result, let surface {
                ghostty_surface_set_focus(surface, true)
            }
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result, let surface {
                ghostty_surface_set_focus(surface, false)
            }
            return result
        }

        // MARK: - Copy/Paste Support

        @objc func copy(_ sender: Any?) {
            guard let selection = getSelectedText(), !selection.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(selection, forType: .string)
        }

        @objc func paste(_ sender: Any?) {
            if let string = NSPasteboard.general.string(forType: .string) {
                sendText(string)
            }
        }

        @objc override func selectAll(_ sender: Any?) {
            _ = sender
        }

        // MARK: - Input

        private func keyAction(_ action: ghostty_input_action_e, event: NSEvent) -> Bool {
            guard let surface else { return false }
            var keyEv = event.ghosttyKeyEvent(action)

            if let text = event.ghosttyCharacters, !text.isEmpty,
               let codepoint = text.utf8.first, codepoint >= 0x20 {
                return text.withCString { ptr in
                    keyEv.text = ptr
                    return ghostty_surface_key(surface, keyEv)
                }
            }

            return ghostty_surface_key(surface, keyEv)
        }

        override func keyDown(with event: NSEvent) {
            _ = keyAction(GHOSTTY_ACTION_PRESS, event: event)
        }

        override func keyUp(with event: NSEvent) {
            _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
        }

        override func flagsChanged(with event: NSEvent) {
            let mod: ghostty_input_mods_e?
            switch event.keyCode {
            case 0x38, 0x3C:
                mod = GHOSTTY_MODS_SHIFT
            case 0x3B, 0x3E:
                mod = GHOSTTY_MODS_CTRL
            case 0x3A, 0x3D:
                mod = GHOSTTY_MODS_ALT
            case 0x37, 0x36:
                mod = GHOSTTY_MODS_SUPER
            case 0x39:
                mod = GHOSTTY_MODS_CAPS
            default:
                mod = nil
            }

            guard let mod else { return }
            let mods = TerminalEmulator.ghosttyMods(event.modifierFlags)
            let action: ghostty_input_action_e = (mods.rawValue & mod.rawValue) != 0 ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
            _ = keyAction(action, event: event)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }

            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseMoved(with event: NSEvent) {
            guard let surface else { return }
            let loc = convert(event.locationInWindow, from: nil)
            ghostty_surface_mouse_pos(surface, Double(loc.x), Double(bounds.height - loc.y), TerminalEmulator.ghosttyMods(event.modifierFlags))
        }

        override func mouseDown(with event: NSEvent) {
            guard let surface else { return }
            let mods = TerminalEmulator.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
        }

        override func mouseUp(with event: NSEvent) {
            guard let surface else { return }
            let mods = TerminalEmulator.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let surface else { return }
            let mods = TerminalEmulator.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods)
        }

        override func rightMouseUp(with event: NSEvent) {
            guard let surface else { return }
            let mods = TerminalEmulator.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods)
        }

        override func otherMouseDown(with event: NSEvent) {
            guard let surface else { return }
            let mods = TerminalEmulator.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, mods)
        }

        override func otherMouseUp(with event: NSEvent) {
            guard let surface else { return }
            let mods = TerminalEmulator.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, mods)
        }

        override func scrollWheel(with event: NSEvent) {
            guard let surface else { return }
            ghostty_surface_mouse_scroll(
                surface,
                Double(event.scrollingDeltaX),
                Double(event.scrollingDeltaY),
                ghostty_input_scroll_mods_t(0)
            )
        }
    }
}

// MARK: - SwiftUI Integration

final class TerminalContainerView: NSView {
    weak var hostedSurface: TerminalEmulator.SurfaceView?

    override var acceptsFirstResponder: Bool { true }

    func hostSurface(_ view: TerminalEmulator.SurfaceView) {
        if hostedSurface !== view {
            hostedSurface?.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = [.width, .height]
            view.frame = bounds
            addSubview(view)
            hostedSurface = view
        }
    }

    override func layout() {
        super.layout()
        hostedSurface?.frame = bounds
    }
}

struct TerminalSurfaceRepresentable: NSViewRepresentable {
    typealias NSViewType = TerminalContainerView
    typealias Coordinator = Void

    let view: TerminalEmulator.SurfaceView
    let size: CGSize

    @MainActor @preconcurrency
    func makeNSView(context: NSViewRepresentableContext<TerminalSurfaceRepresentable>) -> TerminalContainerView {
        let container = TerminalContainerView(frame: NSRect(origin: .zero, size: size))
        container.hostSurface(view)
        return container
    }

    @MainActor @preconcurrency
    func updateNSView(_ nsView: TerminalContainerView, context: NSViewRepresentableContext<TerminalSurfaceRepresentable>) {
        nsView.frame = NSRect(origin: .zero, size: size)
        nsView.hostSurface(view)
        view.sizeDidChange(size)
    }

    @MainActor @preconcurrency
    static func dismantleNSView(_ nsView: TerminalContainerView, coordinator: ()) {
        nsView.hostedSurface?.removeFromSuperview()
    }
}

struct FocusableTerminalView: View {
    @ObservedObject var surfaceView: TerminalEmulator.SurfaceView
    let size: CGSize

    var body: some View {
        TerminalSurfaceRepresentable(view: surfaceView, size: size)
            .focusable()
            .onTapGesture {
                surfaceView.window?.makeFirstResponder(surfaceView)
            }
    }
}

extension TerminalEmulator {
    typealias SurfaceRepresentable = TerminalSurfaceRepresentable
}

#endif
