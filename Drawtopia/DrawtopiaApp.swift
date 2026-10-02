import SwiftUI

/// Drawtopia's application entry point.
///
/// The app owns one `WorldStore` for the entire process. SwiftUI may recreate
/// individual views frequently, so placing the store here ensures navigation,
/// sheet presentation, and device rotation never create competing world models.
@main
struct DrawtopiaApp: App {
    /// Shared, persistent source of truth for the current world and custom shapes.
    @StateObject private var worldStore = WorldStore()

    var body: some Scene {
        WindowGroup {
            // Environment injection lets every editor and library view work with
            // the same world without manually forwarding bindings through layers.
            ContentView()
                .environmentObject(worldStore)
        }
    }
}
