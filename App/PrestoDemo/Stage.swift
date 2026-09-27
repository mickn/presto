import AppKit
import PrestoCore
import SwiftUI

// Everything on screen at a moment of the demo, computed from the real run's events.

/// A window on the pretend desktop: an app Presto opened, or a browser tab it opened.
struct DesktopItem: Identifiable {
    enum Kind { case app(String), browser(title: String, address: String) }

    var id: String
    var kind: Kind
    var appeared: Double
    var removed: Double?
    var undone = false
    /// "1.6 s before you finished".
    var note: String?
}

/// The volume overlay macOS doesn't show for scripted changes; drawn so the change is visible.
struct VolumeFlash {
    var at: Double
    var level: Int
    var muted: Bool
}

/// Scene data in global time (seconds from the start of the video).
struct SceneData {
    var segmentStart: Double
    var audioStart: Double
    var duration: Double
    var title: String
    var said: String
    var events: [LogEvent]
    var envelope: Envelope
    var actions: [String: Action]
    var early: [String: Double]
    var finished: Double?
    var speechEnd: Double?

    func local(_ global: Double) -> Double { global - audioStart }
}

struct World {
    var scenes: [SceneData] = []
    var items: [DesktopItem] = []
    var flashes: [VolumeFlash] = []
    var icons: [String: NSImage] = [:]
    var browserIcon: NSImage?

    mutating func add(_ scene: SceneData) {
        scenes.append(scene)
        for e in scene.events {
            let at = scene.audioStart + e.t
            switch e.event {
            case "executed" where e.status == "done":
                guard let action = e.action.flatMap({ scene.actions[$0] }) else { continue }
                let early = e.action.flatMap { scene.early[$0] }
                let note = early.map { e in
                    abs(e) < 0.15 ? "as you finished" : String(format: "%.1f s %@ you finished", abs(e), e > 0 ? "before" : "after")
                }
                switch action.verb {
                case .openApp:
                    guard let app = action.app, !items.contains(where: { $0.id == app && $0.removed == nil }) else { continue }
                    items.append(DesktopItem(id: app, kind: .app(app), appeared: at, note: note))
                case .quitApp:
                    if let index = items.lastIndex(where: { $0.id == action.app && $0.removed == nil }) { items[index].removed = at }
                case .webSearch, .openWebsite:
                    let query = action.text ?? ""
                    let title = action.verb == .webSearch ? query : (URL(string: query)?.host ?? query)
                    let address = action.verb == .webSearch ? "google.com/search?q=\(query.replacingOccurrences(of: " ", with: "+"))" : query
                    items.append(DesktopItem(id: "web:\(query)", kind: .browser(title: title, address: address), appeared: at, note: note))
                case .setVolume, .volumeUp, .volumeDown, .mute, .unmute:
                    flashes.append(VolumeFlash(at: at, level: action.level ?? 50, muted: action.verb == .mute))
                default:
                    break
                }
            case "undone":
                guard let action = e.action.flatMap({ scene.actions[$0] }), action.verb == .openApp,
                      let index = items.lastIndex(where: { $0.id == action.app && $0.removed == nil }) else { continue }
                items[index].removed = at
                items[index].undone = true
            default:
                break
            }
        }
    }

    mutating func loadIcons() {
        let catalog = AppCatalog.scan()
        for item in items {
            if case let .app(name) = item.kind, let entry = catalog.entry(named: name) {
                icons[name] = NSWorkspace.shared.icon(forFile: entry.url.path)
            }
        }
        if let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) {
            browserIcon = NSWorkspace.shared.icon(forFile: browser.path)
        }
    }
}

// MARK: - Easing

func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
func easeOut(_ x: Double) -> Double { let t = clamp(x); return 1 - pow(1 - t, 3) }
func easeOutBack(_ x: Double) -> Double {
    let t = clamp(x), c1 = 1.70158, c3 = c1 + 1
    return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
}

// MARK: - Palette

enum Palette {
    static let accent = Color(red: 1.0, green: 0.62, blue: 0.1)
    static let jev = Color(red: 0.45, green: 0.78, blue: 1.0)
    static let panel = Color(white: 0.1).opacity(0.72)
    static let hudFill = Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.96)
}

struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.12), Color(red: 0.13, green: 0.07, blue: 0.2)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 0.35, green: 0.2, blue: 0.75).opacity(0.35)).frame(width: 900).blur(radius: 160).offset(x: -520, y: -260)
            Circle().fill(Color(red: 1.0, green: 0.45, blue: 0.15).opacity(0.18)).frame(width: 800).blur(radius: 170).offset(x: 620, y: 360)
        }
    }
}

// MARK: - Scene

struct SceneFrame: View {
    let world: World
    let scene: SceneData
    let number: Int
    let time: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            Wallpaper()
            Header(title: scene.title, number: number)
            Desktop(world: world, time: time)
                .frame(width: 1140, height: 470)
                .offset(x: 70, y: 330)
            VolumeOverlay(flashes: world.flashes, time: time)
                .frame(width: 1140, height: 470)
                .offset(x: 70, y: 330)
            JevPanel(scene: scene, time: time)
                .frame(width: 600, height: 470)
                .offset(x: 1250, y: 330)
            HUDContent(state: hudState, fill: AnyShapeStyle(Palette.hudFill))
                .environment(\.colorScheme, .dark)
                .scaleEffect(1.55, anchor: .top)
                .frame(width: 1920, alignment: .top)
                .offset(y: 70)
            TimelineStrip(scene: scene, time: time)
                .frame(width: 1780, height: 190)
                .offset(x: 70, y: 832)
            Text("Rendered from a real Presto run · every timing comes from its event log")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 1780, alignment: .trailing)
                .offset(x: 70, y: 1040)
        }
        .frame(width: 1920, height: 1080)
        .environment(\.colorScheme, .dark)
    }

    private var hudState: HUDState {
        let t = scene.local(time)
        var state = HUDState()
        let heard = scene.events.last { $0.event == "heard" && $0.t <= t }
        state.transcript = heard?.text ?? ""
        let speechEnd = scene.speechEnd ?? .infinity
        let finished = scene.finished ?? .infinity
        state.phase = t < speechEnd ? .listening : (t < finished ? .finishing : .idle)
        state.level = t < speechEnd ? scene.envelope.value(at: max(t, 0)) * 0.06 : 0
        state.cancelled = scene.events.contains { $0.event == "cancelled" && $0.t <= t }
        var chips: [Chip] = []
        for e in scene.events where e.t <= t {
            switch e.event {
            case "fired":
                if let action = e.firedAction { chips.append(Chip(action: action)) }
            case "executed":
                if let index = chips.lastIndex(where: { $0.action.description == e.action && $0.status == .running }) {
                    chips[index].status = e.status == "done" ? .done : e.status == "failed" ? .failed(e.reason ?? "") : .skipped(e.reason ?? "")
                }
            case "undone":
                if let index = chips.lastIndex(where: { $0.action.description == e.action }) { chips[index].status = .undone }
            default:
                break
            }
        }
        if t >= finished {
            for index in chips.indices { chips[index].early = scene.early[chips[index].action.description] }
        }
        state.chips = chips
        return state
    }
}

private struct Header: View {
    let title: String
    let number: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "bolt.circle.fill").font(.system(size: 30)).foregroundStyle(Palette.accent)
            Text("Presto").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Spacer()
            Text("\(number)").font(.system(size: 17, weight: .bold, design: .rounded))
                .frame(width: 30, height: 30).background(Palette.accent, in: Circle()).foregroundStyle(.black)
            Text(title).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 70)
        .frame(width: 1920)
        .offset(y: 26)
    }
}

// MARK: Desktop

private struct Desktop: View {
    let world: World
    let time: Double

    var body: some View {
        let visible = world.items.filter { $0.appeared <= time && ($0.removed.map { time < $0 + 0.6 } ?? true) }
        ZStack(alignment: .topLeading) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                WindowCard(item: item, icon: icon(for: item), time: time)
                    .offset(slot(index))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func icon(for item: DesktopItem) -> NSImage? {
        switch item.kind {
        case let .app(name): world.icons[name]
        case .browser: world.browserIcon
        }
    }

    private func slot(_ index: Int) -> CGSize {
        let column = index % 3, row = index / 3
        return CGSize(width: Double(column) * 380, height: Double(row) * 240 + Double(column % 2) * 18)
    }
}

private struct WindowCard: View {
    let item: DesktopItem
    let icon: NSImage?
    let time: Double

    var body: some View {
        let appear = easeOutBack((time - item.appeared) / 0.45)
        let leave = item.removed.map { easeOut((time - $0) / 0.5) } ?? 0
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 12, height: 12) }
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.75)).padding(.leading, 8)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Color.white.opacity(0.06))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 350, height: 215)
        .background(Color(red: 0.14, green: 0.14, blue: 0.17), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .overlay(alignment: .center) {
            if item.undone, let removed = item.removed, time >= removed - 0.05 {
                Text("UNDONE").font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(.red)
                    .padding(.horizontal, 18).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.red, lineWidth: 4))
                    .rotationEffect(.degrees(-12))
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
        .scaleEffect(0.6 + 0.4 * appear - 0.15 * leave)
        .opacity(min(clamp((time - item.appeared) / 0.2), 1 - leave))
    }

    private var title: String {
        switch item.kind {
        case let .app(name): name
        case let .browser(title, _): title
        }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 10) {
            if case let .browser(_, address) = item.kind {
                Text(address).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .padding(.horizontal, 16)
            }
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: item.isBrowser ? 70 : 96, height: item.isBrowser ? 70 : 96)
            }
            if let note = item.note {
                Label(note, systemImage: "bolt.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.accent)
            }
        }
    }
}

extension DesktopItem {
    var isBrowser: Bool { if case .browser = kind { true } else { false } }
}

private struct VolumeOverlay: View {
    let flashes: [VolumeFlash]
    let time: Double

    var body: some View {
        if let flash = flashes.last(where: { $0.at <= time && time < $0.at + 1.8 }) {
            let fade = min(clamp((time - flash.at) / 0.15), clamp((flash.at + 1.8 - time) / 0.3))
            VStack(spacing: 18) {
                Image(systemName: flash.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 64)).foregroundStyle(.white)
                HStack(spacing: 3) {
                    ForEach(0 ..< 16, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(!flash.muted && Double(i) < Double(flash.level) / 100 * 16 ? Color.white : Color.white.opacity(0.18))
                            .frame(width: 9, height: 12)
                    }
                }
                Text(flash.muted ? "Muted" : "\(flash.level)%").font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
            .frame(width: 230, height: 230)
            .background(Color(white: 0.15).opacity(0.92), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .opacity(fade)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: Jev panel

private struct JevPanel: View {
    let scene: SceneData
    let time: Double

    var body: some View {
        let t = scene.local(time)
        let answered = scene.events.filter { $0.event == "jev" && $0.t <= t }
        let rows = Array(answered.suffix(5))
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Jev").font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(Palette.jev)
                Text("text in → probabilities out").font(.system(size: 16, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.55))
                Spacer()
                let mean = answered.isEmpty ? 0 : answered.compactMap(\.ms).reduce(0, +) / answered.count
                Text(answered.isEmpty ? "" : "\(answered.count) calls · avg \(mean) ms")
                    .font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.55))
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, e in
                JevRow(event: e, fresh: t - e.t < 0.35, newest: index == rows.count - 1)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

private struct JevRow: View {
    let event: LogEvent
    let fresh: Bool
    let newest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\u{201C}\(event.clause ?? "")\u{201D}").font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white).lineLimit(1)
                Spacer()
                Text("\(event.ms ?? 0) ms").font(.system(size: 13, weight: .bold, design: .rounded))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Palette.jev.opacity(0.18), in: Capsule()).foregroundStyle(Palette.jev)
            }
            HStack(spacing: 14) {
                Bar(label: event.verb ?? "", value: event.verb_conf ?? 0)
                if let app = event.app, !app.isEmpty { Bar(label: app, value: event.app_conf ?? 0) }
            }
        }
        .padding(12)
        .background(Color.white.opacity(newest ? 0.09 : 0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.jev.opacity(fresh ? 0.8 : 0), lineWidth: 2))
    }
}

private struct Bar: View {
    let label: String
    let value: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1)).frame(width: 90, height: 7)
                Capsule().fill(value >= 0.8 ? Palette.accent : Palette.jev).frame(width: 90 * value, height: 7)
            }
            Text(String(format: "%.2f", value)).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
        }
    }
}

// MARK: Timeline

private struct TimelineStrip: View {
    let scene: SceneData
    let time: Double

    /// Seconds shown across the strip: the voice, the last action, and a little room after.
    private var span: Double {
        let lastFired = scene.events.filter { $0.event == "fired" }.map(\.t).max() ?? 0
        return max(scene.envelope.voiceEnd, lastFired) + 1.4
    }
    private let width = 1700.0
    private func x(_ local: Double) -> Double { 40 + local / span * width }

    var body: some View {
        let t = scene.local(time)
        let voiceEnd = scene.envelope.voiceEnd
        let fired = scene.events.filter { $0.event == "fired" && $0.t <= t }

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.panel)
            Text("YOUR VOICE").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.45)).offset(x: 40, y: 14)
            Canvas { context, size in
                let mid = 92.0
                let heard = min(t, Double(scene.envelope.values.count) / scene.envelope.fps)
                for (i, v) in scene.envelope.values.enumerated() {
                    let at = Double(i) / scene.envelope.fps
                    let h = max(2, Double(v) * 70)
                    let rect = CGRect(x: x(at), y: mid - h / 2, width: max(1.5, width / span / scene.envelope.fps - 1), height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.white.opacity(at <= heard ? 0.85 : 0.18)))
                }
            }
            .frame(width: 1780, height: 190)
            if t >= voiceEnd {
                Rectangle().fill(.white.opacity(0.7)).frame(width: 2, height: 110).offset(x: x(voiceEnd), y: 38)
                Text("you finish speaking").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.75))
                    .fixedSize().offset(x: x(voiceEnd) + 8, y: 150)
            }
            ForEach(Array(fired.enumerated()), id: \.offset) { index, e in
                let at = x(e.t)
                let early = scene.early[e.action ?? ""] ?? 0
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Palette.accent).frame(width: 3, height: 116).offset(x: at - 1.5, y: 32)
                    Label(e.firedAction?.label ?? "", systemImage: "bolt.fill")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Palette.accent, in: Capsule())
                        .fixedSize()
                        .offset(x: at + 6, y: 16 + Double(index % 2) * 26)
                    if t >= voiceEnd, early > 0.3 {
                        let grow = easeOut((t - voiceEnd) / 0.5)
                        Rectangle().fill(Palette.accent.opacity(0.9))
                            .frame(width: max(0, (x(voiceEnd) - at) * grow), height: 3)
                            .offset(x: at, y: 132)
                        Text(String(format: "%.1f s early", early)).font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundStyle(Palette.accent).fixedSize()
                            .opacity(grow)
                            .offset(x: at + 8, y: 138)
                    }
                }
            }
            Rectangle().fill(.white).frame(width: 2, height: 150).offset(x: x(min(max(t, 0), span)), y: 20)
        }
    }
}

// MARK: - Cards

struct CardFrame: View {
    let segment: Segment
    let local: Double

    var body: some View {
        let appear = easeOut(local / 0.6)
        ZStack {
            Wallpaper()
            VStack(spacing: 26) {
                if segment.subtitle == nil {
                    Image(systemName: "bolt.circle.fill").font(.system(size: 110)).foregroundStyle(Palette.accent)
                }
                Text(segment.title)
                    .font(.system(size: segment.subtitle == nil ? 120 : 72, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                if let subtitle = segment.subtitle {
                    Text(subtitle).font(.system(size: 36, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center).frame(maxWidth: 1400)
                }
                if let detail = segment.detail {
                    Text(detail).font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.accent).padding(.top, 20)
                }
            }
            .opacity(appear)
            .offset(y: 24 * (1 - appear))
        }
        .frame(width: 1920, height: 1080)
    }
}
