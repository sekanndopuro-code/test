import SwiftUI

@main
struct MalodySlideEditorApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                // ホームバーは隠さない (隠すと、下端に触れた瞬間に白く出て反応してしまう)。
                // 下端を「遅延」にすると、バーは半透明のまま残り、はっきり上へ持ち上げるまでホームに戻らない (本家 Malody と同じ)
                .defersSystemGestures(on: .bottom)
        }
    }
}
