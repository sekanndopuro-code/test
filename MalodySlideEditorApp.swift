import SwiftUI

@main
struct MalodySlideEditorApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
