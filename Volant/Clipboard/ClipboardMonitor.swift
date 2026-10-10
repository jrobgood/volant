import AppKit
import VolantCore

/// Polls the general pasteboard's change count and records the text and image entries of copies that pass the filter.
final class ClipboardMonitor {
    private let store: ClipboardStore
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount

    init(store: ClipboardStore) { self.store = store }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        let types = (pb.types ?? []).map(\.rawValue)
        guard PasteboardFilter.shouldRecord(types: types) else { return }
        let entries = PasteboardCapture.entries(text: pb.string(forType: .string)) {
            pb.data(forType: .png) ?? pb.data(forType: .tiff).flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        }
        for entry in entries {
            switch entry {
            case .text(let text): store.record(text)
            case .image(let png): store.recordImage(png)
            }
        }
    }
}
