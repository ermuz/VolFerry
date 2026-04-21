import AppKit

/// 供 NSTrackingArea 的 owner 使用（须由调用方强引用）
final class MenuBarPointingHandTrackingResponder: NSResponder {
    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

/// 菜单栏 / 状态栏相关：手型光标辅助（与 SwiftUI `pointingHandOnHover` 互补）
enum MenuBarPointingHand {
    /// 在视图内注册跟踪区（用于 NSStatusBarButton 等）
    static func installTracking(on view: NSView, owner: MenuBarPointingHandTrackingResponder, existing: inout NSTrackingArea?) {
        if let old = existing {
            view.removeTrackingArea(old)
            existing = nil
        }
        view.postsBoundsChangedNotifications = true
        let area = NSTrackingArea(
            rect: view.bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect, .assumeInside],
            owner: owner,
            userInfo: nil
        )
        view.addTrackingArea(area)
        existing = area
    }

    /// 鼠标是否位于「系统弹出菜单」类窗口内（含主菜单栏拉下的菜单、状态栏菜单）
    static func mouseIsInsideMenuPaletteWindow(_ point: NSPoint) -> Bool {
        for w in NSApp.windows where w.isVisible {
            if isMenuLikePopupWindow(w), w.frame.contains(point) {
                return true
            }
        }
        return false
    }

    private static func isMenuLikePopupWindow(_ window: NSWindow) -> Bool {
        // 下拉菜单、上下文菜单多为 .popUpMenu；不要用 .mainMenu 以免把整条菜单栏当成可点热区
        if window.level == .popUpMenu { return true }
        let name = String(describing: type(of: window))
        if name.contains("NSPopupMenu") || name.contains("MenuPanel") || name.contains("ContextMenu") {
            return true
        }
        return false
    }
}
