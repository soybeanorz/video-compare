import AppKit

final class VideoCompareWindow: NSWindow {
    var onKeyPressed: ((NSEvent) -> Bool)?
    var onKeyReleased: ((NSEvent) -> Bool)?
    var onMouseDownInContent: ((NSPoint) -> Void)?
    var onScrollWheelInContent: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyPressed?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyPressed?(event) == true {
            return
        }
        if event.type == .keyUp, onKeyReleased?(event) == true {
            return
        }
        if event.type == .leftMouseDown, let contentView {
            let point = contentView.convert(event.locationInWindow, from: nil)
            onMouseDownInContent?(point)
        }
        if event.type == .scrollWheel, onScrollWheelInContent?(event) == true {
            return
        }
        super.sendEvent(event)
    }
}
