import Foundation

/// A clock interruption is not a renderer failure. Only a continuous run of callbacks
/// without submitted frames is evidence that our renderer is failing.
struct RenderHealth {
    private(set) var lastCallback: TimeInterval = 0
    private var lastSubmission: TimeInterval = 0
    private var activeSince: TimeInterval?

    mutating func restart(at now: TimeInterval) {
        lastCallback = now
        activeSince = nil
    }

    mutating func callback(at now: TimeInterval) {
        if activeSince == nil || now - lastCallback >= 1 { activeSince = now }
        lastCallback = now
    }

    mutating func submitted(at now: TimeInterval) {
        lastSubmission = now
    }

    func isStalled(at now: TimeInterval) -> Bool {
        guard let activeSince, now - lastCallback < 1 else { return false }
        return now - max(activeSince, lastSubmission) > 5
    }
}
