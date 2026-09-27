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
        HUDContent(state: model.hudState)
            .frame(width: 620, height: 170, alignment: .top)
            .padding(.top, 4)
    }
}
