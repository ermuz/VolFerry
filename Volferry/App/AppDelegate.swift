import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    private var statusPopover: NSPopover?

    private let statusHandTrackingOwner = MenuBarPointingHandTrackingResponder()
    private var statusHandTrackingArea: NSTrackingArea?
    private var menuBarMouseMonitor: Any?
    /// 处理嵌套子菜单时多次 willOpen / didClose
    private var menuTrackingDepth = 0
    /// 仅当「刚从 AppKit 菜单面板移出」时才恢复箭头，避免每帧 arrow 覆盖 SwiftUI 的 onHover 手型
    private var wasPointerOverMenuPalette = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        VolFerryUserDefaults.registerApplicationDefaults()
        setupMenuBar()
        setupStatusBarItem()
        installStatusItemHandTracking()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closeStatusBarPopoverNotification(_:)),
            name: .closeStatusBarPopover,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeMenuBarMouseMonitor()
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: statusItem?.button)
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: statusItem?.button)
        NotificationCenter.default.removeObserver(self, name: .closeStatusBarPopover, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidResignActive(_ notification: Notification) {
        menuTrackingDepth = 0
        wasPointerOverMenuPalette = false
        removeMenuBarMouseMonitor()
    }

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.delegate = self
        appMenu.addItem(withTitle: "关于 \(AppBrand.displayName)", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 \(AppBrand.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "操作")
        fileMenu.delegate = self
        fileMenu.addItem(withTitle: "刷新磁盘", action: #selector(AppDelegate.refreshDisks(_:)), keyEquivalent: "r")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "磁盘格式化…", action: #selector(AppDelegate.showFormatTool(_:)), keyEquivalent: "")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = statusBarIconImage()
        button.imageScaling = .scaleProportionallyUpOrDown
        button.toolTip = "点击显示 NTFS 设备与挂载操作"
        button.target = self
        button.action = #selector(toggleStatusBarPopover(_:))
        statusItem?.menu = nil
    }
    
    /// 状态栏图标：裁掉 AppIcon 外圈留白后再缩放，避免视觉上偏小。
    private func statusBarIconImage() -> NSImage {
        guard let source = NSApp.applicationIconImage else {
            return NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: AppBrand.displayName) ?? NSImage()
        }
        guard let tiff = source.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else {
            return source
        }
        
        let w = cg.width
        let h = cg.height
        // 进一步裁边，提升状态栏中的视觉占比。
        let inset = Int(Double(min(w, h)) * 0.10)
        let crop = CGRect(x: inset, y: inset, width: max(1, w - inset * 2), height: max(1, h - inset * 2))
        guard let cropped = cg.cropping(to: crop) else {
            return source
        }
        
        let out = NSImage(cgImage: cropped, size: NSSize(width: 23, height: 23))
        out.isTemplate = false
        return out
    }

    private func installStatusItemHandTracking() {
        guard let button = statusItem?.button else { return }
        MenuBarPointingHand.installTracking(on: button, owner: statusHandTrackingOwner, existing: &statusHandTrackingArea)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(statusBarButtonGeometryChanged(_:)),
            name: NSView.frameDidChangeNotification,
            object: button
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(statusBarButtonGeometryChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: button
        )
    }

    @objc private func statusBarButtonGeometryChanged(_ notification: Notification) {
        guard let button = statusItem?.button else { return }
        MenuBarPointingHand.installTracking(on: button, owner: statusHandTrackingOwner, existing: &statusHandTrackingArea)
    }

    private func ensureStatusPopover() -> NSPopover {
        if let existing = statusPopover {
            return existing
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let hosting = NSHostingController(rootView: StatusBarPopoverView())
        hosting.view.frame = CGRect(origin: .zero, size: NSSize(width: 380, height: 440))
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 380, height: 440)
        statusPopover = popover
        return popover
    }

    @objc private func toggleStatusBarPopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        let popover = ensureStatusPopover()
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        /// 刷新由 Popover 内 `onAppear` 触发静默同步，避免与主窗口抢同一 `isLoading`。
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func closeStatusBarPopoverNotification(_ notification: Notification) {
        statusPopover?.performClose(nil)
    }

    // MARK: - NSMenuDelegate（下拉菜单内手型光标）

    func menuWillOpen(_ menu: NSMenu) {
        menuTrackingDepth += 1
        guard menuBarMouseMonitor == nil else { return }
        // 不要用 leftMouseDown：点击主窗口分段控件等时也会触发，会强制 arrow，覆盖 SwiftUI 手型
        menuBarMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.updatePointingHandForMenuPalettes()
            return event
        }
        updatePointingHandForMenuPalettes()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTrackingDepth = max(0, menuTrackingDepth - 1)
        if menuTrackingDepth == 0 {
            wasPointerOverMenuPalette = false
            removeMenuBarMouseMonitor()
            NSCursor.arrow.set()
        }
    }

    private func removeMenuBarMouseMonitor() {
        if let m = menuBarMouseMonitor {
            NSEvent.removeMonitor(m)
            menuBarMouseMonitor = nil
        }
    }

    private func updatePointingHandForMenuPalettes() {
        let p = NSEvent.mouseLocation
        let inside = MenuBarPointingHand.mouseIsInsideMenuPaletteWindow(p)
        if inside {
            NSCursor.pointingHand.set()
            wasPointerOverMenuPalette = true
        } else if wasPointerOverMenuPalette {
            NSCursor.arrow.set()
            wasPointerOverMenuPalette = false
        }
    }

    // MARK: - Actions

    @objc func showMainWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc func refreshDisks(_ sender: Any?) {
        NotificationCenter.default.post(name: .drivesNeedRefresh, object: nil, userInfo: ["showLoading": true])
    }

    @objc func showFormatTool(_ sender: Any?) {
        NotificationCenter.default.post(name: .showFormatSheet, object: nil)
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "关于 \(AppBrand.bilingualTitle)"
        alert.informativeText = "\(AppBrand.bilingualTitle) — macOS NTFS 磁盘管理工具\n支持 NTFS 读写挂载与磁盘格式化\n\n技术栈：ntfs-3g + macFUSE"
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }
}
