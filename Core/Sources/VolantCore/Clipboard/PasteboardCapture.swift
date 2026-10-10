import Foundation

/// Decides which clipboard history entries one pasteboard change produces.
public enum PasteboardCapture {
    public static let maxTextBytes = 256_000
    public static let maxImageBytes = 8_000_000

    public enum Entry: Equatable {
        case text(String)
        case image(Data)
    }

    /// Returns the entries to record, oldest first. Text and image representations are judged
    /// independently, so a copy that carries both (a design app writing a layer name beside the
    /// picture) keeps the image, and text over its cap no longer prevents image capture. The
    /// image is listed last so it becomes the newest row. `image` yields the PNG form of the
    /// pasteboard image, if any, and is evaluated once.
    public static func entries(text: String?, image: () -> Data?) -> [Entry] {
        var result: [Entry] = []
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= maxTextBytes {
            result.append(.text(text))
        }
        if let png = image(), !png.isEmpty, png.count <= maxImageBytes {
            result.append(.image(png))
        }
        return result
    }
}
