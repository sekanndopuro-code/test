import UIKit
import UniformTypeIdentifiers

// 「ファイル」アプリを開いて、プラグインのファイルを選ばせる。
//
// SwiftUI の .fileImporter は、同じ画面の外側 (RootView) にも .fileImporter があると、開かないことがある。
// そこで、UIKit の書類ピッカー (UIDocumentPickerViewController) を、いちばん手前の画面から直接出す。
//   ・複数のファイルをまとめて選べる (.lua / .zip / 画像 など。種類は問わない)
//   ・asCopy: true なので、選んだファイルはアプリの一時フォルダにコピーされて渡される (そのまま読める)

final class PluginFilePicker: NSObject, UIDocumentPickerDelegate {
    private static var current: PluginFilePicker?        // delegate は弱参照なので、選び終わるまで自分で持っておく
    private var completion: (([URL]) -> Void)?

    /// ファイルアプリを開く。選び終わったら completion に URL の一覧を渡す (キャンセルしたら呼ばれない)
    static func present(completion: @escaping ([URL]) -> Void) {
        guard let top = topViewController() else { return }
        let me = PluginFilePicker()
        me.completion = completion
        current = me
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = me
        top.present(picker, animated: true)
    }

    /// いま画面のいちばん手前にある UIViewController (シートやフルスクリーンの上でも出せるように)
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let c = completion
        completion = nil
        PluginFilePicker.current = nil
        c?(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion = nil
        PluginFilePicker.current = nil
    }
}
