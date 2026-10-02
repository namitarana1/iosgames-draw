import SwiftUI

@main
struct DrawtopiaApp: App {
    @StateObject private var worldStore = WorldStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(worldStore)
        }
    }
}
