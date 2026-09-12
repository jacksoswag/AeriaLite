import AVFoundation
import CoreVideo
import Metal
import QuartzCore
import simd

/// The one surface the desktop is ever drawn on.
///
/// It did not start that way. The blend used to be a second layer that took the screen for the
/// length of a transition and handed it back, with the `AVPlayerLayer`s drawing every other frame.
/// That handover could not be made invisible, and both of its symptoms came from the same place:
/// the two paths disagreed about colour, because AVFoundation's video pipeline and CoreAnimation's
/// layer compositing reach the display profile by different routes, and they disagreed about time,
/// because this side pulls the frame matching the next presentation timestamp while the player
/// layer underneath was showing whichever frame it had. Neither gap can be closed by calibration —
/// matching them on one display and one profile would only move the problem to the next.
///
/// So nothing takes turns any more. Every frame the desktop shows is drawn here, from a texture
/// pulled out of the player, whether a transition is running or not. Steady state is a straight
/// resample of the decoder's own pixels with no colour arithmetic applied to them at all, and a
/// blend is the same surface running a different fragment function. There is no moment when
/// anything switches, so there is nothing left to flicker.
///
/// The `AVPlayerLayer`s stay in the tree, hidden, and are used for nothing unless this path stops
/// producing frames — see the session's stall watchdog. A frozen desktop is the one outcome worse
/// than a visible seam.
@MainActor final class Blend: NSObject, CAMetalDisplayLinkDelegate {
    let layer = CAMetalLayer()

    /// Raised when a transition has run out, so the session can retire the clip it came from.
    var onSettle: (() -> Void)?
    /// When this side last put a frame on screen. The session watchdogs it, because with no
    /// player layer visible behind it there is nothing else keeping the desktop alive.
    private(set) var lastPresented = CACurrentMediaTime()
    /// Every callback, drawn or not, which is what separates "the link is dead" from "there was
    /// nothing new to draw".
    private var lastCallback = CACurrentMediaTime()
    /// Consecutive rebuilds that produced no callback at all. Reset by the first one that does.
    /// This is what separates a link the system is deliberately not running — the desktop is
    /// behind Mission Control, the screen is asleep — from one that is never going to work.
    private(set) var revivals = 0

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let blending: MTLRenderPipelineState
    private let presenting: MTLRenderPipelineState
    private let scheduling: MTLRenderPipelineState
    private let textures: CVMetalTextureCache
    private var link: CAMetalDisplayLink?

    /// The clip on screen, and — only while a transition runs — the clip replacing it.
    private var primary: AVPlayerItemVideoOutput?
    private var incoming: AVPlayerItemVideoOutput?
    private var heldPrimary: Frame?
    private var heldIncoming: Frame?
    private var run: Run?
    private var tagged = false
    private var needsDraw = true
    private var suspended = false

    /// Each pixel's crossing, derived once from the frame pair a window opens on and read every
    /// frame after it. Rebuilt only when the drawable changes size.
    private var schedule: MTLTexture?

    private struct Run {
        let config: Transition
        let opened: CFTimeInterval
        var started: CFTimeInterval?
        var scheduled = false
    }

    private struct Frame {
        let keep: [CVMetalTexture]     // the cache hands back wrappers the textures' lives depend on
        let buffer: CVPixelBuffer      // carries the colour tags the layer has to be given
        let luma: MTLTexture
        let chroma: MTLTexture
        let size: CGSize
        /// Read off the buffer rather than assumed: the range from its pixel format, the
        /// coefficients from its YCbCr matrix tag.
        let lumaScale: Float
        let lumaBias: Float
        let chromaScale: Float
        let chromaBias: Float
        let kr: Float
        let kb: Float
    }

    /// Anything missing here means the machine cannot run the shader, and the caller falls back to
    /// the player layers rather than to a blank desktop.
    static func make() -> Blend? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        // Compiled from source at runtime rather than shipped as a metallib, so the extension
        // stays three Swift files and one `swiftc` line in bundle.sh.
        guard let library = try? device.makeLibrary(source: Blend.shader, options: nil),
              let vertex = library.makeFunction(name: "blend_vertex") else { return nil }
        func state(_ name: String, _ format: MTLPixelFormat) -> MTLRenderPipelineState? {
            guard let fragment = library.makeFunction(name: name) else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = format
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        guard let blending = state("blend_fragment", .bgra8Unorm),
              let presenting = state("blend_present", .bgra8Unorm),
              let scheduling = state("blend_schedule", .rgba8Unorm) else { return nil }
        return Blend(device: device, queue: queue, blending: blending,
                     presenting: presenting, scheduling: scheduling, textures: cache)
    }

    private init(device: MTLDevice, queue: MTLCommandQueue, blending: MTLRenderPipelineState,
                 presenting: MTLRenderPipelineState, scheduling: MTLRenderPipelineState,
                 textures: CVMetalTextureCache) {
        self.device = device
        self.queue = queue
        self.blending = blending
        self.presenting = presenting
        self.scheduling = scheduling
        self.textures = textures
        super.init()

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // Three full-resolution drawables is a triple buffer for a wallpaper that redraws only
        // when a frame changes. Two is enough and is 20-odd megabytes cheaper at 4K.
        layer.maximumDrawableCount = 2
        // Deliberately left unset until the first frame arrives, when it is taken from the footage
        // itself. Nothing about colour is decided by a constant in this file.
        layer.colorspace = nil
    }

    /// Video frames only reach the shader through an output attached to the item.
    static func makeOutput() -> AVPlayerItemVideoOutput {
        // The decoder's own planes, in either range, so copying a frame is a retain of a surface
        // that already exists. Asking for 32BGRA instead buys a full-frame colour conversion per
        // frame, which at 4K and 240 fps is gigabytes a second spent reformatting something the
        // shader was about to sample anyway.
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ],
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        return AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
    }

    var isBlending: Bool { run != nil }

    /// The wall-clock instant by which a transition must be over, watchdogged by the session.
    var mustEndBy: CFTimeInterval {
        guard let run else { return .greatestFiniteMagnitude }
        return (run.started ?? run.opened) + run.config.seconds + Blend.primingGrace
    }

    /// How long a clip gets to produce its first frame before a transition gives up and cuts.
    /// Wide enough for an exact seek into a fresh item, the slowest thing that ever starts one.
    static let primingGrace: CFTimeInterval = 1.0

    func place(in bounds: CGRect, scale: CGFloat) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        layer.frame = bounds
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        needsDraw = true
    }

    /// Switch the clip on screen with no transition. The previous frame stays up until the new
    /// clip actually decodes one, so a cut is a cut rather than a cut through black.
    func show(_ output: AVPlayerItemVideoOutput?) {
        finishRun()
        primary = output
        needsDraw = true
        drive(output != nil)
    }

    /// Begin a transition from whatever is on screen into `output`.
    func begin(into output: AVPlayerItemVideoOutput, config: Transition) {
        guard config.isEnabled, heldPrimary != nil else { return show(output) }
        finishRun()
        incoming = output
        heldIncoming = nil
        run = Run(config: config, opened: CACurrentMediaTime())
        needsDraw = true
        drive(true)
    }

    /// Stops drawing without forgetting anything. A `CAMetalLayer` keeps showing its last
    /// presented drawable, so the desktop holds the frame it was on rather than going black, and
    /// resuming is a matter of letting the link run again.
    func suspend() {
        suspended = true
        drive(false)
    }

    /// Rebuilds a display link that has stopped delivering callbacks.
    ///
    /// The link has to be created before there is any way to know the host has attached this layer
    /// to a display, and one created too early never fires at all. That used to cost a transition;
    /// now that nothing else draws the desktop it costs the desktop. Rather than guess when the
    /// layer becomes displayable, the session's poll asks this to check itself — and a link that
    /// has not called back is thrown away and built again, as often as it takes.
    func revive() {
        guard !suspended, primary != nil else { return }
        guard CACurrentMediaTime() - lastCallback > 0.5 else { return }
        link?.invalidate()
        link = nil
        revivals += 1
        drive(true)
    }

    /// True when the link is delivering callbacks but they are not turning into frames, which is
    /// a fault in this file rather than in the system's willingness to run it.
    var isDrawingButNotPresenting: Bool {
        let now = CACurrentMediaTime()
        return now - lastCallback < 1 && now - lastPresented > 5
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        needsDraw = true
        drive(primary != nil)
    }

    func stop() {
        link?.invalidate()
        link = nil
        run = nil
        primary = nil
        incoming = nil
        heldPrimary = nil
        heldIncoming = nil
    }

    /// Ends a transition wherever it has got to, leaving the clip it was heading for on screen.
    func settleNow() {
        guard run != nil else { return }
        finishRun()
        needsDraw = true
    }

    private func finishRun() {
        guard run != nil else { return }
        run = nil
        schedule = nil
        if incoming != nil {
            primary = incoming
            heldPrimary = heldIncoming
            incoming = nil
            heldIncoming = nil
        }
    }

    private func drive(_ wanted: Bool) {
        if wanted, !suspended, link == nil {
            let started = CAMetalDisplayLink(metalLayer: layer)
            started.delegate = self
            started.add(to: .main, forMode: .common)
            link = started
            lastPresented = CACurrentMediaTime()
            lastCallback = lastPresented
        } else if !wanted {
            link?.invalidate()
            link = nil
        }
    }

    // MARK: CAMetalDisplayLinkDelegate

    nonisolated func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        MainActor.assumeIsolated { draw(update) }
    }

    @MainActor private func draw(_ update: CAMetalDisplayLink.Update) {
        lastCallback = CACurrentMediaTime()
        revivals = 0
        let now = update.targetPresentationTimestamp
        CVMetalTextureCacheFlush(textures, 0)
        if let primary, let fresh = pull(primary, at: now) { heldPrimary = fresh; needsDraw = true }
        if let incoming, let fresh = pull(incoming, at: now) { heldIncoming = fresh; needsDraw = true }
        guard let showing = heldPrimary else { return }

        // Colour is read from the footage the first time any of it arrives, and the layer is given
        // exactly what the clip declares, so CoreAnimation converts to whatever profile the
        // display is actually running. Nothing here assumes sRGB, 709, or anything else.
        if !tagged {
            tagged = true
            if let attachments = CVBufferCopyAttachments(showing.buffer, .shouldPropagate),
               let declared = CVImageBufferCreateColorSpaceFromAttachments(attachments)?
                   .takeRetainedValue() {
                layer.colorspace = declared
            } else {
                layer.colorspace = CGDisplayCopyColorSpace(CGMainDisplayID())
            }
        }

        var progress = 0.0
        if var current = run {
            guard let arriving = heldIncoming else {
                // The clip being blended into has not decoded anything yet. Holding the outgoing
                // one up meanwhile is exactly what the player layer used to do, and costs the
                // window only the milliseconds it actually waited.
                if now - current.opened > Blend.primingGrace { finishRun() }
                return present(update.drawable, showing, nil, 0, run: nil)
            }
            if current.started == nil { current.started = now; needsDraw = true }
            let elapsed = now - (current.started ?? now)
            progress = current.config.seconds > 0 ? min(1, max(0, elapsed / current.config.seconds)) : 1
            run = current
            present(update.drawable, showing, arriving, progress, run: current)
            if progress >= 1 {
                finishRun()
                onSettle?()
            }
            return
        }
        present(update.drawable, showing, nil, 0, run: nil)
    }

    /// Draws, and only draws when something has changed. A wallpaper that redraws an identical
    /// frame at the display's refresh rate is a wallpaper that spends battery on nothing.
    ///
    /// The drawable is the one the display link vended. A `CAMetalLayer` with a
    /// `CAMetalDisplayLink` attached refuses `nextDrawable()` — it throws, and thrown from inside
    /// the link's own callback that is an abort, not a dropped frame.
    @MainActor private func present(_ drawable: any CAMetalDrawable, _ showing: Frame,
                                    _ arriving: Frame?, _ progress: Double, run current: Run?) {
        guard needsDraw || current != nil, let buffer = queue.makeCommandBuffer() else { return }
        needsDraw = false
        let target = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let style = current.map { styleCode($0.config.style) } ?? 0
        var uniforms = Uniforms(
            uvScaleA: fill(showing.size, into: target),
            uvScaleB: fill((arriving ?? showing).size, into: target),
            lumaScale: showing.lumaScale,
            lumaBias: showing.lumaBias,
            chromaScale: showing.chromaScale,
            chromaBias: showing.chromaBias,
            kr: showing.kr,
            kb: showing.kb,
            eased: Float(current?.config.progress(at: progress) ?? 0),
            spread: Float(current?.config.spread ?? 0),
            stagger: Float(current?.config.stagger ?? 0),
            chroma: Float(current?.config.chroma ?? 0),
            style: Float(style)
        )

        func encode(_ state: MTLRenderPipelineState, into texture: MTLTexture,
                    reading map: MTLTexture) -> Bool {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
            encoder.setRenderPipelineState(state)
            encoder.setFragmentTexture(showing.luma, index: 0)
            encoder.setFragmentTexture(showing.chroma, index: 1)
            encoder.setFragmentTexture((arriving ?? showing).luma, index: 2)
            encoder.setFragmentTexture((arriving ?? showing).chroma, index: 3)
            encoder.setFragmentTexture(map, index: 4)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            return true
        }

        if arriving != nil {
            // Once per window, from the frame pair it opens on. A map recomputed against two
            // moving clips would let a pixel's crossing run backwards between frames.
            if style != 0, run?.scheduled == false {
                run?.scheduled = true
                schedule = scheduleTexture(for: drawable.texture)
                if let map = schedule,
                   !encode(scheduling, into: map, reading: showing.luma) { return }
            }
            guard encode(blending, into: drawable.texture,
                         reading: schedule ?? showing.luma) else { return }
        } else {
            // Steady state: a straight resample of the decoder's own pixels. No transfer function
            // is applied and none is undone, so what reaches the display is what was decoded.
            guard encode(presenting, into: drawable.texture, reading: showing.luma) else { return }
        }
        buffer.present(drawable)
        buffer.commit()
        lastPresented = CACurrentMediaTime()
    }

    /// Sized to the drawable and sampled 1:1 with it, so a pixel's schedule is read back at
    /// exactly the pixel it was written for.
    private func scheduleTexture(for drawable: MTLTexture) -> MTLTexture? {
        if let schedule, schedule.width == drawable.width, schedule.height == drawable.height {
            return schedule
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: drawable.width, height: drawable.height,
            mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    // MARK: frames

    private func pull(_ output: AVPlayerItemVideoOutput, at host: CFTimeInterval) -> Frame? {
        let time = output.itemTime(forHostTime: host)
        guard time.isValid, output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard CVPixelBufferGetPlaneCount(buffer) == 2 else { return nil }
        func plane(_ index: Int, _ format: MTLPixelFormat) -> (CVMetalTexture, MTLTexture)? {
            var wrapped: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(
                    nil, textures, buffer, nil, format,
                    CVPixelBufferGetWidthOfPlane(buffer, index),
                    CVPixelBufferGetHeightOfPlane(buffer, index),
                    index, &wrapped) == kCVReturnSuccess,
                  let wrapped, let texture = CVMetalTextureGetTexture(wrapped) else { return nil }
            return (wrapped, texture)
        }
        guard let luma = plane(0, .r8Unorm), let chroma = plane(1, .rg8Unorm) else { return nil }

        let full = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let (kr, kb): (Float, Float)
        switch matrix {
        case String(kCVImageBufferYCbCrMatrix_ITU_R_601_4),
             String(kCVImageBufferYCbCrMatrix_SMPTE_240M_1995): (kr, kb) = (0.299, 0.114)
        case String(kCVImageBufferYCbCrMatrix_ITU_R_2020): (kr, kb) = (0.2627, 0.0593)
        default: (kr, kb) = (0.2126, 0.0722)
        }
        return Frame(keep: [luma.0, chroma.0], buffer: buffer, luma: luma.1, chroma: chroma.1,
                     size: CGSize(width: width, height: height),
                     lumaScale: full ? 1 : 255.0 / 219.0,
                     lumaBias: full ? 0 : 16.0 / 255.0,
                     chromaScale: full ? 1 : 255.0 / 224.0,
                     chromaBias: 128.0 / 255.0,
                     kr: kr, kb: kb)
    }

    /// The same crop `videoGravity = .resizeAspectFill` used to give the player layers.
    private func fill(_ source: CGSize, into target: CGSize) -> SIMD2<Float> {
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else {
            return SIMD2(1, 1)
        }
        let from = source.width / source.height, to = target.width / target.height
        return from > to ? SIMD2(Float(to / from), 1) : SIMD2(1, Float(from / to))
    }

    private func styleCode(_ style: Transition.Style) -> Int {
        switch style {
        case .none, .crossfade: return 0
        case .difference: return 1
        }
    }

    /// Mirrors the `Uniforms` declared in the shader. float2 is 8-aligned in both languages and
    /// every other member is a float, so the two layouts agree without padding.
    private struct Uniforms {
        var uvScaleA: SIMD2<Float>
        var uvScaleB: SIMD2<Float>
        var lumaScale: Float
        var lumaBias: Float
        var chromaScale: Float
        var chromaBias: Float
        var kr: Float
        var kb: Float
        var eased: Float
        var spread: Float
        var stagger: Float
        var chroma: Float
        var style: Float
    }
}

extension Blend {
    /// The blend itself.
    ///
    /// Nothing in it depends on where a pixel is. The only input is how far apart the two clips
    /// are at that pixel, and every pixel crosses on a schedule read from its own colour distance.
    ///
    /// What a plain crossfade gets wrong is that it holds the whole frame at fifty per cent of two
    /// different pictures at the same instant, and the double exposure is worst exactly where the
    /// two clips disagree most — the only places the eye was going to look. So the pixels that
    /// disagree are given the *shortest* crossings, spending as little time as possible in the
    /// ambiguous middle, and the pixels the clips already agree on are given the longest, because
    /// a slow cross between two colours that match is free and invisible. Those short crossings
    /// are then staggered across the window by the same measure, so they do not all happen at
    /// once: broad regions of the frame resolve at different moments, in order of how much they
    /// had to change. That ordering is the whole of the movement, and it comes out of the footage
    /// rather than out of a pattern laid over it.
    ///
    /// `chroma` lets each channel follow its own difference instead of the pixel's, which leaves a
    /// whisper of colour separation in the places where the two clips disagree about hue but not
    /// about brightness, and none anywhere else.
    ///
    /// The schedule is computed once, from the first frame pair of the window, and held for its
    /// duration. Recomputing it per frame against two moving clips would let a pixel's crossing
    /// speed up, slow down, or run backwards between frames, and that reads as a shimmer. Fixing
    /// it makes every pixel's progress monotonic by construction.
    ///
    /// Both passes work in linear light: the gamma-space mix a naive crossfade performs is what
    /// makes a dissolve look muddy through its own middle.
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 uvScaleA;
        float2 uvScaleB;
        float lumaScale;      // video range to full, or 1 when the clip is already full range
        float lumaBias;
        float chromaScale;
        float chromaBias;     // 128/255, not 0.5: 8-bit chroma centres on 128 of 256 levels
        float kr;             // the clip's own luma coefficients, from its YCbCr matrix tag
        float kb;
        float eased;
        float spread;
        float stagger;
        float chroma;
        float style;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // One oversized triangle: cheaper than a quad and needs no vertex buffer at all.
    vertex VertexOut blend_vertex(uint id [[vertex_id]]) {
        float2 corner = float2((id << 1) & 2, id & 2);
        VertexOut out;
        out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(corner.x, 1.0 - corner.y);
        return out;
    }

    // The decoder's own two planes, converted here rather than on the way out of AVFoundation.
    // Asking for 32BGRA instead costs a full-frame conversion per frame — at 240 fps and 4K that
    // is billions of bytes a second of work the GPU does for nothing as part of a sample it was
    // taking anyway. The coefficients are the clip's, never a constant.
    static inline float3 ycbcr(float y, float2 cbcr, constant Uniforms &u) {
        float luma = (y - u.lumaBias) * u.lumaScale;
        float2 c = (cbcr - u.chromaBias) * u.chromaScale;
        float kg = 1.0 - u.kr - u.kb;
        return float3(
            luma + 2.0 * (1.0 - u.kr) * c.y,
            luma - (2.0 * (1.0 - u.kb) * u.kb / kg) * c.x - (2.0 * (1.0 - u.kr) * u.kr / kg) * c.y,
            luma + 2.0 * (1.0 - u.kb) * c.x);
    }

    static inline float3 tap(texture2d<float> luma, texture2d<float> chroma, sampler s,
                             float2 uv, float2 uvScale, constant Uniforms &u) {
        float2 at = clamp(0.5 + (uv - 0.5) * uvScale, 0.0, 1.0);
        return ycbcr(luma.sample(s, at).r, chroma.sample(s, at).rg, u);
    }

    // Two frames of the same footage sit close together, so raw distances bunch up against zero.
    // A soft saturating curve spends the useful range on the differences that actually occur
    // rather than on outliers, and cannot clip however far apart a pixel happens to be.
    static inline float3 shape(float3 distance) { return distance / (distance + 0.12); }

    // The real sRGB pair, not a gamma 2.2 stand-in for it: that is the curve this footage is
    // encoded with, and the two diverge most in the shadows. Exact inverses of each other, which
    // is what keeps the first and last frame of a window identical to the clips themselves.
    static inline float3 toLinear(float3 c) {
        c = clamp(c, 0.0, 1.0);
        return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
    }

    static inline float3 toGamma(float3 c) {
        c = clamp(c, 0.0, 1.0);
        return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
    }

    /// Steady state. One sample of the clip on screen, cropped the way the player layer used to
    /// crop it, converted out of the decoder's own colour space and nothing else: no transfer
    /// function applied, none undone.
    fragment float4 blend_present(VertexOut in [[stage_in]],
                                  texture2d<float> lumaA [[texture(0)]],
                                  texture2d<float> chromaA [[texture(1)]],
                                  texture2d<float> lumaB [[texture(2)]],
                                  texture2d<float> chromaB [[texture(3)]],
                                  constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler smooth(filter::linear, mip_filter::none, address::clamp_to_edge);
        return float4(tap(lumaA, chromaA, smooth, in.uv, u.uvScaleA, u), 1.0);
    }

    /// Written once per transition, then read every frame: rgb is each channel's own distance
    /// between the two clips at this pixel, a is the pixel's overall distance.
    fragment float4 blend_schedule(VertexOut in [[stage_in]],
                                   texture2d<float> lumaA [[texture(0)]],
                                   texture2d<float> chromaA [[texture(1)]],
                                   texture2d<float> lumaB [[texture(2)]],
                                   texture2d<float> chromaB [[texture(3)]],
                                   constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler smooth(filter::linear, mip_filter::none, address::clamp_to_edge);
        float3 a = toLinear(tap(lumaA, chromaA, smooth, in.uv, u.uvScaleA, u));
        float3 b = toLinear(tap(lumaB, chromaB, smooth, in.uv, u.uvScaleB, u));
        float3 apart = abs(a - b);
        // Weighted rather than a plain RGB distance: a pixel that differs only in blue is a pixel
        // that barely differs, and scheduling it as though it were a large change would waste the
        // window on something nobody can see.
        float overall = dot(apart, float3(0.2126, 0.7152, 0.0722));
        return float4(shape(apart), shape(float3(overall)).r);
    }

    fragment float4 blend_fragment(VertexOut in [[stage_in]],
                                   texture2d<float> lumaA [[texture(0)]],
                                   texture2d<float> chromaA [[texture(1)]],
                                   texture2d<float> lumaB [[texture(2)]],
                                   texture2d<float> chromaB [[texture(3)]],
                                   texture2d<float> schedule [[texture(4)]],
                                   constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler smooth(filter::linear, mip_filter::none, address::clamp_to_edge);
        constexpr sampler exact(filter::nearest, mip_filter::none, address::clamp_to_edge);
        float3 a = toLinear(tap(lumaA, chromaA, smooth, in.uv, u.uvScaleA, u));
        float3 b = toLinear(tap(lumaB, chromaB, smooth, in.uv, u.uvScaleB, u));

        if (u.style < 0.5) {
            return float4(toGamma(mix(a, b, u.eased)), 1.0);
        }

        float4 map = schedule.sample(exact, in.uv);
        float3 apart = mix(float3(map.a), map.rgb, u.chroma);

        // How long this channel spends crossing, as a fraction of the window. The further apart
        // the two clips are here, the less of the window is spent half-way between them.
        float3 width = 1.0 - u.spread * apart;
        // Whatever the crossing does not use, it is free to move within, and it moves by the same
        // measure that shortened it. The arithmetic leaves every ramp inside 0...1 exactly, which
        // is what keeps the first and last frame of a blend identical to the clips themselves.
        float3 room = 0.5 * (1.0 - width);
        float3 centre = 0.5 + u.stagger * room * (2.0 * apart - 1.0);

        float3 t = smoothstep(centre - 0.5 * width, centre + 0.5 * width, float3(u.eased));
        return float4(toGamma(mix(a, b, t)), 1.0);
    }
    """
}
