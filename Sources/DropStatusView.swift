import AppKit

final class DropStatusView: NSView {
    var onClick: (() -> Void)?
    var onDragEntered: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    private var highlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
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

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let image = NSImage(systemSymbolName: highlighted ? "arrow.down.circle.fill" : "arrow.up.circle", accessibilityDescription: "Caliph Drop")?
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
        let allowed = Set(["jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff"])
        return objects.filter { allowed.contains($0.pathExtension.lowercased()) }
    }
}
