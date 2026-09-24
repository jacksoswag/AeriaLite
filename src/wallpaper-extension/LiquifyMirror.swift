import CoreGraphics
import Foundation
import ImageIO
import Network
import QuartzCore

/// Liquify's Spotify background, exactly as Liquify renders it.
///
/// Nothing here draws. Liquify (a Spicetify theme running inside Spotify) renders its own warped,
/// blurred, dimmed album-art wall into an offscreen canvas at the size this side asks for and sends
/// the finished pixels; the compositor treats them as one more source to show or blend into. That
/// is the whole reason the frames come over a socket instead of as parameters: a second
/// implementation of the warp would drift from the first the moment either changed.
///
/// A page cannot listen on a port, so this is the server and Liquify connects out to it, retrying
/// every few seconds. The protocol is pull-based, one frame in flight: the pull is what keeps
/// Liquify rendering while Spotify's window is hidden, when the page gets no animation frames and
/// its timers are throttled to a crawl, but incoming socket messages are still delivered promptly.
/// It also makes the frame rate this side's decision, taken from the rate Liquify says it wants.
///
/// The port is open only while the menu app is: WallpaperAgent keeps this process alive for as
/// long as AeriaLite is the wallpaper, so the listener follows the app's `agent.lock` instead.
///
///     → {"type":"hello","v":1,"width":W,"height":H,     display size in points,
///        "blur":b,"distortion":d,"speed":s}              and the desktop-only multipliers
///     → {"type":"pull"}
///     ← {"type":"info",...}                             settings, cover, readiness
///     ← "LQXF" u16 v, u16 flags, u32 w, u32 h, u32 seq, u32 fps, f64 t, then w·h RGBA8 top-down sRGB
@MainActor final class LiquifyMirror {
    static let shared = LiquifyMirror()
    static let port: UInt16 = 47823

    struct Frame: Sendable {
        /// This side's own counter, not Liquify's: it has to keep rising across reconnects and
        /// across the frame restored from disk at launch.
        let seq: UInt64
        let width: Int
        let height: Int
        let pixels: Data
    }

    private(set) var latest: Frame?
    private(set) var connected = false
    private(set) var framesReceived = 0
    private(set) var listening = false

    private var listener: NWListener?
    private var gate: DispatchSourceTimer?
    private var connection: NWConnection?
    private var wanted = Set<ObjectIdentifier>()
    private var pacer: DispatchSourceTimer?
    private var inFlight = false
    private var lastPull: CFTimeInterval = 0
    private var fps = 60.0
    private var counter: UInt64 = 0
    private var lastSaved: CFTimeInterval = 0
    private var tuning = NativeIPC.SpotifyTuning()

    /// The last frame Liquify sent, kept so a desktop switched to Spotify while Spotify is closed
    /// shows the wall as it last was rather than whatever the film was on.
    nonisolated private static let cache = NativeIPC.root.appendingPathComponent("liquify-last.png")
    private static let headerSize = 32

    private init() {
        restore()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.follow() } }
        timer.resume()
        gate = timer
    }

    /// The frame a source switched to the mirror should start from. While Liquify is connected
    /// that is the next one it sends, so a blend opens on the wall as it is now rather than on a
    /// frame restored from disk; with nothing connected the restored frame is the best there is.
    var baseline: UInt64 { connected ? counter : 0 }

    var stateLabel: String {
        if connected { return framesReceived > 0 ? "live" : "connected" }
        if !listening { return "not-listening" }
        return latest == nil ? "waiting" : "cached"
    }

    /// Frames are only pulled while some desktop is showing, or blending into or out of, the
    /// mirror. With nobody asking, a connected Liquify costs nothing on either side.
    func want(_ owner: AnyObject, _ on: Bool) {
        let id = ObjectIdentifier(owner)
        let before = wanted.isEmpty
        if on { wanted.insert(id) } else { wanted.remove(id) }
        if before != wanted.isEmpty { pace() }
    }

    /// The config's multipliers, applied by Liquify to the desktop's frames only. A change goes out
    /// as a fresh hello, which Liquify already takes as "the consumer changed its mind".
    func tune(_ next: NativeIPC.SpotifyTuning) {
        guard next != tuning else { return }
        tuning = next
        if let connection, connected { hello(connection) }
    }

    func image() -> CGImage? {
        latest.flatMap(LiquifyMirror.image(of:))
    }

    // MARK: server

    /// Opens the port while the menu app runs and closes it, with any connection, once it is gone.
    /// A listener that failed, as when the port is still held by an extension process on its way
    /// out, is retried on the next check.
    private func follow() {
        let present = NativeIPC.agentRunning
        if present, listener == nil { listen() }
        guard !present, let listener else { return }
        listener.cancel()
        self.listener = nil
        listening = false
        connection?.cancel()
        connection = nil
        connected = false
        inFlight = false
        pace()
    }

    private func listen() {
        let parameters = NWParameters.tcp
        let socket = NWProtocolWebSocket.Options()
        socket.autoReplyPing = true
        socket.maximumMessageSize = 64 << 20
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        parameters.allowLocalEndpointReuse = true
        // Loopback only: this is a wallpaper, not a service.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                     port: NWEndpoint.Port(rawValue: LiquifyMirror.port)!)
        guard let made = try? NWListener(using: parameters) else { return }
        made.newConnectionHandler = { [weak self] incoming in
            MainActor.assumeIsolated { self?.accept(incoming) }
        }
        made.stateUpdateHandler = { [weak self, weak made] state in
            MainActor.assumeIsolated {
                guard let self, let made, made === self.listener else { return }
                switch state {
                case .ready: self.listening = true
                case .failed:
                    self.listening = false
                    made.cancel()
                    self.listener = nil
                default: break
                }
            }
        }
        listener = made
        made.start(queue: .main)
    }

    /// One publisher at a time, and the newest wins: a Spotify that was restarted reconnects
    /// before the old socket has necessarily noticed it is dead.
    private func accept(_ incoming: NWConnection) {
        connection?.cancel()
        connection = incoming
        inFlight = false
        incoming.stateUpdateHandler = { [weak self, weak incoming] state in
            MainActor.assumeIsolated {
                guard let self, let incoming, incoming === self.connection else { return }
                switch state {
                case .ready:
                    self.connected = true
                    self.hello(incoming)
                    self.pace()
                case .failed, .cancelled:
                    self.connection = nil
                    self.connected = false
                    self.inFlight = false
                    self.pace()
                default: break
                }
            }
        }
        incoming.start(queue: .main)
        receive(on: incoming)
    }

    private func hello(_ on: NWConnection) {
        let size = CGDisplayBounds(CGMainDisplayID()).size
        send(["type": "hello", "v": 1, "width": Int(size.width), "height": Int(size.height),
              "blur": tuning.blur, "distortion": tuning.distortion, "speed": tuning.speed], on: on)
    }

    private func receive(on from: NWConnection) {
        from.receiveMessage { [weak self, weak from] data, context, _, error in
            MainActor.assumeIsolated {
                guard let self, let from, from === self.connection else { return }
                if error != nil { return from.cancel() }
                if let data, let metadata = context?.protocolMetadata(
                    definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                    switch metadata.opcode {
                    case .binary: self.frame(data)
                    case .text: self.info(data)
                    default: break
                    }
                }
                self.receive(on: from)
            }
        }
    }

    private func send(_ message: [String: Any], on to: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        let context = NWConnection.ContentContext(
            identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        to.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func info(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "info" else { return }
        if let rate = object["fps"] as? Double { fps = min(60, max(1, rate)) }
    }

    private func frame(_ data: Data) {
        inFlight = false
        guard data.count >= LiquifyMirror.headerSize else { return }
        let bytes = [UInt8](data.prefix(LiquifyMirror.headerSize))
        guard bytes[0] == 0x4C, bytes[1] == 0x51, bytes[2] == 0x58, bytes[3] == 0x46 else { return }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard u16(4) == 1 else { return }
        let flags = u16(6), width = u32(8), height = u32(12)
        // Liquify asks for 60 while its cover crossfade runs and its own frame-rate setting
        // otherwise; honouring it is what keeps the two in step.
        let rate = u32(20)
        if rate > 0 { fps = min(60, max(1, Double(rate))) }
        guard flags & 2 == 0, width > 0, height > 0,
              data.count == LiquifyMirror.headerSize + width * height * 4 else { return }
        counter += 1
        framesReceived += 1
        latest = Frame(seq: counter, width: width, height: height,
                       pixels: data.subdata(in: data.startIndex + LiquifyMirror.headerSize ..< data.endIndex))
        persist()
    }

    // MARK: pacing

    /// A fixed tick checked against the wanted rate rather than a timer re-armed per frame: the
    /// rate moves every time a crossfade starts or ends, and one outstanding pull at a time is the
    /// backpressure, so a slow Spotify simply gets fewer requests.
    private func pace() {
        let needed = connected && !wanted.isEmpty
        if needed, pacer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.pull() } }
            timer.resume()
            pacer = timer
        } else if !needed, let pacer {
            pacer.cancel()
            self.pacer = nil
        }
    }

    private func pull() {
        guard let connection, connected else { return }
        let now = CACurrentMediaTime()
        // A frame that never came back, from a page that was reloaded mid-render.
        if inFlight, now - lastPull > 2 { inFlight = false }
        guard !inFlight, now - lastPull >= 1 / fps - 0.004 else { return }
        inFlight = true
        lastPull = now
        send(["type": "pull"], on: connection)
    }

    // MARK: disk

    private func persist() {
        let now = CACurrentMediaTime()
        guard now - lastSaved > 30, let frame = latest else { return }
        lastSaved = now
        DispatchQueue.global(qos: .utility).async {
            guard let image = LiquifyMirror.image(of: frame),
                  let destination = CGImageDestinationCreateWithURL(
                    LiquifyMirror.cache as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    private func restore() {
        guard let source = CGImageSourceCreateWithURL(LiquifyMirror.cache as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let base = context.data else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        counter += 1
        latest = Frame(seq: counter, width: width, height: height,
                       pixels: Data(bytes: base, count: width * height * 4))
    }

    nonisolated private static func image(of frame: Frame) -> CGImage? {
        guard let provider = CGDataProvider(data: frame.pixels as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8,
                       bitsPerPixel: 32, bytesPerRow: frame.width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}
