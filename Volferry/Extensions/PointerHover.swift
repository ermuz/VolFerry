import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    /// 悬停时显示手型指针（macOS）；`enabled == false` 时不显示手型（用于禁用按钮等）
    func pointingHandOnHover(enabled: Bool = true) -> some View {
        modifier(PointingHandCursorModifier(enabled: enabled))
    }
    
    /// 与 `pointingHandOnHover` 相同，语义上表示「可点击 / 可交互」控件统一使用
    func interactivePointerHover(enabled: Bool = true) -> some View {
        pointingHandOnHover(enabled: enabled)
    }
    
    /// 允许拖选并复制（⌘C）
    func textSelectable() -> some View {
        textSelection(.enabled)
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    let enabled: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onHover { inside in
                guard enabled else {
                    if hovering {
                        NSCursor.arrow.set()
                        hovering = false
                    }
                    return
                }
                hovering = inside
                if inside {
                    NSCursor.pointingHand.set()
                    // 分段控件等点击后系统可能改回箭头且不再次触发 onHover，稍后补一次手型
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        guard enabled, hovering else { return }
                        NSCursor.pointingHand.set()
                    }
                } else {
                    NSCursor.arrow.set()
                }
            }
            .onChange(of: enabled) { _, canUse in
                if !canUse, hovering {
                    NSCursor.arrow.set()
                    hovering = false
                }
            }
            .onDisappear {
                if hovering {
                    NSCursor.arrow.set()
                    hovering = false
                }
            }
        #else
        content
        #endif
    }
}
