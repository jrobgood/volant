import AppKit
import Combine
import SwiftUI

/// A small floating indicator for dictation started from the global hotkey. It is borderless and
/// non-activating, cannot become key or main, and ignores the mouse, so the app the owner is
/// typing in stays frontmost and keeps keyboard focus. It is ordered in with
/// `orderFrontRegardless`, never `makeKey`, and nothing here activates Volant.
final class DictationIndicatorPanel: NSPanel {
    static let width: CGFloat = 440
    static let bottomInset: CGFloat = 72
    let model: DictationIndicatorModel
    private let host: NSHostingView<AnyView>
    private var subscription: AnyCancellable?

    init(model: DictationIndicatorModel) {
        self.model = model
        host = NSHostingView(rootView: AnyView(ThemedRoot { DictationIndicatorView(model: model) }))
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 64),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        setAccessibilitySubrole(.floatingWindow)
        contentView = host
        subscription = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows, resizes or hides the panel to match the model.
    func refresh() {
        guard model.isVisible else { fadeOut(); return }
        host.layoutSubtreeIfNeeded()
        let height = max(44, host.fittingSize.height)
        let origin = Self.origin(for: NSSize(width: Self.width, height: height), on: Self.targetScreen())
        setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
        alphaValue = 1
        if !isVisible { orderFrontRegardless() }
    }

    /// Fades the panel out, unless the model has become visible again in the meantime.
    private func fadeOut() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if !self.model.isVisible { self.orderOut(nil) }
            self.alphaValue = 1
        })
    }

    /// The screen under the mouse pointer, where the owner is looking, or the main screen.
    static func targetScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Bottom center of the screen's visible area, above the Dock.
    static func origin(for size: NSSize, on screen: NSScreen?) -> NSPoint {
        guard let frame = screen?.visibleFrame else { return .zero }
        return NSPoint(x: (frame.midX - size.width / 2).rounded(), y: (frame.minY + bottomInset).rounded())
    }
}

/// The indicator's content: a symbol for the phase, a title, and the heard text, stop hint or
/// result beneath it. Drawn on the theme's window background so light, dark and palette themes
/// stay legible in a window that is never key.
struct DictationIndicatorView: View {
    @ObservedObject var model: DictationIndicatorModel
    @Environment(\.volantTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DictationIndicatorSymbol(phase: model.phase)
            DictationIndicatorText(model: model)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: DictationIndicatorPanel.width, alignment: .leading)
        .background(theme.windowBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.separator(0.12)))
        .accessibilityElement(children: .combine)
    }
}

/// The phase symbol: a tinted microphone while listening, a waveform while transcribing, and a
/// check or notice for the result.
struct DictationIndicatorSymbol: View {
    let phase: DictationIndicatorModel.Phase

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }

    private var tinted: Bool {
        switch phase {
        case .listening: return true
        case .result(_, let outcome): return outcome == .copied || outcome == .typed
        default: return false
        }
    }

    private var name: String {
        switch phase {
        case .hidden, .listening: return "mic.fill"
        case .transcribing: return "waveform"
        case .result(_, .copied), .result(_, .typed): return "checkmark.circle.fill"
        case .result(_, .failed): return "exclamationmark.triangle.fill"
        case .result: return "mic.slash"
        }
    }
}

/// The indicator's title and detail lines for the current phase.
struct DictationIndicatorText: View {
    @ObservedObject var model: DictationIndicatorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if !model.partial.isEmpty {
                Text(model.partial).font(.system(size: 13)).lineLimit(2).truncationMode(.head)
            }
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var title: String {
        switch model.phase {
        case .hidden, .listening: return "Listening"
        case .transcribing: return "Transcribing…"
        case .result(let text, _): return text
        }
    }

    private var detail: String? {
        var lines: [String] = []
        if model.phase == .listening {
            lines.append(model.stopHint + Self.keyHint(escape: model.escapeCancels, return: model.returnFinishes))
        }
        if model.phase == .listening || model.phase == .transcribing, let problem = model.volumeProblem {
            lines.append(problem)
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// The end of the stop hint, naming only the keys that are actually registered.
    static func keyHint(escape: Bool, return finishes: Bool) -> String {
        switch (finishes, escape) {
        case (true, true): return ". Return finishes, Escape cancels."
        case (true, false): return ". Return finishes."
        case (false, true): return ". Escape cancels."
        case (false, false): return "."
        }
    }
}
