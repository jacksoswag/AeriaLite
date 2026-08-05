import AppKit

/// One screen's window, player, and the gate tying them together.
///
/// Gating off stops the clock and releases the decoder but leaves the last frame up and the window
/// ordered in. The gate asks WindowServer whether this very window is on screen, so ordering it
/// out would make the answer permanently no and the wallpaper would never come back.
///
/// Stopping from the panel is different and does hide the window, because that is a user saying
/// they want it gone rather than the machine noticing nobody is looking.
final class Wall {
    private let window: DesktopWindow
    let player: Player
    private var asleep = false
    private var wanted = false
    private var enabled = false
    private var generation = 0
    private static let settleDelay = 0.75
    private static let probe = DispatchQueue(label: "aerialite.coverage", qos: .utility)

    private let policy: Settings.Fullscreen

    init(screen: NSScreen, onFullscreen: Settings.Fullscreen) {
        policy = onFullscreen
        window = DesktopWindow(screen: screen)
        player = Player(label: "screen \(screen.localizedName)")
        let view = window.contentView!
        player.layer.frame = view.bounds
        player.layer.contentsScale = screen.backingScaleFactor   // 1x layers soften on retina
        player.layer.isOpaque = true                              // lets the compositor skip blending
        player.layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = player.layer                                 // layer-hosting: assign, then opt in
        view.wantsLayer = true
        window.orderFront(nil)
        Spaces.spread(window: window.windowNumber)
    }

    /// Returns early unless the value changed, since ordering the window front is not free.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        // ordering out drops the CGS registration, so a window brought back without re-registering
        // belongs to no Space and never shows
        if on { window.orderFront(nil); Spaces.spread(window: window.windowNumber) }
        gate(immediate: true)
        if !on { player.stop(); window.orderOut(nil) }   // a user stop forgets the queue position
    }
    func setAsleep(_ sleeping: Bool) { asleep = sleeping; gate() }

    /// The visibility question is a synchronous IPC into WindowServer, and WindowServer is the
    /// process compositing the video. Asking it from the main thread stalls the same run loop the
    /// picture depends on, thirty times over during a chase, so the query runs off it.
    func gate(immediate: Bool = false) {
        guard policy != .play else { return decide(true, immediate: immediate) }
        let number = window.windowNumber
        Wall.probe.async { [weak self] in
            let visible = Coverage.isVisible(window: number)
            DispatchQueue.main.async { self?.decide(visible, immediate: immediate) }
        }
    }

    /// Asymmetric on purpose. Becoming visible is applied at once, because waiting means
    /// arriving on the desktop and watching a still frame for a beat. Becoming hidden waits for
    /// settleDelay, because that is the direction a window animation flaps in: a window on its
    /// way to covering the display reports not-covering briefly, and pausing on that is churn.
    private func decide(_ visible: Bool, immediate: Bool) {
        let next = enabled && !asleep && visible
        guard next != wanted else { return }
        generation += 1
        guard !immediate, !next else { return apply(next) }
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Wall.settleDelay) { [weak self] in
            guard let self, mine == self.generation else { return }
            Wall.probe.async {
                let still = self.policy == .play || Coverage.isVisible(window: self.window.windowNumber)
                DispatchQueue.main.async {
                    let settled = self.enabled && !self.asleep && still
                    guard settled != self.wanted else { return }
                    self.apply(settled)
                }
            }
        }
    }

    private func apply(_ on: Bool) {
        wanted = on
        // stop tears the decoder down and forgets the position; pause keeps both and the frame
        if on { player.setActive(true) } else if policy == .stop { player.stop() } else { player.setActive(false) }
    }

    deinit {
        player.stop()
        window.orderOut(nil)
    }
}
