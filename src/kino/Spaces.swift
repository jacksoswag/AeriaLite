import AppKit

// Private CoreGraphics Services. Undocumented and unversioned, so every call here is treated as
// best-effort: a failure leaves the window where AppKit put it rather than throwing.
@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray?
@_silgen_name("CGSAddWindowsToSpaces")
private func CGSAddWindowsToSpaces(_ cid: Int32, _ windows: CFArray, _ spaces: CFArray)

/// Puts one window on every ordinary Space explicitly, which is a different thing from
/// `.canJoinAllSpaces`. That flag keeps a single window and moves it to whatever Space became
/// current, so during a swipe the window is still on the Space being left and the destination has
/// nothing to composite: the flat colour shows through until the transition settles. Registering
/// the window against each Space id means it is already present on the destination.
///
/// Fullscreen Spaces are excluded on purpose. A wallpaper drawn over a fullscreen app is worse
/// than the problem being solved, and the gate that pauses playback assumes it is not there.
enum Spaces {
    static func spread(window number: Int) {
        guard number > 0 else { return }
        let cid = CGSMainConnectionID()
        guard let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return }

        var ids: [UInt64] = []
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for space in spaces {
                // type 0 is a normal desktop; 4 is a fullscreen app's own Space
                guard (space["type"] as? Int) == 0, let id = space["id64"] as? UInt64 else { continue }
                ids.append(id)
            }
        }
        guard !ids.isEmpty else { return }
        CGSAddWindowsToSpaces(cid, [number] as CFArray, ids as CFArray)
    }
}
