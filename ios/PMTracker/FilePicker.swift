import UIKit
import UniformTypeIdentifiers

/// Opens and saves files with the standard iOS document picker.
/// (Used instead of SwiftUI's .fileImporter/.fileExporter, which can silently do nothing when several are on screen.)
@MainActor
final class FilePicker: NSObject, UIDocumentPickerDelegate {
    static let shared = FilePicker()

    private var pickHandler: ((URL) -> Void)?
    private var exportHandler: ((Bool) -> Void)?

    /// Lets you pick any file. `asCopy` makes iOS download it from iCloud and hand the app its own copy.
    func pickFile(_ handler: @escaping (URL) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .plainText, .text, .data, .item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        exportHandler = nil
        pickHandler = handler
        present(picker)
    }

    /// Shows "Save to Files" for the data.
    func export(_ data: Data, filename: String, completion: @escaping (Bool) -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = self
        pickHandler = nil
        exportHandler = completion
        present(picker)
    }

    private func present(_ vc: UIViewController) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        top.present(vc, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let done = exportHandler {
            exportHandler = nil
            done(true)
            return
        }
        guard let handler = pickHandler, let url = urls.first else { return }
        pickHandler = nil
        handler(url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if let done = exportHandler { done(false) }
        exportHandler = nil
        pickHandler = nil
    }
}
