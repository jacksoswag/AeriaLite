import AppKit
import ServiceManagement
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

    /// The wallpaper extension is owned by WallpaperAgent and survives the menu app. Only tell it
    /// to stop playback; the bounded cache remains warm and durable downloads are untouched.
    func applicationWillTerminate(_ note: Notification) {
        state.shutdown()
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
        // Named so macOS remembers wherever it is command-dragged to.
        status.autosaveName = "AeriaLite"
        status.button?.image = App.helmet
        status.button?.target = self
        status.button?.action = #selector(toggle)

        if SMAppService.mainApp.status != .enabled {
            do { try SMAppService.mainApp.register() }
            catch {
                FileHandle.standardError.write(Data(
                    "aerialite: could not register as a login item: \(error)\n".utf8))
            }
        }
    }



    /// The same silhouette the app icon is built from, bundled by scripts/bundle.sh. Marked as a
    /// template so AppKit tints it to whatever the menu bar is doing, which is the only way this
    /// tracks light and dark.

    private static let helmet: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 17, height: 17)
        return image
    }()

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
