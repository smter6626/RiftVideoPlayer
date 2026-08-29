import CoreVideo
import Metal

final class FramePlusMEMCEngine {
    private struct Params {
        var fullWidth: UInt32
        var fullHeight: UInt32
        var lowWidth: UInt32
        var lowHeight: UInt32
        var vectorWidth: UInt32
        var vectorHeight: UInt32
        var downscale: UInt32
        var blockSize: UInt32
        var searchRadius: UInt32
        var timestep: Float
        var occlusionThreshold: Float
    }

    private let device: MTLDevice
    private let textureCache: CVMetalTextureCache
    private let downsamplePipeline: MTLComputePipelineState
    private let estimatePipeline: MTLComputePipelineState
    private let filterPipeline: MTLComputePipelineState
    private let warpPipeline: MTLComputePipelineState
    private var lowA: MTLTexture?
    private var lowB: MTLTexture?
    private var vectorsRaw: MTLTexture?
    private var vectorsFiltered: MTLTexture?
    private var cachedSize = CGSize.zero

    init(device: MTLDevice) throws {
        self.device = device

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let cache else {
            throw FramePlusMEMCError.textureCache
        }
        textureCache = cache

        let library = try Self.makeLibrary(device: device)
        downsamplePipeline = try Self.pipeline(named: "memcDownsample", library: library, device: device)
        estimatePipeline = try Self.pipeline(named: "memcEstimateMotion", library: library, device: device)
        filterPipeline = try Self.pipeline(named: "memcFilterVectors", library: library, device: device)
        warpPipeline = try Self.pipeline(named: "memcWarp", library: library, device: device)
    }

    func encode(
        previous: CVPixelBuffer,
        current: CVPixelBuffer,
        output: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        timestep: Float = 0.5
    ) throws {
        let width = CVPixelBufferGetWidth(current)
        let height = CVPixelBufferGetHeight(current)
        guard width == CVPixelBufferGetWidth(previous), height == CVPixelBufferGetHeight(previous) else {
            throw FramePlusMEMCError.resolutionMismatch
        }

        try ensureTextures(width: width, height: height)

        guard let frameA = makeTexture(from: previous),
              let frameB = makeTexture(from: current),
              let lowA,
              let lowB,
              let vectorsRaw,
              let vectorsFiltered else {
            throw FramePlusMEMCError.textureCreation
        }

        var params = makeParams(width: width, height: height, timestep: timestep)

        try encodeDownsample(source: frameA, destination: lowA, params: &params, commandBuffer: commandBuffer)
        try encodeDownsample(source: frameB, destination: lowB, params: &params, commandBuffer: commandBuffer)
        try encodeMotionEstimate(lowA: lowA, lowB: lowB, vectors: vectorsRaw, params: &params, commandBuffer: commandBuffer)
        try encodeVectorFilter(input: vectorsRaw, output: vectorsFiltered, params: &params, commandBuffer: commandBuffer)
        try encodeWarp(frameA: frameA, frameB: frameB, vectors: vectorsFiltered, output: output, params: &params, commandBuffer: commandBuffer)
    }

    private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        if let library = device.makeDefaultLibrary() {
            return library
        }

        if let url = ResourceLocator.url(forResource: "FramePlusMEMC", withExtension: "metal") {
            let source = try String(contentsOf: url)
            return try device.makeLibrary(source: source, options: nil)
        }

        throw FramePlusMEMCError.library
    }

    private static func pipeline(named name: String, library: MTLLibrary, device: MTLDevice) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw FramePlusMEMCError.function(name)
        }
        return try device.makeComputePipelineState(function: function)
    }

    private func ensureTextures(width: Int, height: Int) throws {
        let size = CGSize(width: width, height: height)
        guard size != cachedSize else { return }

        let params = makeParams(width: width, height: height, timestep: 0.5)
        lowA = makeTexture(width: Int(params.lowWidth), height: Int(params.lowHeight), pixelFormat: .r16Float)
        lowB = makeTexture(width: Int(params.lowWidth), height: Int(params.lowHeight), pixelFormat: .r16Float)
        vectorsRaw = makeTexture(width: Int(params.vectorWidth), height: Int(params.vectorHeight), pixelFormat: .rg16Float)
        vectorsFiltered = makeTexture(width: Int(params.vectorWidth), height: Int(params.vectorHeight), pixelFormat: .rg16Float)
        cachedSize = size
    }

    private func makeParams(width: Int, height: Int, timestep: Float) -> Params {
        let downscale: UInt32 = 4
        let blockSize: UInt32 = 4
        let searchRadius: UInt32 = 12
        let lowWidth = UInt32(max(1, (width + Int(downscale) - 1) / Int(downscale)))
        let lowHeight = UInt32(max(1, (height + Int(downscale) - 1) / Int(downscale)))
        let vectorWidth = max(1, (lowWidth + blockSize - 1) / blockSize)
        let vectorHeight = max(1, (lowHeight + blockSize - 1) / blockSize)

        return Params(
            fullWidth: UInt32(width),
            fullHeight: UInt32(height),
            lowWidth: lowWidth,
            lowHeight: lowHeight,
            vectorWidth: vectorWidth,
            vectorHeight: vectorHeight,
            downscale: downscale,
            blockSize: blockSize,
            searchRadius: searchRadius,
            timestep: timestep,
            occlusionThreshold: 0.30
        )
    }

    private func makeTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    private func encodeDownsample(source: MTLTexture, destination: MTLTexture, params: inout Params, commandBuffer: MTLCommandBuffer) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw FramePlusMEMCError.encoder }
        encoder.setComputePipelineState(downsamplePipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        dispatch(encoder, width: destination.width, height: destination.height, pipeline: downsamplePipeline)
        encoder.endEncoding()
    }

    private func encodeMotionEstimate(lowA: MTLTexture, lowB: MTLTexture, vectors: MTLTexture, params: inout Params, commandBuffer: MTLCommandBuffer) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw FramePlusMEMCError.encoder }
        encoder.setComputePipelineState(estimatePipeline)
        encoder.setTexture(lowA, index: 0)
        encoder.setTexture(lowB, index: 1)
        encoder.setTexture(vectors, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        dispatch(encoder, width: vectors.width, height: vectors.height, pipeline: estimatePipeline)
        encoder.endEncoding()
    }

    private func encodeVectorFilter(input: MTLTexture, output: MTLTexture, params: inout Params, commandBuffer: MTLCommandBuffer) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw FramePlusMEMCError.encoder }
        encoder.setComputePipelineState(filterPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        dispatch(encoder, width: output.width, height: output.height, pipeline: filterPipeline)
        encoder.endEncoding()
    }

    private func encodeWarp(frameA: MTLTexture, frameB: MTLTexture, vectors: MTLTexture, output: MTLTexture, params: inout Params, commandBuffer: MTLCommandBuffer) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw FramePlusMEMCError.encoder }
        encoder.setComputePipelineState(warpPipeline)
        encoder.setTexture(frameA, index: 0)
        encoder.setTexture(frameB, index: 1)
        encoder.setTexture(vectors, index: 2)
        encoder.setTexture(output, index: 3)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        dispatch(encoder, width: output.width, height: output.height, pipeline: warpPipeline)
        encoder.endEncoding()
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, width: Int, height: Int, pipeline: MTLComputePipelineState) {
        let threadWidth = min(16, pipeline.maxTotalThreadsPerThreadgroup)
        let threadHeight = max(1, min(16, pipeline.maxTotalThreadsPerThreadgroup / threadWidth))
        let groupSize = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        let groups = MTLSize(
            width: (width + groupSize.width - 1) / groupSize.width,
            height: (height + groupSize.height - 1) / groupSize.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: groupSize)
    }
}

enum FramePlusMEMCError: Error {
    case textureCache
    case library
    case function(String)
    case textureCreation
    case resolutionMismatch
    case encoder
}
