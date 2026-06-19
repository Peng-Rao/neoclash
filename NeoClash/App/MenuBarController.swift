import AppKit
import NeoClashCore
import Observation
import SwiftUI

/// Owns the AppKit menu bar item and presents the SwiftUI panel in a transient popover.
///
/// SwiftUI's `MenuBarExtra` window style does not give enough control over panel sizing and status
/// item updates here, so this small AppKit bridge keeps those concerns outside the SwiftUI views.
@MainActor
final class MenuBarController: NSObject {
    private enum Layout {
        static let panelWidth: CGFloat = 300
        static let fallbackPanelHeight: CGFloat = 380
        static let maxPanelHeight: CGFloat = 640
    }

    private let runtime: RuntimeStore
    private let coordinator: AppCoordinator
    private var statusItem: NSStatusItem?

    // Keep one hosting controller alive for the popover lifetime; its root view is refreshed before
    // each presentation so environment values and measured size match the current runtime state.
    private lazy var hostingController = NSHostingController(rootView: AnyView(menuBarContent))
    private lazy var popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = hostingController
        return popover
    }()

    init(runtime: RuntimeStore, coordinator: AppCoordinator) {
        self.runtime = runtime
        self.coordinator = coordinator
        super.init()
    }

    func install() {
        guard statusItem == nil else {
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        guard let button = item.button else {
            return
        }

        button.action = #selector(togglePopover(_:))
        button.target = self
        button.toolTip = "NeoClash"
        button.imagePosition = .imageOnly
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        updateStatusItemImage()
        observeRuntimeStatus()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else {
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            refreshPopoverContent()
            button.highlight(true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private var menuBarContent: some View {
        MenuBarPanelView()
            .environment(runtime)
            .environment(coordinator)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func refreshPopoverContent() {
        hostingController.rootView = AnyView(menuBarContent)
        hostingController.view.setFrameSize(NSSize(width: Layout.panelWidth, height: Layout.fallbackPanelHeight))
        hostingController.view.layoutSubtreeIfNeeded()

        // Ask SwiftUI for its fitting height after layout, then cap the popover so long proxy lists
        // do not create an oversized menu bar window.
        let fittingHeight = hostingController.view.fittingSize.height
        let panelHeight = fittingHeight.isFinite && fittingHeight > 0
            ? min(fittingHeight, Layout.maxPanelHeight)
            : Layout.fallbackPanelHeight

        popover.contentSize = NSSize(width: Layout.panelWidth, height: panelHeight)
    }

    private func updateStatusItemImage() {
        let symbolName = runtime.status.isRunning ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "NeoClash")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    private func observeRuntimeStatus() {
        // Observation tracking is one-shot: after the status changes, update the icon and register a
        // fresh tracking closure for the next transition.
        withObservationTracking {
            _ = runtime.status.isRunning
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateStatusItemImage()
                self?.observeRuntimeStatus()
            }
        }
    }
}

extension MenuBarController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        statusItem?.button?.highlight(false)
    }
}
