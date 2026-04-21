import Foundation
import os.log

/// 自动挂载策略：
/// - 用户手动成功「读写挂载」后，记录该 NTFS 的稳定标识（优先 VolumeUUID）。
/// - 后续检测到同一分区时，自动尝试：先系统挂载，再升级为 ntfs-3g 读写。
actor AutoMountManager {
    static let shared = AutoMountManager()
    
    private let logger = Logger(subsystem: VolFerryApp.subsystem, category: "AutoMount")
    private let defaults = UserDefaults.standard
    
    private let targetIDsKey = VolFerryUserDefaults.Key.autoMountReadWriteTargetIDs
    private let retryInterval: TimeInterval = 45
    
    /// 每个稳定 id 的最近尝试时间，避免刷新循环时高频重复执行。
    private var lastAttemptAt: [String: Date] = [:]
    
    private init() {}
    
    nonisolated static func stableID(for drive: DriveInfo) -> String? {
        if let v = drive.volumeUUID?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            return "vol:\(v.lowercased())"
        }
        if let d = drive.diskUUID?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
            return "disk:\(d.lowercased())"
        }
        return nil
    }
    
    private func targetIDs() -> Set<String> {
        let arr = defaults.stringArray(forKey: targetIDsKey) ?? []
        return Set(arr)
    }
    
    private func saveTargetIDs(_ ids: Set<String>) {
        defaults.set(Array(ids).sorted(), forKey: targetIDsKey)
    }
    
    func isReadWriteTarget(_ drive: DriveInfo) -> Bool {
        guard defaults.bool(forKey: VolFerryUserDefaults.Key.autoMountReadWriteGloballyEnabled) else { return false }
        guard let key = Self.stableID(for: drive) else { return false }
        return targetIDs().contains(key)
    }
    
    func setReadWriteTarget(_ drive: DriveInfo, enabled: Bool) {
        if enabled {
            guard defaults.bool(forKey: VolFerryUserDefaults.Key.autoMountReadWriteGloballyEnabled) else { return }
        }
        guard let key = Self.stableID(for: drive) else { return }
        var ids = targetIDs()
        let changed: Bool
        if enabled {
            changed = ids.insert(key).inserted
        } else {
            changed = ids.remove(key) != nil
        }
        if changed {
            logger.info("\(enabled ? "记录" : "移除")自动读写目标: \(key, privacy: .public)")
            saveTargetIDs(ids)
            Task { @MainActor in
                NotificationCenter.default.post(name: .autoMountTargetsChanged, object: nil)
            }
        }
    }
    
    /// 关闭全局自动读写时调用：清空所有分区勾选并重置重试时间。
    func clearAllReadWriteTargets() {
        saveTargetIDs([])
        lastAttemptAt.removeAll()
        logger.info("已清空全部 NTFS 自动读写分区（全局关闭）")
        Task { @MainActor in
            NotificationCenter.default.post(name: .autoMountTargetsChanged, object: nil)
        }
    }
    
    func processDetectedNTFSDrives(_ drives: [DriveInfo]) async {
        guard defaults.bool(forKey: VolFerryUserDefaults.Key.autoMountReadWriteGloballyEnabled) else { return }
        let targets = targetIDs()
        guard !targets.isEmpty else { return }
        
        let ntfs = drives.filter(\.isNTFS)
        guard !ntfs.isEmpty else { return }
        guard MountManager.findNTFS3G() != nil else { return }
        /// 启动自动任务会尝试静默读取钥匙串密码（系统策略下可能出现一次授权提示）。
        guard let password = await MainActor.run(body: { AuthManager.shared.backgroundPasswordWithoutPrompt() }),
              !password.isEmpty else { return }
        
        var changed = false
        for drive in ntfs {
            guard let key = Self.stableID(for: drive), targets.contains(key) else { continue }
            if drive.isReadWrite { continue }
            if let last = lastAttemptAt[key], Date().timeIntervalSince(last) < retryInterval {
                continue
            }
            lastAttemptAt[key] = Date()
            
            do {
                if !drive.isMounted {
                    _ = try await MountManager.mountVolumeSystem(partitionIdentifier: drive.partitionIdentifier)
                }
                guard let ntfs3g = MountManager.findNTFS3G() else { continue }
                _ = try await MountManager.mountReadWrite(drive: drive, ntfs3gPath: ntfs3g, password: password)
                changed = true
                logger.info("自动读写挂载成功: \(key, privacy: .public)")
            } catch {
                logger.error("自动读写挂载失败 \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        
        if changed {
            await MainActor.run {
                NotificationCenter.default.post(name: .drivesNeedRefresh, object: nil, userInfo: ["showLoading": false])
            }
        }
    }
}

