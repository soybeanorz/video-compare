import AppKit
import CoreVideo
import Metal
import MetalKit
import simd

private struct MetalVideoVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

private struct MetalVideoUniforms {
    var viewportSize: SIMD2<Float>
    var fullRange: Float
    var bitDepth: Float
}

final class MetalCompositeView: MTKView {
    private let renderCommandQueue: MTLCommandQueue
    private let yuvPipeline: MTLRenderPipelineState
    private let bgraPipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private var frameA: CVPixelBuffer?
    private var frameB: CVPixelBuffer?
    private var visibleA = true
    private var visibleB = true

    var layoutMode: CompareLayout = .sideBySideHorizontal {
        didSet { needsDisplay = true }
    }
    var showingAInToggle = true {
        didSet { needsDisplay = true }
    }
    var wipeFraction: CGFloat = 0.5 {
        didSet { needsDisplay = true }
    }
    var rectA: CGRect = .zero {
        didSet { needsDisplay = true }
    }
    var rectB: CGRect = .zero {
        didSet { needsDisplay = true }
    }
    var transformA = TransformState() {
        didSet { needsDisplay = true }
    }
    var transformB = TransformState() {
        didSet { needsDisplay = true }
    }

    init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: MetalCompositeView.shaderSource, options: nil),
              let vertex = library.makeFunction(name: "videoVertex"),
              let yuvFragment = library.makeFunction(name: "yuvFragment"),
              let bgraFragment = library.makeFunction(name: "bgraFragment") else {
            fatalError("Metal setup failed")
        }

        func makePipeline(fragment: MTLFunction) -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                fatalError("Metal pipeline setup failed: \(error)")
            }
        }

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let cache else {
            fatalError("CVMetalTextureCache setup failed")
        }

        renderCommandQueue = commandQueue
        yuvPipeline = makePipeline(fragment: yuvFragment)
        bgraPipeline = makePipeline(fragment: bgraFragment)
        textureCache = cache

        super.init(frame: .zero, device: device)
        framebufferOnly = true
        enableSetNeedsDisplay = true
        isPaused = true
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    func setFrame(_ pixelBuffer: CVPixelBuffer?, slot: VideoSlot) {
        switch slot {
        case .a: frameA = pixelBuffer
        case .b: frameB = pixelBuffer
        }
        needsDisplay = true
    }

    func setVisible(_ visible: Bool, slot: VideoSlot) {
        switch slot {
        case .a: visibleA = visible
        case .b: visibleB = visible
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: CGRect) {
        guard let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              let commandBuffer = renderCommandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let viewport = SIMD2<Float>(Float(bounds.width * scale), Float(bounds.height * scale))
        var uniforms = MetalVideoUniforms(viewportSize: viewport, fullRange: 0, bitDepth: 8)

        switch layoutMode {
        case .sideBySideHorizontal:
            draw(slot: .a, appRect: scaledTopLeft(rectA, scale: scale), clip: scaledTopLeft(rectA, scale: scale), encoder: encoder, uniforms: &uniforms)
            draw(slot: .b, appRect: scaledTopLeft(rectB, scale: scale), clip: scaledTopLeft(rectB, scale: scale), encoder: encoder, uniforms: &uniforms)
        case .overlapToggle:
            let slot: VideoSlot = showingAInToggle ? .a : .b
            let rect = scaledTopLeft(rectA, scale: scale)
            draw(slot: slot, appRect: rect, clip: rect, encoder: encoder, uniforms: &uniforms)
        case .overlapWipe:
            let full = scaledTopLeft(rectA, scale: scale)
            draw(slot: .b, appRect: full, clip: full, encoder: encoder, uniforms: &uniforms)
            let clip = CGRect(x: full.minX, y: full.minY, width: full.width * max(0, min(1, wipeFraction)), height: full.height)
            draw(slot: .a, appRect: full, clip: clip, encoder: encoder, uniforms: &uniforms)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func draw(slot: VideoSlot, appRect: CGRect, clip: CGRect, encoder: MTLRenderCommandEncoder, uniforms: inout MetalVideoUniforms) {
        let pixelBuffer: CVPixelBuffer?
        var transform: TransformState
        let visible: Bool
        switch slot {
        case .a:
            pixelBuffer = frameA
            transform = transformA
            visible = visibleA
        case .b:
            pixelBuffer = frameB
            transform = transformB
            visible = visibleB
        }
        guard visible, let pixelBuffer, appRect.width > 1, appRect.height > 1 else { return }
        if layoutMode == .sideBySideHorizontal {
            transform = TransformState()
        }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let sourceWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard sourceWidth > 0, sourceHeight > 0 else { return }

        let fit = min(appRect.width / sourceWidth, appRect.height / sourceHeight)
        let zoom = pow(2.0, transform.zoom)
        let finalScale = fit * zoom
        let videoWidth = sourceWidth * finalScale
        let videoHeight = sourceHeight * finalScale
        let videoRect = CGRect(
            x: appRect.midX - videoWidth / 2 + CGFloat(transform.panX) * appRect.width / 2,
            y: appRect.midY - videoHeight / 2 + CGFloat(transform.panY) * appRect.height / 2,
            width: videoWidth,
            height: videoHeight
        )
        let drawRect = videoRect.intersection(clip)
        guard !drawRect.isNull, drawRect.width > 0, drawRect.height > 0 else { return }

        let u0 = Float((drawRect.minX - videoRect.minX) / videoRect.width)
        let u1 = Float((drawRect.maxX - videoRect.minX) / videoRect.width)
        let v0 = Float((drawRect.minY - videoRect.minY) / videoRect.height)
        let v1 = Float((drawRect.maxY - videoRect.minY) / videoRect.height)
        var vertices = [
            MetalVideoVertex(position: SIMD2(Float(drawRect.minX), Float(drawRect.minY)), texCoord: SIMD2(u0, v0)),
            MetalVideoVertex(position: SIMD2(Float(drawRect.minX), Float(drawRect.maxY)), texCoord: SIMD2(u0, v1)),
            MetalVideoVertex(position: SIMD2(Float(drawRect.maxX), Float(drawRect.minY)), texCoord: SIMD2(u1, v0)),
            MetalVideoVertex(position: SIMD2(Float(drawRect.maxX), Float(drawRect.maxY)), texCoord: SIMD2(u1, v1))
        ]

        if CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 {
            drawYUV(pixelBuffer: pixelBuffer, pixelFormat: pixelFormat, vertices: &vertices, encoder: encoder, uniforms: &uniforms)
        } else {
            drawBGRA(pixelBuffer: pixelBuffer, vertices: &vertices, encoder: encoder, uniforms: &uniforms)
        }
    }

    private func drawYUV(pixelBuffer: CVPixelBuffer, pixelFormat: OSType, vertices: inout [MetalVideoVertex], encoder: MTLRenderCommandEncoder, uniforms: inout MetalVideoUniforms) {
        let is10Bit = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let fullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let yFormat: MTLPixelFormat = is10Bit ? .r16Unorm : .r8Unorm
        let uvFormat: MTLPixelFormat = is10Bit ? .rg16Unorm : .rg8Unorm

        guard let yTexture = texture(from: pixelBuffer, pixelFormat: yFormat, plane: 0),
              let uvTexture = texture(from: pixelBuffer, pixelFormat: uvFormat, plane: 1) else { return }

        uniforms.fullRange = fullRange ? 1 : 0
        uniforms.bitDepth = is10Bit ? 10 : 8
        encoder.setRenderPipelineState(yuvPipeline)
        encoder.setVertexBytes(&vertices, length: MemoryLayout<MetalVideoVertex>.stride * vertices.count, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalVideoUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalVideoUniforms>.stride, index: 0)
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uvTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices.count)
    }

    private func drawBGRA(pixelBuffer: CVPixelBuffer, vertices: inout [MetalVideoVertex], encoder: MTLRenderCommandEncoder, uniforms: inout MetalVideoUniforms) {
        guard let texture = texture(from: pixelBuffer, pixelFormat: .bgra8Unorm, plane: 0) else { return }
        encoder.setRenderPipelineState(bgraPipeline)
        encoder.setVertexBytes(&vertices, length: MemoryLayout<MetalVideoVertex>.stride * vertices.count, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalVideoUniforms>.stride, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices.count)
    }

    private func texture(from pixelBuffer: CVPixelBuffer, pixelFormat: MTLPixelFormat, plane: Int) -> MTLTexture? {
        let width: Int
        let height: Int
        if CVPixelBufferGetPlaneCount(pixelBuffer) > plane {
            width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
            height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        } else {
            width = CVPixelBufferGetWidth(pixelBuffer)
            height = CVPixelBufferGetHeight(pixelBuffer)
        }

        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            plane,
            &cvTexture
        )
        guard result == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    private func scaledTopLeft(_ rect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float2 position;
        float2 texCoord;
    };

    struct Uniforms {
        float2 viewportSize;
        float fullRange;
        float bitDepth;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    vertex VertexOut videoVertex(uint vertexID [[vertex_id]],
                                 constant VertexIn *vertices [[buffer(0)]],
                                 constant Uniforms &uniforms [[buffer(1)]]) {
        VertexIn input = vertices[vertexID];
        float2 ndc = float2(
            input.position.x / uniforms.viewportSize.x * 2.0 - 1.0,
            1.0 - input.position.y / uniforms.viewportSize.y * 2.0
        );
        VertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.texCoord = input.texCoord;
        return out;
    }

    fragment float4 yuvFragment(VertexOut input [[stage_in]],
                                constant Uniforms &uniforms [[buffer(0)]],
                                texture2d<float, access::sample> yTexture [[texture(0)]],
                                texture2d<float, access::sample> uvTexture [[texture(1)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float y = yTexture.sample(s, input.texCoord).r;
        float2 uv = uvTexture.sample(s, input.texCoord).rg;
        float cb;
        float cr;
        if (uniforms.fullRange > 0.5) {
            cb = uv.x - 0.5;
            cr = uv.y - 0.5;
        } else if (uniforms.bitDepth > 8.5) {
            y = (y - 64.0 / 1023.0) * (1023.0 / 876.0);
            cb = (uv.x - 512.0 / 1023.0) * (1023.0 / 896.0);
            cr = (uv.y - 512.0 / 1023.0) * (1023.0 / 896.0);
        } else {
            y = (y - 16.0 / 255.0) * (255.0 / 219.0);
            cb = (uv.x - 128.0 / 255.0) * (255.0 / 224.0);
            cr = (uv.y - 128.0 / 255.0) * (255.0 / 224.0);
        }
        float3 rgb;
        rgb.r = y + 1.5748 * cr;
        rgb.g = y - 0.1873 * cb - 0.4681 * cr;
        rgb.b = y + 1.8556 * cb;
        return float4(clamp(rgb, 0.0, 1.0), 1.0);
    }

    fragment float4 bgraFragment(VertexOut input [[stage_in]],
                                 texture2d<float, access::sample> texture [[texture(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        return texture.sample(s, input.texCoord);
    }
    """
}
