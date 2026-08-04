import AppKit

/// Borderless window one level above the desktop icons, covering the system wallpaper and sitting
/// under every application window. Replaces Apple's video wallpaper path entirely.
final class DesktopWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        // Space membership comes from CGSAddWindowsToSpaces, never from a collectionBehavior flag.
        // Anything that also claims a space drags the active one while a transition resolves:
        // .fullScreenNone took a fullscreen cycle from 4 space changes to 11, and .stationary threw
        // the desktop rightward on an adjacent swipe. Neither goes back.
        collectionBehavior = [.ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        // sharingType left at default so ScreenCaptureKit still sees this. Spectra's overlay
        // sets .none for the opposite reason, and copying that here hides the wallpaper from
        // screenshots and from anything sampling the desktop to match it
        setFrame(screen.frame, display: false)   // frame not visibleFrame, or the notch strip stays black
    }
}
