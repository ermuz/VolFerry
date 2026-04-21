import AppKit
import SwiftUI

/// 与 SwiftUI `@Environment(\.colorScheme)` 解耦，直接读取系统当前外观（避免窗口曾被强锁深色后 environment 长期为 `.dark`）。
enum AppleEffectiveAppearance {
    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// 将外观模式同步到当前窗口的 `NSWindow.appearance`（`nil` = 跟随系统），比仅使用 `preferredColorScheme` 在 macOS 上更可靠。
struct WindowAppearanceBridge: NSViewRepresentable {
    var mode: AppearanceMode
    
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        return v
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView, attempt: 0)
    }
    
    private func apply(to view: NSView, attempt: Int) {
        DispatchQueue.main.async {
            if let window = view.window {
                switch mode {
                case .system:
                    window.appearance = nil
                case .light:
                    window.appearance = NSAppearance(named: .aqua)
                case .dark:
                    window.appearance = NSAppearance(named: .darkAqua)
                }
                return
            }
            guard attempt < 48 else { return }
            apply(to: view, attempt: attempt + 1)
        }
    }
}
