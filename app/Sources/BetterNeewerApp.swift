import AppKit
import SwiftUI

@MainActor
final class BetterNeewerDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let controller = StudioController()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var controlWindow: NSWindow?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureApplicationMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "lightbulb", accessibilityDescription: "Better Neewer studio lights")
            button.image?.isTemplate = true
            button.toolTip = "Better Neewer — studio lights"
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityIdentifier("better-neewer-status")
        }
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 420, height: 600)
        let content = StudioView(controller: controller, maximumHeight: maximumContentHeight,
                                 heightChanged: { [weak self] height in
            self?.popover.contentSize = NSSize(width: 420, height: height)
        }, openWindow: { [weak self] in self?.showControlWindow() })
        popover.contentViewController = NSHostingController(rootView: content)
        controller.connectAll()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.controller.resumeWantedConnections() }
        }
        if CommandLine.arguments.contains("--control-window") || CommandLine.arguments.contains("--preview-window") {
            showControlWindow()
        }
    }

    private var maximumContentHeight: CGFloat {
        let screen = statusItem?.button?.window?.screen ?? controlWindow?.screen ?? NSScreen.main
        return max(220, min(850, (screen?.visibleFrame.height ?? 900) - 90))
    }

    private func configureApplicationMenu() {
        let menu = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Open control window", action: #selector(openWindowFromMenu), keyEquivalent: "0")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Better Neewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        menu.addItem(item)

        // NSHostingController does not install an Edit menu. These nil-target
        // actions reach the focused AppKit field editor through the responder
        // chain, including SwiftUI numeric fields and the rename sheet.
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    @objc private func openWindowFromMenu() { showControlWindow() }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        // Recreate the shell to account for a different display's available height;
        // observed light state stays in the shared controller. This does not apply settings.
        popover.contentViewController = NSHostingController(rootView: StudioView(
            controller: controller, maximumHeight: maximumContentHeight,
            heightChanged: { [weak self] height in
                self?.popover.contentSize = NSSize(width: 420, height: height)
            }, openWindow: { [weak self] in self?.showControlWindow() }))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showControlWindow() {
        popover.performClose(nil)
        if let controlWindow {
            controlWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Studio lights — Better Neewer"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = StudioView(controller: controller, maximumHeight: maximumContentHeight,
                                 heightChanged: { [weak window] height in
            guard let window else { return }
            let top = window.frame.maxY
            window.setContentSize(NSSize(width: 420, height: height))
            var frame = window.frame
            frame.origin.y = top - frame.height
            window.setFrame(frame, display: true)
        }, isWindow: true)
        window.contentViewController = NSHostingController(rootView: content)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controlWindow = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showControlWindow() }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        controller.shutdown()
    }

}

@main
enum BetterNeewerApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = BetterNeewerDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
