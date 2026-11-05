import SwiftUI
import UIKit

/// File picker for the pairing file.
///
/// Not `.fileImporter`: that opens files in place, and on iOS 27 picking from
/// On My iPhone in that mode leaves the picker open with no file and no error
/// (OpenMinis/iCTRL#5). Asking for a copy works, and a copy is all the import
/// needs.
struct PairingFilePicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: PairingFileStore.supportedContentTypes,
                                                    asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
