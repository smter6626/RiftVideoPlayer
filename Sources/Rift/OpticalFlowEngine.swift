@preconcurrency import AVFoundation
@preconcurrency import CoreImage
@preconcurrency import OSLog
@preconcurrency import Vision

private let flowLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Rift", category: "OpticalFlow")

struct OpticalFlowSnapshot {
    let pixelBuffer: CVPixelBuffer
    let vectorScale: Float
    let sourceWidth: Int
    let pairKey: String
}

private struct OpticalFlowInput: @unchecked Sendable {
    let previousFrame: CVPixelBuffer
    let currentFrame: CVPixelBuffer
    let sourceWidth: Int
    let pairKey: String
}

final class OpticalFlowEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "liquid-player.optical-flow", qos: .utility)
    private let lock = NSLock()
    private var isProcessing = false
    private var latestFlow: CVPixelBuffer?
    private var latestVectorScale: Float = 1
    private var latestSourceWidth = 1
    private var latestPairKey = ""
    private var latestFlowTime = CACurrentMediaTime()
    private var lastProcessingTime = CACurrentMediaTime()
    private let minimumProcessingInterval = 0.03
    private let maximumFlowWidth = 512
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    func snapshotFlow(maxAge: TimeInterval, pairKey: String) -> OpticalFlowSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        guard let latestFlow,
              latestPairKey == pairKey,
              CACurrentMediaTime() - latestFlowTime <= maxAge else {
            return nil
        }

        return OpticalFlowSnapshot(
            pixelBuffer: latestFlow,
            vectorScale: latestVectorScale,
            sourceWidth: latestSourceWidth,
            pairKey: latestPairKey
        )
    }

    func reset() {
        lock.lock()
        latestFlow = nil
        latestVectorScale = 1
        latestSourceWidth = 1
        latestPairKey = ""
        latestFlowTime = 0
        lock.unlock()
    }

    func update(previousFrame: CVPixelBuffer, currentFrame: CVPixelBuffer, pairKey: String) {
        lock.lock()
        let now = CACurrentMediaTime()
        let canProcess = !isProcessing && now - lastProcessingTime >= minimumProcessingInterval
        if canProcess {
            isProcessing = true
            lastProcessingTime = now
        }
        lock.unlock()

        guard canProcess,
              CVPixelBufferGetWidth(previousFrame) == CVPixelBufferGetWidth(currentFrame),
              CVPixelBufferGetHeight(previousFrame) == CVPixelBufferGetHeight(currentFrame) else {
            return
        }

        let input = OpticalFlowInput(
            previousFrame: previousFrame,
            currentFrame: currentFrame,
            sourceWidth: CVPixelBufferGetWidth(currentFrame),
            pairKey: pairKey
        )

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.isProcessing = false
                self.lock.unlock()
            }

            let previousForFlow = self.downsample(input.previousFrame) ?? input.previousFrame
            let currentForFlow = self.downsample(input.currentFrame) ?? input.currentFrame
            let vectorScale = Float(input.sourceWidth) / Float(CVPixelBufferGetWidth(currentForFlow))

            let handler = VNImageRequestHandler(cvPixelBuffer: previousForFlow, options: [:])
            let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: currentForFlow, options: [:])
            request.computationAccuracy = .high
            request.outputPixelFormat = kCVPixelFormatType_TwoComponent16Half

            do {
                try handler.perform([request])
                let flow = request.results?.first?.pixelBuffer
                self.lock.lock()
                self.latestFlow = flow
                self.latestVectorScale = vectorScale
                self.latestSourceWidth = input.sourceWidth
                self.latestPairKey = input.pairKey
                self.latestFlowTime = CACurrentMediaTime()
                self.lock.unlock()
            } catch {
                self.lock.lock()
                self.latestFlow = nil
                self.lock.unlock()
                flowLogger.error("Optical flow request failed: \(error.localizedDescription)")
            }
        }
    }

    private func downsample(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard width > maximumFlowWidth else { return pixelBuffer }

        let scale = CGFloat(maximumFlowWidth) / CGFloat(width)
        let targetWidth = maximumFlowWidth
        let targetHeight = max(1, Int(CGFloat(height) * scale))
        var output: CVPixelBuffer?

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            targetWidth,
            targetHeight,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &output
        )

        guard result == kCVReturnSuccess, let output else { return nil }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        ciContext.render(image, to: output)
        return output
    }
}
