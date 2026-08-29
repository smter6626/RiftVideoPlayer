import AVFoundation
import AppKit
import CoreImage
import MetalKit
import OSLog
import QuartzCore
import SwiftUI

private let playerViewLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Rift", category: "Video")

struct RiftPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let fpsMode: FPSMode
    let interpolationMode: InterpolationMode
    let sourceFrameRate: Double?
    let visualEnhancementsEnabled: Bool
    var isHDRContent: Bool = false
    var onStatsChanged: @MainActor (VideoRenderStats) -> Void = { _ in }

    func makeNSView(context: Context) -> MetalVideoView {
        let view = MetalVideoView()
        context.coordinator.configure(
            view: view,
            player: player,
            fpsMode: fpsMode,
            interpolationMode: interpolationMode,
            sourceFrameRate: sourceFrameRate,
            visualEnhancementsEnabled: visualEnhancementsEnabled,
            isHDRContent: isHDRContent,
            onStatsChanged: onStatsChanged
        )
        return view
    }

    func updateNSView(_ view: MetalVideoView, context: Context) {
        context.coordinator.configure(
            view: view,
            player: player,
            fpsMode: fpsMode,
            interpolationMode: interpolationMode,
            sourceFrameRate: sourceFrameRate,
            visualEnhancementsEnabled: visualEnhancementsEnabled,
            isHDRContent: isHDRContent,
            onStatsChanged: onStatsChanged
        )
    }

    func makeCoordinator() -> MetalVideoRenderer {
        MetalVideoRenderer()
    }
}

struct VideoRenderStats {
    let renderingFPS: Double
    let isArtificialInterpolationActive: Bool
    let fluxWorkingWidth: Int?
    let opticalFlowUsage: Double
    let blendFallbackUsage: Double
    let rifeStatus: String
    let isRIFELoaded: Bool
}

final class MetalVideoView: MTKView {
    var isHDRContent = false {
        didSet {
            guard oldValue != isHDRContent else { return }
            colorPixelFormat = isHDRContent ? .bgra10_xr : .bgra8Unorm
            (layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = isHDRContent
        }
    }

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())

        framebufferOnly = false
        enableSetNeedsDisplay = true
        isPaused = true
        preferredFramesPerSecond = 60
        // bgra8Unorm — CI aplica gamma sRGB al renderizar
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        layer?.isOpaque = true
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.displaySyncEnabled = true
            metalLayer.presentsWithTransaction = false
            metalLayer.allowsNextDrawableTimeout = false
            metalLayer.maximumDrawableCount = 3
            metalLayer.wantsExtendedDynamicRangeContent = false
        }
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        if device == nil {
            device = MTLCreateSystemDefaultDevice()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isPaused = true
            delegate = nil
        }
    }
}

@MainActor
final class MetalVideoRenderer: NSObject, MTKViewDelegate {
    private weak var player: AVPlayer?
    private weak var attachedItem: AVPlayerItem?
    private var fpsMode: FPSMode = .native
    private var interpolationMode: InterpolationMode = .disabled
    private var visualEnhancementsEnabled = false
    private var isHDRContent = false
    private var sourceFrameRate: Double?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var commandQueue: MTLCommandQueue?
    private var ciContext: CIContext?
    private var textureCache: CVMetalTextureCache?
    private var framePlusEngine: FramePlusMEMCEngine?

    // FIX Bug 4: doble buffer para el output de Metal — evita leer datos GPU en vuelo
    private var framePlusOutputPoolA: CVPixelBuffer?
    private var framePlusOutputPoolB: CVPixelBuffer?
    private var framePlusOutputTextureA: MTLTexture?
    private var framePlusOutputTextureB: MTLTexture?
    private var framePlusOutputToggle = false
    private var framePlusLastOutputSize: CGSize = .zero

    private let framePlusInFlightSemaphore = DispatchSemaphore(value: 3)
    private let frameBuffer = AsyncFrameBuffer(capacity: 6)
    private var prefetcher: FramePrefetcher?

    // FIX Bug 3: la cadencia ya no avanza el frame fuente en el pulso de interpolación
    private var framePlusDisplayPulse = 0
    private var framePlusHeldFrame: CVPixelBuffer?
    private var framePlusHeldTime = CMTime.invalid
    // framePlusNextFrame ya no se usa para "avanzar" — peek() lo hace sin consumir
    private var framePlusNextFrame: SourceVideoFrame?

    // FIX: contador de frames únicos para el stat de FPS real de Frame+
    private var framePlusUniqueFrameCount = 0
    private var framePlusStatsStart = CACurrentMediaTime()

    private var previousFrame: CVPixelBuffer?
    private var previousFrameTime = CMTime.invalid
    private var latestFrame: CVPixelBuffer?
    private var latestFrameTime = CMTime.invalid
    private var liveInterpolationPair: LiveInterpolationPair?
    private var sourceFrames: [SourceVideoFrame] = []
    private let opticalFlowEngine = OpticalFlowEngine()
    private let rifeInterpolator = RIFECoreMLInterpolator()
    private var isLoadingRIFE = false
    private var rifeInFlight = false
    private var activeRIFEPairKey: String?
    private var rifeFrameCache: [Float: CVPixelBuffer] = [:]
    private var pendingRIFETimesteps: Set<Float> = []
    private var rifeFailureBackoffUntil = 0.0
    private var rifeStabilityBackoffUntil = 0.0
    private var statsHandler: (@MainActor (VideoRenderStats) -> Void)?
    private var statsStartTime = CACurrentMediaTime()
    private var renderedFrameCount = 0
    private var interpolatedFrameCount = 0
    private var opticalFlowFrameCount = 0
    private var blendFallbackFrameCount = 0
    private var sourceFrameStatsCount = 0
    private var fluxWorkingMaxWidth: CGFloat = 1920
    private var sourceFrameIndex = 0
    private var memcDisabledUntil = 0.0
    private var previousAverageLuma: Double?
    private var averageLumaAccumulator = 0.0
    private var averageLumaSamples = 0
    private let rifeWorkingMaxWidth: CGFloat = 1920
    private let rifeWorkingMaxHeight: CGFloat = 1080
    private let memcIntensity = MEMCIntensity.high
    private let renderColorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private lazy var memcKernel: CIKernel? = {
        CIKernel(source:
            """
            kernel vec4 memcInterpolate(sampler previousFrame, sampler currentFrame, sampler flowMap, float amount, float maxMotion, float warpStrength, float memcMix, float flowScale, float occlusionThreshold) {
                vec2 dc = destCoord();
                vec4 extent = samplerExtent(currentFrame);
                vec2 minCoord = extent.xy + vec2(0.5);
                vec2 maxCoord = extent.xy + extent.zw - vec2(1.5);
                vec4 flowSample = sample(flowMap, samplerTransform(flowMap, dc));
                vec2 motion = flowSample.xy * flowScale * warpStrength;
                float motionLength = length(motion);

                if (motionLength > maxMotion) {
                    motion = motion * (maxMotion / motionLength);
                }

                vec2 previousCoord = clamp(dc - motion * amount, minCoord, maxCoord);
                vec2 currentCoord = clamp(dc + motion * (1.0 - amount), minCoord, maxCoord);

                vec4 previousColor = sample(previousFrame, samplerTransform(previousFrame, previousCoord));
                vec4 currentColor = sample(currentFrame, samplerTransform(currentFrame, currentCoord));
                vec4 previousOriginal = sample(previousFrame, samplerTransform(previousFrame, dc));
                vec4 currentOriginal = sample(currentFrame, samplerTransform(currentFrame, dc));
                vec4 warped = mix(previousColor, currentColor, amount);
                vec4 dissolved = mix(previousOriginal, currentOriginal, amount);
                float disagreement = distance(previousColor.rgb, currentColor.rgb);
                float confidence = 1.0 - smoothstep(occlusionThreshold * 0.55, occlusionThreshold, disagreement);
                float edgeDistance = min(min(dc.x - minCoord.x, maxCoord.x - dc.x), min(dc.y - minCoord.y, maxCoord.y - dc.y));
                float edgeConfidence = smoothstep(0.0, 72.0, edgeDistance);
                float motionAmount = smoothstep(1.0, maxMotion * 0.28, motionLength);
                float motionConfidence = mix(confidence, max(confidence, 0.94), motionAmount);
                float finalMix = memcMix * motionConfidence * edgeConfidence;

                return mix(dissolved, warped, finalMix);
            }
            """
        )
    }()

    private lazy var fastBlendKernel: CIKernel? = {
        CIKernel(source:
            """
            kernel vec4 fastBlend(sampler previousFrame, sampler currentFrame, float amount) {
                vec2 dc = destCoord();
                vec4 previousColor = sample(previousFrame, samplerTransform(previousFrame, dc));
                vec4 currentColor = sample(currentFrame, samplerTransform(currentFrame, dc));
                return mix(previousColor, currentColor, amount);
            }
            """
        )
    }()

    private weak var mtkView: MetalVideoView?
    nonisolated(unsafe) private var rateObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var itemObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var timeObserver: Any?

    deinit {
        for _ in 0..<3 {
            framePlusInFlightSemaphore.signal()
        }
        let rObs = rateObservation
        let iObs = itemObservation
        let tObserver = timeObserver
        let p = player
        let v = mtkView
        DispatchQueue.main.async {
            v?.isPaused = true
            v?.delegate = nil
            rObs?.invalidate()
            iObs?.invalidate()
            if let tObserver, let p {
                p.removeTimeObserver(tObserver)
            }
        }
    }

    private func cleanupObservations() {
        stopFramePlusPrefetcher()
        rateObservation = nil
        itemObservation = nil
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        self.timeObserver = nil
    }

    func configure(
        view: MetalVideoView,
        player: AVPlayer,
        fpsMode: FPSMode,
        interpolationMode: InterpolationMode,
        sourceFrameRate: Double?,
        visualEnhancementsEnabled: Bool,
        isHDRContent: Bool = false,
        onStatsChanged: @escaping @MainActor (VideoRenderStats) -> Void
    ) {
        if self.player !== player {
            cleanupObservations()
            self.player = player
        }
        if self.interpolationMode != interpolationMode {
            resetRIFECache()
            resetFramePlusCadence()
        }
        if self.sourceFrameRate != sourceFrameRate {
            sourceFrames.removeAll(keepingCapacity: true)
            liveInterpolationPair = nil
            previousFrame = nil
            previousFrameTime = .invalid
            latestFrame = nil
            latestFrameTime = .invalid
            resetStats()
        }

        self.mtkView = view
        self.fpsMode = fpsMode
        self.interpolationMode = interpolationMode
        self.visualEnhancementsEnabled = visualEnhancementsEnabled
        self.isHDRContent = isHDRContent
        self.sourceFrameRate = sourceFrameRate
        self.statsHandler = onStatsChanged
        view.isHDRContent = isHDRContent

        view.preferredFramesPerSecond = preferredRenderFPS(
            fpsMode: fpsMode,
            interpolationMode: interpolationMode,
            sourceFrameRate: sourceFrameRate
        )

        if interpolationMode == .motion2Intense {
            view.preferredFramesPerSecond = framePlusRenderFPS(for: view)
        }
        view.delegate = self

        if commandQueue == nil, let device = view.device {
            commandQueue = device.makeCommandQueue()
            ciContext = CIContext(
                mtlDevice: device,
                options: [
                    .cacheIntermediates: false,
                    .workingColorSpace: renderColorSpace,
                    .outputColorSpace: renderColorSpace,
                    .workingFormat: CIFormat.RGBAh,  // 16-bit half-float internal
                    .outputPremultiplied: true,
                    .useSoftwareRenderer: false
                ]
            )
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            textureCache = cache
            do {
                framePlusEngine = try FramePlusMEMCEngine(device: device)
            } catch {
                framePlusEngine = nil
                print("[Rift] ⚠️ FramePlusMEMCEngine init failed: \(error) — Frame+ MEMC disabled, falling back to crossfade")
            }
        }

        attachOutputIfNeeded(to: player.currentItem)
        stopFramePlusPrefetcher()
        if interpolationMode != .disabled, interpolationMode != .motion2Intense {
            loadRIFEIfNeeded()
        }
        setupObservations(for: player, in: view)
    }

    private func preferredRenderFPS(
        fpsMode: FPSMode,
        interpolationMode: InterpolationMode,
        sourceFrameRate: Double?
    ) -> Int {
        guard fpsMode == .flux else {
            return nativeDisplaySyncedFPS(sourceFrameRate: sourceFrameRate)
        }
        switch interpolationMode {
        case .disabled:
            return fpsMode.renderFramesPerSecond(sourceFrameRate: sourceFrameRate)
        case .rife2x:
            if let sourceFrameRate, sourceFrameRate > 0 {
                return min(displayRefreshFPS(), max(60, Int((sourceFrameRate * 2).rounded())))
            }
            return 60
        case .motion2Intense:
            return displayRefreshFPS()
        case .rife4x, .rifeAdaptive:
            return displayRefreshFPS()
        }
    }

    private func framePlusRenderFPS(for view: MTKView) -> Int {
        displayRefreshFPS(for: view.window?.screen)
    }

    private func nativeDisplaySyncedFPS(sourceFrameRate: Double?) -> Int {
        let displayFPS = displayRefreshFPS()
        guard let sourceFrameRate, sourceFrameRate.isFinite, sourceFrameRate > 0 else {
            return displayFPS
        }

        return sourceFrameRate >= 58 ? min(displayFPS, Int(sourceFrameRate.rounded())) : displayFPS
    }

    private func displayRefreshFPS(for screen: NSScreen? = nil) -> Int {
        let rawFPS = screen?.maximumFramesPerSecond
            ?? NSScreen.main?.maximumFramesPerSecond
            ?? 60
        return min(240, max(60, rawFPS))
    }

    private func loadRIFEIfNeeded() {
        guard !rifeInterpolator.isLoaded,
              !isLoadingRIFE,
              CACurrentMediaTime() >= rifeFailureBackoffUntil else { return }
        isLoadingRIFE = true
        Task { @MainActor in
            defer { self.isLoadingRIFE = false }
            do {
                try await self.rifeInterpolator.loadEngine()
            } catch {
                playerViewLogger.error("RIFE engine failed to load: \(error.localizedDescription)")
                self.rifeFailureBackoffUntil = CACurrentMediaTime() + 3.0
            }
        }
    }

    private func setupObservations(for player: AVPlayer, in view: MetalVideoView) {
        guard timeObserver == nil else {
            updateRenderingState(player: player, view: view)
            return
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let view = self.mtkView, let player = self.player else { return }
                if player.timeControlStatus != .playing {
                    view.setNeedsDisplay(view.bounds)
                }
            }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, let view = self.mtkView else { return }
                self.updateRenderingState(player: player, view: view)
            }
        }
        itemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, let view = self.mtkView else { return }
                self.attachOutputIfNeeded(to: player.currentItem)
                self.updateRenderingState(player: player, view: view)
            }
        }
        attachOutputIfNeeded(to: player.currentItem)
        updateRenderingState(player: player, view: view)
    }

    private func updateRenderingState(player: AVPlayer, view: MetalVideoView) {
        let isPlaying = player.timeControlStatus == .playing
        if interpolationMode == .motion2Intense, player.currentItem != nil {
            view.preferredFramesPerSecond = framePlusRenderFPS(for: view)
            view.isPaused = !isPlaying
            view.enableSetNeedsDisplay = !isPlaying
            if !isPlaying {
                view.setNeedsDisplay(view.bounds)
            }
            return
        }
        if isPlaying {
            view.isPaused = false
            view.enableSetNeedsDisplay = false
        } else {
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.setNeedsDisplay(view.bounds)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

    func draw(in view: MTKView) {
        autoreleasepool {
            drawFrame(in: view)
        }
    }

    private func drawFrame(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let ciContext,
              let output = videoOutput,
              let player else { return }

        let hostTime = CACurrentMediaTime()
        let isPlaying = player.timeControlStatus == .playing
        let itemTime = isPlaying ? output.itemTime(forHostTime: hostTime) : player.currentTime()

        if output.hasNewPixelBuffer(forItemTime: itemTime) {
            var displayTime = CMTime.invalid
            if let frame = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime) {
                let frameTime = normalizedSourceFrameTime(displayTime.isValid ? displayTime : itemTime)
                let oldFrame = sourceFrames.last?.pixelBuffer ?? latestFrame
                let oldFrameTime = sourceFrames.last?.time ?? latestFrameTime
                latestFrame = frame
                latestFrameTime = frameTime

                let didAppendSourceFrame = appendSourceFrame(frame, time: frameTime)
                if didAppendSourceFrame {
                    previousFrame = oldFrame
                    previousFrameTime = oldFrameTime
                    sourceFrameIndex += 1
                    sourceFrameStatsCount += 1
                    if interpolationMode != .motion2Intense {
                        detectSceneChangeIfNeeded(frame)
                    }
                    if let oldFrame, oldFrameTime.isValid, frameTime.isValid {
                        let duration = frameTime.seconds - oldFrameTime.seconds
                        if duration.isFinite, duration > 0, duration < 0.20 {
                            liveInterpolationPair = LiveInterpolationPair(
                                previous: SourceVideoFrame(pixelBuffer: oldFrame, time: oldFrameTime),
                                next: SourceVideoFrame(pixelBuffer: frame, time: frameTime),
                                startHostTime: hostTime,
                                duration: duration
                            )
                        }
                    }
                    if fpsMode == .flux, let previousFrame {
                        let shouldUpdateFlow = interpolationMode != .motion2Intense && sourceFrameIndex.isMultiple(of: 3)
                        if shouldUpdateFlow {
                            opticalFlowEngine.update(
                                previousFrame: previousFrame,
                                currentFrame: frame,
                                pairKey: pairKey(previous: previousFrameTime, next: frameTime)
                            )
                        }
                    }
                    if fpsMode == .flux,
                       interpolationMode != .disabled,
                       interpolationMode != .motion2Intense,
                       let previousFrame {
                        scheduleRIFEIfNeeded(
                            previous: SourceVideoFrame(pixelBuffer: previousFrame, time: previousFrameTime),
                            next: SourceVideoFrame(pixelBuffer: frame, time: frameTime)
                        )
                    }
                }
            }
        }

        guard let frame = image(
            for: itemTime,
            hostTime: hostTime,
            drawableSize: view.drawableSize,
            commandBuffer: commandBuffer
        ) else { return }

        recordRenderedFrame(frame)

        let displayImage = visualEnhancementsEnabled
            ? applyVisualEnhancements(frame.image)
            : frame.image
        let fittedImage = frame.needsDetailBoost
            ? detailBoosted(aspectFit(displayImage, in: view.drawableSize))
            : aspectFit(displayImage, in: view.drawableSize)
        let dithered = applyDithering(fittedImage)
        ciContext.render(
            dithered,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(origin: .zero, size: view.drawableSize),
            colorSpace: renderColorSpace
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // ════════════════════════════════════════════════════════════════
    // interpolateFrameMetal — FIX Bug 4: doble buffer A/B
    //
    // El shader Metal escribe al buffer que NO se está mostrando.
    // Alternamos con framePlusOutputToggle en cada llamada.
    // Esto elimina la condición de carrera donde el render del
    // pulso N leía datos de GPU que aún no habían terminado del N-1.
    // ════════════════════════════════════════════════════════════════
    private func interpolateFrameMetal(
        current: CVPixelBuffer,
        currentTime: CMTime,
        next: CVPixelBuffer,
        nextTime: CMTime,
        timestep: Float,
        commandBuffer: MTLCommandBuffer
    ) -> CIImage? {
        guard let framePlusEngine,
              let textureCache,
              CVPixelBufferGetWidth(current) == CVPixelBufferGetWidth(next),
              CVPixelBufferGetHeight(current) == CVPixelBufferGetHeight(next) else {
            return nil
        }

        let w = CVPixelBufferGetWidth(next)
        let h = CVPixelBufferGetHeight(next)
        guard w > 0, h > 0 else { return nil }

        let currentSize = CGSize(width: w, height: h)

        // Recrear ambos buffers si la resolución cambia
        if framePlusLastOutputSize != currentSize {
            framePlusLastOutputSize = currentSize
            framePlusOutputPoolA = nil
            framePlusOutputPoolB = nil
            framePlusOutputTextureA = nil
            framePlusOutputTextureB = nil

            let attrs: [CFString: Any] = [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            var pbA: CVPixelBuffer?
            var pbB: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pbA)
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pbB)
            framePlusOutputPoolA = pbA
            framePlusOutputPoolB = pbB
        }

        // Alternar qué buffer usa este frame
        framePlusOutputToggle.toggle()
        let pixelBuffer = framePlusOutputToggle ? framePlusOutputPoolA : framePlusOutputPoolB
        var outputTexture = framePlusOutputToggle ? framePlusOutputTextureA : framePlusOutputTextureB

        guard let pixelBuffer else { return nil }

        // Crear textura si no existe para este slot
        if outputTexture == nil {
            var texRef: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .bgra8Unorm, w, h, 0, &texRef
            )
            outputTexture = texRef.flatMap { CVMetalTextureGetTexture($0) }
            if framePlusOutputToggle {
                framePlusOutputTextureA = outputTexture
            } else {
                framePlusOutputTextureB = outputTexture
            }
        }

        guard let outputTexture else { return nil }

        do {
            try framePlusEngine.encode(
                previous: current,
                current: next,
                output: outputTexture,
                commandBuffer: commandBuffer,
                timestep: timestep
            )
        } catch {
            playerViewLogger.error("Frame⁺ MEMC encode failed, falling back to crossfade: \(error.localizedDescription)")
            return nil
        }

        propagateColorAttachments(from: next, to: pixelBuffer)
        return ciImage(from: pixelBuffer, fallbackSource: next)
    }

    // Helper para renderizar negro sin código duplicado
    private func renderBlack(
        to drawable: CAMetalDrawable,
        commandBuffer: MTLCommandBuffer,
        ciContext: CIContext,
        size: CGSize
    ) {
        ciContext.render(
            CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)),
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(origin: .zero, size: size),
            colorSpace: renderColorSpace
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func startFramePlusPrefetcher() {
        guard prefetcher == nil, let output = videoOutput else { return }
        frameBuffer.reset()
        framePlusUniqueFrameCount = 0
        framePlusStatsStart = CACurrentMediaTime()
        let p = FramePrefetcher(output: output, buffer: frameBuffer)
        p.start()
        prefetcher = p
    }

    private func stopFramePlusPrefetcher() {
        prefetcher?.stop()
        prefetcher = nil
        frameBuffer.reset()
        framePlusNextFrame = nil
    }

    private func resetFramePlusCadence() {
        framePlusHeldFrame = nil
        framePlusHeldTime = .invalid
        framePlusNextFrame = nil
        framePlusDisplayPulse = 0
        frameBuffer.reset()
        framePlusUniqueFrameCount = 0
        framePlusStatsStart = CACurrentMediaTime()
    }

    private func attachOutputIfNeeded(to item: AVPlayerItem?) {
        guard attachedItem !== item else { return }
        if let videoOutput, let attachedItem {
            attachedItem.remove(videoOutput)
        }
        stopFramePlusPrefetcher()

        attachedItem = item
        previousFrame = nil
        previousFrameTime = .invalid
        latestFrame = nil
        latestFrameTime = .invalid
        liveInterpolationPair = nil
        framePlusHeldFrame = nil
        framePlusHeldTime = .invalid
        framePlusNextFrame = nil
        framePlusDisplayPulse = 0
        frameBuffer.reset()
        sourceFrames.removeAll(keepingCapacity: true)
        sourceFrameIndex = 0
        memcDisabledUntil = 0
        opticalFlowEngine.reset()
        previousAverageLuma = nil
        averageLumaAccumulator = 0
        averageLumaSamples = 0
        resetStats()
        resetRIFECache()
        let oldPoolA = framePlusOutputPoolA
        let oldPoolB = framePlusOutputPoolB
        let oldTexA = framePlusOutputTextureA
        let oldTexB = framePlusOutputTextureB
        framePlusOutputPoolA = nil
        framePlusOutputPoolB = nil
        framePlusOutputTextureA = nil
        framePlusOutputTextureB = nil
        framePlusLastOutputSize = .zero
        framePlusOutputToggle = false

        if oldPoolA != nil || oldPoolB != nil || oldTexA != nil || oldTexB != nil,
           let device = MTLCreateSystemDefaultDevice(),
           let commandQueue = device.makeCommandQueue() {
            let buffer = commandQueue.makeCommandBuffer()
            buffer?.addCompletedHandler { _ in
                _ = oldPoolA
                _ = oldPoolB
                _ = oldTexA
                _ = oldTexB
            }
            buffer?.commit()
        }

        guard let item else {
            videoOutput = nil
            return
        }

        let attributes: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
        item.add(output)
        videoOutput = output

    }

    private func image(
        for itemTime: CMTime,
        hostTime: CFTimeInterval,
        drawableSize: CGSize,
        commandBuffer: MTLCommandBuffer
    ) -> InterpolatedImage? {
        guard let latestSourceFrame = sourceFrames.last ?? latestFrame.map({ SourceVideoFrame(pixelBuffer: $0, time: latestFrameTime) }) else {
            return nil
        }
        guard fpsMode == .flux else {
            return InterpolatedImage(
                image: ciImage(from: latestSourceFrame.pixelBuffer),
                isInterpolated: false,
                needsDetailBoost: false,
                usedOpticalFlow: false
            )
        }

        let pair: (previous: SourceVideoFrame, next: SourceVideoFrame, targetSeconds: Double)
        if interpolationMode == .motion2Intense, let bufferedPair = sourceFramePair(for: itemTime) {
            pair = bufferedPair
        } else if interpolationMode == .motion2Intense, let livePair = liveInterpolationPair {
            let phase = min(max((hostTime - livePair.startHostTime) / livePair.duration, 0), 0.985)
            pair = (
                previous: livePair.previous,
                next: livePair.next,
                targetSeconds: livePair.previous.time.seconds + livePair.duration * phase
            )
        } else if let bufferedPair = sourceFramePair(for: itemTime) {
            pair = bufferedPair
        } else {
            return InterpolatedImage(
                image: ciImage(from: latestSourceFrame.pixelBuffer),
                isInterpolated: false,
                needsDetailBoost: false,
                usedOpticalFlow: false
            )
        }

        let frameDuration = pair.next.time.seconds - pair.previous.time.seconds
        guard frameDuration.isFinite, frameDuration > 0 else {
            return InterpolatedImage(
                image: ciImage(from: latestSourceFrame.pixelBuffer),
                isInterpolated: false,
                needsDetailBoost: false,
                usedOpticalFlow: false
            )
        }

        let t = min(max((pair.targetSeconds - pair.previous.time.seconds) / frameDuration, 0), 0.985)

        if t <= 0.001 {
            return InterpolatedImage(
                image: ciImage(from: pair.previous.pixelBuffer),
                isInterpolated: false,
                needsDetailBoost: false,
                usedOpticalFlow: false
            )
        }

        if t >= 0.999 {
            return InterpolatedImage(
                image: ciImage(from: pair.next.pixelBuffer),
                isInterpolated: false,
                needsDetailBoost: false,
                usedOpticalFlow: false
            )
        }

        let interpolationWidth = fluxInterpolationWidth(for: pair.previous.pixelBuffer)
        let prevCI = scaledToWidth(ciImage(from: pair.previous.pixelBuffer), width: interpolationWidth)
        let nextCI = scaledToWidth(ciImage(from: pair.next.pixelBuffer), width: interpolationWidth)
        let key = pairKey(previous: pair.previous.time, next: pair.next.time)

        if interpolationMode == .motion2Intense {
            if let memcImage = interpolateFrameMetal(
                current: pair.previous.pixelBuffer,
                currentTime: pair.previous.time,
                next: pair.next.pixelBuffer,
                nextTime: pair.next.time,
                timestep: Float(t),
                commandBuffer: commandBuffer
            ) {
                return InterpolatedImage(
                    image: memcImage,
                    isInterpolated: true,
                    needsDetailBoost: false,
                    usedOpticalFlow: true
                )
            }

            return InterpolatedImage(
                image: interpolatedImage(
                    previousImage: prevCI,
                    currentImage: nextCI,
                    amount: t,
                    pairKey: key,
                    allowOpticalFlow: false
                ).image,
                isInterpolated: true,
                needsDetailBoost: false,
                usedOpticalFlow: false
            )
        }

        if let rifeImage = rifeImage(for: pair, amount: t) {
            return InterpolatedImage(
                image: rifeImage,
                isInterpolated: true,
                needsDetailBoost: false,
                usedOpticalFlow: true
            )
        }

        let result = interpolatedImage(
            previousImage: prevCI,
            currentImage: nextCI,
            amount: t,
            pairKey: key,
            allowOpticalFlow: interpolationMode != .motion2Intense
        )

        return InterpolatedImage(
            image: result.image,
            isInterpolated: true,
            needsDetailBoost: false,
            usedOpticalFlow: result.usedOpticalFlow
        )
    }

    private func interpolatedImage(
        previousImage: CIImage,
        currentImage: CIImage,
        amount: Double,
        pairKey: String,
        allowOpticalFlow: Bool
    ) -> MEMCImage {
        if allowOpticalFlow,
           CACurrentMediaTime() >= memcDisabledUntil,
           let flow = opticalFlowEngine.snapshotFlow(maxAge: 0.42, pairKey: pairKey),
           let memcImage = opticalFlowImage(
                previousImage: previousImage,
                currentImage: currentImage,
                flow: flow,
                amount: amount
           ) {
            return MEMCImage(image: memcImage, usedOpticalFlow: true)
        }

        let blend = fastBlendKernel?.apply(
            extent: currentImage.extent,
            roiCallback: { _, rect in rect },
            arguments: [previousImage, currentImage, Float(amount)]
        )?.cropped(to: currentImage.extent) ?? currentImage

        return MEMCImage(image: blend, usedOpticalFlow: false)
    }

    private func scheduleRIFEIfNeeded(previous: SourceVideoFrame, next: SourceVideoFrame) {
        guard rifeInterpolator.isLoaded else {
            loadRIFEIfNeeded()
            return
        }
        guard !rifeInFlight,
              CACurrentMediaTime() >= rifeFailureBackoffUntil,
              CACurrentMediaTime() >= rifeStabilityBackoffUntil else { return }

        let key = pairKey(previous: previous.time, next: next.time)
        if activeRIFEPairKey != key {
            activeRIFEPairKey = key
            rifeFrameCache.removeAll(keepingCapacity: true)
            pendingRIFETimesteps.removeAll(keepingCapacity: true)
        }

        guard let timestep = desiredRIFETimesteps().first(where: {
                  rifeFrameCache[$0] == nil && !pendingRIFETimesteps.contains($0)
              }),
              let preparedPrevious = preparedRIFEBuffer(from: previous.pixelBuffer),
              let preparedNext = preparedRIFEBuffer(from: next.pixelBuffer) else { return }

        rifeInFlight = true
        pendingRIFETimesteps.insert(timestep)
        Task { @MainActor in
            let start = CACurrentMediaTime()
            defer {
                self.pendingRIFETimesteps.remove(timestep)
                self.rifeInFlight = false
            }
            do {
                let interpolated = try await self.rifeInterpolator.interpolate(
                    frame0: preparedPrevious,
                    frame1: preparedNext,
                    timestep: timestep
                )
                if self.activeRIFEPairKey == key {
                    self.rifeFrameCache[timestep] = interpolated
                }
                let latencyMS = (CACurrentMediaTime() - start) * 1000
                if latencyMS > 180 {
                    self.rifeFailureBackoffUntil = CACurrentMediaTime() + 0.75
                }
            } catch {
                self.rifeFailureBackoffUntil = CACurrentMediaTime() + 2.5
            }
        }
    }

    private func preparedRIFEBuffer(from pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let sourceWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        guard sourceWidth <= rifeWorkingMaxWidth, sourceHeight <= rifeWorkingMaxHeight else { return nil }

        let width = max(32, Int(sourceWidth.rounded()))
        let height = max(32, Int(sourceHeight.rounded()))

        if width == Int(sourceWidth), height == Int(sourceHeight),
           CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA {
            return pixelBuffer
        }

        var output: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &output
        ) == kCVReturnSuccess, let output else { return nil }

        let image = ciImage(from: pixelBuffer)
            .cropped(to: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
        ciContext?.render(image, to: output)
        return output
    }

    private func rifeImage(
        for pair: (previous: SourceVideoFrame, next: SourceVideoFrame, targetSeconds: Double),
        amount: Double
    ) -> CIImage? {
        guard interpolationMode != .disabled,
              activeRIFEPairKey == pairKey(previous: pair.previous.time, next: pair.next.time),
              !rifeFrameCache.isEmpty else { return nil }
        let timestep = nearestRIFETimestep(to: amount)
        guard let frame = rifeFrameCache[timestep] else { return nil }
        return ciImage(from: frame)
    }

    private func desiredRIFETimesteps() -> [Float] {
        switch interpolationMode {
        case .disabled:          []
        case .rife2x:            [0.5]
        case .rife4x:            [0.25, 0.5, 0.75]
        case .rifeAdaptive:      currentRenderFPSEstimate() >= 85 ? [0.25, 0.5, 0.75] : [0.5]
        case .motion2Intense:    []
        }
    }

    private func nearestRIFETimestep(to amount: Double) -> Float {
        let timesteps = desiredRIFETimesteps()
        guard let nearest = timesteps.min(by: { abs(Double($0) - amount) < abs(Double($1) - amount) }) else {
            return 0.5
        }
        return nearest
    }

    private func currentRenderFPSEstimate() -> Double {
        let elapsed = CACurrentMediaTime() - statsStartTime
        guard elapsed > 0.05 else { return 0 }
        return Double(renderedFrameCount) / elapsed
    }

    private func pairKey(previous: CMTime, next: CMTime) -> String {
        "\(previous.value)/\(previous.timescale)-\(next.value)/\(next.timescale)"
    }

    private func resetRIFECache() {
        activeRIFEPairKey = nil
        rifeFrameCache.removeAll(keepingCapacity: true)
        pendingRIFETimesteps.removeAll(keepingCapacity: true)
    }

    @discardableResult
    private func appendSourceFrame(_ pixelBuffer: CVPixelBuffer, time: CMTime) -> Bool {
        guard time.isValid, time.seconds.isFinite else { return false }
        if let last = sourceFrames.last {
            let delta = time.seconds - last.time.seconds
            let duplicateThreshold = max(0.0005, estimatedNominalSourceFrameDuration() * 0.35)
            if abs(delta) < duplicateThreshold {
                sourceFrames[sourceFrames.count - 1] = SourceVideoFrame(pixelBuffer: pixelBuffer, time: time)
                return false
            }
            if delta < 0 || delta > 0.75 {
                sourceFrames.removeAll(keepingCapacity: true)
            }
        }
        sourceFrames.append(SourceVideoFrame(pixelBuffer: pixelBuffer, time: time))
        if sourceFrames.count > 8 {
            sourceFrames.removeFirst(sourceFrames.count - 8)
        }
        return true
    }

    private func sourceFramePair(for itemTime: CMTime) -> (previous: SourceVideoFrame, next: SourceVideoFrame, targetSeconds: Double)? {
        guard sourceFrames.count >= 2 else { return nil }
        let delay = estimatedSourceFrameDuration()
        let targetSeconds = itemTime.seconds - delay
        for index in 0..<(sourceFrames.count - 1) {
            let previous = sourceFrames[index]
            let next = sourceFrames[index + 1]
            if targetSeconds >= previous.time.seconds && targetSeconds <= next.time.seconds {
                return (previous, next, targetSeconds)
            }
        }
        if targetSeconds < sourceFrames[0].time.seconds {
            return (sourceFrames[0], sourceFrames[1], sourceFrames[0].time.seconds)
        }
        let previous = sourceFrames[sourceFrames.count - 2]
        let next = sourceFrames[sourceFrames.count - 1]
        return (previous, next, min(targetSeconds, next.time.seconds - 0.0001))
    }

    private func estimatedSourceFrameDuration() -> Double {
        let bufferFrames = interpolationMode == .motion2Intense ? 1.35 : 1.25
        let maximumDelay = interpolationMode == .motion2Intense ? 0.24 : 0.10
        if sourceFrames.count >= 2 {
            let newest = sourceFrames[sourceFrames.count - 1].time.seconds
            let previous = sourceFrames[sourceFrames.count - 2].time.seconds
            let delta = newest - previous
            if delta.isFinite, delta > 0 {
                return min(delta * bufferFrames, maximumDelay)
            }
        }
        if let sourceFrameRate, sourceFrameRate.isFinite, sourceFrameRate > 0 {
            return min(bufferFrames / sourceFrameRate, maximumDelay)
        }
        return bufferFrames / 24.0
    }

    private func estimatedNominalSourceFrameDuration() -> Double {
        if let sourceFrameRate, sourceFrameRate.isFinite, sourceFrameRate > 1 {
            return 1.0 / sourceFrameRate
        }
        return 1.0 / 24.0
    }

    private func normalizedSourceFrameTime(_ time: CMTime) -> CMTime {
        guard interpolationMode == .motion2Intense,
              let sourceFrameRate,
              sourceFrameRate.isFinite,
              sourceFrameRate > 1,
              sourceFrameRate < 59.5,
              time.isValid,
              time.seconds.isFinite else {
            return time
        }

        let frameNumber = max(0, floor(time.seconds * sourceFrameRate + 0.05))
        let seconds = frameNumber / sourceFrameRate
        return CMTime(seconds: seconds, preferredTimescale: 600_000)
    }

    private func opticalFlowImage(
        previousImage: CIImage,
        currentImage: CIImage,
        flow: OpticalFlowSnapshot,
        amount: Double
    ) -> CIImage? {
        guard let memcKernel else { return nil }
        let rawFlowImage = CIImage(cvPixelBuffer: flow.pixelBuffer)
        let flowImage = scaledFlowImage(rawFlowImage, to: currentImage.extent)
        return memcKernel.apply(
            extent: currentImage.extent,
            roiCallback: { _, rect in rect.insetBy(dx: -96, dy: -96) },
            arguments: [
                previousImage,
                currentImage,
                flowImage,
                Float(amount),
                Float(memcIntensity.maxMotion),
                Float(memcIntensity.warpStrength),
                Float(memcIntensity.mix),
                effectiveFlowScale(for: flow, currentImage: currentImage),
                Float(memcIntensity.occlusionThreshold)
            ]
        )?.cropped(to: currentImage.extent)
    }

    private func scaledFlowImage(_ image: CIImage, to extent: CGRect) -> CIImage {
        guard image.extent.width > 0, image.extent.height > 0,
              extent.width > 0, extent.height > 0 else { return image }
        let scaleX = extent.width / image.extent.width
        let scaleY = extent.height / image.extent.height
        let transform = CGAffineTransform(
            a: scaleX, b: 0, c: 0, d: scaleY,
            tx: extent.origin.x - image.extent.origin.x * scaleX,
            ty: extent.origin.y - image.extent.origin.y * scaleY
        )
        return image.transformed(by: transform).cropped(to: extent)
    }

    private func effectiveFlowScale(for flow: OpticalFlowSnapshot, currentImage: CIImage) -> Float {
        let sourceWidth = max(1, flow.sourceWidth)
        let workingScale = currentImage.extent.width / CGFloat(sourceWidth)
        return flow.vectorScale * Float(workingScale)
    }

    private func detectSceneChangeIfNeeded(_ pixelBuffer: CVPixelBuffer) {
        guard sourceFrameIndex.isMultiple(of: 30) else { return }
        let image = ciImage(from: pixelBuffer)
        let extent = image.extent
        guard let averageFilter = CIFilter(name: "CIAreaAverage") else { return }
        averageFilter.setValue(image, forKey: kCIInputImageKey)
        averageFilter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        guard let outputImage = averageFilter.outputImage else { return }
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext?.render(
            outputImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: renderColorSpace
        )
        let luma = (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255.0
        averageLumaAccumulator += luma
        averageLumaSamples += 1
        if let previousAverageLuma, abs(luma - previousAverageLuma) > 0.20 {
            memcDisabledUntil = CACurrentMediaTime() + 0.8
            opticalFlowEngine.reset()
        }
        previousAverageLuma = luma
    }

    private func recordRenderedFrame(_ frame: InterpolatedImage) {
        renderedFrameCount += 1
        if frame.isInterpolated {
            interpolatedFrameCount += 1
            if frame.usedOpticalFlow {
                opticalFlowFrameCount += 1
            } else {
                blendFallbackFrameCount += 1
            }
        }

        let now = CACurrentMediaTime()
        let elapsed = now - statsStartTime
        guard elapsed >= 0.5 else { return }

        let drawLoopFPS = Double(renderedFrameCount) / elapsed
        if interpolationMode != .disabled, drawLoopFPS < 55 {
            rifeStabilityBackoffUntil = CACurrentMediaTime() + 3.0
            resetRIFECache()
        }
        let isInterpolationActive = interpolatedFrameCount > 0
        let opticalFlowUsage = interpolatedFrameCount > 0
            ? Double(opticalFlowFrameCount) / Double(interpolatedFrameCount)
            : 0
        let blendFallbackUsage = interpolatedFrameCount > 0
            ? Double(blendFallbackFrameCount) / Double(interpolatedFrameCount)
            : 0

        let reportedFPS = fpsMode == .native
            ? (sourceFrameRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? drawLoopFPS)
            : drawLoopFPS

        statsHandler?(VideoRenderStats(
            renderingFPS: reportedFPS,
            isArtificialInterpolationActive: isInterpolationActive,
            fluxWorkingWidth: fpsMode == .flux ? Int(fluxWorkingMaxWidth.rounded()) : nil,
            opticalFlowUsage: opticalFlowUsage,
            blendFallbackUsage: blendFallbackUsage,
            rifeStatus: rifeInterpolator.statusText,
            isRIFELoaded: rifeInterpolator.isLoaded
        ))
        resetStats()
    }

    private func resetStats() {
        statsStartTime = CACurrentMediaTime()
        renderedFrameCount = 0
        interpolatedFrameCount = 0
        opticalFlowFrameCount = 0
        blendFallbackFrameCount = 0
        sourceFrameStatsCount = 0
    }

    private func applyVisualEnhancements(_ image: CIImage) -> CIImage {
        PlayerState.applyVisualEnhancements(to: image)
    }

    private func applyDithering(_ image: CIImage) -> CIImage {
        image
    }

    private func ciImage(from pixelBuffer: CVPixelBuffer, fallbackSource: CVPixelBuffer? = nil) -> CIImage {
        let resolvedColorSpace = self.colorSpace(for: pixelBuffer)
            ?? fallbackSource.flatMap { self.colorSpace(for: $0) }
            ?? renderColorSpace
        return CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: resolvedColorSpace])
    }

    private func colorSpace(for pixelBuffer: CVPixelBuffer) -> CGColorSpace? {
        if let value = copyAttachment(from: pixelBuffer, key: kCVImageBufferCGColorSpaceKey),
           CFGetTypeID(value) == CGColorSpace.typeID {
            return (value as! CGColorSpace)
        }

        if let value = copyAttachment(from: pixelBuffer, key: kCVImageBufferColorPrimariesKey),
           let primaries = value as? String,
           primaries == (kCVImageBufferColorPrimaries_ITU_R_709_2 as String) {
            return CGColorSpace(name: CGColorSpace.itur_709)
        }

        return nil
    }

    private func propagateColorAttachments(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        CVBufferPropagateAttachments(source, destination)
        if copyAttachment(from: destination, key: kCVImageBufferCGColorSpaceKey) == nil {
            CVBufferSetAttachment(destination, kCVImageBufferCGColorSpaceKey, renderColorSpace, .shouldPropagate)
        }
    }

    private func copyAttachment(from pixelBuffer: CVPixelBuffer, key: CFString) -> CFTypeRef? {
        CVBufferCopyAttachment(pixelBuffer, key, nil)
    }

    private func aspectFit(_ image: CIImage, in drawableSize: CGSize) -> CIImage {
        guard image.extent.width > 0, image.extent.height > 0,
              drawableSize.width > 0, drawableSize.height > 0 else { return image }
        let scale = min(drawableSize.width / image.extent.width, drawableSize.height / image.extent.height)
        let scaledSize = CGSize(width: image.extent.width * scale, height: image.extent.height * scale)
        let offset = CGPoint(
            x: (drawableSize.width - scaledSize.width) * 0.5,
            y: (drawableSize.height - scaledSize.height) * 0.5
        )
        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
    }

    private func fluxInterpolationWidth(for frame: CVPixelBuffer) -> CGFloat {
        let sourceWidth = CGFloat(CVPixelBufferGetWidth(frame))
        guard sourceWidth > 0 else { return fluxWorkingMaxWidth }
        return min(sourceWidth, fluxWorkingMaxWidth)
    }

    private func scaledToWidth(_ image: CIImage, width: CGFloat) -> CIImage {
        guard image.extent.width > 0, width > 0 else { return image }
        let scale = width / image.extent.width
        let scaledHeight = image.extent.height * scale
        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: scaledHeight))
    }

    private func detailBoosted(_ image: CIImage) -> CIImage {
        image
            .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.35])
            .cropped(to: image.extent)
    }
}

// MARK: - Private types

private struct InterpolatedImage {
    let image: CIImage
    let isInterpolated: Bool
    let needsDetailBoost: Bool
    let usedOpticalFlow: Bool
}

private struct LiveInterpolationPair {
    let previous: SourceVideoFrame
    let next: SourceVideoFrame
    let startHostTime: CFTimeInterval
    let duration: Double
}

private struct MEMCImage {
    let image: CIImage
    let usedOpticalFlow: Bool
}

private enum MEMCIntensity {
    case high

    var maxMotion: Double { 320 }
    var warpStrength: Double { 1.0 }
    var mix: Double { 0.96 }
    var occlusionThreshold: Double { 0.28 }
}
