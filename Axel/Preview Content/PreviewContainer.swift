import Foundation
import SwiftData

@MainActor
final class PreviewContainer {
    static let shared = PreviewContainer()

    let container: ModelContainer

    private init() {
        let schema = Schema([WorkTask.self, Skill.self, Context.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)

        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
            insertSampleData()
        } catch {
            fatalError("Failed to create preview container: \(error)")
        }
    }

    private func insertSampleData() {
        // Sample todos
        let sampleTodos = [
            "Buy groceries",
            "Finish project report",
            "Call mom",
            "Schedule dentist appointment",
            "Review pull request"
        ]

        for title in sampleTodos {
            let todo = WorkTask(title: title)
            container.mainContext.insert(todo)
        }

        // Mark one as completed for variety
        if let firstTodo = try? container.mainContext.fetch(FetchDescriptor<WorkTask>()).first {
            firstTodo.toggleComplete()
        }

        // Sample skills
        let sampleSkills: [(String, String)] = [
            ("Code Review", "# Code Review\n\nReview code changes for:\n- Correctness\n- Performance\n- Security\n- Style"),
            ("Test Writer", "# Test Writer\n\nWrite comprehensive tests:\n- Unit tests\n- Integration tests\n- Edge cases"),
            ("Refactor", "# Refactor\n\nImprove code quality:\n- Extract methods\n- Reduce complexity\n- Improve naming")
        ]

        for (name, content) in sampleSkills {
            let skill = Skill(name: name, content: content)
            container.mainContext.insert(skill)
        }

        // Sample contexts
        let sampleContexts: [(String, String)] = [
            ("Project Overview", "# Project Overview\n\nThis is a SwiftUI app for managing coding tasks with AI agents."),
            ("Coding Standards", "# Coding Standards\n\n- Use SwiftUI for all views\n- Follow MVVM pattern\n- Use SwiftData for persistence"),
            ("API Reference", "# API Reference\n\nDocument key APIs and endpoints here.")
        ]

        for (name, content) in sampleContexts {
            let context = Context(name: name, content: content)
            container.mainContext.insert(context)
        }
    }
}
