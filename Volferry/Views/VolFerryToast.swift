import SwiftUI

/// 居中非阻塞浮层提示，替代阻塞式 `alert`，符合 HIG 中「轻量反馈」的用法。
private func volFerryToastAutoDismissSeconds(for text: String) -> Double {
    let n = text.count
    if n > 200 { return 8 }
    if n > 100 { return 5.5 }
    return 3.8
}

private struct VolFerryToastModifier: ViewModifier {
    @Binding var message: String?
    let dark: Bool
    var onHidden: (() -> Void)?
    
    @State private var hideTask: Task<Void, Never>?
    
    func body(content: Content) -> some View {
        content
            .overlay {
                toastOverlay
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: message)
            .onChange(of: message) { _, newValue in
                hideTask?.cancel()
                hideTask = nil
                guard let text = newValue, !text.isEmpty else { return }
                let delay = volFerryToastAutoDismissSeconds(for: text)
                hideTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    if message == text {
                        message = nil
                        onHidden?()
                    }
                }
            }
    }
    
    @ViewBuilder
    private var toastOverlay: some View {
        if let text = message, !text.isEmpty {
            ZStack {
                Color.black.opacity(dark ? 0.38 : 0.22)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissToast()
                    }
                
                toastCard(text: text)
                    .padding(28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .center)))
        }
    }
    
    private func toastCard(text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title3)
                .foregroundStyle(VolFerryTheme.accent)
                .accessibilityHidden(true)
                .padding(.top, 2)
            Text(text)
                .font(.body)
                .foregroundStyle(VolFerryTheme.textPrimary(dark))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelectable()
                .frame(maxWidth: .infinity)
            Button {
                dismissToast()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(VolFerryTheme.textSecondary(dark))
            }
            .buttonStyle(.plain)
            .help("关闭")
            .accessibilityLabel("关闭提示")
            .pointingHandOnHover()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: 480)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(VolFerryTheme.bgSecondary(dark))
                .shadow(color: .black.opacity(dark ? 0.45 : 0.18), radius: 24, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(VolFerryTheme.border(dark).opacity(0.55), lineWidth: 1)
        )
    }
    
    private func dismissToast() {
        hideTask?.cancel()
        hideTask = nil
        let hadContent = message != nil
        message = nil
        if hadContent {
            onHidden?()
        }
    }
}

extension View {
    /// 居中浮层 Toast：窗口中央卡片、半透明背景（点击背景可关）、自动消失，可点「×」提前关闭；`onHidden` 在消息清空后调用（含自动与手动）。
    func volFerryToast(message: Binding<String?>, dark: Bool, onHidden: (() -> Void)? = nil) -> some View {
        modifier(VolFerryToastModifier(message: message, dark: dark, onHidden: onHidden))
    }
}
