import AppKit
import SwiftUI

/// 承载 `NSPopUpButton`，在 `layout` 中铺满宽度（与「磁盘工具」等 AppKit 界面一致）。
final class FormatPopUpHostingView: NSView {
    let popUp: NSPopUpButton
    
    init(popUp: NSPopUpButton) {
        self.popUp = popUp
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(popUp)
        popUp.translatesAutoresizingMaskIntoConstraints = false
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layout() {
        super.layout()
        popUp.frame = bounds
    }
}

/// 使用系统 `NSPopUpButton`，在横向约束下会铺满剩余区域（与 SwiftUI `Picker`+`.menu` 的 intrinsic 窄条不同）。
struct FormatPopUpPicker: NSViewRepresentable {
    @Binding var selectionRaw: String
    var useDarkAppearance: Bool
    
    private var items: [(id: String, title: String)] {
        DiskFormatKind.allCases.map { ($0.rawValue, $0.menuTitle) }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeNSView(context: Context) -> FormatPopUpHostingView {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.controlSize = .regular
        popUp.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        popUp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popUp.target = context.coordinator
        popUp.action = #selector(Coordinator.selectionChanged(_:))
        
        context.coordinator.popUp = popUp
        context.coordinator.parent = self
        
        fillMenu(popUp)
        syncSelection(popUp)
        applyAppearance(popUp)
        
        return FormatPopUpHostingView(popUp: popUp)
    }
    
    func updateNSView(_ nsView: FormatPopUpHostingView, context: Context) {
        context.coordinator.parent = self
        guard let popUp = context.coordinator.popUp else { return }
        
        if popUp.numberOfItems != items.count {
            fillMenu(popUp)
        }
        syncSelection(popUp)
        applyAppearance(popUp)
        nsView.needsLayout = true
    }
    
    private func fillMenu(_ popUp: NSPopUpButton) {
        popUp.removeAllItems()
        for item in items {
            popUp.addItem(withTitle: item.title)
            popUp.lastItem?.representedObject = item.id as NSString
        }
    }
    
    private func syncSelection(_ popUp: NSPopUpButton) {
        if let idx = items.firstIndex(where: { $0.id == selectionRaw }) {
            if popUp.indexOfSelectedItem != idx {
                popUp.selectItem(at: idx)
            }
            return
        }
        // 绑定值无效或首帧尚未写入：回退到 NTFS，与 DiskFormatKind 默认一致。
        // 勿用「第一项」以免 allCases 顺序变化；勿在已匹配时写回 selectionRaw，避免覆盖 @AppStorage 里用户上次选的格式。
        guard popUp.numberOfItems > 0 else { return }
        let fallback = DiskFormatKind.ntfs.rawValue
        if let idx = items.firstIndex(where: { $0.id == fallback }) {
            popUp.selectItem(at: idx)
            if selectionRaw != fallback {
                selectionRaw = fallback
            }
        }
    }
    
    private func applyAppearance(_ popUp: NSPopUpButton) {
        popUp.appearance = NSAppearance(named: useDarkAppearance ? .darkAqua : .aqua)
    }
    
    final class Coordinator: NSObject {
        var parent: FormatPopUpPicker?
        weak var popUp: NSPopUpButton?
        
        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let id = sender.selectedItem?.representedObject as? String,
                  let parent = parent else { return }
            parent.selectionRaw = id
        }
    }
}
