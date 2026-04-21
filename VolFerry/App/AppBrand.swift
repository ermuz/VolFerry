import Foundation

/// 用户可见的应用名称：`Info.plist` 为中文「卷渡」；`en.lproj/InfoPlist.strings` 为英文 **VolFerry**。
enum AppBrand {
    /// 中文品牌（与基座 `Info.plist` 一致）
    static let chineseName = "卷渡"
    /// 英文品牌（与 `en.lproj/InfoPlist.strings` 中 `CFBundleDisplayName` 一致）
    static let englishName = "VolFerry"
    
    /// 系统根据语言从 Bundle 解析后的显示名（中文环境多为「卷渡」，英文多为「VolFerry」）。
    static var displayName: String {
        let info = Bundle.main.infoDictionary
        if let v = info?["CFBundleDisplayName"] as? String,
           !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return v
        }
        if let v = info?["CFBundleName"] as? String,
           !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return v
        }
        return chineseName
    }
    
    /// 关于窗口等：双语并列，避免只熟悉其中一种语言的用户找不到应用。
    static var bilingualTitle: String {
        "\(chineseName)（\(englishName)）"
    }
}
