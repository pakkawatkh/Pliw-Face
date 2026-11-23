import AppKit
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusBarController: StatusBarController?
    private var setupWindow: NSWindow?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.local.tiffy-face"
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if instances.count > 1 {
            NSApp.terminate(nil)
            return
        }

        // Pure Menu Bar accessory app (zero Dock clutter)
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()

        FaceUnlockEngine.shared.startBackgroundMonitoring()

        statusBarController = StatusBarController(onOpenSetup: { [weak self] in
            self?.showSetupWindow()
        })

        // Open compact popover briefly right after launch so the user sees it immediately
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            self?.statusBarController?.showPopover()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        FaceUnlockEngine.shared.stopBackgroundMonitoring()
        SessionCryptoVault.shared.disarmSession()
    }

    public func showSetupWindow() {
        if let existing = setupWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 570),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Tiffy Face — Setup & Face Lab"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1.0)
        window.isReleasedWhenClosed = false
        window.delegate = self

        window.contentView = NSHostingView(rootView: SetupWindowView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.setupWindow = window
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        FaceUnlockEngine.shared.refreshSystemReadiness()
    }

    public func windowWillClose(_ notification: Notification) {
        let engine = FaceUnlockEngine.shared
        if engine.runMode == .diagnosticScan {
            engine.stopAnyActiveScan()
        }
        if case .enrollment = engine.runMode {
            engine.stopAnyActiveScan()
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Tiffy Face", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
