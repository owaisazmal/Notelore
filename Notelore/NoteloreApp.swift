import SwiftData
import SwiftUI

@main
struct NoteloreApp: App {
    private let container: ModelContainer
    @State private var services: AppServices

    init() {
        do {
            let container = try ModelContainer(for: Session.self, Note.self)
            self.container = container
            self._services = State(initialValue: AppServices(modelContainer: container))
        } catch {
            fatalError("Could not open the Notelore library: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(services: services)
        }
        .modelContainer(container)
    }
}
