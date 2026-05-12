import AppKit
import CMpv
import Foundation
import OpenGL.GL3

private let getOpenGLProcAddress: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
    guard let name else { return nil }
    let openGLLibrary = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY)
    guard let openGLLibrary else { return nil }
    return dlsym(openGLLibrary, name)
}

private let renderUpdateCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    guard let context else { return }
    let view = Unmanaged<MPVRenderView>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        view.needsDisplay = true
    }
}

final class MPVRenderView: NSOpenGLView {
    private var renderContext: OpaquePointer?
    private var isAttached = false

    init() {
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFAColorSize), 24,
            UInt32(NSOpenGLPFAAlphaSize), 8,
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAAccelerated),
            0
        ]
        let pixelFormat = attributes.withUnsafeBufferPointer {
            NSOpenGLPixelFormat(attributes: $0.baseAddress!)
        }
        guard let pixelFormat else {
            fatalError("OpenGL pixel format is unavailable")
        }
        super.init(frame: .zero, pixelFormat: pixelFormat)!
        wantsLayer = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        openGLContext?.makeCurrentContext()
        var swapInterval: GLint = 1
        openGLContext?.setValues(&swapInterval, for: .swapInterval)
        glClearColor(0, 0, 0, 1)
    }

    func attach(handle: OpaquePointer) -> Bool {
        guard !isAttached else { return true }
        openGLContext?.makeCurrentContext()

        var glInit = mpv_opengl_init_params(
            get_proc_address: getOpenGLProcAddress,
            get_proc_address_ctx: nil
        )
        var advancedControl: Int32 = 0
        var createdContext: OpaquePointer?

        let result = "opengl".withCString { apiName in
            withUnsafeMutablePointer(to: &glInit) { glInitPointer in
                withUnsafeMutablePointer(to: &advancedControl) { advancedPointer in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: apiName)),
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(glInitPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: UnsafeMutableRawPointer(advancedPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                    ]
                    return mpv_render_context_create(&createdContext, handle, &params)
                }
            }
        }

        guard result >= 0, let createdContext else {
            Diagnostics.log("mpv render context create failed: \(result)")
            return false
        }

        renderContext = createdContext
        isAttached = true
        mpv_render_context_set_update_callback(
            createdContext,
            renderUpdateCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        needsDisplay = true
        return true
    }

    func detach() {
        guard let renderContext else { return }
        openGLContext?.makeCurrentContext()
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        mpv_render_context_free(renderContext)
        self.renderContext = nil
        isAttached = false
    }

    override func reshape() {
        super.reshape()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        canvasParent?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        canvasParent?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        canvasParent?.mouseUp(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        openGLContext?.makeCurrentContext()
        guard let renderContext else {
            glViewport(0, 0, GLsizei(bounds.width), GLsizei(bounds.height))
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            openGLContext?.flushBuffer()
            return
        }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let width = max(1, Int32(bounds.width * scale))
        let height = max(1, Int32(bounds.height * scale))

        _ = mpv_render_context_update(renderContext)
        glViewport(0, 0, GLsizei(width), GLsizei(height))

        var fbo = mpv_opengl_fbo(fbo: 0, w: width, h: height, internal_format: 0)
        var flipY: Int32 = 1
        var blockForTargetTime: Int32 = 0
        withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flipY) { flipPointer in
                withUnsafeMutablePointer(to: &blockForTargetTime) { blockPointer in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(blockPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                    ]
                    mpv_render_context_render(renderContext, &params)
                }
            }
        }
        openGLContext?.flushBuffer()
    }

    private var canvasParent: VideoCanvasView? {
        var view = superview
        while let current = view {
            if let canvas = current as? VideoCanvasView {
                return canvas
            }
            view = current.superview
        }
        return nil
    }
}
