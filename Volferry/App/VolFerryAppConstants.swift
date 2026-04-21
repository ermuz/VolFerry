import Foundation

/// 应用级标识：`UserDefaults` 键、OSLog、通知名等与 **VolFerry / 卷渡** 品牌一致。
enum VolFerryApp {
    /// 与 `PRODUCT_BUNDLE_IDENTIFIER` 对齐（Console / OSLog 过滤）
    static let subsystem = "com.volferry.ntfs"
    
    /// 钥匙串服务名（管理员密码）
    static let keychainAuthService = "com.volferry.ntfs.auth"
}

/// `UserDefaults.standard` 键定义。
enum VolFerryUserDefaults {
    enum Key {
        static let appearanceMode = "volferry.appearanceMode"
        static let showOnlyNTFSDisks = "volferry.showOnlyNTFSDisks"
        static let saveAdminPasswordToKeychain = "volferry.saveAdminPasswordToKeychain"
        static let brewScriptOpenWithWorkspaceDefault = "volferry.brewScriptOpenWithWorkspaceDefault"
        static let autoMountReadWriteTargetIDs = "volferry.autoMountReadWriteTargetIDs"
        /// 总开关：关闭后清空分区勾选并不再后台自动读写；开启后需在各 NTFS 卡片上重新勾选。
        static let autoMountReadWriteGloballyEnabled = "volferry.autoMountReadWriteGloballyEnabled"
        static let launchAtLoginEnabled = "volferry.launchAtLoginEnabled"
    }
    
    /// 未写入过偏好时，`register` 提供合理默认（须在读取键之前调用，一般在 `applicationDidFinishLaunching` 最早处）。
    static func registerApplicationDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.autoMountReadWriteGloballyEnabled: true
        ])
    }
}

extension Notification.Name {
    /// 系统外观变化（与 `NSApplicationDidChangeEffectiveAppearanceNotification` 一致）。
    static let systemEffectiveAppearanceChanged = Notification.Name("NSApplicationDidChangeEffectiveAppearanceNotification")
    
    static let drivesNeedRefresh = Notification.Name("\(VolFerryApp.subsystem).drivesNeedRefresh")
    static let showFormatSheet = Notification.Name("\(VolFerryApp.subsystem).showFormatSheet")
    static let closeStatusBarPopover = Notification.Name("\(VolFerryApp.subsystem).closeStatusBarPopover")
    static let focusDevicesTab = Notification.Name("\(VolFerryApp.subsystem).focusDevicesTab")
    static let focusDepsTab = Notification.Name("\(VolFerryApp.subsystem).focusDepsTab")
    static let openFormatSheetWithTargetTag = Notification.Name("\(VolFerryApp.subsystem).openFormatSheetWithTargetTag")
    static let autoMountTargetsChanged = Notification.Name("\(VolFerryApp.subsystem).autoMountTargetsChanged")
}
