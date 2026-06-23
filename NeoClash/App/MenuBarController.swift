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

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        guard let button = item.button else {
            return
        }

        button.action = #selector(togglePopover(_:))
        button.target = self
        button.toolTip = "NeoClash"
        button.imagePosition = .imageOnly
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        refreshStatusItem()
        observeRuntime()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(statusBarModeChanged),
            name: .neoStatusBarModeChanged,
            object: nil
        )
    }

    @objc private func statusBarModeChanged() {
        refreshStatusItem()
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

    /// Refreshes the status item's icon and, when "Icon and Speed" is selected and the core is
    /// running, appends a compact up/down throughput readout next to it.
    private func refreshStatusItem() {
        guard let button = statusItem?.button else {
            return
        }
        let running = runtime.status.isRunning
        let symbolName = running ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "NeoClash")
        image?.isTemplate = true
        button.image = image

        if StatusBarMode.stored == .iconAndSpeed, running {
            button.imagePosition = .imageLeading
            let down = Self.compactRate(runtime.traffic.downloadPerSecond)
            let up = Self.compactRate(runtime.traffic.uploadPerSecond)
            button.attributedTitle = NSAttributedString(
                string: " ↓\(down) ↑\(up)",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)]
            )
        } else {
            button.imagePosition = .imageOnly
            button.title = ""
        }
    }

    private static func compactRate(_ bytesPerSecond: Int) -> String {
        let kb = Double(bytesPerSecond) / 1024
        if kb < 1 { return "0K" }
        if kb < 1000 { return "\(Int(kb.rounded()))K" }
        return String(format: "%.1fM", kb / 1024)
    }

    private func observeRuntime() {
        // Observation tracking is one-shot: after the status or traffic changes, refresh the status
        // item and register a fresh tracking closure for the next transition.
        withObservationTracking {
            _ = runtime.status.isRunning
            _ = runtime.traffic.downloadPerSecond
            _ = runtime.traffic.uploadPerSecond
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshStatusItem()
                self?.observeRuntime()
            }
        }
    }
}

extension MenuBarController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        statusItem?.button?.highlight(false)
    }
}
