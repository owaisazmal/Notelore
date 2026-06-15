import SwiftUI

struct RootView: View {
    let services: AppServices

    var body: some View {
        TabView {
            RecordView(services: services)
                .tabItem { Label("Record", systemImage: "mic") }
            LibraryView(services: services)
                .tabItem { Label("Library", systemImage: "books.vertical") }
            AskView(services: services)
                .tabItem { Label("Ask", systemImage: "text.book.closed") }
            PrepView(services: services)
                .tabItem { Label("Prep", systemImage: "checklist") }
            SettingsView(services: services)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Color.vermillion)
    }
}
