import UIKit
import UniformTypeIdentifiers
import PhotosUI

// 「ファイル」アプリを開いて、プラグインのファイルを選ばせる。
//
// SwiftUI の .fileImporter は、同じ画面の外側 (RootView) にも .fileImporter があると、開かないことがある。
// そこで、UIKit の書類ピッカー (UIDocumentPickerViewController) を、いちばん手前の画面から直接出す。
//   ・複数のファイルをまとめて選べる (.lua / .zip / 画像 など。種類は問わない)
//   ・asCopy: true なので、選んだファイルはアプリの一時フォルダにコピーされて渡される (そのまま読める)

final class PluginFilePicker: NSObject, UIDocumentPickerDelegate {
    private static var current: PluginFilePicker?        // delegate は弱参照なので、選び終わるまで自分で持っておく
    private var completion: (([URL]) -> Void)?
    private var cancelled: (() -> Void)?

    /// ファイルアプリを開く。選び終わったら completion に URL の一覧を渡す。
    /// キャンセルしたとき (開けなかったときも) は completion は呼ばれず、cancelled があればそれが呼ばれる。
    /// multiple = false なら、1つだけ選ばせる (ReadBytesSelect 用)
    static func present(multiple: Bool = true, cancelled: (() -> Void)? = nil, completion: @escaping ([URL]) -> Void) {
        guard let top = topViewController() else {
            cancelled?()
            return
        }
        let me = PluginFilePicker()
        me.completion = completion
        me.cancelled = cancelled
        current = me
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.item], asCopy: true)
        picker.allowsMultipleSelection = multiple
        picker.delegate = me
        top.present(picker, animated: true)
    }

    /// いま画面のいちばん手前にある UIViewController (シートやフルスクリーンの上でも出せるように)
    static func topViewController() -> UIViewController? {
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
        cancelled = nil
        PluginFilePicker.current = nil
        c?(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let c = cancelled
        completion = nil
        cancelled = nil
        PluginFilePicker.current = nil
        c?()
    }
}

// 「写真」アプリ (フォトライブラリ) を開いて、画像を1枚選ばせる (ReadBytesSelect の 'photo')。
//   ・PHPickerViewController は写真アプリ側の画面を借りて出すので、写真ライブラリへのアクセス許可 (Info.plist の説明文) は要らない
//   ・選んだ画像の元のデータ (HEIC / JPEG / PNG など) をそのまま渡す。向き (EXIF) は DecodeImage 側で直す
final class PluginPhotoPicker: NSObject, PHPickerViewControllerDelegate {
    private static var current: PluginPhotoPicker?        // delegate は弱参照なので、選び終わるまで自分で持っておく
    private var completion: ((Data?) -> Void)?

    /// 写真ピッカーを開く。選び終わったら completion に画像のデータを渡す (別スレッドから呼ばれることがある)。
    /// キャンセル・開けなかった・読めなかったときは nil
    static func present(completion: @escaping (Data?) -> Void) {
        guard let top = PluginFilePicker.topViewController() else {
            completion(nil)
            return
        }
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let me = PluginPhotoPicker()
        me.completion = completion
        current = me
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = me
        top.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)          // PHPicker は自分では閉じない
        let c = completion
        completion = nil
        PluginPhotoPicker.current = nil
        guard let provider = results.first?.itemProvider else {
            c?(nil)                             // キャンセル (results が空)
            return
        }
        let typeID = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) ?? false })
            ?? UTType.image.identifier
        provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, _ in
            c?(data)
        }
    }
}
