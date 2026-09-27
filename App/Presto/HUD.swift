import AppKit
import PrestoCore
import SwiftUI

/// A floating, click-through panel at the top of the screen that never takes focus, so
/// keystrokes Presto sends still land in the app you're using.
@MainActor
final class HUDController {
    private var panel: NSPanel?
    private weak var model: AppModel?
    private static let size = NSSize(width: 620, height: 170)

    func attach(_ model: AppModel) {
        self.model = model
    }

    func show() {
        guard let model else { return }
        let panel = panel ?? makePanel(model)
        self.panel = panel
        position(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    func snapshot(to url: URL) {
        guard let view = panel?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private func makePanel(_ model: AppModel) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        return panel
    }

    /// Top centre of the screen the pointer is on.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.maxY - Self.size.height - 8))
    }
}

struct HUDView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                StatusDot(phase: model.phase, level: model.level, cancelled: model.cancelled)
                Text(caption)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(model.transcript.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.interpolate)
                    .animation(.snappy(duration: 0.15), value: model.transcript)
            }
            if !model.chips.isEmpty {
                ChipRow(chips: model.chips)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 580, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .frame(width: 620, height: 170, alignment: .top)
        .padding(.top, 4)
        .animation(.spring(duration: 0.3), value: model.chips)
    }

    private var caption: String {
        if let notice = model.notice, model.transcript.isEmpty { return notice }
        if model.cancelled { return "Cancelled" }
        if !model.transcript.isEmpty { return model.transcript }
        switch model.phase {
        case .starting, .listening: return "Listening…"
        case .finishing: return "…"
        case .idle: return model.chips.isEmpty ? "Didn't catch that" : ""
        }
    }
}

private struct StatusDot: View {
    let phase: AppModel.Phase
    let level: Float
    let cancelled: Bool

    var body: some View {
        ZStack {
            switch phase {
            case .starting, .listening:
                Circle().fill(.red.opacity(0.25))
                    .frame(width: 26, height: 26)
                    .scaleEffect(1 + CGFloat(min(level * 12, 0.6)))
                    .animation(.easeOut(duration: 0.12), value: level)
                Circle().fill(.red).frame(width: 12, height: 12)
            case .finishing:
                ProgressView().controlSize(.small)
            case .idle:
                Image(systemName: cancelled ? "xmark.circle.fill" : "bolt.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(cancelled ? Color.secondary : Color.yellow)
            }
        }
        .frame(width: 28, height: 28)
    }
}

private struct ChipRow: View {
    let chips: [Chip]

    var body: some View {
        FlowRow(spacing: 8) {
            ForEach(chips) { chip in
                ChipView(chip: chip)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
    }
}

private struct ChipView: View {
    let chip: Chip

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(chip.status == .done || chip.status == .running ? Color.orange : tint)
            Text(chip.action.label)
                .strikethrough(chip.status == .undone)
                .lineLimit(1)
            if let early = chip.early, early > 0.05, chip.status == .done {
                Text(String(format: "%.1fs early", early))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.orange)
            }
            if let reason = reason {
                Text(reason).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.system(size: 13, weight: .medium, design: .rounded))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.14), in: Capsule())
    }

    private var icon: String {
        switch chip.status {
        case .running: "bolt.fill"
        case .done: "bolt.fill"
        case .skipped: "pause.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .undone: "arrow.uturn.backward"
        }
    }

    private var tint: Color {
        switch chip.status {
        case .running, .done: .yellow
        case .skipped, .undone: .secondary
        case .failed: .orange
        }
    }

    private var reason: String? {
        switch chip.status {
        case let .skipped(reason), let .failed(reason): reason
        default: nil
        }
    }
}

/// Lays chips out left to right, wrapping when a row is full.
private struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 560
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
