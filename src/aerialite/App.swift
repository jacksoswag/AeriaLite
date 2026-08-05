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
    /// AeriaLite goes with it.
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
        status.button?.image = App.horizon()
        status.button?.target = self
        status.button?.action = #selector(toggle)
    }

    /// The app icon reduced to a glyph: the limb and the sun over it. A template image is one
    /// flat colour, so the atmosphere band the icon is built around cannot survive here and the
    /// whole read rests on the two shapes being close enough to pair. The limb's circle is far
    /// larger than the image, leaving a shallow arc.
    private static func horizon() -> NSImage {
        let image = NSImage(size: NSSize(width: 17, height: 15), flipped: false) { _ in
            NSColor.black.setStroke()
            let limb = NSBezierPath(ovalIn: NSRect(x: 8.5 - 21.2, y: -16.6 - 21.2, width: 42.4, height: 42.4))
            limb.lineWidth = 2.0
            limb.stroke()

            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 5.6, y: 6.7, width: 5.8, height: 5.8)).fill()
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
