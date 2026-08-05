import AppKit
import SwiftUI

/// Menu bar agent. No dock icon, no windows of its own beyond the popover, so the only thing
/// resident between interactions is the playback path.
@MainActor final class App: NSObject, NSApplicationDelegate {
    private static var keep: App?
    private var status: NSStatusItem!
    private let popover = NSPopover()
    private var outside: Any?           // global mouse monitor, live only while the panel is up
    private var sigterm: DispatchSourceSignal?
    private let state = AppState()

    static func run() -> Never {
        let delegate = App()
        keep = delegate                       // NSApplication holds its delegate weakly
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        exit(0)
    }

    /// Quitting hands the desktop back to macOS, agent included. The streamed cache is throwaway
    /// by definition and downloads are not, so only the former goes; anything macOS cached for
    /// Kino goes with it.
    func applicationWillTerminate(_ note: Notification) {
        Library.clearCache()
        Library.clearAppleWallpaperCaches()
        AppleWallpaper.restore()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // AppKit leaves SIGTERM at its default action, so launchd stopping the agent would skip
        // applicationWillTerminate and leave the desktop with no wallpaper of either kind
        signal(SIGTERM, SIG_IGN)
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm?.setEventHandler { NSApplication.shared.terminate(nil) }
        sigterm?.resume()

        popover.behavior = .transient
        popover.setValue(true, forKey: "shouldHideAnchor")   // drops the arrow pointing at the status item
        // the panel is built on first open, so SwiftUI stays out of the process for anyone who
        // sets an order once and never opens the menu again
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = App.projector()
        status.button?.target = self
        status.button?.action = #selector(toggle)
    }

    /// The app icon's projector reduced to a menu bar glyph: housing, barrel, two reels, and
    /// nothing else. SF Symbols has no projector. The reels are stroked rather than punched
    /// because a hub that small closes up below 16 points, and the icon's light cone is left
    /// out because a template image cannot fade, so a cone here would be a solid horn.
    private static func projector() -> NSImage {
        let image = NSImage(size: NSSize(width: 17, height: 15), flipped: false) { _ in
            let solid = NSBezierPath()
            solid.append(NSBezierPath(roundedRect: NSRect(x: 0.5, y: 1.8, width: 11.0, height: 4.4),
                                      xRadius: 1.4, yRadius: 1.4))
            solid.append(NSBezierPath(roundedRect: NSRect(x: 11.2, y: 2.9, width: 2.4, height: 2.2),
                                      xRadius: 0.9, yRadius: 0.9))
            NSColor.black.setFill()
            solid.fill()

            NSColor.black.setStroke()
            for (cx, cy, r) in [(3.9, 9.6, 2.8), (9.6, 8.7, 2.0)] {
                let reel = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                reel.lineWidth = 1.5
                reel.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func toggle() {
        guard let button = status.button else { return }
        if popover.isShown { return dismiss() }
        state.reload()
        if popover.contentViewController == nil {
            let host = NSHostingController(rootView: ControlPanel(state: state))
            // without this the controller never reports the SwiftUI size, and the popover is
            // positioned against a stale one: it lands under the menu bar and clips
            host.sizingOptions = [.preferredContentSize]
            popover.contentViewController = host
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        watchForOutsideClick()
    }

    /// .transient alone does not dismiss this one, because making the panel key means clicks
    /// elsewhere never reach the popover. A global monitor sees them instead; it is torn down on
    /// close so it is not watching every click in the session.
    private func watchForOutsideClick() {
        guard outside == nil else { return }
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.dismiss()
        }
    }

    private func dismiss() {
        if let outside { NSEvent.removeMonitor(outside) }
        outside = nil
        popover.performClose(nil)
    }
}
