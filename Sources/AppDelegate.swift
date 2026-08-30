import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let state = AppState()

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
        statusItem = NSStatusBar.system.statusItem(withLength: 30)

        let dropView = DropStatusView(frame: NSRect(x: 0, y: 0, width: 30, height: 24))
        dropView.onClick = { [weak self] in
            self?.togglePopover()
        }
        dropView.onDragEntered = { [weak self] in
            self?.showPopover()
        }
        dropView.onDrop = { [weak self] urls in
            guard let self else { return }
            self.showPopover()
            self.state.enqueue(urls: urls)
        }
        statusItem.view = dropView
    }

    private func showPopover() {
        guard let view = statusItem.view else { return }
        if !popover.isShown {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }
}
