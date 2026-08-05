import AppKit

/// Asks WindowServer whether our own wallpaper window is actually on screen.
///
/// Two earlier approaches failed and are worth not re-trying. AppKit's `NSWindow.occlusionState`
/// reports raw 8192 with `.visible` never set on a window pinned below the desktop icons, and
/// emits no change notification. Scanning for a layer-0 window whose bounds contain
/// `CGDisplayBounds` misses a real fullscreen space entirely: measured, a fullscreen window is
/// (0, 33, 1470, 923) against display bounds of (0, 0, 1470, 956), because macOS keeps the
/// menu bar strip out of the frame even while the menu bar is hidden, so `contains` is never
/// true. That test only ever passed against a synthetic window built at the full display size.
///
/// The window must stay ordered in for this to work. Ordering it out makes it permanently
/// not-on-screen, which would latch the gate closed with no way back.
enum Coverage {
    static func isVisible(window number: Int) -> Bool {
        guard number > 0,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow],
                                                    CGWindowID(number)) as? [[String: Any]],
              let info = list.first else { return false }
        return (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
    }
}
