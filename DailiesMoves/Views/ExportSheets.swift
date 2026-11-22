import SwiftUI
import UIKit

/// Presents native UIKit system sheets (`UIDocumentPickerViewController` and `UIActivityViewController`)
/// directly from the active window's top-most `UIViewController`.
///
/// Presenting remote view controllers like `UIDocumentPickerViewController` directly (instead of embedding
/// them inside a SwiftUI `.sheet` hosting wrapper) avoids blank/stuck sheet bugs on iOS 17–26.
@MainActor
final class NativeExportPresenter: NSObject, UIDocumentPickerDelegate {
    static let shared = NativeExportPresenter()

    private var exportCompletion: ((Result<URL, Error>) -> Void)?

    func presentExport(fileURL: URL, onComplete: @escaping (Result<URL, Error>) -> Void) {
        guard let presenter = topViewController() else { return }
        exportCompletion = onComplete
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    func presentShare(fileURL: URL) {
        guard let presenter = topViewController() else { return }
        let vc = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        presenter.present(vc, animated: true)
    }

    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let keyWindow = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: - UIDocumentPickerDelegate

    nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let first = urls.first
        Task { @MainActor in
            let cb = self.exportCompletion
            self.exportCompletion = nil
            if let first {
                cb?(.success(first))
            }
        }
    }

    nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Task { @MainActor in
            self.exportCompletion = nil
        }
    }
}
