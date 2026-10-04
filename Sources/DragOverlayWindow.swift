import AppKit

@MainActor
final class DragOverlayWindow: NSPanel {
    let dropView: DragOverlayView

    init() {
        dropView = DragOverlayView(frame: .zero)
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = dropView
        orderOut(nil)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(frame: NSRect) {
        guard !frame.isEmpty, !frame.isNull else { return }
        if self.frame != frame {
            setFrame(frame, display: false)
        }
        if !isVisible {
            orderFrontRegardless()
        }
    }

    func hide() {
        if isVisible {
            orderOut(nil)
        }
        dropView.resetHighlight()
    }
}

@MainActor
final class DragOverlayView: NSView {
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    private var highlighted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        registerForDraggedTypes([.fileURL])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !imageURLs(from: sender.draggingPasteboard).isEmpty else { return [] }
        highlighted = true
        needsDisplay = true
        onDragEntered?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        resetHighlight()
        onDragExited?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !imageURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = imageURLs(from: sender.draggingPasteboard)
        resetHighlight()
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        resetHighlight()
    }

    func resetHighlight() {
        guard highlighted else { return }
        highlighted = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !bounds.isEmpty else { return }

        let rect = bounds.insetBy(dx: 6, dy: 6)
        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        NSColor.windowBackgroundColor.withAlphaComponent(highlighted ? 0.96 : 0.88).setFill()
        path.fill()
        NSColor.systemBlue.withAlphaComponent(highlighted ? 0.95 : 0.7).setStroke()
        path.lineWidth = highlighted ? 2 : 1
        if !highlighted { path.setLineDash([5, 4], count: 2, phase: 0) }
        path.stroke()

        let symbolName = highlighted ? "arrow.down.circle.fill" : "arrow.down.circle"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let symbolSize = min(24, max(18, rect.height - 28))
            let symbolRect = NSRect(x: rect.minX + 14, y: rect.midY - symbolSize / 2,
                                    width: symbolSize, height: symbolSize)
            image.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)
        }

        let title = highlighted ? "松开上传图片" : "拖到这里上传"
        let subtitle = "Caliph Drop"
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let textX = rect.minX + 48
        let titleSize = title.size(withAttributes: titleAttributes)
        title.draw(at: NSPoint(x: textX, y: rect.midY - 2), withAttributes: titleAttributes)
        subtitle.draw(at: NSPoint(x: textX, y: rect.midY - titleSize.height - 1), withAttributes: subtitleAttributes)
    }

    private func imageURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return SupportedImage.filter(objects)
    }
}
