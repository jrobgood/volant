import SwiftUI
import VolantCore

enum LauncherEntryKind: String {
    case snippet, quicklink

    var title: String { self == .snippet ? "Create Snippet" : "Create Quicklink" }
    var savedMessage: String { self == .snippet ? "Snippet saved." : "Quicklink saved." }
    /// The name field's placeholder, which also lets the panel find that field to focus it.
    var namePlaceholder: String { self == .snippet ? "Email signature" : "Search Docs" }
}

/// The in-panel form's fields. It is observed by the form alone, so typing does not redraw the
/// launcher, and it holds the snapshot the new entry is validated and saved against.
final class LauncherEntryDraft: ObservableObject, Identifiable {
    let id = UUID()
    let kind: LauncherEntryKind
    var snapshot: LauncherEntries.Snapshot
    @Published var name = ""
    @Published var keyword = ""
    /// The snippet text or the quicklink URL.
    @Published var text = ""
    @Published var error: String?

    init(kind: LauncherEntryKind, snapshot: LauncherEntries.Snapshot) {
        self.kind = kind
        self.snapshot = snapshot
    }
}

/// Creates a snippet or quicklink inside the launcher. Return in a single-line field saves,
/// Command-Return saves from anywhere, including the multi-line snippet text, and Escape cancels
/// back to the launcher.
struct LauncherEntryFormView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var draft: LauncherEntryDraft
    @FocusState private var field: Field?

    private enum Field: Hashable { case name, keyword, text }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(draft.kind.title).font(.headline)
            fields
            Spacer(minLength: 0)
            buttons
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .onAppear { field = .name }
        .onKeyPress(.escape) { model.cancelEntryForm(); return .handled }
    }

    @ViewBuilder private var fields: some View {
        labeled("Name") {
            TextField(draft.kind.namePlaceholder, text: $draft.name)
                .focused($field, equals: .name).onSubmit(save)
                .accessibilityIdentifier("launcher-entry-name")
        }
        if draft.kind == .snippet {
            labeled("Keyword") {
                TextField("Optional, one word, for example sig", text: $draft.keyword)
                    .focused($field, equals: .keyword).onSubmit(save)
                    .accessibilityIdentifier("launcher-entry-keyword")
            }
            snippetText
        } else {
            labeled("URL") {
                TextField("https://example.com/search?q={query}", text: $draft.text)
                    .focused($field, equals: .text).onSubmit(save)
                    .accessibilityIdentifier("launcher-entry-url")
            }
            hint("Type the quicklink’s name, a space and a term to put it in place of {query}. Opens http, https, mailto and Shortcuts run links.")
        }
    }

    private var snippetText: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Text").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            TextEditor(text: $draft.text)
                .font(.system(size: 13)).scrollContentBackground(.hidden)
                .padding(4).frame(minHeight: 56, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                .focused($field, equals: .text)
                .accessibilityLabel("Snippet text")
                .accessibilityIdentifier("launcher-entry-text")
            hint("Placeholders: " + LauncherEntries.snippetPlaceholders.joined(separator: " ") + ". Return adds a line; ⌘↩ saves.")
        }
    }

    /// Keeps a validation error beside the buttons rather than on its own line, so the form fits
    /// the compact panel size with an error showing.
    private var buttons: some View {
        HStack(spacing: 12) {
            Button("Cancel") { model.cancelEntryForm() }
            if let error = draft.error {
                Text(error).font(.callout).foregroundStyle(.red).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error: " + error)
            }
            Spacer(minLength: 8)
            Button("Save") { save() }
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("launcher-entry-save")
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            content().textFieldStyle(.roundedBorder)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Saves, or moves focus to the first field that needs attention when saving fails.
    private func save() {
        guard !model.saveEntry(draft) else { return }
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { field = .name }
        else if draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { field = .text }
    }
}
