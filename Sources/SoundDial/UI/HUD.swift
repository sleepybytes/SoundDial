import AppKit
import Observation
import SwiftUI

/// Small translucent overlay shown at the bottom of the screen after each hotkey.
@MainActor
final class HUD {
    static let shared = HUD()

    @Observable @MainActor
    final class State {
        var icon: NSImage?
        var symbol: String?
        var title = ""
        var subtitle = ""
        var level: Float = 0
        var muted = false
    }

    private let state = State()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(icon: NSImage?, symbol: String?, title: String, subtitle: String, level: Float, muted: Bool) {
        state.icon = icon
        state.symbol = symbol
        state.title = title
        state.subtitle = subtitle
        state.level = level
        state.muted = muted

        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 110))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { [weak panel] in
            try? await Task.sleep(for: .seconds(1.3))
            guard !Task.isCancelled, let panel else { return }
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 0 }
            if !Task.isCancelled { panel.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 92),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView(state: state))
        return panel
    }
}

private struct HUDView: View {
    let state: HUD.State

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Group {
                    if let icon = state.icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: state.symbol ?? "speaker.wave.2").resizable().scaledToFit().padding(4)
                    }
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title).font(.headline).lineLimit(1)
                    if !state.subtitle.isEmpty {
                        Text(state.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(state.muted ? "Muted" : "\(Int((state.level * 100).rounded()))%")
                    .font(.system(.body, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            LevelBar(level: state.muted ? 0 : state.level)
        }
        .padding(14)
        .frame(width: 300, height: 92)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.primary).frame(width: geo.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.1), value: level)
    }
}
