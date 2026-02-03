import SwiftUI

#if os(macOS)
import AppKit

struct TaskTableSection {
    let title: String
    let color: NSColor?
    let status: TaskStatus
    let tasks: [WorkTask]
    let placeholderText: String?
}

enum TaskTableRow: Equatable {
    case header(String, Int, NSColor?, TaskStatus)
    case task(UUID, TaskStatus, Int?)
    case placeholder(String, TaskStatus)
    case dropZone(TaskStatus)

    static func == (lhs: TaskTableRow, rhs: TaskTableRow) -> Bool {
        switch (lhs, rhs) {
        case (.header(let t1, let c1, _, let s1), .header(let t2, let c2, _, let s2)):
            return t1 == t2 && c1 == c2 && s1 == s2
        case (.task(let id1, let s1, let p1), .task(let id2, let s2, let p2)):
            return id1 == id2 && s1 == s2 && p1 == p2
        case (.placeholder(let t1, let s1), .placeholder(let t2, let s2)):
            return t1 == t2 && s1 == s2
        case (.dropZone(let s1), .dropZone(let s2)):
            return s1 == s2
        default:
            return false
        }
    }
}

struct TaskTableView: NSViewRepresentable {
    let sections: [TaskTableSection]
    let isDragging: Bool
    let dropTargetEndStatus: TaskStatus?
    let expandedTaskId: UUID?
    let selectedTaskIds: Set<UUID>
    let rowView: (WorkTask, Int?) -> AnyView
    let headerView: (String, Int?, NSColor?) -> AnyView
    let placeholderView: (String) -> AnyView
    let dropZoneView: (TaskStatus, Bool) -> AnyView
    let onReorder: (_ draggedId: UUID, _ targetTask: WorkTask, _ targetStatus: TaskStatus) -> Void
    let onDropAtEnd: (_ draggedId: UUID, _ targetStatus: TaskStatus) -> Void
    let onDragStart: (_ draggedId: UUID) -> Void
    let onDragEnd: () -> Void
    let onDropTargetChange: (_ taskId: UUID?, _ endStatus: TaskStatus?) -> Void
    let onBackgroundClick: () -> Void
    let onTaskClick: ((_ taskId: UUID, _ modifiers: NSEvent.ModifierFlags) -> Void)?
    let onTaskDoubleClick: ((_ taskId: UUID) -> Void)?
    let onKeyDown: ((_ event: NSEvent) -> Bool)?

    // Keep a reference to tasks for lookup
    private var taskLookup: [UUID: WorkTask] {
        var lookup: [UUID: WorkTask] = [:]
        for section in sections {
            for task in section.tasks {
                lookup[task.id] = task
            }
        }
        return lookup
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: NSViewRepresentableContext<TaskTableView>) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)

        let tableView = TaskTableNSTableView()
        tableView.headerView = nil
        tableView.selectionHighlightStyle = .none
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAutomaticRowHeights = true
        tableView.rowSizeStyle = .custom
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.style = .plain
        tableView.wantsLayer = true  // Required for Core Animation
        tableView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        tableView.onBackgroundClick = onBackgroundClick
        tableView.coordinator = context.coordinator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.registerForDraggedTypes([.string])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        context.coordinator.taskLookup = taskLookup
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: NSViewRepresentableContext<TaskTableView>) {
        context.coordinator.parent = self
        context.coordinator.taskLookup = taskLookup

        if let tableView = context.coordinator.tableView as? TaskTableNSTableView {
            tableView.onBackgroundClick = onBackgroundClick
        }

        let oldExpandedTaskId = context.coordinator.expandedTaskId
        let oldSelectedTaskIds = context.coordinator.selectedTaskIds
        let oldRowItems = context.coordinator.rowItems

        context.coordinator.expandedTaskId = expandedTaskId
        context.coordinator.selectedTaskIds = selectedTaskIds
        context.coordinator.updateSections(sections)

        guard let tableView = context.coordinator.tableView else { return }

        // Handle selection changes - reload rows whose selection state changed
        let selectionChanged = oldSelectedTaskIds != selectedTaskIds
        if selectionChanged {
            let changedIds = oldSelectedTaskIds.symmetricDifference(selectedTaskIds)
            var rowsToUpdate = IndexSet()
            for (index, row) in context.coordinator.rowItems.enumerated() {
                if case .task(let id, _, _) = row, changedIds.contains(id) {
                    rowsToUpdate.insert(index)
                }
            }
            if !rowsToUpdate.isEmpty {
                tableView.reloadData(forRowIndexes: rowsToUpdate, columnIndexes: IndexSet(integer: 0))
            }
        }

        let newRowItems = context.coordinator.rowItems

        if TaskTableView.hasStructuralChange(old: oldRowItems, new: newRowItems) {
            tableView.reloadData()
            return
        }

        // Get old and new task IDs for comparison
        let oldTaskIds = oldRowItems.compactMap { row -> UUID? in
            if case .task(let id, _, _) = row { return id }
            return nil
        }
        let newTaskIds = newRowItems.compactMap { row -> UUID? in
            if case .task(let id, _, _) = row { return id }
            return nil
        }

        // If expanded task changed, update the affected rows and animate height change
        if oldExpandedTaskId != expandedTaskId {
            // If collapsing (was expanded, now not), restore focus to table view
            if oldExpandedTaskId != nil && expandedTaskId == nil {
                // Use asyncAfter to ensure the text field has been removed first
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak tableView] in
                    guard let tableView = tableView else { return }
                    tableView.window?.makeFirstResponder(tableView)
                }
            }

            var rowsToUpdate = IndexSet()

            // Find row for previously expanded task
            if let oldId = oldExpandedTaskId,
               let rowIndex = newRowItems.firstIndex(where: {
                   if case .task(let id, _, _) = $0 { return id == oldId }
                   return false
               }) {
                rowsToUpdate.insert(rowIndex)
            }

            // Find row for newly expanded task
            if let newId = expandedTaskId,
               let rowIndex = newRowItems.firstIndex(where: {
                   if case .task(let id, _, _) = $0 { return id == newId }
                   return false
               }) {
                rowsToUpdate.insert(rowIndex)
            }

            if !rowsToUpdate.isEmpty {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    ctx.allowsImplicitAnimation = true
                    // Reload the specific rows to update their content
                    tableView.reloadData(forRowIndexes: rowsToUpdate, columnIndexes: IndexSet(integer: 0))
                    // Notify about height changes
                    tableView.noteHeightOfRows(withIndexesChanged: rowsToUpdate)
                }
            }
            return
        }

        // Handle deletions with animation
        let deletedIds = Set(oldTaskIds).subtracting(Set(newTaskIds))
        if !deletedIds.isEmpty {
            var rowsToRemove = IndexSet()
            for (index, row) in oldRowItems.enumerated() {
                if case .task(let id, _, _) = row, deletedIds.contains(id) {
                    rowsToRemove.insert(index)
                }
            }
            if !rowsToRemove.isEmpty {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    ctx.allowsImplicitAnimation = true
                    tableView.removeRows(at: rowsToRemove, withAnimation: .effectFade)
                } completionHandler: {
                    // Only reload if row count changed significantly
                    if abs(oldRowItems.count - newRowItems.count) > rowsToRemove.count {
                        tableView.reloadData()
                    }
                }
                return
            }
        }

        // Handle insertions
        let insertedIds = Set(newTaskIds).subtracting(Set(oldTaskIds))
        if !insertedIds.isEmpty {
            var rowsToInsert = IndexSet()
            for (index, row) in newRowItems.enumerated() {
                if case .task(let id, _, _) = row, insertedIds.contains(id) {
                    rowsToInsert.insert(index)
                }
            }
            if !rowsToInsert.isEmpty {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    ctx.allowsImplicitAnimation = true
                    tableView.insertRows(at: rowsToInsert, withAnimation: .effectFade)
                }
                return
            }
        }

        // Handle reordering with animation
        if oldTaskIds != newTaskIds && Set(oldTaskIds) == Set(newTaskIds) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.allowsImplicitAnimation = true
                tableView.beginUpdates()
                // Build a mapping of task ID to old index
                var oldIndexMap: [UUID: Int] = [:]
                for (index, row) in oldRowItems.enumerated() {
                    if case .task(let id, _, _) = row {
                        oldIndexMap[id] = index
                    }
                }
                // Move rows to their new positions
                for (newIndex, newRow) in newRowItems.enumerated() {
                    if case .task(let taskId, _, _) = newRow {
                        if let oldIndex = oldIndexMap[taskId], oldIndex != newIndex {
                            tableView.moveRow(at: oldIndex, to: newIndex)
                            // Update the map to reflect the move
                            for (id, idx) in oldIndexMap {
                                if idx == oldIndex {
                                    oldIndexMap[id] = newIndex
                                } else if oldIndex < idx && idx <= newIndex {
                                    oldIndexMap[id] = idx - 1
                                } else if newIndex <= idx && idx < oldIndex {
                                    oldIndexMap[id] = idx + 1
                                }
                            }
                        }
                    }
                }
                tableView.endUpdates()
            }
            return
        }

        // If structure changed (headers, drop zones, etc.) do a full reload
        if oldRowItems.count != newRowItems.count || oldRowItems != newRowItems {
            tableView.reloadData()
        }
    }

    static func hasStructuralChange(old: [TaskTableRow], new: [TaskTableRow]) -> Bool {
        structuralSignature(old) != structuralSignature(new)
    }

    static func structuralSignature(_ rows: [TaskTableRow]) -> [String] {
        rows.compactMap { row in
            switch row {
            case .header(let title, let count, _, let status):
                return "header:\(title):\(count):\(status.rawValue)"
            case .placeholder(let text, let status):
                return "placeholder:\(text):\(status.rawValue)"
            case .dropZone(let status):
                return "dropZone:\(status.rawValue)"
            case .task:
                return nil
            }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: TaskTableView
        var rowItems: [TaskTableRow] = []
        weak var tableView: NSTableView?
        var expandedTaskId: UUID?
        var selectedTaskIds: Set<UUID> = []
        var taskLookup: [UUID: WorkTask] = [:]

        init(_ parent: TaskTableView) {
            self.parent = parent
            self.expandedTaskId = parent.expandedTaskId
            self.selectedTaskIds = parent.selectedTaskIds
            super.init()
            updateSections(parent.sections)
        }

        func updateSections(_ sections: [TaskTableSection]) {
            rowItems = sections.flatMap { section -> [TaskTableRow] in
                var rows: [TaskTableRow] = [
                    .header(section.title, section.tasks.count, section.color, section.status)
                ]
                if section.tasks.isEmpty {
                    if let placeholderText = section.placeholderText {
                        rows.append(.placeholder(placeholderText, section.status))
                    }
                } else {
                    rows.append(contentsOf: section.tasks.enumerated().map { index, task in
                        let position = section.status == .queued ? index + 1 : nil
                        return .task(task.id, section.status, position)
                    })
                }
                // Don't add drop zones - they cause layout shifts when dragging starts
                // The drop logic handles end-of-section drops without needing extra rows
                return rows
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rowItems.count
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            false
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            // Allow selection for task rows (needed for drag initiation)
            // Visual highlight is disabled via selectionHighlightStyle = .none
            guard row < rowItems.count else { return false }
            if case .task(_, let status, _) = rowItems[row] {
                return isReorderable(status)
            }
            return false
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            // Return automatic height
            return -1
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < rowItems.count else { return nil }

            let rowItem = rowItems[row]

            // Use different identifiers for different row types to improve reuse
            let identifier: NSUserInterfaceItemIdentifier
            switch rowItem {
            case .header: identifier = NSUserInterfaceItemIdentifier("header")
            case .task: identifier = NSUserInterfaceItemIdentifier("task")
            case .placeholder: identifier = NSUserInterfaceItemIdentifier("placeholder")
            case .dropZone: identifier = NSUserInterfaceItemIdentifier("dropZone")
            }

            // Reuse existing cell or create new one
            let cell: NSTableCellView
            if let existingCell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                cell = existingCell
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier

                let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
                hostingView.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(hostingView)
                NSLayoutConstraint.activate([
                    hostingView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                    hostingView.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                    hostingView.topAnchor.constraint(equalTo: cell.topAnchor),
                    hostingView.bottomAnchor.constraint(equalTo: cell.bottomAnchor)
                ])
            }

            // Get the hosting view and update its content
            guard let hostingView = cell.subviews.first as? NSHostingView<AnyView> else {
                return cell
            }

            switch rowItem {
            case .header(let title, let count, let color, _):
                hostingView.rootView = parent.headerView(title, count, color)
            case .task(let taskId, _, let position):
                if let task = taskLookup[taskId] {
                    hostingView.rootView = parent.rowView(task, position)
                }
            case .placeholder(let text, _):
                hostingView.rootView = parent.placeholderView(text)
            case .dropZone(let status):
                let isActive = parent.dropTargetEndStatus == status
                hostingView.rootView = parent.dropZoneView(status, isActive)
            }

            return cell
        }

        // MARK: - Drag and Drop

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < rowItems.count else { return nil }
            if case .task(let taskId, let status, _) = rowItems[row], isReorderable(status) {
                return NSString(string: taskId.uuidString)
            }
            return nil
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            guard let row = rowIndexes.first, row < rowItems.count else { return }
            if case .task(let taskId, let status, _) = rowItems[row], isReorderable(status) {
                parent.onDragStart(taskId)
            }
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            parent.onDragEnd()
            parent.onDropTargetChange(nil, nil)
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard let idString = info.draggingPasteboard.string(forType: .string),
                  let draggedId = UUID(uuidString: idString) else {
                parent.onDropTargetChange(nil, nil)
                return []
            }
            guard !rowItems.isEmpty else {
                parent.onDropTargetChange(nil, nil)
                return []
            }

            // Use the proposed row from NSTableView (it handles the Y precision)
            // but ensure we target a valid reorderable section
            var targetRow = max(0, min(row, rowItems.count))

            // Find the status of the section we're dropping into
            var targetStatus: TaskStatus?
            var targetTaskId: UUID?

            // Look at the row we're inserting before (or the last row if at end)
            let lookupRow = targetRow < rowItems.count ? targetRow : rowItems.count - 1
            if lookupRow >= 0 && lookupRow < rowItems.count {
                switch rowItems[lookupRow] {
                case .task(let taskId, let status, _):
                    if taskId != draggedId {
                        targetStatus = status
                        targetTaskId = taskId
                    } else if targetRow > 0 {
                        // Dropping on self - check row before
                        if case .task(let prevId, let prevStatus, _) = rowItems[targetRow - 1], prevId != draggedId {
                            targetStatus = prevStatus
                            targetTaskId = prevId
                        }
                    }
                case .header(_, _, _, let status):
                    targetStatus = status
                case .placeholder(_, let status):
                    targetStatus = status
                case .dropZone(let status):
                    targetStatus = status
                }
            }

            // Check if we can drop here
            guard let status = targetStatus, isReorderable(status) else {
                parent.onDropTargetChange(nil, nil)
                return []
            }

            // Always use .above and let NSTableView show its built-in indicator
            tableView.setDropRow(targetRow, dropOperation: .above)
            parent.onDropTargetChange(targetTaskId, targetTaskId == nil ? status : nil)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let idString = info.draggingPasteboard.string(forType: .string),
                  let draggedId = UUID(uuidString: idString) else {
                return false
            }
            guard !rowItems.isEmpty else { return false }

            // If dropping at the end or beyond
            if row >= rowItems.count {
                // Find last reorderable section and drop at end
                for section in parent.sections.reversed() {
                    if isReorderable(section.status) {
                        parent.onDropAtEnd(draggedId, section.status)
                        return true
                    }
                }
                return false
            }

            // Look at the row we're inserting before
            let targetItem = rowItems[row]

            switch targetItem {
            case .task(let taskId, let status, _):
                guard isReorderable(status), let targetTask = taskLookup[taskId] else { return false }
                parent.onReorder(draggedId, targetTask, status)
                return true

            case .header(_, _, _, let status):
                guard isReorderable(status) else { return false }
                // Dropping before header = insert at start of section
                if let firstTask = parent.sections.first(where: { $0.status == status })?.tasks.first {
                    parent.onReorder(draggedId, firstTask, status)
                } else {
                    parent.onDropAtEnd(draggedId, status)
                }
                return true

            case .placeholder(_, let status):
                guard isReorderable(status) else { return false }
                parent.onDropAtEnd(draggedId, status)
                return true

            case .dropZone(let status):
                guard isReorderable(status) else { return false }
                parent.onDropAtEnd(draggedId, status)
                return true
            }
        }

        private func isReorderable(_ status: TaskStatus) -> Bool {
            status == .queued || status == .backlog
        }

        // MARK: - Click Handling

        func handleRowClick(row: Int, modifiers: NSEvent.ModifierFlags) {
            guard row < rowItems.count else { return }
            if case .task(let taskId, _, _) = rowItems[row] {
                parent.onTaskClick?(taskId, modifiers)
            }
        }

        func handleRowDoubleClick(row: Int) {
            guard row < rowItems.count else { return }
            if case .task(let taskId, _, _) = rowItems[row] {
                parent.onTaskDoubleClick?(taskId)
            }
        }

        func handleKeyDown(event: NSEvent) -> Bool {
            return parent.onKeyDown?(event) ?? false
        }
    }
}

final class TaskTableNSTableView: NSTableView {
    var onBackgroundClick: (() -> Void)?
    weak var coordinator: TaskTableView.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // First, let AppKit find the view at this point
        guard let hitView = super.hitTest(point) else { return nil }

        // Check if this is inside a row
        let rowIndex = row(at: point)
        if rowIndex >= 0 {
            // Get the row rect to determine click position
            let rowRect = rect(ofRow: rowIndex)
            let relativeX = point.x - rowRect.minX

            // Allow clicks in the left 50 pixels to reach buttons (status indicator area)
            if relativeX < 50 {
                return hitView
            }

            // Allow clicks on interactive controls (buttons, menus, text fields) to pass through
            if isInteractiveControl(hitView) {
                return hitView
            }

            // For the main row area, intercept to handle at table level
            // This ensures selection works via mouseDown
            return self
        }

        return hitView
    }

    /// Check if the view is an interactive control that should handle its own clicks
    private func isInteractiveControl(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current, v !== self {
            // Check for standard AppKit controls
            if v is NSButton || v is NSPopUpButton || v is NSTextField || v is NSTextView || v is NSSegmentedControl {
                return true
            }
            // Check for SwiftUI controls embedded via NSHostingView
            let typeName = String(describing: type(of: v))
            if typeName.contains("Button") || typeName.contains("Menu") || typeName.contains("TextField") || typeName.contains("TextEditor") {
                return true
            }
            current = v.superview
        }
        return false
    }

    override func mouseDown(with event: NSEvent) {
        // Make this view first responder for keyboard events
        window?.makeFirstResponder(self)

        let location = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: location)

        if clickedRow == -1 {
            onBackgroundClick?()
            deselectAll(nil)
            return
        }

        // Handle click on a row immediately (on mouseDown)
        if let coordinator = coordinator {
            coordinator.handleRowClick(row: clickedRow, modifiers: event.modifierFlags)

            // Check for double-click
            if event.clickCount == 2 {
                coordinator.handleRowDoubleClick(row: clickedRow)
            }
        }

        // Also update NSTableView's internal selection for drag operations
        // This is needed because drag initiation uses the table's selected rows
        if clickedRow >= 0 {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        // Call super for drag initiation
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Forward keyboard events to the coordinator
        if let coordinator = coordinator, coordinator.handleKeyDown(event: event) {
            return // Event was handled
        }
        super.keyDown(with: event)
    }
}

#endif
