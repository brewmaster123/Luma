import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 0.9.9: the Files picker for «Добавить из файлов».
/// In 0.9.8 SwiftUI's file importer sat on a sheet stacked on a sheet, next to the recorder's sheet,
/// and on the iPhone a chosen file often never arrived. This is the system document picker itself.
/// It opens copies (`asCopy`): the system downloads the file, from iCloud or another app's folder
/// as well, and hands over a copy in the app's own temporary folder. The person's original file
/// is never opened in place and never deleted; only that copy is removed after the import.
struct AudioFilePicker: UIViewControllerRepresentable {
  let done: (URL?) -> Void

  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true)
    picker.allowsMultipleSelection = false
    picker.shouldShowFileExtensions = true
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(done: done) }

  final class Coordinator: NSObject, UIDocumentPickerDelegate {
    let done: (URL?) -> Void
    init(done: @escaping (URL?) -> Void) { self.done = done }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
      done(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      done(nil)
    }
  }
}
