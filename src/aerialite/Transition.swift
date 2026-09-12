import Foundation

/// The blend that replaces the cut between one clip and the next.
///
/// Read from config.json by the menu app, clamped there, and carried to the wallpaper extension
/// inside the command snapshot. The extension never opens config.json of its own accord, so the
/// command file stays the only channel between the two processes.
struct Transition: Codable, Equatable {
    /// How long the two clips overlap, in wall-clock seconds. 0 restores the hard cut. The
    /// outgoing clip is never truncated; the incoming one simply starts this early, so a rotation
    /// loses this much from each clip's tail rather than gaining a pause between them.
    var seconds = 1.6
    var style = Style.difference
    var curve = Curve.smootherstep
    /// How much a pixel's own colour difference shortens its crossing. At 0 every pixel crosses
    /// over the whole window on one schedule, which is an ordinary fade.
    var spread = 0.7
    /// Where the shortened crossings sit in the window. Positive puts the pixels that differ most
    /// last, negative first, 0 centres everything.
    var stagger = 0.35
    /// How much each channel follows its own difference rather than the pixel's overall one.
    var chroma = 0.3
    /// Whether the switches you ask for by hand blend as well, or stay instant:
    /// next, previous, clicking a clip in the panel, and dropping the position slider.
    var manual = true

    /// Anything that leaves the blend with no width or no algorithm is the hard cut, and the
    /// extension checks this before it commits a second decoder to the transition.
    var isEnabled: Bool { seconds >= 0.05 && style != .none }

    /// Where the two clips stand at a point in the window, 0 entirely the outgoing clip and 1
    /// entirely the incoming one.
    func progress(at fraction: Double) -> Double { curve(fraction) }

    /// Which algorithm runs. `difference` is the one this feature exists for; the other two are
    /// escape hatches, kept because a blend is a matter of taste and the cut is sometimes right.
    enum Style: String, Codable, Equatable {
        /// No blend. Identical to `seconds: 0`, spelled the way someone turning it off reaches for.
        case none
        /// One schedule for the whole frame, in linear light rather than the usual muddy
        /// gamma-space mix. What `difference` becomes as `spread` goes to 0.
        case crossfade
        /// Every pixel crosses on a schedule read from how far apart the two clips are at that
        /// pixel. Nothing in it depends on where the pixel is.
        case difference

        static func named(_ raw: String) -> Style? { Style(rawValue: raw.lowercased()) }
    }

    init() {}

    /// Every field is optional and every value is clamped here, because config.json is hand-edited
    /// and the process that reads the result composites the desktop. A nonsense number should cost
    /// its own key, not the wallpaper.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seconds = min(10, max(0, try c.decodeIfPresent(Double.self, forKey: .seconds) ?? seconds))
        if let raw = try c.decodeIfPresent(String.self, forKey: .style), let named = Style.named(raw) {
            style = named
        }
        curve = try c.decodeIfPresent(Curve.self, forKey: .curve) ?? curve
        // Capped below 1 rather than at it: a pixel whose crossing has no width at all is a pixel
        // that jumps, and the point of all of this is that nothing ever does.
        spread = min(0.95, max(0, try c.decodeIfPresent(Double.self, forKey: .spread) ?? spread))
        stagger = min(1, max(-1, try c.decodeIfPresent(Double.self, forKey: .stagger) ?? stagger))
        chroma = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .chroma) ?? chroma))
        manual = try c.decodeIfPresent(Bool.self, forKey: .manual) ?? manual
    }
}

/// The shape of the blend over its window. Named presets cover what anyone actually asks for, and
/// a bare four-number array is the CSS `cubic-bezier` everybody already knows the feel of.
enum Curve: Equatable {
    case linear
    case smoothstep
    case smootherstep
    case bezier(Double, Double, Double, Double)

    /// Presets, and the spelling each one is written back out as.
    private static let presets: [(name: String, curve: Curve)] = [
        ("linear", .linear),
        ("smoothstep", .smoothstep),
        ("smootherstep", .smootherstep),
        ("ease", .bezier(0.25, 0.1, 0.25, 1)),
        ("easeIn", .bezier(0.42, 0, 1, 1)),
        ("easeOut", .bezier(0, 0, 0.58, 1)),
        ("easeInOut", .bezier(0.42, 0, 0.58, 1)),
    ]

    static func named(_ raw: String) -> Curve? {
        let key = raw.lowercased().replacingOccurrences(of: "-", with: "")
        return presets.first { $0.name.lowercased() == key }?.curve
    }

    func callAsFunction(_ fraction: Double) -> Double {
        let t = min(1, max(0, fraction))
        switch self {
        case .linear: return t
        case .smoothstep: return t * t * (3 - 2 * t)
        case .smootherstep: return t * t * t * (t * (t * 6 - 15) + 10)
        case let .bezier(x1, y1, x2, y2): return Curve.solve(t, x1, y1, x2, y2)
        }
    }

    /// The unit cubic Bézier with endpoints pinned at (0,0) and (1,1): find the parameter whose x
    /// is the elapsed fraction, then read that parameter's y.
    private static func solve(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        func axis(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        func slope(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b)
        }
        var t = x
        for _ in 0..<8 {
            let error = axis(t, x1, x2) - x
            if abs(error) < 1e-6 { return axis(t, y1, y2) }
            let d = slope(t, x1, x2)
            if abs(d) < 1e-6 { break }
            t -= error / d
        }
        // Newton stalls exactly where a hand-written control point puts a flat spot, which is not
        // an exotic case in a file people edit. Bisection cannot diverge, so it finishes the job.
        var low = 0.0, high = 1.0
        t = x
        for _ in 0..<32 {
            let at = axis(t, x1, x2)
            if abs(at - x) < 1e-6 { break }
            if at < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return axis(t, y1, y2)
    }
}

extension Curve: Codable {
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let raw = try? value.decode(String.self), let named = Curve.named(raw) {
            self = named
        } else if let points = try? value.decode([Double].self), points.count == 4 {
            // Only x is constrained: a y outside 0...1 overshoots, which is the whole reason
            // anyone writes the control points out by hand instead of naming a preset.
            self = .bezier(min(1, max(0, points[0])), points[1], min(1, max(0, points[2])), points[3])
        } else {
            // A misspelled preset is a typo in a file with no schema, not a reason to refuse the
            // rest of it. The default shape is a safe thing to land on.
            self = .smootherstep
        }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        if let preset = Curve.presets.first(where: { $0.curve == self }) {
            try value.encode(preset.name)
        } else if case let .bezier(x1, y1, x2, y2) = self {
            try value.encode([x1, y1, x2, y2])
        }
    }
}
