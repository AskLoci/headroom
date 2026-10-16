import AppKit
import HeadroomCore
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 520)
        popover.contentViewController = NSHostingController(rootView: PopoverView().environment(model))
        popover.delegate = self
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("Headroom")
        }
        renderTitle()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.openWindowOnFirstLaunch()
        }
    }

    /// The first launch also opens the window: a full menu bar tucks a new item into its hidden-items list.
    private func openWindowOnFirstLaunch() {
        let key = "didOpenWindowOnFirstLaunch"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        showWindow()
    }

    /// Draws the menu bar image now and again whenever the segments change.
    private func renderTitle() {
        withObservationTracking {
            draw()
        } onChange: { [weak self] in
            Task { @MainActor in self?.renderTitle() }
        }
    }

    private func draw() {
        let segments = model.menuBarSegments
        let image = MenuBarTitle.image(segments)
        // A fixed length skips the standard padding so the item needs as little menu bar room as possible.
        let length = ceil(image.size.width) + 2
        if statusItem.length != length { statusItem.length = length }
        statusItem.button?.image = image
        statusItem.button?.setAccessibilityValue(segments.map { "\($0.glyph) \($0.percentText)" }.joined(separator: ", "))
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Shows Headroom in a regular window, for when the menu bar has no room for its item.
    func showWindow() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: PopoverView().environment(model)))
            window.title = "Headroom"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        model.contentShown()
    }

    func popoverDidShow(_ notification: Notification) {
        model.contentShown()
    }

    func popoverDidClose(_ notification: Notification) {
        updateVisibility()
    }

    func windowWillClose(_ notification: Notification) {
        if !popover.isShown { model.contentHidden() }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        updateVisibility()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        updateVisibility()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        updateVisibility()
    }

    /// Lists follow file changes at once only while the popover or an unobscured window is showing.
    private func updateVisibility() {
        let windowShowing = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        if popover.isShown || windowShowing {
            model.contentShown()
        } else {
            model.contentHidden()
        }
    }
}

enum MenuBarTitle {
    /// One ring per provider filled to the weekly share used, with the provider's mark inside (an
    /// asterisk for Claude, a terminal for Codex) and the percentage beside it. A template image, which
    /// macOS tints for a light or dark menu bar, unless a number has reached 80 %; then that ring and
    /// number turn orange (red from 95 %).
    static func image(_ segments: [MenuBarSegment]) -> NSImage {
        let template = segments.allSatisfy { $0.level == .normal }
        let width = segments.map(segmentWidth).reduce(0, +) + spacing * CGFloat(max(segments.count - 1, 0))
        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for segment in segments {
                draw(segment, at: x, template: template)
                x += segmentWidth(segment) + spacing
            }
            return true
        }
        image.isTemplate = template
        return image
    }

    private static let height: CGFloat = 22
    private static let ringSize: CGFloat = 16
    private static let ringLine: CGFloat = 1.9
    private static let gap: CGFloat = 3
    private static let spacing: CGFloat = 8

    private static func label(_ segment: MenuBarSegment, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: segment.percentText, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: color,
        ])
    }

    private static func segmentWidth(_ segment: MenuBarSegment) -> CGFloat {
        ringSize + gap + ceil(label(segment, color: .black).size().width)
    }

    private static func draw(_ segment: MenuBarSegment, at x: CGFloat, template: Bool) {
        // In a template image only alpha matters, so everything is drawn in black.
        let base: NSColor = template ? .black : .labelColor
        let tint: NSColor = switch segment.level {
        case .normal: base
        case .warning: .systemOrange
        case .critical: .systemRed
        }
        let ring = NSRect(x: x, y: (height - ringSize) / 2, width: ringSize, height: ringSize)
            .insetBy(dx: ringLine / 2, dy: ringLine / 2)
        let track = NSBezierPath(ovalIn: ring)
        track.lineWidth = ringLine
        base.withAlphaComponent(0.3).setStroke()
        track.stroke()
        if let percent = segment.percent, percent > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: ring.midX, y: ring.midY), radius: ring.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * min(percent, 100) / 100, clockwise: true)
            arc.lineWidth = ringLine
            arc.lineCapStyle = .round
            tint.setStroke()
            arc.stroke()
        }
        let symbol = segment.provider == .claude ? "asterisk" : "terminal"
        let config = NSImage.SymbolConfiguration(pointSize: 7, weight: .bold).applying(.init(paletteColors: [base]))
        if let mark = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = mark.size
            mark.draw(in: NSRect(x: ring.midX - size.width / 2, y: ring.midY - size.height / 2, width: size.width, height: size.height))
        }
        let text = label(segment, color: tint)
        text.draw(at: NSPoint(x: x + ringSize + gap, y: (height - text.size().height) / 2))
    }
}
