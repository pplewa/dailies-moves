import SwiftUI
import UIKit

/// Native iOS Share Sheet wrapper for `.gpx` files.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Native Files / iCloud Drive export sheet wrapping `UIDocumentPickerViewController(forExporting:asCopy:)`.
/// Avoids SwiftUI `.fileExporter` custom-UTType and toolbar-menu presentation bugs on iOS 17–26.
struct DocumentExportSheet: UIViewControllerRepresentable {
    let fileURL: URL
    let onComplete: (Result<URL, Error>) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onComplete: (Result<URL, Error>) -> Void
        let onCancel: () -> Void

        init(onComplete: @escaping (Result<URL, Error>) -> Void, onCancel: @escaping () -> Void) {
            self.onComplete = onComplete
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let first = urls.first {
                onComplete(.success(first))
            } else {
                onCancel()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
