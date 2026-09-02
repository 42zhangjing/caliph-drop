import AppKit
import QuartzCore

final class DropStatusView: NSView {
    var onClick: (() -> Void)?
    var onDragEntered: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    private let hitSlop = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

    private var highlighted = false {
        didSet {
            guard highlighted != oldValue else { return }
            needsDisplay = true
            if highlighted {
                animateDropTargetPulse()
            } else {
                animateHighlightExit()
            }
        }
    }
    private var uploadActivity: UploadActivity = .idle
    private var successReset: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01 else { return nil }
        let expandedBounds = NSRect(
            x: bounds.minX - hitSlop.left,
            y: bounds.minY - hitSlop.bottom,
            width: bounds.width + hitSlop.left + hitSlop.right,
            height: bounds.height + hitSlop.top + hitSlop.bottom
        )
        return expandedBounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    func setExternalDragHighlighted(_ value: Bool) {
        highlighted = value
    }

    func setUploadActivity(_ activity: UploadActivity) {
        successReset?.cancel()
        let changed = activity != uploadActivity
        uploadActivity = activity
        updateAccessibilityLabel()
        needsDisplay = true

        if changed {
            animateStateTransition(for: activity)
        }

        guard activity == .success else { return }
        let reset = DispatchWorkItem { [weak self] in
            guard let self, self.uploadActivity == .success else { return }
            self.uploadActivity = .idle
            self.updateAccessibilityLabel()
            self.needsDisplay = true
            self.animateStateTransition(for: .idle)
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

    private func configureView() {
        wantsLayer = true
        layer?.masksToBounds = false
        registerForDraggedTypes([.fileURL])
        configureAccessibility()
    }

    private func animateStateTransition(for activity: UploadActivity) {
        guard let layer else { return }
        displayIfNeeded()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.38
        fade.toValue = 1.0

        let scale = CABasicAnimation(keyPath: "transform.scale")
        switch activity {
        case .success:
            scale.fromValue = 0.80
            scale.toValue = 1.0
        case .failed:
            scale.fromValue = 0.90
            scale.toValue = 1.0
        case .idle, .working:
            scale.fromValue = 0.92
            scale.toValue = 1.0
        }

        let group = CAAnimationGroup()
        group.animations = [fade, scale]
        group.duration = activity == .success ? 0.22 : 0.16
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "caliph.activity-transition")
    }

    private func animateDropTargetPulse() {
        guard let layer else { return }
        displayIfNeeded()

        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [1.0, 1.13, 1.04]
        pulse.keyTimes = [0.0, 0.55, 1.0]
        pulse.duration = 0.24
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.72, 1.0, 0.96]
        fade.keyTimes = pulse.keyTimes
        fade.duration = pulse.duration
        fade.timingFunction = pulse.timingFunction

        let group = CAAnimationGroup()
        group.animations = [pulse, fade]
        group.duration = pulse.duration
        layer.add(group, forKey: "caliph.drop-target-pulse")
    }

    private func animateHighlightExit() {
        guard let layer else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.04
        scale.toValue = 1.0
        scale.duration = 0.12
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(scale, forKey: "caliph.drop-target-exit")
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
