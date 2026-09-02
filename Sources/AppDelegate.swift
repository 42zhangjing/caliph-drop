import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let state = AppState()
    private lazy var dragOverlay = DragOverlayWindow()
    private weak var dropStatusView: DropStatusView?

    private var itemsObservation: AnyCancellable?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var dragLocalEventMonitor: Any?
    private var dragGlobalEventMonitor: Any?
    private var popoverCloseWorkItem: DispatchWorkItem?
    private var isClosingPopover = false

    private static let popoverOpenDuration: TimeInterval = 0.11
    private static let popoverCloseDuration: TimeInterval = 0.08

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.loadSettings()
        setupPopover()
        setupStatusItem()
        installDragOverlayMonitors()
    }

    private func setupPopover() {
        popover.behavior = .transient
        // NSPopover's stock animation feels intentionally soft/slow. We disable it and
        // run a much shorter fade + micro-scale transition ourselves.
        popover.animates = false
        popover.contentSize = NSSize(width: 390, height: 560)
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverRootView(state: state))
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 36)
        guard let button = statusItem.button else { return }
        button.image = nil
        button.title = ""

        let dropView = DropStatusView(frame: button.bounds)
        dropStatusView = dropView
        dropView.autoresizingMask = [.width, .height]
        dropView.onClick = { [weak self] in
            self?.togglePopover()
        }
        dropView.onDragEntered = { [weak self] in
            self?.showPopover(activateApp: false)
        }
        dropView.onDrop = { [weak self] urls in
            guard let self else { return }
            self.showPopover(activateApp: false)
            self.state.enqueue(urls: urls)
        }
        button.addSubview(dropView)

        configureDragOverlay(for: dropView)

        itemsObservation = state.$items
            .map(Self.activity(for:))
            .removeDuplicates()
            .sink { [weak dropView] activity in
                dropView?.setUploadActivity(activity)
            }
    }

    private func configureDragOverlay(for dropView: DropStatusView) {
        dragOverlay.dropView.onDragEntered = { [weak self, weak dropView] in
            dropView?.setExternalDragHighlighted(true)
            self?.showPopover(activateApp: false)
        }
        dragOverlay.dropView.onDragExited = { [weak dropView] in
            dropView?.setExternalDragHighlighted(false)
        }
        dragOverlay.dropView.onDrop = { [weak self, weak dropView] urls in
            guard let self else { return }
            dropView?.setExternalDragHighlighted(false)
            self.dragOverlay.hide()
            self.showPopover(activateApp: false)
            self.state.enqueue(urls: urls)
        }
    }

    private func showPopover(activateApp: Bool) {
        guard let view = statusItem.button else { return }

        popoverCloseWorkItem?.cancel()
        popoverCloseWorkItem = nil
        isClosingPopover = false

        if !popover.isShown {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            installEventMonitors()
            animatePopoverOpen()
        } else {
            restorePopoverVisualState()
        }

        if activateApp {
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            closePopoverFast()
        } else {
            showPopover(activateApp: true)
        }
    }

    private func animatePopoverOpen() {
        guard let window = popover.contentViewController?.view.window else { return }
        let contentView = popover.contentViewController?.view

        window.alphaValue = 0.0
        prepareContentLayer(contentView, scale: 0.985)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            restorePopoverVisualState()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.popoverOpenDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            window.animator().alphaValue = 1.0
        }

        animateContentScale(contentView, from: 0.985, to: 1.0, duration: Self.popoverOpenDuration)
    }

    private func closePopoverFast() {
        guard popover.isShown else { return }
        guard !isClosingPopover else { return }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finishPopoverClose()
            return
        }

        isClosingPopover = true
        popoverCloseWorkItem?.cancel()

        if let window = popover.contentViewController?.view.window {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.popoverCloseDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                context.allowsImplicitAnimation = true
                window.animator().alphaValue = 0.0
            }
        }

        animateContentScale(
            popover.contentViewController?.view,
            from: 1.0,
            to: 0.992,
            duration: Self.popoverCloseDuration
        )

        let close = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.finishPopoverClose()
            }
        }
        popoverCloseWorkItem = close
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.popoverCloseDuration, execute: close)
    }

    private func finishPopoverClose() {
        popoverCloseWorkItem?.cancel()
        popoverCloseWorkItem = nil
        isClosingPopover = false
        restorePopoverVisualState()
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func prepareContentLayer(_ view: NSView?, scale: CGFloat) {
        guard let view else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.opacity = 1.0
        layer.transform = CATransform3DMakeScale(scale, scale, 1.0)
    }

    private func animateContentScale(_ view: NSView?, from: CGFloat, to: CGFloat, duration: TimeInterval) {
        guard let view else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }

        layer.transform = CATransform3DMakeScale(to, to, 1.0)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = from
        scale.toValue = to
        scale.duration = duration
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(scale, forKey: "caliph.popover-scale")
    }

    private func restorePopoverVisualState() {
        if let window = popover.contentViewController?.view.window {
            window.alphaValue = 1.0
        }
        if let layer = popover.contentViewController?.view.layer {
            layer.removeAnimation(forKey: "caliph.popover-scale")
            layer.opacity = 1.0
            layer.transform = CATransform3DIdentity
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popoverCloseWorkItem?.cancel()
        popoverCloseWorkItem = nil
        isClosingPopover = false
        restorePopoverVisualState()
        state.discardUnsavedSettings()
        removeEventMonitors()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        state.refreshLaunchAtLoginStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        popoverCloseWorkItem?.cancel()
        removeEventMonitors()
        removeDragOverlayMonitors()
        dragOverlay.hide()
    }

    private func installEventMonitors() {
        guard localEventMonitor == nil, globalEventMonitor == nil else { return }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.closePopoverFast()
                return nil
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                let point = NSEvent.mouseLocation
                if !self.containsInPopover(point) && !self.containsInStatusItem(point) {
                    self.closePopoverFast()
                }
            }
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closePopoverFast()
            }
        }
    }

    private func removeEventMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func installDragOverlayMonitors() {
        guard dragLocalEventMonitor == nil, dragGlobalEventMonitor == nil else { return }

        dragLocalEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handleDragTracking(eventType: event.type, point: NSEvent.mouseLocation)
            return event
        }

        dragGlobalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            let eventType = event.type
            let point = NSEvent.mouseLocation
            Task { @MainActor in
                self?.handleDragTracking(eventType: eventType, point: point)
            }
        }
    }

    private func removeDragOverlayMonitors() {
        if let dragLocalEventMonitor {
            NSEvent.removeMonitor(dragLocalEventMonitor)
            self.dragLocalEventMonitor = nil
        }
        if let dragGlobalEventMonitor {
            NSEvent.removeMonitor(dragGlobalEventMonitor)
            self.dragGlobalEventMonitor = nil
        }
    }

    private func handleDragTracking(eventType: NSEvent.EventType, point: NSPoint) {
        if eventType == .leftMouseUp {
            hideDragOverlay()
            return
        }

        guard eventType == .leftMouseDragged else { return }
        guard hasSupportedImageOnDragPasteboard(), let overlayFrame = dragOverlayFrame() else {
            hideDragOverlay()
            return
        }

        // 判定激活区：比超大实际感应面板再向外扩展 30pt，保证光标在靠近过程中就已准备好接收拖拽
        let activationFrame = overlayFrame.insetBy(dx: -30, dy: -30)
        if activationFrame.contains(point) {
            dragOverlay.show(frame: overlayFrame)
            return
        }

        let dismissalFrame = overlayFrame.insetBy(dx: -60, dy: -50)
        if dragOverlay.isVisible, !dismissalFrame.contains(point) {
            hideDragOverlay()
        }
    }

    private func hideDragOverlay() {
        dragOverlay.hide()
        dropStatusView?.setExternalDragHighlighted(false)
    }

    private func hasSupportedImageOnDragPasteboard() -> Bool {
        let pasteboard = NSPasteboard(name: .drag)
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return !SupportedImage.filter(urls).isEmpty
    }

    private func dragOverlayFrame() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let frameInWindow = button.convert(button.bounds, to: nil)
        let statusFrame = window.convertToScreen(frameInWindow)

        // 超大感应区：水平向两侧各延伸 110pt（总宽约 256pt），垂直向下延伸 75pt、向上延伸 8pt，覆盖屏幕顶部大范围区域
        let extendedX = statusFrame.origin.x - 110
        let extendedWidth = statusFrame.size.width + 220
        let extendedY = statusFrame.origin.y - 75
        let extendedHeight = statusFrame.size.height + 75 + 8

        var frame = NSRect(x: extendedX, y: extendedY, width: extendedWidth, height: extendedHeight)
        if let screen = window.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(statusFrame) }) {
            frame = frame.intersection(screen.frame)
        }
        guard !frame.isEmpty, !frame.isNull else { return nil }
        return frame.integral
    }

    private func containsInPopover(_ point: NSPoint) -> Bool {
        popover.contentViewController?.view.window?.frame.contains(point) == true
    }

    private func containsInStatusItem(_ point: NSPoint) -> Bool {
        guard let button = statusItem.button, let window = button.window else { return false }
        let frameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(frameInWindow).contains(point)
    }

    private static func activity(for items: [UploadItem]) -> UploadActivity {
        if items.contains(where: {
            switch $0.status {
            case .processing, .uploading: return true
            case .waiting, .done, .failed: return false
            }
        }) {
            return .working
        }
        if items.contains(where: { if case .failed = $0.status { return true }; return false }) {
            return .failed
        }
        if items.contains(where: { if case .done = $0.status { return true }; return false }) {
            return .success
        }
        return .idle
    }
}
