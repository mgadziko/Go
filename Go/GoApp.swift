import SwiftUI

@main
struct GoApp: App {
    @StateObject private var game = GoGameViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(game)
                .frame(minWidth: 860, minHeight: 720)
        }
    }
}
