import AppKit

final class DropStatusView: NSView {
    var onClick: (() -> Void)?
    var onDragEntered: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    private var highlighted = false {
        didSet { needsDisplay = true }
    }
    private var uploadActivity: UploadActivity = .idle
    private var successReset: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
        configureAccessibility()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    func setUploadActivity(_ activity: UploadActivity) {
        successReset?.cancel()
        uploadActivity = activity
        updateAccessibilityLabel()
        needsDisplay = true

        guard activity == .success else { return }
        let reset = DispatchWorkItem { [weak self] in
            guard let self, self.uploadActivity == .success else { return }
            self.uploadActivity = .idle
            self.updateAccessibilityLabel()
            self.needsDisplay = true
        }
        successReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: reset)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !imageURLs(from: sender.draggingPasteboard).isEmpty else { return [] }
        highlighted = true
        onDragEntered?()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !imageURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = imageURLs(from: sender.draggingPasteboard)
        highlighted = false
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if highlighted {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).setFill()
            let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
            bg.fill()
        }

        let symbol: String
        let color: NSColor
        if highlighted {
            symbol = "arrow.down.circle.fill"
            color = .controlAccentColor
        } else {
            switch uploadActivity {
            case .idle:
                symbol = "arrow.up.circle"
                color = .labelColor
            case .working:
                symbol = "arrow.up.circle.fill"
                color = .controlAccentColor
            case .success:
                symbol = "checkmark.circle.fill"
                color = .systemGreen
            case .failed:
                symbol = "exclamationmark.triangle.fill"
                color = .systemRed
            }
        }

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Caliph Drop")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        let size = image?.size ?? NSSize(width: 16, height: 16)
        let rect = NSRect(x: (bounds.width - size.width) / 2,
                          y: (bounds.height - size.height) / 2,
                          width: size.width,
                          height: size.height)
        image?.draw(in: rect)
    }

    private func imageURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return SupportedImage.filter(objects)
    }

    private func configureAccessibility() {
        toolTip = "Caliph Drop：拖入图片或点击打开"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibilityLabel()
    }

    private func updateAccessibilityLabel() {
        let label: String
        switch uploadActivity {
        case .idle: label = "Caliph Drop，拖入图片或点击打开"
        case .working: label = "Caliph Drop，正在上传"
        case .success: label = "Caliph Drop，上传成功"
        case .failed: label = "Caliph Drop，上传失败"
        }
        setAccessibilityLabel(label)
    }
}
