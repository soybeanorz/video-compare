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
    var textureSize: SIMD2<Float>
}

private struct MetalColorAdjustmentUniforms {
    var enabled: Float
    var exposure: Float
    var contrast: Float
    var brightness: Float
    var saturation: Float
    var temperature: Float
    var tint: Float
    var blackPoint: Float
    var whitePoint: Float
    var sharpness: Float
    var curveShadows: Float
    var curveMidtones: Float
    var curveHighlights: Float
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
    var colorAdjustmentA = ColorAdjustmentState() {
        didSet { needsDisplay = true }
    }
    var colorAdjustmentB = ColorAdjustmentState() {
        didSet { needsDisplay = true }
    }
    var originalBypassSlot: VideoSlot? {
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
        var uniforms = MetalVideoUniforms(viewportSize: viewport, fullRange: 0, bitDepth: 8, textureSize: SIMD2<Float>(1, 1))

        switch layoutMode {
        case .sideBySideHorizontal:
            draw(slot: .a, appRect: scaledTopLeft(rectA, scale: scale), clip: scaledTopLeft(rectA, scale: scale), encoder: encoder, uniforms: &uniforms)
            draw(slot: .b, appRect: scaledTopLeft(rectB, scale: scale), clip: scaledTopLeft(rectB, scale: scale), encoder: encoder, uniforms: &uniforms)
        case .overlapWipe:
            let full = scaledTopLeft(rectA, scale: scale)
            let leftClip = CGRect(x: full.minX, y: full.minY, width: full.width * max(0, min(1, wipeFraction)), height: full.height)
            let rightClip = CGRect(x: leftClip.maxX, y: full.minY, width: max(0, full.maxX - leftClip.maxX), height: full.height)
            draw(slot: .a, appRect: full, clip: leftClip, encoder: encoder, uniforms: &uniforms)
            draw(slot: .b, appRect: full, clip: rightClip, encoder: encoder, uniforms: &uniforms)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func draw(slot: VideoSlot, appRect: CGRect, clip: CGRect, encoder: MTLRenderCommandEncoder, uniforms: inout MetalVideoUniforms) {
        let pixelBuffer: CVPixelBuffer?
        var transform: TransformState
        let adjustment: ColorAdjustmentState
        let visible: Bool
        switch slot {
        case .a:
            pixelBuffer = frameA
            transform = transformA
            adjustment = originalBypassSlot == .a ? disabledAdjustment(from: colorAdjustmentA) : colorAdjustmentA
            visible = visibleA
        case .b:
            pixelBuffer = frameB
            transform = transformB
            adjustment = originalBypassSlot == .b ? disabledAdjustment(from: colorAdjustmentB) : colorAdjustmentB
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
            drawYUV(pixelBuffer: pixelBuffer, pixelFormat: pixelFormat, vertices: &vertices, encoder: encoder, uniforms: &uniforms, adjustment: adjustment)
        } else {
            drawBGRA(pixelBuffer: pixelBuffer, vertices: &vertices, encoder: encoder, uniforms: &uniforms, adjustment: adjustment)
        }
    }

    private func drawYUV(pixelBuffer: CVPixelBuffer, pixelFormat: OSType, vertices: inout [MetalVideoVertex], encoder: MTLRenderCommandEncoder, uniforms: inout MetalVideoUniforms, adjustment: ColorAdjustmentState) {
        let is10Bit = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let fullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let yFormat: MTLPixelFormat = is10Bit ? .r16Unorm : .r8Unorm
        let uvFormat: MTLPixelFormat = is10Bit ? .rg16Unorm : .rg8Unorm

        guard let yTexture = texture(from: pixelBuffer, pixelFormat: yFormat, plane: 0),
              let uvTexture = texture(from: pixelBuffer, pixelFormat: uvFormat, plane: 1) else { return }

        uniforms.fullRange = fullRange ? 1 : 0
        uniforms.bitDepth = is10Bit ? 10 : 8
        uniforms.textureSize = SIMD2<Float>(Float(CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)), Float(CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)))
        var adjustmentUniforms = metalAdjustmentUniforms(from: adjustment)
        encoder.setRenderPipelineState(yuvPipeline)
        encoder.setVertexBytes(&vertices, length: MemoryLayout<MetalVideoVertex>.stride * vertices.count, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalVideoUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalVideoUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&adjustmentUniforms, length: MemoryLayout<MetalColorAdjustmentUniforms>.stride, index: 1)
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uvTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices.count)
    }

    private func drawBGRA(pixelBuffer: CVPixelBuffer, vertices: inout [MetalVideoVertex], encoder: MTLRenderCommandEncoder, uniforms: inout MetalVideoUniforms, adjustment: ColorAdjustmentState) {
        guard let texture = texture(from: pixelBuffer, pixelFormat: .bgra8Unorm, plane: 0) else { return }
        uniforms.textureSize = SIMD2<Float>(Float(CVPixelBufferGetWidth(pixelBuffer)), Float(CVPixelBufferGetHeight(pixelBuffer)))
        var adjustmentUniforms = metalAdjustmentUniforms(from: adjustment)
        encoder.setRenderPipelineState(bgraPipeline)
        encoder.setVertexBytes(&vertices, length: MemoryLayout<MetalVideoVertex>.stride * vertices.count, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalVideoUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalVideoUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&adjustmentUniforms, length: MemoryLayout<MetalColorAdjustmentUniforms>.stride, index: 1)
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

    private func disabledAdjustment(from adjustment: ColorAdjustmentState) -> ColorAdjustmentState {
        var disabled = adjustment
        disabled.isEnabled = false
        return disabled
    }

    private func metalAdjustmentUniforms(from adjustment: ColorAdjustmentState) -> MetalColorAdjustmentUniforms {
        MetalColorAdjustmentUniforms(
            enabled: adjustment.isEnabled ? 1 : 0,
            exposure: Float(adjustment.exposure),
            contrast: Float(adjustment.contrast),
            brightness: Float(adjustment.brightness),
            saturation: Float(adjustment.saturation),
            temperature: Float(adjustment.temperature),
            tint: Float(adjustment.tint),
            blackPoint: Float(adjustment.blackPoint),
            whitePoint: Float(adjustment.whitePoint),
            sharpness: Float(adjustment.sharpness),
            curveShadows: Float(adjustment.curveShadows),
            curveMidtones: Float(adjustment.curveMidtones),
            curveHighlights: Float(adjustment.curveHighlights)
        )
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
        float2 textureSize;
    };

    struct Adjustments {
        float enabled;
        float exposure;
        float contrast;
        float brightness;
        float saturation;
        float temperature;
        float tint;
        float blackPoint;
        float whitePoint;
        float sharpness;
        float curveShadows;
        float curveMidtones;
        float curveHighlights;
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

    float toneCurve(float value, constant Adjustments &adjustments) {
        float v = clamp(value, 0.0, 1.0);
        float2 p0 = float2(0.0, 0.0);
        float2 p1 = float2(0.25, clamp(adjustments.curveShadows, 0.0, 1.0));
        float2 p2 = float2(0.5, clamp(adjustments.curveMidtones, 0.0, 1.0));
        float2 p3 = float2(0.75, clamp(adjustments.curveHighlights, 0.0, 1.0));
        float2 p4 = float2(1.0, 1.0);
        if (v < p1.x) {
            return mix(p0.y, p1.y, v / max(0.001, p1.x - p0.x));
        }
        if (v < p2.x) {
            return mix(p1.y, p2.y, (v - p1.x) / max(0.001, p2.x - p1.x));
        }
        if (v < p3.x) {
            return mix(p2.y, p3.y, (v - p2.x) / max(0.001, p3.x - p2.x));
        }
        return mix(p3.y, p4.y, (v - p3.x) / max(0.001, p4.x - p3.x));
    }

    float3 applyAdjustments(float3 rgb, constant Adjustments &adjustments) {
        if (adjustments.enabled < 0.5) {
            return clamp(rgb, 0.0, 1.0);
        }

        rgb *= exp2(adjustments.exposure);
        rgb += adjustments.brightness * 0.35;

        float white = max(adjustments.whitePoint, adjustments.blackPoint + 0.05);
        rgb = (rgb - adjustments.blackPoint) / max(0.001, white - adjustments.blackPoint);

        float contrast = 1.0 + adjustments.contrast * 1.5;
        rgb = (rgb - 0.5) * contrast + 0.5;

        rgb.r += adjustments.temperature * 0.08 + adjustments.tint * 0.03;
        rgb.g -= adjustments.tint * 0.06;
        rgb.b -= adjustments.temperature * 0.08 - adjustments.tint * 0.03;

        float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        rgb = mix(float3(luma), rgb, 1.0 + adjustments.saturation);
        rgb = float3(toneCurve(rgb.r, adjustments), toneCurve(rgb.g, adjustments), toneCurve(rgb.b, adjustments));
        return clamp(rgb, 0.0, 1.0);
    }

    float limitedY(texture2d<float, access::sample> yTexture, sampler s, float2 texCoord, constant Uniforms &uniforms) {
        float y = yTexture.sample(s, texCoord).r;
        if (uniforms.fullRange > 0.5) {
            return y;
        }
        if (uniforms.bitDepth > 8.5) {
            return (y - 64.0 / 1023.0) * (1023.0 / 876.0);
        }
        return (y - 16.0 / 255.0) * (255.0 / 219.0);
    }

    fragment float4 yuvFragment(VertexOut input [[stage_in]],
                                constant Uniforms &uniforms [[buffer(0)]],
                                constant Adjustments &adjustments [[buffer(1)]],
                                texture2d<float, access::sample> yTexture [[texture(0)]],
                                texture2d<float, access::sample> uvTexture [[texture(1)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float y = limitedY(yTexture, s, input.texCoord, uniforms);
        if (adjustments.enabled > 0.5 && adjustments.sharpness > 0.001) {
            float2 texel = float2(1.0) / max(uniforms.textureSize, float2(1.0));
            float left = limitedY(yTexture, s, input.texCoord - float2(texel.x, 0.0), uniforms);
            float right = limitedY(yTexture, s, input.texCoord + float2(texel.x, 0.0), uniforms);
            float up = limitedY(yTexture, s, input.texCoord - float2(0.0, texel.y), uniforms);
            float down = limitedY(yTexture, s, input.texCoord + float2(0.0, texel.y), uniforms);
            y = y + (y * 4.0 - left - right - up - down) * adjustments.sharpness * 0.35;
        }
        float2 uv = uvTexture.sample(s, input.texCoord).rg;
        float cb;
        float cr;
        if (uniforms.fullRange > 0.5) {
            cb = uv.x - 0.5;
            cr = uv.y - 0.5;
        } else if (uniforms.bitDepth > 8.5) {
            cb = (uv.x - 512.0 / 1023.0) * (1023.0 / 896.0);
            cr = (uv.y - 512.0 / 1023.0) * (1023.0 / 896.0);
        } else {
            cb = (uv.x - 128.0 / 255.0) * (255.0 / 224.0);
            cr = (uv.y - 128.0 / 255.0) * (255.0 / 224.0);
        }
        float3 rgb;
        rgb.r = y + 1.5748 * cr;
        rgb.g = y - 0.1873 * cb - 0.4681 * cr;
        rgb.b = y + 1.8556 * cb;
        return float4(applyAdjustments(rgb, adjustments), 1.0);
    }

    fragment float4 bgraFragment(VertexOut input [[stage_in]],
                                 constant Uniforms &uniforms [[buffer(0)]],
                                 constant Adjustments &adjustments [[buffer(1)]],
                                 texture2d<float, access::sample> texture [[texture(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float3 rgb = texture.sample(s, input.texCoord).rgb;
        if (adjustments.enabled > 0.5 && adjustments.sharpness > 0.001) {
            float2 texel = float2(1.0) / max(uniforms.textureSize, float2(1.0));
            float3 left = texture.sample(s, input.texCoord - float2(texel.x, 0.0)).rgb;
            float3 right = texture.sample(s, input.texCoord + float2(texel.x, 0.0)).rgb;
            float3 up = texture.sample(s, input.texCoord - float2(0.0, texel.y)).rgb;
            float3 down = texture.sample(s, input.texCoord + float2(0.0, texel.y)).rgb;
            rgb = rgb + (rgb * 4.0 - left - right - up - down) * adjustments.sharpness * 0.35;
        }
        return float4(applyAdjustments(rgb, adjustments), 1.0);
    }
    """
}
