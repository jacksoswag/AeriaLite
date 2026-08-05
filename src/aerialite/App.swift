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
        status.button?.image = App.helmet()
        status.button?.target = self
        status.button?.action = #selector(toggle)
    }

    /// The app icon at menu bar size. SF Symbols has no helmet. A template image is one flat
    /// colour, so the visor is punched out of the shell rather than filled dark, and the shell is
    /// a dome over a square-cornered body over a collar, the same three subpaths the icon unions.
    private static func helmet() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            let shell = NSBezierPath(ovalIn: NSRect(x: 3.1, y: 2.7, width: 11.8, height: 11.8))
            shell.append(NSBezierPath(rect: NSRect(x: 3.1, y: 4.3, width: 11.8, height: 4.3)))
            shell.append(NSBezierPath(roundedRect: NSRect(x: 2.0, y: 2.2, width: 14.0, height: 2.6),
                                      xRadius: 1.0, yRadius: 1.0))
            shell.windingRule = .nonZero
            NSColor.black.setFill()
            shell.fill()

            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(roundedRect: NSRect(x: 5.5, y: 6.2, width: 7.0, height: 6.2),
                         xRadius: 2.0, yRadius: 2.0).fill()
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
