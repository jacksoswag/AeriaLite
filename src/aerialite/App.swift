import AppKit
import Darwin
import ServiceManagement
import SwiftUI

/// Menu bar agent. No dock icon, no windows of its own beyond the popover, so the only thing
/// resident between interactions is the playback path.
@MainActor final class App: NSObject, NSApplicationDelegate, NSPopoverDelegate {
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
        popover.delegate = self
        popover.setValue(true, forKey: "shouldHideAnchor")   // drops the arrow pointing at the status item
        // the panel is built on first open, so SwiftUI stays out of the process for anyone who
        // sets an order once and never opens the menu again
        //
        // Created once and never rebuilt. On macOS 26 a status item is not a window this process
        // owns: AppKit asks com.apple.controlcenter.statusitems for an FBSScene and exports the
        // button into it, so `button.window` is a detached host that never reports menu bar
        // coordinates and ControlCenter does the placing. Any liveness check written against that
        // window's frame reads as "not in the menu bar" forever, and removeStatusItem sends
        // NSStatusItemClearAutosaveStateAction, so rebuilding on that signal both discards the item
        // ControlCenter had already accepted and erases the saved slot on every pass.
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Named so macOS remembers wherever it is command-dragged to.
        status.autosaveName = "AeriaLite"
        status.button?.image = App.helmet
        status.button?.target = self
        status.button?.action = #selector(toggle)

        // A backend that is hosted but not presenting cannot be fixed by publishing at it, so give
        // WallpaperAgent a few seconds to acquire on its own and only then restart it. The delay
        // matters: on an ordinary login the extension is acquired within a second or two and this
        // never fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !self.state.nativeBackendLive else { return }
            DispatchQueue.global(qos: .utility).async {
                let recovered = NativeActivation.reacquire()
                if !recovered {
                    FileHandle.standardError.write(Data(
                        "aerialite: the wallpaper backend did not come back; run aerialite activate-native\n".utf8))
                }
            }
        }

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
        state.panelIsVisible = true
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

    /// Releasing the hosting controller on close is what keeps a closed panel free. SwiftUI keeps
    /// the view tree subscribed to every @Published on AppState for as long as the controller
    /// exists, so a retained one re-evaluates ControlPanel's body on each tick of the 0.25s ticker
    /// -- forever, for a panel nobody is looking at -- and holds its CoreAnimation layers, raster
    /// buffers and IOSurfaces resident behind it. Rebuilding costs one frame on the next open,
    /// which is the same cost already paid for the first one.
    func popoverDidClose(_ note: Notification) {
        state.panelIsVisible = false
        popover.contentViewController = nil
        // Releasing the tree returns the objects but not the pages. Building the panel takes this
        // process to a 86.5 MB peak against 7.8 MB of live allocations once it is closed again, and
        // the small zone holds the difference as dirty free pages rather than handing it back, so
        // the footprint stays near its peak for a panel that no longer exists. Asking the zones to
        // release costs a few milliseconds on a path the user has just finished interacting with.
        // Deferred one turn because the view tree is released through the autorelease pool.
        DispatchQueue.main.async { malloc_zone_pressure_relief(nil, 0) }
    }
}
