import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum IOSDocumentPickerError: Error {
    case cancelled
}

enum IOSDataPackagePickerMode {
    case importing
    case exporting(URL)
}

struct IOSDocumentPicker: UIViewControllerRepresentable {
    let mode: IOSDataPackagePickerMode
    let completion: (Result<[URL], Error>) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = switch mode {
        case .importing:
            UIDocumentPickerViewController(
                forOpeningContentTypes: [.json],
                asCopy: false
            )
        case let .exporting(url):
            UIDocumentPickerViewController(
                forExporting: [url],
                asCopy: true
            )
        }
        controller.allowsMultipleSelection = false
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let completion: (Result<[URL], Error>) -> Void

        init(completion: @escaping (Result<[URL], Error>) -> Void) {
            self.completion = completion
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            completion(.success(urls))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            completion(.failure(IOSDocumentPickerError.cancelled))
        }
    }
}
