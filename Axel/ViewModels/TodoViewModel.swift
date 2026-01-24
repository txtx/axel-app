import Foundation
import SwiftData

@MainActor
@Observable
final class TodoViewModel {
    var newTodoTitle = ""

    func addTodo(context: ModelContext) async {
        guard !newTodoTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let todo = WorkTask(title: newTodoTitle.trimmingCharacters(in: .whitespacesAndNewlines))
        context.insert(todo)
        newTodoTitle = ""

        // Sync to push the new task to Supabase
        await SyncService.shared.performFullSync(context: context)
    }

    func toggleComplete(_ item: WorkTask, context: ModelContext) async {
        item.toggleComplete()
        await SyncService.shared.performFullSync(context: context)
    }

    func deleteTodo(_ item: WorkTask, context: ModelContext) async {
        // If the task was synced, delete from Supabase first
        if let syncId = item.syncId {
            await SyncService.shared.deleteTask(syncId: syncId)
        }
        context.delete(item)
    }
}
