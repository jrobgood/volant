import SwiftUI

/// Recording and removal commit immediately. A failed write stays pending for retry.
struct ShortcutControl: View {
    let title: String
    let value: String
    let onSave: (String) throws -> Void
    @State private var feedback = ShortcutFeedback()
    @State private var pending: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            ShortcutRecorder(value: Binding(get: { value }, set: { persist($0) }), removable: true)
                .frame(height: 26)
                .accessibilityLabel(title + " shortcut: " + (value.isEmpty ? "Not set" : value))
                .accessibilityAction(named: "Remove shortcut") { persist("") }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                if let pending { Button("Retry") { persist(pending) }.font(.callout) }
            } else if let message = feedback.message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(title + " shortcut " + message.lowercased())
            }
        }
        .onChange(of: value) { _, latest in feedback.valueChanged(to: latest) }
        .task(id: feedback.generation) {
            guard feedback.message != nil else { return }
            try? await Task.sleep(for: ShortcutFeedback.duration)
            if !Task.isCancelled { feedback.expire() }
        }
    }
    private func persist(_ replacement: String) {
        feedback.clear()
        pending = replacement
        do {
            try onSave(replacement)
            pending = nil
            error = nil
            feedback.saved(replacement)
        } catch { self.error = error.localizedDescription }
    }
}

/// The brief Saved or Removed confirmation after this control writes a shortcut. It expires after a
/// short delay, and it clears as soon as the shortcut changes to anything else, such as an edit made in
/// the app's editor sheet, so a stale confirmation never outlives the value it describes.
struct ShortcutFeedback: Equatable {
    static let duration: Duration = .seconds(2.5)
    private(set) var message: String?
    private(set) var generation = 0
    private var savedValue: String?

    /// Records a successful write of `value` and shows its confirmation.
    mutating func saved(_ value: String) {
        savedValue = value
        message = value.isEmpty ? "Removed" : "Saved"
        generation += 1
    }
    /// Keeps the confirmation while the displayed value is the one just written; clears it otherwise.
    mutating func valueChanged(to value: String) {
        if value != savedValue { clear() }
    }
    /// Hides the confirmation once its display time has passed.
    mutating func expire() { clear() }
    /// Removes any confirmation, for example when a new write starts.
    mutating func clear() {
        message = nil
        savedValue = nil
        generation += 1
    }
}
