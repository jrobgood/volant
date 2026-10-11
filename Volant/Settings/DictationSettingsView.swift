import SwiftUI
import VolantCore

/// Settings → General → Dictation: where dictation's text goes, when typing happens, the
/// Accessibility state while typing is chosen, and the output volume.
struct DictationSettingsSection: View {
    let config: Preferences
    @ObservedObject var access: DictationTypingAccess
    let apply: (() throws -> Void) -> Void
    let configURL: URL

    var body: some View {
        Section {
            Picker("Dictation output", selection: Binding(get: { config.dictationOutput }, set: choose)) {
                Text("Copy to clipboard").tag(DictationOutput.copy)
                Text("Type at the cursor").tag(DictationOutput.type)
            }
            if config.dictationOutput == .type {
                Picker("Type", selection: Binding(get: { config.dictationTypesWhileSpeaking }, set: { value in
                    apply { try Preferences.updateBoolean("dictationTypesWhileSpeaking", value: value, at: configURL) }
                })) {
                    Text("While speaking").tag(true)
                    Text("When finished").tag(false)
                }
                LabeledContent("Accessibility") { DictationAccessStatus(access: access) }
            } else if access.stoppedHelper {
                LabeledContent {
                    Button("Open Accessibility Settings") { access.openAccessibilitySettings() }
                } label: {
                    Text("Volant no longer uses Accessibility. To remove its access, turn off Volant in Privacy & Security → Accessibility.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle("Lower volume while dictating", isOn: Binding(get: { config.dictationLowersVolume }, set: { value in
                apply { try Preferences.updateBoolean("dictationLowersVolume", value: value, at: configURL) }
            }))
        } header: {
            Text("Dictation")
        } footer: {
            SettingsFooter(footer)
        }
        .onAppear { access.refresh(config.dictationOutput) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            access.refresh(config.dictationOutput)
        }
    }

    /// Saves the choice, then lets the access model connect, prompt once, or stop the helper.
    private func choose(_ output: DictationOutput) {
        guard output != config.dictationOutput else { return }
        var saved = false
        apply {
            try Preferences.updateDictationOutput(output, at: configURL)
            saved = true
        }
        if saved { access.chose(output) }
    }

    private var footer: String {
        let volume = "While the microphone is listening, the current output plays at a fifth of its volume. It returns to its previous level when you stop, unless you changed the volume yourself in the meantime. Muted outputs and outputs without software volume are left alone."
        guard config.dictationOutput == .type else {
            return "Dictation from the shortcut copies what you said; press ⌘V to paste it. Type at the cursor types it into the app you’re using instead, and asks once for Accessibility permission. " + volume
        }
        return "Volant’s input helper types into the app in front without bringing Volant forward: each phrase as soon as it’s final, or everything when you stop. Return finishes and Escape cancels. It never types into password fields or while secure input is on, and copies instead. Only the helper uses Accessibility; System Settings lists it as Volant. Choosing Copy to clipboard stops the helper. " + volume
    }
}

/// The Accessibility state for typing, with the action that fixes it.
struct DictationAccessStatus: View {
    @ObservedObject var access: DictationTypingAccess

    var body: some View {
        HStack(spacing: 8) {
            switch access.state {
            case .idle, .checking:
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            case .allowed:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            case .notAllowed:
                Text("Not allowed").foregroundStyle(.secondary)
                Button("Open Accessibility Settings") { access.openAccessibilitySettings() }
            case .unavailable:
                Text("Input helper unavailable").foregroundStyle(.secondary)
                Button("Check Again") { access.refresh(.type) }
            }
        }
    }
}
