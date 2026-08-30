import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let state = AppState()
    private var itemsObservation: AnyCancellable?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.loadSettings()
        setupPopover()
        setupStatusItem()
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

        itemsObservation = state.$items
            .map(Self.activity(for:))
            .removeDuplicates()
            .sink { [weak dropView] activity in
                dropView?.setUploadActivity(activity)
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
