import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

private enum MediaFileSortMode: Int, CaseIterable {
    case none
    case name
    case kind
    case modifiedDate
    case size

    var title: String {
        switch self {
        case .none: "None"
        case .name: "Name"
        case .kind: "Kind"
        case .modifiedDate: "Date Modified"
        case .size: "Size"
        }
    }
}

private final class MediaEntry: @unchecked Sendable {
    let url: URL
    let isDirectory: Bool
    let modifiedDate: Date
    let fileSize: UInt64
    var children: [MediaEntry]?

    init(url: URL, isDirectory: Bool, modifiedDate: Date, fileSize: UInt64) {
        self.url = url
        self.isDirectory = isDirectory
        self.modifiedDate = modifiedDate
        self.fileSize = fileSize
    }

    var name: String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    var kind: String {
        if isDirectory { return "Folder" }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "File" : "\(ext) File"
    }
}

private final class MediaDirectoryLoader {
    private final class CompletionBox: @unchecked Sendable {
        let completion: (Int, URL, [MediaEntry]) -> Void

        init(_ completion: @escaping (Int, URL, [MediaEntry]) -> Void) {
            self.completion = completion
        }
    }

    private let queue = DispatchQueue(label: "VideoCompare.mediaDirectoryLoader", qos: .userInitiated)

    func load(url: URL, sortMode: MediaFileSortMode, requestID: Int, completion: @escaping (Int, URL, [MediaEntry]) -> Void) {
        let standardized = url.standardizedFileURL
        let completionBox = CompletionBox(completion)
        queue.async {
            let entries = MediaDirectoryTreeView.loadEntries(in: standardized, sortMode: sortMode)
            DispatchQueue.main.async {
                completionBox.completion(requestID, standardized, entries)
            }
        }
    }
}

private final class MediaThumbnailLoader: @unchecked Sendable {
    private final class CompletionBox: @unchecked Sendable {
        let completion: (Int, String, NSImage?) -> Void

        init(_ completion: @escaping (Int, String, NSImage?) -> Void) {
            self.completion = completion
        }
    }

    private final class ImageBox: @unchecked Sendable {
        let image: NSImage?

        init(_ image: NSImage?) {
            self.image = image
        }
    }

    private let queue = DispatchQueue(label: "VideoCompare.mediaThumbnailLoader", qos: .userInitiated)
    private let lock = NSLock()
    private var cache: [String: NSImage] = [:]
    private var latestByFile: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    func cachedImage(for entry: MediaEntry, thumbnailSize: CGFloat, scale: CGFloat) -> NSImage? {
        let key = cacheKey(for: entry, thumbnailSize: thumbnailSize, scale: scale)
        let fileKey = fileCacheKey(for: entry)
        lock.lock()
        defer { lock.unlock() }
        return cache[key] ?? latestByFile[fileKey]
    }

    func load(entry: MediaEntry, thumbnailSize: CGFloat, scale: CGFloat, requestID: Int, completion: @escaping (Int, String, NSImage?) -> Void) {
        guard canGenerateThumbnail(for: entry) else {
            completion(requestID, entry.url.path, nil)
            return
        }

        let key = cacheKey(for: entry, thumbnailSize: thumbnailSize, scale: scale)
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            completion(requestID, entry.url.path, cached)
            return
        }
        if inFlight.contains(key) {
            lock.unlock()
            return
        }
        inFlight.insert(key)
        lock.unlock()

        let url = entry.url
        let fileKey = fileCacheKey(for: entry)
        let pixelSize = max(48, Int((thumbnailSize * max(scale, 1)).rounded(.up)))
        let completionBox = CompletionBox(completion)
        queue.async { [weak self] in
            let image: NSImage?
            if MediaFileSupport.isImage(url) {
                image = Self.imageThumbnail(url: url, pixelSize: pixelSize)
            } else {
                image = Self.videoThumbnail(url: url, pixelSize: pixelSize)
            }
            self?.lock.lock()
            if let image {
                self?.cache[key] = image
                self?.latestByFile[fileKey] = image
            }
            self?.inFlight.remove(key)
            self?.lock.unlock()
            let imageBox = ImageBox(image)
            DispatchQueue.main.async {
                completionBox.completion(requestID, url.path, imageBox.image)
            }
        }
    }

    private func cacheKey(for entry: MediaEntry, thumbnailSize: CGFloat, scale: CGFloat) -> String {
        let pixelSize = Int((thumbnailSize * max(scale, 1)).rounded(.up))
        return "\(fileCacheKey(for: entry))|p=\(pixelSize)"
    }

    private func fileCacheKey(for entry: MediaEntry) -> String {
        let modified = Int(entry.modifiedDate.timeIntervalSinceReferenceDate)
        return "\(entry.url.path)|m=\(modified)|s=\(entry.fileSize)"
    }

    private func canGenerateThumbnail(for entry: MediaEntry) -> Bool {
        !entry.isDirectory && (MediaFileSupport.isImage(entry.url) || MediaFileSupport.videoExtensions.contains(entry.url.pathExtension.lowercased()))
    }

    private static func imageThumbnail(url: URL, pixelSize: Int) -> NSImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func videoThumbnail(url: URL, pixelSize: Int) -> NSImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixelSize, height: pixelSize)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let times = [
            CMTime(seconds: 0.5, preferredTimescale: 600),
            CMTime(seconds: 0, preferredTimescale: 600)
        ]
        for time in times {
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }
        return nil
    }
}

private final class MediaNameCellView: NSTableCellView {
    override func layout() {
        super.layout()
        imageView?.frame = NSRect(x: 3, y: 4, width: 18, height: 18)
        textField?.frame = NSRect(x: 29, y: 3, width: max(0, bounds.width - 33), height: 20)
    }
}

private final class MediaTextCellView: NSTableCellView {
    override func layout() {
        super.layout()
        textField?.frame = bounds.insetBy(dx: 6, dy: 3)
    }
}

private final class MediaOutlineView: NSOutlineView {
    var onContextMenu: ((NSPoint) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?(convert(event.locationInWindow, from: nil)) ?? super.menu(for: event)
    }
}

private final class MediaIconItemView: NSView {
    override var isFlipped: Bool { true }
}

private final class IconSizeCapsuleBackgroundView: NSView {
    var featherWidth: CGFloat = 5

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let outerRect = bounds.insetBy(dx: 1, dy: 1)
        let feather = min(featherWidth, min(outerRect.width, outerRect.height) / 2.05)
        guard outerRect.width > feather * 2, outerRect.height > feather * 2 else { return }

        let steps = 36
        for layer in 0..<steps {
            let progress = CGFloat(layer) / CGFloat(steps - 1)
            let inset = feather * progress
            let rect = outerRect.insetBy(dx: inset, dy: inset)
            let alpha = 0.03 + 0.12 * pow(progress, 1.45)
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: rect.height / 2,
                yRadius: rect.height / 2
            ).fill()
        }
    }
}

private final class MediaIconItem: NSCollectionViewItem {
    private static let horizontalPadding: CGFloat = 8
    private static let topPadding: CGFloat = 8
    private static let labelGap: CGFloat = 6
    static let labelHeight: CGFloat = 34

    private var iconSize: CGFloat = MediaFileTreesView.defaultIconSize

    override func loadView() {
        view = MediaIconItemView(frame: NSRect(x: 0, y: 0, width: 140, height: 160))
        view.wantsLayer = true
        view.layer?.cornerRadius = 8

        let imageView = NSImageView()
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        let textField = NSTextField(labelWithString: "")
        textField.alignment = .center
        textField.maximumNumberOfLines = 2
        textField.lineBreakMode = .byTruncatingMiddle
        textField.font = NSFont.systemFont(ofSize: 11)
        textField.textColor = .labelColor
        view.addSubview(imageView)
        view.addSubview(textField)
        self.imageView = imageView
        self.textField = textField
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let imageSide = min(iconSize, max(24, view.bounds.width - Self.horizontalPadding * 2))
        let imageX = floor((view.bounds.width - imageSide) / 2)
        imageView?.frame = NSRect(
            x: imageX,
            y: Self.topPadding,
            width: imageSide,
            height: imageSide
        )
        textField?.frame = NSRect(
            x: Self.horizontalPadding,
            y: Self.topPadding + imageSide + Self.labelGap,
            width: max(0, view.bounds.width - Self.horizontalPadding * 2),
            height: Self.labelHeight
        )
    }

    func configure(entry: MediaEntry, image: NSImage, iconSize: CGFloat) {
        self.iconSize = iconSize
        imageView?.image = image
        textField?.stringValue = entry.name
        view.needsLayout = true
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor
        }
    }
}

private final class MediaCollectionView: NSCollectionView {
    var onDoubleClickItem: ((Int) -> Void)?
    var onContextMenu: ((NSPoint) -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return }
        onDoubleClickItem?(indexPath.item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?(convert(event.locationInWindow, from: nil)) ?? super.menu(for: event)
    }
}

private final class MediaFileTreeResizeHandleView: NSView {
    var onDragStarted: ((NSEvent) -> Void)?

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        onDragStarted?(event)
    }
}

private final class PathTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              event.modifierFlags.intersection([.control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "a":
            return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case "c":
            return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case "v":
            return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case "x":
            return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

final class MediaDirectoryTreeView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate {
    static let collapsedHeight: CGFloat = 44
    static let expandedHeight: CGFloat = 220

    let slot: VideoSlot
    var onFileOpened: ((VideoSlot, URL) -> Void)?
    var onIconSizeChanged: ((CGFloat) -> Void)?
    var isExpanded = false {
        didSet {
            guard oldValue != isExpanded else { return }
            updateExpandedState()
            needsLayout = true
        }
    }

    private let toolbarView = NSView()
    private let upButton = NSButton()
    private let pathField = PathTextField(string: "")
    private let viewModeControl: NSSegmentedControl
    private let sortButton = NSButton()

    private let listScrollView = NSScrollView()
    private let outlineView = MediaOutlineView()
    private let iconScrollView = NSScrollView()
    private let collectionView = MediaCollectionView()
    private let iconSizeControlView = IconSizeCapsuleBackgroundView()
    private let iconSizeLabel = NSTextField(labelWithString: "图标大小")
    private let iconSizeSlider = NSSlider(
        value: Double(MediaFileTreesView.defaultIconSize),
        minValue: Double(MediaFileTreesView.minIconSize),
        maxValue: Double(MediaFileTreesView.maxIconSize),
        target: nil,
        action: nil
    )

    private var rootURL: URL
    private var rootEntry: MediaEntry
    private var displayURL: URL?
    private var iconEntries: [MediaEntry] = []
    private var sortMode: MediaFileSortMode = .none
    private var showsIconView = false
    private var isAnimatingToolbar = false
    private var suppressesBrowserContent = false
    private var lastColumnLayoutWidth: CGFloat = -1
    private var iconCache: [String: NSImage] = [:]
    private var iconSize: CGFloat = MediaFileTreesView.defaultIconSize
    private let directoryLoader = MediaDirectoryLoader()
    private let thumbnailLoader = MediaThumbnailLoader()
    private var directoryRequestID = 0
    private var pendingDirectoryLoads: [String: Int] = [:]
    private var thumbnailRequestID = 0

    private func rectDebug(_ rect: NSRect) -> String {
        "x=\(String(format: "%.1f", rect.origin.x)) y=\(String(format: "%.1f", rect.origin.y)) w=\(String(format: "%.1f", rect.width)) h=\(String(format: "%.1f", rect.height))"
    }

    init(slot: VideoSlot, rootURL: URL) {
        self.slot = slot
        self.rootURL = rootURL.standardizedFileURL
        self.rootEntry = MediaDirectoryTreeView.directoryEntry(for: self.rootURL)
        let images = [
            NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List") ?? NSImage(),
            NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Icon") ?? NSImage()
        ]
        self.viewModeControl = NSSegmentedControl(images: images, trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: .zero)
        setupViews()
        reload(rootURL: rootURL)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let toolbarHeight = Self.collapsedHeight
        toolbarView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: toolbarHeight)
        Diagnostics.log("fileTree.\(slot.rawValue).layout expanded=\(isExpanded) animatingToolbar=\(isAnimatingToolbar) bounds=(\(rectDebug(bounds))) pathBefore=(\(rectDebug(pathField.frame)))")

        if !isAnimatingToolbar {
            let frames = toolbarFrames(expanded: isExpanded)
            upButton.frame = frames.up
            sortButton.frame = frames.sort
            viewModeControl.frame = frames.viewMode
            pathField.frame = frames.path
            Diagnostics.log("fileTree.\(slot.rawValue).layout.applyToolbar path=(\(rectDebug(frames.path)))")
        }

        let contentFrame = NSRect(x: 0, y: toolbarHeight, width: bounds.width, height: isExpanded ? max(0, bounds.height - toolbarHeight) : 0)
        listScrollView.frame = contentFrame
        iconScrollView.frame = contentFrame
        layoutIconSizeControl(in: contentFrame)

        if abs(contentFrame.width - lastColumnLayoutWidth) > 0.5 {
            lastColumnLayoutWidth = contentFrame.width
            let nameW = max(190, floor(contentFrame.width * 0.48))
            outlineView.tableColumn(withIdentifier: .nameColumn)?.width = nameW
            outlineView.tableColumn(withIdentifier: .dateColumn)?.width = 132
            outlineView.tableColumn(withIdentifier: .kindColumn)?.width = 92
            outlineView.tableColumn(withIdentifier: .sizeColumn)?.width = 78
        }
    }

    func reload(rootURL: URL, displayURL: URL? = nil) {
        let newRootURL = rootURL.standardizedFileURL
        let newDisplayURL = displayURL?.standardizedFileURL
        if self.rootURL == newRootURL, self.displayURL == newDisplayURL, rootEntry.children != nil {
            refreshPathField()
            return
        }
        self.rootURL = newRootURL
        self.displayURL = newDisplayURL
        rootEntry = Self.directoryEntry(for: self.rootURL)
        pendingDirectoryLoads.removeAll()
        refreshPathField()
        reloadBrowsers()
    }

    func setBrowserContentSuppressed(_ suppressed: Bool) {
        guard suppressesBrowserContent != suppressed else { return }
        suppressesBrowserContent = suppressed
        updateExpandedState()
    }

    var isShowingIconView: Bool {
        showsIconView
    }

    func setIconSize(_ size: CGFloat) {
        let clamped = min(MediaFileTreesView.maxIconSize, max(MediaFileTreesView.minIconSize, size))
        iconSizeSlider.doubleValue = Double(clamped)
        guard abs(iconSize - clamped) > 0.5 else { return }
        iconSize = clamped
        updateIconLayout()
        collectionView.reloadData()
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard expanded != isExpanded else { return }
        layoutSubtreeIfNeeded()
        let startFrames = toolbarFrames(expanded: isExpanded)
        let targetFrames = toolbarFrames(expanded: expanded)
        let controls = [upButton, viewModeControl, sortButton]
        Diagnostics.log(
            "fileTree.\(slot.rawValue).toolbar.request from=\(isExpanded) to=\(expanded) animated=\(animated) pathStart=(\(rectDebug(startFrames.path))) pathTarget=(\(rectDebug(targetFrames.path))) currentPath=(\(rectDebug(pathField.frame)))"
        )

        guard animated else {
            isAnimatingToolbar = false
            isExpanded = expanded
            pathField.frame = targetFrames.path
            upButton.frame = targetFrames.up
            viewModeControl.frame = targetFrames.viewMode
            sortButton.frame = targetFrames.sort
            controls.forEach {
                $0.alphaValue = 1
                $0.isHidden = !expanded
            }
            return
        }

        isAnimatingToolbar = true
        pathField.frame = startFrames.path
        upButton.frame = startFrames.up
        viewModeControl.frame = startFrames.viewMode
        sortButton.frame = startFrames.sort

        if expanded {
            isExpanded = true
            controls.forEach {
                $0.isHidden = false
                $0.alphaValue = 0
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                Diagnostics.log("fileTree.\(self.slot.rawValue).toolbar.expand.path.start duration=\(context.duration)")
                pathField.animator().frame = targetFrames.path
                upButton.animator().frame = targetFrames.up
                viewModeControl.animator().frame = targetFrames.viewMode
                sortButton.animator().frame = targetFrames.sort
            } completionHandler: {
                Diagnostics.log("fileTree.\(self.slot.rawValue).toolbar.expand.path.complete actual=(\(self.rectDebug(self.pathField.frame)))")
                self.pathField.frame = targetFrames.path
                self.upButton.frame = targetFrames.up
                self.viewModeControl.frame = targetFrames.viewMode
                self.sortButton.frame = targetFrames.sort
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.08
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    Diagnostics.log("fileTree.\(self.slot.rawValue).toolbar.expand.controls.start duration=\(context.duration)")
                    controls.forEach { $0.animator().alphaValue = 1 }
                } completionHandler: {
                    Diagnostics.log("fileTree.\(self.slot.rawValue).toolbar.expand.controls.complete pathActual=(\(self.rectDebug(self.pathField.frame)))")
                    self.isAnimatingToolbar = false
                    controls.forEach {
                        $0.alphaValue = 1
                        $0.isHidden = false
                    }
                    self.needsLayout = true
                }
            }
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            Diagnostics.log("fileTree.\(self.slot.rawValue).toolbar.collapse.controls.start duration=\(context.duration)")
            controls.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: {
            Diagnostics.log("fileTree.\(self.slot.rawValue).toolbar.collapse.controls.complete pathBefore=(\(self.rectDebug(self.pathField.frame)))")
            self.isExpanded = false
            controls.forEach { $0.isHidden = true }
            self.pathField.frame = startFrames.path
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                Diagnostics.log("fileTree.\(self.slot.rawValue).toolbar.collapse.path.start duration=\(context.duration) from=(\(self.rectDebug(startFrames.path))) to=(\(self.rectDebug(targetFrames.path)))")
                self.pathField.animator().frame = targetFrames.path
            } completionHandler: {
                Diagnostics.log("fileTree.\(self.slot.rawValue).toolbar.collapse.path.complete actual=(\(self.rectDebug(self.pathField.frame)))")
                self.pathField.frame = targetFrames.path
                self.upButton.frame = targetFrames.up
                self.viewModeControl.frame = targetFrames.viewMode
                self.sortButton.frame = targetFrames.sort
                self.isAnimatingToolbar = false
                controls.forEach {
                    $0.alphaValue = 1
                    $0.isHidden = true
                }
                self.needsLayout = true
            }
        }
        logToolbarAnimationSamples(expanded: expanded)
    }

    private func logToolbarAnimationSamples(expanded: Bool) {
        for delay in [0.04, 0.12, 0.22, 0.32] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                Diagnostics.log(
                    "fileTree.\(self.slot.rawValue).toolbar.sample expanded=\(expanded) t=\(String(format: "%.2f", delay)) path=(\(self.rectDebug(self.pathField.frame))) upHidden=\(self.upButton.isHidden) viewHidden=\(self.viewModeControl.isHidden) sortHidden=\(self.sortButton.isHidden)"
                )
            }
        }
    }

    func endPathEditingIfNeeded() -> Bool {
        guard let window,
              let fieldEditor = window.firstResponder as? NSTextView,
              window.fieldEditor(false, for: pathField) === fieldEditor else {
            return false
        }
        window.makeFirstResponder(nil)
        refreshPathField()
        return true
    }

    var isPathEditing: Bool {
        guard let window,
              let fieldEditor = window.firstResponder as? NSTextView else {
            return false
        }
        return window.fieldEditor(false, for: pathField) === fieldEditor
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: (item as? MediaEntry) ?? rootEntry).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: (item as? MediaEntry) ?? rootEntry)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? MediaEntry)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let entry = item as? MediaEntry, let tableColumn else { return nil }
        if tableColumn.identifier == .nameColumn {
            let id = NSUserInterfaceItemIdentifier("nameCell")
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? MediaNameCellView ?? MediaNameCellView()
            cell.identifier = id
            let imageView = cell.imageView ?? NSImageView()
            imageView.image = icon(for: entry)
            imageView.imageScaling = .scaleProportionallyDown
            if imageView.superview == nil {
                cell.addSubview(imageView)
                cell.imageView = imageView
            }
            let textField = cell.textField ?? NSTextField(labelWithString: "")
            textField.font = NSFont.systemFont(ofSize: 13)
            textField.lineBreakMode = .byTruncatingMiddle
            textField.textColor = .labelColor
            textField.stringValue = entry.name
            if textField.superview == nil {
                cell.addSubview(textField)
                cell.textField = textField
            }
            return cell
        }

        let id = NSUserInterfaceItemIdentifier("textCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? MediaTextCellView ?? MediaTextCellView()
        cell.identifier = id
        let textField = cell.textField ?? NSTextField(labelWithString: "")
        textField.font = NSFont.systemFont(ofSize: 12)
        textField.textColor = .secondaryLabelColor
        textField.lineBreakMode = .byTruncatingTail
        if textField.superview == nil {
            cell.addSubview(textField)
            cell.textField = textField
        }
        switch tableColumn.identifier {
        case .dateColumn:
            textField.alignment = .left
            textField.stringValue = Self.dateFormatter.string(from: entry.modifiedDate)
        case .kindColumn:
            textField.alignment = .left
            textField.stringValue = entry.kind
        case .sizeColumn:
            textField.alignment = .right
            textField.stringValue = entry.isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: Int64(entry.fileSize), countStyle: .file)
        default:
            textField.stringValue = ""
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let entry = item as? MediaEntry else { return nil }
        return entry.url as NSURL
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        iconEntries.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("iconItem"), for: indexPath)
        guard let iconItem = item as? MediaIconItem, iconEntries.indices.contains(indexPath.item) else { return item }
        let entry = iconEntries[indexPath.item]
        let fallback = icon(for: entry)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if let thumbnail = thumbnailLoader.cachedImage(for: entry, thumbnailSize: iconSize, scale: scale) {
            iconItem.configure(entry: entry, image: thumbnail, iconSize: iconSize)
            requestThumbnail(for: entry, at: indexPath)
        } else {
            iconItem.configure(entry: entry, image: fallback, iconSize: iconSize)
            requestThumbnail(for: entry, at: indexPath)
        }
        return iconItem
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard iconEntries.indices.contains(indexPath.item) else { return nil }
        return iconEntries[indexPath.item].url as NSURL
    }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        toolbarView.wantsLayer = true
        toolbarView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        addSubview(toolbarView)

        configureToolbarButton(upButton, symbolName: "chevron.left")
        upButton.target = self
        upButton.action = #selector(goUp)
        toolbarView.addSubview(upButton)

        pathField.font = NSFont.systemFont(ofSize: 13)
        pathField.textColor = .labelColor
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.target = self
        pathField.action = #selector(pathEntered)
        pathField.bezelStyle = .roundedBezel
        pathField.focusRingType = .default
        toolbarView.addSubview(pathField)

        viewModeControl.selectedSegment = 0
        viewModeControl.segmentStyle = .texturedRounded
        viewModeControl.target = self
        viewModeControl.action = #selector(viewModeChanged)
        toolbarView.addSubview(viewModeControl)

        configureToolbarButton(sortButton, symbolName: "rectangle.grid.3x2")
        sortButton.target = self
        sortButton.action = #selector(showSortMenu)
        toolbarView.addSubview(sortButton)

        setupOutlineView()
        setupIconView()
        updateExpandedState()
    }

    private func setupOutlineView() {
        outlineView.headerView = NSTableHeaderView()
        outlineView.rowHeight = 26
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.backgroundColor = .textBackgroundColor
        outlineView.selectionHighlightStyle = .regular
        outlineView.allowsColumnReordering = false
        outlineView.allowsColumnResizing = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.doubleAction = #selector(openSelectedListItem)
        outlineView.target = self
        outlineView.onContextMenu = { [weak self] point in
            self?.contextMenuForList(at: point)
        }
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: true)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)

        addColumn(id: .nameColumn, title: "Name", width: 220)
        addColumn(id: .dateColumn, title: "Date Modified", width: 132)
        addColumn(id: .kindColumn, title: "Kind", width: 92)
        addColumn(id: .sizeColumn, title: "Size", width: 78)
        outlineView.outlineTableColumn = outlineView.tableColumn(withIdentifier: .nameColumn)

        listScrollView.documentView = outlineView
        listScrollView.hasVerticalScroller = true
        listScrollView.autohidesScrollers = true
        listScrollView.borderType = .noBorder
        addSubview(listScrollView)
    }

    private func setupIconView() {
        let flow = NSCollectionViewFlowLayout()
        flow.itemSize = iconItemSize(for: iconSize)
        flow.minimumInteritemSpacing = 10
        flow.minimumLineSpacing = 10
        flow.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collectionView.collectionViewLayout = flow
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.backgroundColors = [.textBackgroundColor]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.register(MediaIconItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("iconItem"))
        collectionView.onDoubleClickItem = { [weak self] index in
            self?.openIconEntry(at: index)
        }
        collectionView.onContextMenu = { [weak self] point in
            self?.contextMenuForIconView(at: point)
        }
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: true)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)

        iconScrollView.documentView = collectionView
        iconScrollView.hasVerticalScroller = true
        iconScrollView.autohidesScrollers = true
        iconScrollView.borderType = .noBorder
        iconScrollView.isHidden = true
        addSubview(iconScrollView)

        iconSizeControlView.isHidden = true

        iconSizeLabel.font = NSFont.systemFont(ofSize: 11)
        iconSizeLabel.textColor = .labelColor
        iconSizeLabel.alignment = .right
        iconSizeControlView.addSubview(iconSizeLabel)

        iconSizeSlider.target = self
        iconSizeSlider.action = #selector(iconSizeSliderChanged)
        iconSizeSlider.isContinuous = true
        iconSizeSlider.controlSize = .small
        iconSizeSlider.toolTip = "图标大小"
        iconSizeControlView.addSubview(iconSizeSlider)

        addSubview(iconSizeControlView, positioned: .above, relativeTo: iconScrollView)
    }

    private func addColumn(id: NSUserInterfaceItemIdentifier, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: id)
        column.title = title
        column.width = width
        column.minWidth = id == .nameColumn ? 140 : 60
        column.resizingMask = .userResizingMask
        outlineView.addTableColumn(column)
    }

    private func configureToolbarButton(_ button: NSButton, symbolName: String) {
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
    }

    @objc private func pathEntered() {
        let expanded = NSString(string: pathField.stringValue).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            NSSound.beep()
            refreshPathField()
            return
        }
        if isDirectory.boolValue {
            reload(rootURL: url)
            return
        }
        guard MediaFileSupport.isSupported(url) else {
            NSSound.beep()
            refreshPathField()
            return
        }
        onFileOpened?(slot, url)
        reload(rootURL: url.deletingLastPathComponent(), displayURL: url)
    }

    @objc private func goUp() {
        let parent = rootURL.deletingLastPathComponent()
        guard parent.path != rootURL.path else { return }
        reload(rootURL: parent)
    }

    @objc private func viewModeChanged() {
        showsIconView = viewModeControl.selectedSegment == 1
        updateExpandedState()
    }

    @objc private func iconSizeSliderChanged() {
        let size = CGFloat(iconSizeSlider.doubleValue)
        setIconSize(size)
        onIconSizeChanged?(size)
    }

    @objc private func showSortMenu() {
        let menu = NSMenu()
        for mode in MediaFileSortMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(sortMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = sortMode == mode ? .on : .off
            menu.addItem(item)
            if mode == .none {
                menu.addItem(.separator())
            }
        }
        menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSPoint(x: 0, y: sortButton.bounds.maxY + 4), in: sortButton)
    }

    @objc private func sortMenuItemSelected(_ sender: NSMenuItem) {
        let raw = sender.representedObject as? Int ?? MediaFileSortMode.none.rawValue
        sortMode = MediaFileSortMode(rawValue: raw) ?? .none
        rootEntry.children = nil
        pendingDirectoryLoads.removeAll()
        reloadBrowsers()
    }

    private func contextMenuForList(at point: NSPoint) -> NSMenu? {
        let row = outlineView.row(at: point)
        let entry = row >= 0 ? outlineView.item(atRow: row) as? MediaEntry : nil
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return contextMenu(for: entry)
    }

    private func contextMenuForIconView(at point: NSPoint) -> NSMenu? {
        let indexPath = collectionView.indexPathForItem(at: point)
        let entry = indexPath.flatMap { iconEntries.indices.contains($0.item) ? iconEntries[$0.item] : nil }
        if let indexPath {
            collectionView.selectionIndexPaths = [indexPath]
        }
        return contextMenu(for: entry)
    }

    private func contextMenu(for entry: MediaEntry?) -> NSMenu {
        let menu = NSMenu()
        if let entry {
            menu.addItem(menuItem(title: "打开", action: #selector(contextOpen(_:)), representedObject: entry))
            menu.addItem(menuItem(title: "在 Finder 中显示", action: #selector(contextRevealInFinder(_:)), representedObject: entry))
            menu.addItem(.separator())
            menu.addItem(menuItem(title: "重命名...", action: #selector(contextRename(_:)), representedObject: entry))
            menu.addItem(menuItem(title: "移到废纸篓", action: #selector(contextTrash(_:)), representedObject: entry))
        } else {
            menu.addItem(menuItem(title: "新建文件夹...", action: #selector(contextNewFolder(_:)), representedObject: rootEntry))
            menu.addItem(menuItem(title: "在 Finder 中显示", action: #selector(contextRevealInFinder(_:)), representedObject: rootEntry))
        }
        return menu
    }

    private func menuItem(title: String, action: Selector, representedObject: MediaEntry) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        return item
    }

    @objc private func contextOpen(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? MediaEntry else { return }
        open(entry: entry)
    }

    @objc private func contextRevealInFinder(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? MediaEntry else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    @objc private func contextNewFolder(_ sender: NSMenuItem) {
        let parent = existingDirectory(for: rootURL) ?? FileManager.default.homeDirectoryForCurrentUser
        guard let name = promptForFileName(title: "新建文件夹", message: "输入新文件夹名称：", defaultValue: "未命名文件夹") else {
            return
        }
        do {
            try FileManager.default.createDirectory(at: parent.appendingPathComponent(name), withIntermediateDirectories: false)
            refreshAfterFileOperation(preferredRoot: parent)
        } catch {
            showFileOperationError(title: "无法新建文件夹", error: error)
        }
    }

    @objc private func contextRename(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? MediaEntry,
              let name = promptForFileName(title: "重命名", message: "输入新名称：", defaultValue: entry.name) else {
            return
        }
        let destination = entry.url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: entry.url, to: destination)
            refreshAfterFileOperation(preferredRoot: rootURL)
        } catch {
            showFileOperationError(title: "无法重命名", error: error)
        }
    }

    @objc private func contextTrash(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? MediaEntry else { return }
        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: &resultingURL)
            refreshAfterFileOperation(preferredRoot: rootURL)
        } catch {
            showFileOperationError(title: "无法移到废纸篓", error: error)
        }
    }

    @objc private func openSelectedListItem() {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0, let entry = outlineView.item(atRow: row) as? MediaEntry else { return }
        open(entry: entry)
    }

    private func openIconEntry(at index: Int) {
        guard iconEntries.indices.contains(index) else { return }
        open(entry: iconEntries[index])
    }

    private func open(entry: MediaEntry) {
        if entry.isDirectory {
            reload(rootURL: entry.url)
        } else {
            onFileOpened?(slot, entry.url)
        }
    }

    private func reloadBrowsers() {
        iconEntries = children(of: rootEntry)
        thumbnailRequestID += 1
        outlineView.reloadData()
        collectionView.reloadData()
        updateExpandedState()
        needsLayout = true
    }

    private func refreshAfterFileOperation(preferredRoot: URL) {
        let nextRoot = existingDirectory(for: preferredRoot) ?? existingDirectory(for: preferredRoot.deletingLastPathComponent()) ?? FileManager.default.homeDirectoryForCurrentUser
        rootEntry = Self.directoryEntry(for: nextRoot)
        rootURL = nextRoot
        displayURL = nil
        pendingDirectoryLoads.removeAll()
        refreshPathField()
        reloadBrowsers()
    }

    private func existingDirectory(for url: URL) -> URL? {
        var current = url.standardizedFileURL
        while current.path != "/" {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return current
            }
            current.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: "/")
    }

    private func promptForFileName(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = defaultValue
        input.lineBreakMode = .byTruncatingMiddle
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "." && trimmed != ".." else {
            NSSound.beep()
            return nil
        }
        return trimmed
    }

    private func showFileOperationError(title: String, error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.runModal()
    }

    private func updateExpandedState() {
        upButton.isHidden = !isExpanded
        viewModeControl.isHidden = !isExpanded
        sortButton.isHidden = !isExpanded
        let showsBrowser = isExpanded && !suppressesBrowserContent
        listScrollView.isHidden = !showsBrowser || showsIconView
        iconScrollView.isHidden = !showsBrowser || !showsIconView
        iconSizeControlView.isHidden = iconScrollView.isHidden
    }

    private func layoutIconSizeControl(in contentFrame: NSRect) {
        let feather: CGFloat = 5
        let contentWidth = min(150, max(136, contentFrame.width - 24))
        let contentHeight: CGFloat = 20
        let controlWidth = contentWidth + feather * 2
        let controlHeight = contentHeight + feather * 2
        iconSizeControlView.frame = NSRect(
            x: max(contentFrame.minX + 12, contentFrame.maxX - controlWidth - 12),
            y: max(contentFrame.minY + 8, contentFrame.maxY - controlHeight - 10),
            width: controlWidth,
            height: controlHeight
        )
        iconSizeControlView.featherWidth = feather
        iconSizeControlView.needsDisplay = true

        let labelWidth: CGFloat = 50
        let contentRect = NSRect(x: feather, y: feather, width: contentWidth, height: contentHeight)
        let labelHeight: CGFloat = 18
        let sliderHeight: CGFloat = 22
        iconSizeLabel.frame = NSRect(
            x: contentRect.minX + 2,
            y: contentRect.midY - labelHeight / 2 - 2,
            width: labelWidth,
            height: labelHeight
        )
        iconSizeSlider.frame = NSRect(
            x: contentRect.minX + labelWidth + 8,
            y: contentRect.midY - sliderHeight / 2,
            width: max(58, contentWidth - labelWidth - 10),
            height: sliderHeight
        )
    }

    private func updateIconLayout() {
        thumbnailRequestID += 1
        if let flow = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
            flow.itemSize = iconItemSize(for: iconSize)
            flow.invalidateLayout()
        }
        collectionView.collectionViewLayout?.invalidateLayout()
        collectionView.needsLayout = true
        iconScrollView.needsLayout = true
    }

    private func iconItemSize(for iconSize: CGFloat) -> NSSize {
        let width = max(96, iconSize + 28)
        let height = MediaIconItem.labelHeight + iconSize + 22
        return NSSize(width: width, height: height)
    }

    private func requestThumbnail(for entry: MediaEntry, at indexPath: IndexPath) {
        guard !entry.isDirectory,
              (MediaFileSupport.isImage(entry.url) || MediaFileSupport.videoExtensions.contains(entry.url.pathExtension.lowercased())) else {
            return
        }
        let requestID = thumbnailRequestID
        let targetPath = entry.url.path
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        thumbnailLoader.load(entry: entry, thumbnailSize: iconSize, scale: scale, requestID: requestID) { [weak self] completedID, path, image in
            guard let self,
                  completedID == self.thumbnailRequestID,
                  path == targetPath,
                  let image,
                  self.iconEntries.indices.contains(indexPath.item),
                  self.iconEntries[indexPath.item].url.path == path,
                  let item = self.collectionView.item(at: indexPath) as? MediaIconItem else {
                return
            }
            item.configure(entry: self.iconEntries[indexPath.item], image: image, iconSize: self.iconSize)
        }
    }

    private func refreshPathField() {
        pathField.stringValue = (displayURL ?? rootURL).path
    }

    private func toolbarFrames(expanded: Bool) -> (up: NSRect, path: NSRect, viewMode: NSRect, sort: NSRect) {
        let controlW: CGFloat = 74
        let sortW: CGFloat = 34
        let sort = NSRect(x: bounds.width - 10 - sortW, y: 7, width: sortW, height: 30)
        let viewMode = NSRect(x: sort.minX - controlW - 8, y: 7, width: controlW, height: 30)
        let up = NSRect(x: 10, y: 7, width: 30, height: 30)
        let path: NSRect
        if expanded {
            path = NSRect(x: 48, y: 8, width: max(120, viewMode.minX - 58), height: 28)
        } else {
            path = NSRect(x: 12, y: 8, width: max(120, bounds.width - 24), height: 28)
        }
        return (up, path, viewMode, sort)
    }

    private func children(of entry: MediaEntry) -> [MediaEntry] {
        if let children = entry.children {
            return children
        }
        guard entry.isDirectory else {
            entry.children = []
            return []
        }
        requestChildren(for: entry)
        return []
    }

    private func requestChildren(for entry: MediaEntry) {
        let key = entry.url.standardizedFileURL.path
        guard pendingDirectoryLoads[key] == nil else { return }
        directoryRequestID += 1
        let requestID = directoryRequestID
        pendingDirectoryLoads[key] = requestID
        directoryLoader.load(url: entry.url, sortMode: sortMode, requestID: requestID) { [weak self] completedID, url, entries in
            guard let self else { return }
            let key = url.standardizedFileURL.path
            guard self.pendingDirectoryLoads[key] == completedID else { return }
            self.pendingDirectoryLoads.removeValue(forKey: key)
            guard let target = self.entry(matching: url, in: self.rootEntry), target.children == nil else { return }
            target.children = entries
            if target === self.rootEntry {
                self.iconEntries = entries
                self.outlineView.reloadData()
                self.collectionView.reloadData()
            } else {
                self.outlineView.reloadItem(target, reloadChildren: true)
            }
            self.updateExpandedState()
            self.needsLayout = true
        }
    }

    private func entry(matching url: URL, in entry: MediaEntry) -> MediaEntry? {
        let standardized = url.standardizedFileURL
        if entry.url.standardizedFileURL == standardized {
            return entry
        }
        guard let children = entry.children else { return nil }
        for child in children {
            if let match = self.entry(matching: standardized, in: child) {
                return match
            }
        }
        return nil
    }

    private func icon(for entry: MediaEntry) -> NSImage {
        let fileExtension = entry.url.pathExtension.lowercased()
        let key = entry.isDirectory ? "folder" : (fileExtension.isEmpty ? "file" : "ext:\(fileExtension)")
        if let cached = iconCache[key] {
            return cached
        }
        let image: NSImage
        if entry.isDirectory {
            image = NSWorkspace.shared.icon(for: .folder)
        } else {
            image = NSWorkspace.shared.icon(for: UTType(filenameExtension: fileExtension) ?? .data)
        }
        iconCache[key] = image
        return image
    }

    nonisolated fileprivate static func loadEntries(in url: URL, sortMode: MediaFileSortMode) -> [MediaEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []

        let loaded = urls.compactMap { url -> MediaEntry? in
            let values = try? url.resourceValues(forKeys: keys)
            let isDirectory = values?.isDirectory == true
            let isRegular = values?.isRegularFile == true
            guard isDirectory || (isRegular && MediaFileSupport.isSupported(url)) else { return nil }
            return MediaEntry(
                url: url.standardizedFileURL,
                isDirectory: isDirectory,
                modifiedDate: values?.contentModificationDate ?? .distantPast,
                fileSize: UInt64(values?.fileSize ?? 0)
            )
        }
        return sort(entries: loaded, sortMode: sortMode)
    }

    nonisolated private static func sort(entries: [MediaEntry], sortMode: MediaFileSortMode) -> [MediaEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            switch sortMode {
            case .none, .name:
                return compareName(lhs, rhs) == .orderedAscending
            case .kind:
                if lhs.kind != rhs.kind { return lhs.kind.localizedStandardCompare(rhs.kind) == .orderedAscending }
                return compareName(lhs, rhs) == .orderedAscending
            case .modifiedDate:
                if lhs.modifiedDate != rhs.modifiedDate { return lhs.modifiedDate > rhs.modifiedDate }
                return compareName(lhs, rhs) == .orderedAscending
            case .size:
                if lhs.fileSize != rhs.fileSize { return lhs.fileSize > rhs.fileSize }
                return compareName(lhs, rhs) == .orderedAscending
            }
        }
    }

    nonisolated private static func compareName(_ lhs: MediaEntry, _ rhs: MediaEntry) -> ComparisonResult {
        lhs.name.localizedStandardCompare(rhs.name)
    }

    private static func directoryEntry(for url: URL) -> MediaEntry {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return MediaEntry(
            url: url.standardizedFileURL,
            isDirectory: true,
            modifiedDate: values?.contentModificationDate ?? .distantPast,
            fileSize: 0
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private extension NSUserInterfaceItemIdentifier {
    static let nameColumn = NSUserInterfaceItemIdentifier("name")
    static let dateColumn = NSUserInterfaceItemIdentifier("date")
    static let kindColumn = NSUserInterfaceItemIdentifier("kind")
    static let sizeColumn = NSUserInterfaceItemIdentifier("size")
}

final class MediaFileTreesView: NSView {
    static let panelGap: CGFloat = 10
    static let collapsedHeight = MediaDirectoryTreeView.collapsedHeight
    static let expandedHeight = MediaDirectoryTreeView.expandedHeight
    static let minIconSize: CGFloat = 72
    static let maxIconSize: CGFloat = 180
    static let defaultIconSize: CGFloat = 112
    private static let iconSizeDefaultsKey = "mediaFileTree.iconSize.v1"
    private static let expandedHeightDefaultsKey = "mediaFileTree.expandedHeight.v1"
    private static let resizeHandleHeight: CGFloat = 8

    let treeA: MediaDirectoryTreeView
    let treeB: MediaDirectoryTreeView
    var onHeightChanged: ((CGFloat) -> Void)?
    private(set) var isExpanded = false
    private var iconSize = MediaFileTreesView.loadIconSize()
    private let resizeHandleView = MediaFileTreeResizeHandleView()
    private var expandedHeightRange: ClosedRange<CGFloat> = collapsedHeight...expandedHeight
    private var userExpandedHeight = MediaFileTreesView.loadExpandedHeight()

    var currentExpandedHeight: CGFloat {
        userExpandedHeight
    }

    init(defaultRoot: URL) {
        treeA = MediaDirectoryTreeView(slot: .a, rootURL: defaultRoot)
        treeB = MediaDirectoryTreeView(slot: .b, rootURL: defaultRoot)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        treeA.setIconSize(iconSize)
        treeB.setIconSize(iconSize)
        treeA.onIconSizeChanged = { [weak self] size in self?.setSharedIconSize(size) }
        treeB.onIconSizeChanged = { [weak self] size in self?.setSharedIconSize(size) }
        addSubview(treeA)
        addSubview(treeB)
        resizeHandleView.onDragStarted = { [weak self] event in
            self?.trackHeightResize(from: event)
        }
        addSubview(resizeHandleView, positioned: .above, relativeTo: nil)
        updateResizeHandleVisibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let gap = Self.panelGap
        let leftWidth = floor((bounds.width - gap) / 2)
        treeA.frame = NSRect(x: 0, y: 0, width: leftWidth, height: bounds.height)
        treeB.frame = NSRect(x: leftWidth + gap, y: 0, width: max(0, bounds.width - leftWidth - gap), height: bounds.height)
        resizeHandleView.frame = NSRect(
            x: 0,
            y: max(0, bounds.height - Self.resizeHandleHeight),
            width: bounds.width,
            height: Self.resizeHandleHeight
        )
    }

    func setExpandedHeightRange(_ range: ClosedRange<CGFloat>) {
        let lower = max(Self.collapsedHeight, range.lowerBound)
        let upper = max(lower, range.upperBound)
        expandedHeightRange = lower...upper
        let clamped = min(upper, max(lower, userExpandedHeight))
        guard abs(clamped - userExpandedHeight) > 0.5 else { return }
        userExpandedHeight = clamped
        UserDefaults.standard.set(Double(userExpandedHeight), forKey: Self.expandedHeightDefaultsKey)
    }

    func reload(rootA: URL, rootB: URL) {
        reload(rootA: rootA, displayA: nil, rootB: rootB, displayB: nil)
    }

    func reload(rootA: URL, displayA: URL?, rootB: URL, displayB: URL?) {
        treeA.reload(rootURL: rootA, displayURL: displayA)
        treeB.reload(rootURL: rootB, displayURL: displayB)
    }

    func setExpanded(_ expanded: Bool, animated: Bool = false) {
        isExpanded = expanded
        treeA.setExpanded(expanded, animated: animated)
        treeB.setExpanded(expanded, animated: animated)
        updateResizeHandleVisibility()
        needsLayout = true
    }

    func setBrowserContentSuppressed(_ suppressed: Bool) {
        treeA.setBrowserContentSuppressed(suppressed)
        treeB.setBrowserContentSuppressed(suppressed)
    }

    func endPathEditingIfNeeded() -> Bool {
        treeA.endPathEditingIfNeeded() || treeB.endPathEditingIfNeeded()
    }

    var isPathEditing: Bool {
        treeA.isPathEditing || treeB.isPathEditing
    }

    private func setSharedIconSize(_ size: CGFloat) {
        iconSize = min(Self.maxIconSize, max(Self.minIconSize, size))
        UserDefaults.standard.set(Double(iconSize), forKey: Self.iconSizeDefaultsKey)
        treeA.setIconSize(iconSize)
        treeB.setIconSize(iconSize)
    }

    private func updateResizeHandleVisibility() {
        resizeHandleView.isHidden = !isExpanded
    }

    private func trackHeightResize(from event: NSEvent) {
        guard isExpanded, let window else { return }
        let startY = event.locationInWindow.y
        let startHeight = userExpandedHeight
        while true {
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            if next.type == .leftMouseUp { break }
            let proposed = startHeight + (startY - next.locationInWindow.y)
            let clamped = min(expandedHeightRange.upperBound, max(expandedHeightRange.lowerBound, proposed))
            guard abs(clamped - userExpandedHeight) > 0.5 else { continue }
            userExpandedHeight = clamped
            UserDefaults.standard.set(Double(userExpandedHeight), forKey: Self.expandedHeightDefaultsKey)
            onHeightChanged?(userExpandedHeight)
        }
    }

    private static func loadIconSize() -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: iconSizeDefaultsKey)
        guard stored > 0 else { return defaultIconSize }
        return min(maxIconSize, max(minIconSize, CGFloat(stored)))
    }

    private static func loadExpandedHeight() -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: expandedHeightDefaultsKey)
        guard stored > 0 else { return expandedHeight }
        return min(520, max(collapsedHeight, CGFloat(stored)))
    }
}
