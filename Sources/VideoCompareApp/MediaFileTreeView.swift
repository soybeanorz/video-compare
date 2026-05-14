import AppKit

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

private final class MediaEntry {
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

private final class MediaIconItem: NSCollectionViewItem {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 104, height: 88))
        view.wantsLayer = true
        view.layer?.cornerRadius = 8

        let imageView = NSImageView(frame: NSRect(x: 32, y: 8, width: 40, height: 40))
        imageView.imageScaling = .scaleProportionallyDown
        let textField = NSTextField(labelWithString: "")
        textField.frame = NSRect(x: 6, y: 52, width: 92, height: 31)
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

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor
        }
    }
}

private final class MediaCollectionView: NSCollectionView {
    var onDoubleClickItem: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return }
        onDoubleClickItem?(indexPath.item)
    }
}

final class MediaDirectoryTreeView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let slot: VideoSlot
    var onFileOpened: ((VideoSlot, URL) -> Void)?

    private let toolbarView = NSView()
    private let upButton = NSButton()
    private let pathField = NSTextField(string: "")
    private let viewModeControl: NSSegmentedControl
    private let sortButton = NSButton()

    private let listScrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let iconScrollView = NSScrollView()
    private let collectionView = MediaCollectionView()

    private var rootURL: URL
    private var rootEntry: MediaEntry
    private var iconEntries: [MediaEntry] = []
    private var sortMode: MediaFileSortMode = .none
    private var showsIconView = false

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
        let toolbarHeight: CGFloat = 44
        toolbarView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: toolbarHeight)

        upButton.frame = NSRect(x: 10, y: 7, width: 30, height: 30)
        let controlW: CGFloat = 74
        let sortW: CGFloat = 34
        sortButton.frame = NSRect(x: bounds.width - 10 - sortW, y: 7, width: sortW, height: 30)
        viewModeControl.frame = NSRect(x: sortButton.frame.minX - controlW - 8, y: 7, width: controlW, height: 30)
        pathField.frame = NSRect(x: 48, y: 8, width: max(120, viewModeControl.frame.minX - 58), height: 28)

        let contentFrame = NSRect(x: 0, y: toolbarHeight, width: bounds.width, height: max(0, bounds.height - toolbarHeight))
        listScrollView.frame = contentFrame
        iconScrollView.frame = contentFrame

        let nameW = max(190, floor(contentFrame.width * 0.48))
        outlineView.tableColumn(withIdentifier: .nameColumn)?.width = nameW
        outlineView.tableColumn(withIdentifier: .dateColumn)?.width = 132
        outlineView.tableColumn(withIdentifier: .kindColumn)?.width = 92
        outlineView.tableColumn(withIdentifier: .sizeColumn)?.width = 78
    }

    func reload(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
        rootEntry = Self.directoryEntry(for: self.rootURL)
        pathField.stringValue = self.rootURL.path
        reloadBrowsers()
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
            imageView.image = NSWorkspace.shared.icon(forFile: entry.url.path)
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
        guard let entry = item as? MediaEntry, !entry.isDirectory else { return nil }
        return entry.url as NSURL
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        iconEntries.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("iconItem"), for: indexPath)
        guard let iconItem = item as? MediaIconItem, iconEntries.indices.contains(indexPath.item) else { return item }
        let entry = iconEntries[indexPath.item]
        iconItem.imageView?.image = NSWorkspace.shared.icon(forFile: entry.url.path)
        iconItem.textField?.stringValue = entry.name
        return iconItem
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard iconEntries.indices.contains(indexPath.item), !iconEntries[indexPath.item].isDirectory else { return nil }
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
        flow.itemSize = NSSize(width: 104, height: 88)
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
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: true)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)

        iconScrollView.documentView = collectionView
        iconScrollView.hasVerticalScroller = true
        iconScrollView.autohidesScrollers = true
        iconScrollView.borderType = .noBorder
        iconScrollView.isHidden = true
        addSubview(iconScrollView)
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
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            NSSound.beep()
            pathField.stringValue = rootURL.path
            return
        }
        reload(rootURL: url)
    }

    @objc private func goUp() {
        let parent = rootURL.deletingLastPathComponent()
        guard parent.path != rootURL.path else { return }
        reload(rootURL: parent)
    }

    @objc private func viewModeChanged() {
        showsIconView = viewModeControl.selectedSegment == 1
        listScrollView.isHidden = showsIconView
        iconScrollView.isHidden = !showsIconView
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
        reloadBrowsers()
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
        outlineView.reloadData()
        collectionView.reloadData()
        needsLayout = true
    }

    private func children(of entry: MediaEntry) -> [MediaEntry] {
        if let children = entry.children {
            return children
        }
        guard entry.isDirectory else {
            entry.children = []
            return []
        }
        let loaded = loadEntries(in: entry.url)
        entry.children = loaded
        return loaded
    }

    private func loadEntries(in url: URL) -> [MediaEntry] {
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
        return sort(entries: loaded)
    }

    private func sort(entries: [MediaEntry]) -> [MediaEntry] {
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

    private func compareName(_ lhs: MediaEntry, _ rhs: MediaEntry) -> ComparisonResult {
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

    let treeA: MediaDirectoryTreeView
    let treeB: MediaDirectoryTreeView

    init(defaultRoot: URL) {
        treeA = MediaDirectoryTreeView(slot: .a, rootURL: defaultRoot)
        treeB = MediaDirectoryTreeView(slot: .b, rootURL: defaultRoot)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(treeA)
        addSubview(treeB)
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
    }

    func reload(rootA: URL, rootB: URL) {
        treeA.reload(rootURL: rootA)
        treeB.reload(rootURL: rootB)
    }
}
