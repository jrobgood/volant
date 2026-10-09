import SwiftUI
import VolantCore

struct ACPConversationView: View {
    @ObservedObject var model: ACPModel
    var settings: () -> Void = {}
    var back: () -> Void = {}
    var caffeinate: CaffeinateService?
    var focusRequest: UUID = UUID()
    /// Notes and clipboard text offered by the @ picker; none when the host provides no source.
    var contextCandidates: ((String) -> [ChatAttachment])?
    /// The launcher's other conversations, for New and the conversation buttons; nil where this view
    /// shows one model on its own.
    var conversations: ACPConversations?
    var newConversation: () -> Void = {}
    var select: (ACPModel) -> Void = { _ in }
    @State private var follow = true
    @State private var picking = false
    @State private var mentionLocation: Int?
    @State private var editorFocus = UUID()
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: back) { Image(systemName: "chevron.left") }.buttonStyle(.plain).help("Back to search")
                    .accessibilityLabel("Back to search")
                Image("VolantWing").renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 18, height: 18).foregroundStyle(.tint)
                    .accessibilityHidden(true).overlay(LauncherDragHandle())
                if let caffeinate { CaffeinateStatusView(service: caffeinate) }
                Text("AI Chat").fontWeight(.medium)
                Text(model.providerTitle).foregroundStyle(.secondary).lineLimit(1).help(model.providerTitle)
                if !model.project.isEmpty {
                    Label((model.project as NSString).lastPathComponent, systemImage: "folder")
                        .foregroundStyle(.secondary).lineLimit(1).help(model.project)
                }
                Spacer(minLength: 4)
                Button("Settings", action: settings)
                if model.active {
                    if let conversations { ACPNewConversationButton(conversations: conversations, action: newConversation) }
                    Button("End", action: model.disconnect)
                }
                else {
                    if model.canResume { Button("Resume", action: model.resume).help("Continue your last conversation with this provider and folder") }
                    Button(model.canResume ? "New" : "Connect", action: model.start).disabled(!model.configured)
                }
            }.padding(.horizontal, 16).padding(.vertical, 8)
            if let conversations { ACPConversationTabs(conversations: conversations, select: select) }
            Divider()
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.state.messages.isEmpty {
                        Text("What would you like to talk about?")
                            .font(.headline)
                        Text(model.usesAPI ? "Chat with your selected model." : "Chat with your configured AI provider. A project folder is optional.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(model.usesAPI ? "Your messages and this conversation’s completed turns are sent to the configured server. This connection has no agent tools." : "Volant sends only what you write here and anything you attach with @. Sign in through the provider’s CLI before starting.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(model.state.messages) { message in
                        ACPMessageView(message: message, provider: model.providerTitle)
                    }
                    ForEach(model.state.permissions) { permission in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(permission.title, systemImage: "hand.raised").font(.headline)
                            DisclosureGroup("Operation details") {
                                Text(permission.detail).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            }
                            // No default approval or Return shortcut. The user selects the exact agent-provided option.
                            ViewThatFits(in: .horizontal) {
                                HStack { permissionButtons(permission) }
                                VStack(alignment: .leading) { permissionButtons(permission) }
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8)).id(permission.id)
                    }
                    if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    Color.clear.frame(height: 1).id("conversation-bottom")
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                DispatchQueue.main.async {
                    if let permission = model.state.permissions.first { proxy.scrollTo(permission.id, anchor: .top) }
                    else if follow { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
                }
            }
            .onChange(of: model.state.messages) { _, _ in
                if follow { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            }
            .onChange(of: model.state.permissions) { _, _ in
                if let permission = model.state.permissions.first { proxy.scrollTo(permission.id, anchor: .top) }
            }
            }
            Divider()
            HStack(spacing: 8) {
                if model.state.busy && model.state.permissions.isEmpty { ProgressView().controlSize(.small) }
                Text(model.state.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox).font(.caption)
                if ["working", "cancelling"].contains(model.state.phase) {
                    Button("Cancel", action: model.cancel).disabled(model.state.phase == "cancelling")
                }
            }.padding(.horizontal, 16).padding(.vertical, 6)
            if picking, let contextCandidates {
                ChatContextPicker(candidates: contextCandidates, choose: attach, close: closePicker)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.attachments) { attachment in
                            ChatAttachmentChip(attachment: attachment) { model.detach(attachment.id) }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 6)
                .accessibilityLabel("Attached: " + model.attachments.map(\.title).joined(separator: ", "))
            }
            HStack(alignment: .bottom, spacing: 10) {
                ACPPromptView(text: $model.draft, focusRequest: editorFocus, send: model.send,
                              mention: { location in if contextCandidates != nil { mentionLocation = location; picking = true } })
                    .frame(height: 64)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(alignment: .topLeading) {
                        if model.draft.isEmpty {
                            Text("Ask your agent…").font(.system(size: 14)).foregroundStyle(.tertiary)
                                .padding(9).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                if contextCandidates != nil {
                    Button { mentionLocation = nil; picking.toggle() } label: { Image(systemName: "at") }
                        .help("Attach a note or clipboard item (type @)")
                        .accessibilityLabel("Attach a note or clipboard item")
                        .background(ControlAnchor("chat.attach"))
                }
                Button("Send", action: model.send).disabled(!model.canSend)
                    .help("Return to send; Shift-Return for a new line")
            }.padding(.horizontal, 16).padding(.bottom, 12)
        }
        .onAppear { editorFocus = focusRequest }
        .onChange(of: focusRequest) { _, value in editorFocus = value }
    }

    /// Choosing removes the @ that opened the picker, if it is still where it was typed.
    private func attach(_ attachment: ChatAttachment) {
        if model.attach(attachment), let location = mentionLocation {
            let draft = model.draft as NSString
            if location < draft.length, draft.substring(with: NSRange(location: location, length: 1)) == "@" {
                model.draft = draft.replacingCharacters(in: NSRange(location: location, length: 1), with: "")
            }
        }
        closePicker()
    }

    private func closePicker() {
        picking = false
        mentionLocation = nil
        editorFocus = UUID()
    }
    private func permissionButtons(_ permission: ACPPermission) -> some View {
        ForEach(permission.options) { option in
            Button(option.name) { model.choose(permission, option) }
                .help(option.kind.replacingOccurrences(of: "_", with: " "))
                .disabled(model.state.phase != "working")
        }
    }
}


/// Starts another conversation while this one keeps running. It observes the list, so it enables
/// again as soon as a conversation in the background ends.
private struct ACPNewConversationButton: View {
    @ObservedObject var conversations: ACPConversations
    let action: () -> Void
    var body: some View {
        Button("New", action: action)
            .disabled(!conversations.canStartAnother)
            .help("Start another conversation; this one keeps running")
    }
}

/// One button per conversation the owner can switch to, once there is more than one.
private struct ACPConversationTabs: View {
    @ObservedObject var conversations: ACPConversations
    let select: (ACPModel) -> Void
    var body: some View {
        if conversations.shown.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(conversations.shown) { conversation in
                        ACPConversationTab(model: conversation, selected: conversation === conversations.current) { select(conversation) }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
    }
}

/// Observes only its own conversation, so a reply streaming in one button redraws that button.
private struct ACPConversationTab: View {
    @ObservedObject var model: ACPModel
    let selected: Bool
    let select: () -> Void
    @Environment(\.volantTheme) private var theme
    private var folder: String? { model.project.isEmpty ? nil : (model.project as NSString).lastPathComponent }
    private var waiting: Bool { !model.state.permissions.isEmpty }
    /// Provider, folder, first question and status, so VoiceOver tells the buttons apart without the
    /// visual marks.
    private var spokenLabel: String {
        var parts = [model.providerTitle]
        if let folder { parts.append(folder) }
        if let topic = model.topic { parts.append(topic) }
        parts.append(waiting ? "Needs your permission" : model.state.status)
        return parts.joined(separator: ", ")
    }
    var body: some View {
        Button(action: select) {
            HStack(spacing: 4) {
                if waiting { Image(systemName: "hand.raised") }
                else if model.state.busy { ProgressView().controlSize(.mini) }
                Text(model.providerTitle).lineLimit(1)
                if let folder { Text(folder).foregroundStyle(.secondary).lineLimit(1) }
                if let topic = model.topic { Text(topic).foregroundStyle(.secondary).lineLimit(1) }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(selected ? theme.selection : theme.card(selected: false), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(model.project.isEmpty ? model.providerTitle : model.project)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The launcher's row for running conversations. With one it is the row Volant always showed; with
/// several it stays one row, with a button per conversation.
struct ACPActivityStrip: View {
    @ObservedObject var conversations: ACPConversations
    /// Shows a conversation in AI Chat.
    var open: (ACPModel) -> Void
    var body: some View {
        let live = conversations.live
        if let only = live.first, live.count == 1 {
            ACPActivityRow(model: only) { open(only) }
            Divider()
        } else if live.count > 1 {
            HStack {
                Image(systemName: "bubble.left.and.bubble.right")
                Text("AI Chat").fontWeight(.medium)
                ForEach(live) { conversation in
                    ACPConversationBadge(model: conversation) { open(conversation) }
                }
                Spacer()
                // When the row runs short of width, the badges truncate before this button.
                Button("Open conversation") { open(conversations.nextToOpen) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).layoutPriority(1)
                    .help("Open a running conversation, the one waiting for your permission first")
            }.font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 8)
            Divider()
        }
    }
}

private struct ACPActivityRow: View {
    @ObservedObject var model: ACPModel
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack {
                Image(systemName: model.state.permissions.isEmpty ? "bubble.left.and.bubble.right" : "hand.raised")
                Text("AI Chat").fontWeight(.medium)
                Text(model.providerTitle).foregroundStyle(.secondary).lineLimit(1).help(model.providerTitle)
                Text(model.state.status).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text("Open conversation").foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 8)
        }.buttonStyle(.plain)
    }
}

private struct ACPConversationBadge: View {
    @ObservedObject var model: ACPModel
    let open: () -> Void
    @Environment(\.volantTheme) private var theme
    private var waiting: Bool { !model.state.permissions.isEmpty }
    private var spokenLabel: String {
        let parts: [String?] = [model.providerTitle, model.topic, waiting ? "Needs your permission" : model.state.status]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }
    var body: some View {
        Button(action: open) {
            HStack(spacing: 3) {
                if waiting { Image(systemName: "hand.raised") }
                Text(model.providerTitle).lineLimit(1)
                if let topic = model.topic { Text(topic).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(theme.card(selected: false), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(model.state.status)
        .accessibilityLabel(spokenLabel)
    }
}

/// Provider Markdown is rendered locally; user prompts and tool summaries stay literal.
private struct ACPMessageView: View {
    let message: ACPMessage
    let provider: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.role == "Agent" ? provider : message.role)
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if message.role == "Agent" {
                MarkdownContent(text: message.text)
            } else {
                Text(message.text).font(.system(size: 14)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let attachments = message.attachments, !attachments.isEmpty {
                    Label(attachments.joined(separator: " · "), systemImage: "paperclip")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .accessibilityLabel("Attached: " + attachments.joined(separator: ", "))
                }
            }
        }
        .padding(message.role == "You" ? 12 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(message.role == "You" ? 0.05 : 0),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}
