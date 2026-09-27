import PrestoCore
import SwiftUI

// The HUD's look, independent of the app model, so the demo renderer draws exactly what the app shows.

enum ListeningPhase: Equatable { case idle, starting, listening, finishing }

/// One action in the HUD.
struct Chip: Identifiable, Equatable {
    enum Status: Equatable { case running, done, skipped(String), failed(String), undone }

    var id = UUID()
    var action: Action
    var status: Status = .running
    /// Seconds before the speaker finished; filled in at the end of the utterance.
    var early: Double?
}

struct HUDState: Equatable {
    var phase: ListeningPhase = .idle
    var transcript = ""
    var level: Float = 0
    var chips: [Chip] = []
    var notice: String?
    var cancelled = false
}

struct HUDContent: View {
    let state: HUDState
    /// Offscreen rendering can't draw materials; the demo passes an opaque fill instead.
    var fill: AnyShapeStyle = AnyShapeStyle(.regularMaterial)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                StatusDot(phase: state.phase, level: state.level, cancelled: state.cancelled)
                Text(caption)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(state.transcript.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.interpolate)
                    .animation(.snappy(duration: 0.15), value: state.transcript)
            }
            if !state.chips.isEmpty {
                ChipRow(chips: state.chips)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 580, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .animation(.spring(duration: 0.3), value: state.chips)
    }

    private var caption: String {
        if let notice = state.notice, state.transcript.isEmpty { return notice }
        if state.cancelled { return "Cancelled" }
        if !state.transcript.isEmpty { return state.transcript }
        switch state.phase {
        case .starting, .listening: return "Listening…"
        case .finishing: return "…"
        case .idle: return state.chips.isEmpty ? "Didn't catch that" : ""
        }
    }
}

private struct StatusDot: View {
    let phase: ListeningPhase
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
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
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
