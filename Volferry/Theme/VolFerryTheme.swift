import SwiftUI

/// 应用界面外观：与 `UserDefaults` 键 `volferry.appearanceMode` 对应（`system` / `light` / `dark`）。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    
    /// 自定义 `VolFerryTheme` 是否按深色绘制；「跟随系统」使用 `NSApp.effectiveAppearance`，不依赖 SwiftUI `colorScheme`（避免窗口曾被锁深色后 environment 不恢复）。
    func resolvedIsDark() -> Bool {
        switch self {
        case .system: return AppleEffectiveAppearance.isDark
        case .light: return false
        case .dark: return true
        }
    }
    
}

/// 语义色（成功 / 警告 / 危险等）
enum VolFerryTheme {
    
    static func bgPrimary(_ dark: Bool) -> Color {
        dark ? Color(red: 29 / 255, green: 29 / 255, blue: 31 / 255) : Color(red: 1, green: 1, blue: 1)
    }
    
    static func bgSecondary(_ dark: Bool) -> Color {
        dark ? Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255) : Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)
    }
    
    static func bgTertiary(_ dark: Bool) -> Color {
        dark ? Color(red: 58 / 255, green: 58 / 255, blue: 60 / 255) : Color(red: 229 / 255, green: 229 / 255, blue: 234 / 255)
    }
    
    static func textPrimary(_ dark: Bool) -> Color {
        dark ? Color.white : Color.black
    }
    
    static func textSecondary(_ dark: Bool) -> Color {
        dark
            ? Color(red: 152 / 255, green: 152 / 255, blue: 157 / 255)
            // 浅色卡片上略加深，避免说明文字与 `bgSecondary` 对比不足
            : Color(red: 72 / 255, green: 74 / 255, blue: 80 / 255)
    }
    
    static func border(_ dark: Bool) -> Color {
        dark ? Color(red: 56 / 255, green: 56 / 255, blue: 58 / 255) : Color(red: 210 / 255, green: 210 / 255, blue: 215 / 255)
    }
    
    static let accent = Color(red: 0 / 255, green: 122 / 255, blue: 255 / 255)
    static let success = Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
    static let warning = Color(red: 255 / 255, green: 149 / 255, blue: 0 / 255)
    static let danger = Color(red: 255 / 255, green: 59 / 255, blue: 48 / 255)
    /// 推出卷（靛色，与挂载蓝、读写绿、安全移除橙区分）
    static let actionUnmount = Color(red: 88 / 255, green: 86 / 255, blue: 214 / 255)
    /// 安全移除整张外置磁盘（橙红，与「格式化」纯红区分）
    static let actionEjectDisk = Color(red: 255 / 255, green: 115 / 255, blue: 50 / 255)
    
    /// 设备卡片 / 状态栏：各操作的 SF Symbol 与强调色（挂载 / 读写 / 只读 / 推出卷 / 格式化 / 安全移除）
    enum DeviceToolbar {
        enum Kind {
            case mount
            case readWrite
            case readOnly
            case unmount
            case format
            case eject
            case installDeps
        }
        
        static func systemImage(_ kind: Kind) -> String {
            switch kind {
            case .mount: return "arrow.down.circle.fill"
            case .readWrite: return "square.and.pencil.circle.fill"
            case .readOnly: return "lock.circle.fill"
            case .unmount: return "eject.circle.fill"
            case .format: return "hammer.circle.fill"
            case .eject: return "externaldrive.badge.minus"
            case .installDeps: return "cube.box.fill"
            }
        }
        
        static func tint(_ kind: Kind) -> Color {
            switch kind {
            case .mount: return VolFerryTheme.accent
            case .readWrite: return VolFerryTheme.success
            case .readOnly: return VolFerryTheme.warning
            case .unmount: return VolFerryTheme.actionUnmount
            case .format: return VolFerryTheme.danger
            case .eject: return VolFerryTheme.actionEjectDisk
            case .installDeps: return VolFerryTheme.warning
            }
        }
    }
}
