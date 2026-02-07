import SwiftData
import Foundation

// MARK: - Preview Container

@MainActor
class PreviewContainer {
    static let shared = PreviewContainer()
    
    lazy var container: ModelContainer = {
        let schema = Schema([
            Profile.self,
            Organization.self,
            OrganizationMember.self,
            Workspace.self,
            WorkTask.self,
            TaskAssignee.self,
            TaskComment.self,
            TaskAttachment.self,
            Terminal.self,
            TaskDispatch.self,
            Hint.self,
            Skill.self,
            Context.self,
            TaskSkill.self
        ])
        
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            
            // Add some sample data for previews
            let context = container.mainContext
            
            let workspace = Workspace(name: "Sample Workspace", slug: "sample-workspace", path: "/path/to/workspace")
            context.insert(workspace)
            
            let task1 = WorkTask(title: "Sample Task 1", description: "This is a sample task")
            task1.workspace = workspace
            context.insert(task1)
            
            let task2 = WorkTask(title: "Sample Task 2", description: nil)
            task2.workspace = workspace
            task2.taskStatus = .completed
            context.insert(task2)
            
            try context.save()
            
            return container
        } catch {
            fatalError("Failed to create preview container: \(error)")
        }
    }()
    
    private init() {}
}
