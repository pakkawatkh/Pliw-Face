import AppKit
import Combine
import SwiftUI

@MainActor
public final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    private let onOpenSetup: () -> Void
    private let onPreviewHUD: () -> Void

    public init(onOpenSetup: @escaping () -> Void, onPreviewHUD: @escaping () -> Void = {}) {
        self.onOpenSetup = onOpenSetup
        self.onPreviewHUD = onPreviewHUD
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        configurePopover()
        configureStatusButton()
        observeEngineState()
    }

    public func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    public func showPopover() {
        guard let button = statusItem.button else { return }
        FaceUnlockEngine.shared.refreshSystemReadiness()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installOutsideClickMonitor()
    }

    public func closePopover() {
        popover.performClose(nil)
        removeOutsideClickMonitor()
    }

    public func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self

        let rootView = MenuBarPopoverView(
            onOpenSetup: { [weak self] in
                self?.closePopover()
                self?.onOpenSetup()
            },
            onPreviewHUD: { [weak self] in
                self?.onPreviewHUD()
            },
            onQuit: { [weak self] in
                self?.closePopover()
                NSApplication.shared.terminate(nil)
            }
        )
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]
        hostingController.view.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = hostingController
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // Omit `button.toolTip` intentionally to avoid the macOS floating stuck-tooltip bug.
        updateIcon()
    }

    private func observeEngineState() {
        let engine = FaceUnlockEngine.shared
        Publishers.CombineLatest(engine.$isSessionArmed, engine.$phase)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.updateIcon()
            }
            .store(in: &cancellables)
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let engine = FaceUnlockEngine.shared
        let symbolName = engine.isReadyForLockScreenUnlock ? "faceid" : "faceid"
        let weight: NSFont.Weight = engine.isReadyForLockScreenUnlock ? .bold : .regular
        let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: weight)
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Pliw Face")?
            .withSymbolConfiguration(config)
        img?.isTemplate = true
        button.image = img
        button.alphaValue = engine.isReadyForLockScreenUnlock ? 1.0 : 0.60
        button.title = ""
        button.imagePosition = .imageOnly
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu(from: sender)
        } else {
            togglePopover()
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        closePopover()
        let menu = NSMenu()
        let engine = FaceUnlockEngine.shared

        let sessionItem = NSMenuItem(
            title: engine.isSessionArmed ? "Lock Session" : "Arm Session with Touch ID",
            action: #selector(toggleSession),
            keyEquivalent: ""
        )
        sessionItem.target = self
        menu.addItem(sessionItem)

        let setupItem = NSMenuItem(title: "Setup & Face Lab...", action: #selector(openSetupWindow), keyEquivalent: ",")
        setupItem.target = self
        menu.addItem(setupItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Pliw Face", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleSession() {
        let engine = FaceUnlockEngine.shared
        if engine.isSessionArmed {
            engine.disarmSession()
        } else {
            engine.armSession()
        }
    }

    @objc private func openSetupWindow() {
        onOpenSetup()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.popover.isShown == true {
                    self?.closePopover()
                }
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }
}
