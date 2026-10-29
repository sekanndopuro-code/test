import SwiftUI

@main
struct MalodySlideEditorApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)   // ホームバーを自動で隠す
                .defersSystemGestures(on: .bottom)   // 下端スワイプは1回目を無視(2回目でホームへ)
        }
    }
}
