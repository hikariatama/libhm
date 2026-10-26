import SwiftUI

@main
struct PhotoAtlasApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands { PhotosProjectGuideCommands() }
    }
}
