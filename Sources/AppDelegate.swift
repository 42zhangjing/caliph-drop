import AppKit
import Combine
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.loadSettings()
        setupPopover()
        setupStatusItem()
        installDragOverlayMonitors()
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 390, height: 560)
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverRootView(state: state))
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 34)
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
        if !popover.isShown {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            installEventMonitors()
        }
        if activateApp {
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover(activateApp: true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        state.discardUnsavedSettings()
        removeEventMonitors()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        state.refreshLaunchAtLoginStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
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
                self.popover.performClose(nil)
                return nil
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                let point = NSEvent.mouseLocation
                if !self.containsInPopover(point) && !self.containsInStatusItem(point) {
                    self.popover.performClose(nil)
                }
            }
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.popover.performClose(nil)
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

        // Show the actual target slightly before the cursor reaches it so AppKit has
        // time to begin NSDraggingDestination negotiation on the next drag update.
        let activationFrame = overlayFrame.insetBy(dx: -16, dy: -12)
        if activationFrame.contains(point) {
            dragOverlay.show(frame: overlayFrame)
            return
        }

        let dismissalFrame = overlayFrame.insetBy(dx: -24, dy: -18)
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

        // 34pt remains the real NSStatusItem width. The transparent drag-only panel
        // extends the physical destination without changing the visible menu-bar layout.
        var frame = statusFrame.insetBy(dx: -9, dy: -8)
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
