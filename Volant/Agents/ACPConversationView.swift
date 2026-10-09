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
                if model.active { Button("End", action: model.disconnect) }
                else {
                    if model.canResume { Button("Resume", action: model.resume).help("Continue your last conversation with this provider and folder") }
                    Button(model.canResume ? "New" : "Connect", action: model.start).disabled(!model.configured)
                }
            }.padding(.horizontal, 16).padding(.vertical, 8)
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


struct ACPActivityStrip: View {
    @ObservedObject var model: ACPModel
    var open: () -> Void
    var body: some View {
        if model.active {
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
            Divider()
        }
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
// CI baseline marker
