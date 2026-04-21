import Foundation

/// 与 `diskutil partitionDisk` 的分区表类型对应
enum PartitionDiskScheme: String, CaseIterable, Identifiable {
    case gpt = "GPTFormat"
    case mbr = "MBRFormat"
    
    var id: String { rawValue }
    
    var menuTitle: String {
        switch self {
        case .gpt: return "GUID 分区表 (GPT) — 推荐"
        case .mbr: return "主引导记录 (MBR) — 兼容旧版 Windows"
        }
    }
}

/// 预设布局（各卷使用同一文件系统性格，由 `diskutil listFilesystems` 支持）
enum PartitionDiskPreset: String, CaseIterable, Identifiable {
    case single
    case dualHalf
    case tripleThird
    
    var id: String { rawValue }
    
    var menuTitle: String {
        switch self {
        case .single: return "单分区（占满整盘）"
        case .dualHalf: return "两个分区（约各 50%）"
        case .tripleThird: return "三个分区（约各占三分之一）"
        }
    }
    
    var partitionCount: Int {
        switch self {
        case .single: return 1
        case .dualHalf: return 2
        case .tripleThird: return 3
        }
    }
    
    /// `(personality, volumeName, sizeSpec)` 三元组，供 `diskutil partitionDisk` 追加
    func partitionTriplets(filesystemPersonality: String, volumeNames: [String]) -> [(String, String, String)] {
        precondition(volumeNames.count == partitionCount)
        switch self {
        case .single:
            return [(filesystemPersonality, volumeNames[0], "R")]
        case .dualHalf:
            return [
                (filesystemPersonality, volumeNames[0], "50%"),
                (filesystemPersonality, volumeNames[1], "R")
            ]
        case .tripleThird:
            return [
                (filesystemPersonality, volumeNames[0], "33%"),
                (filesystemPersonality, volumeNames[1], "34%"),
                (filesystemPersonality, volumeNames[2], "R")
            ]
        }
    }
}

/// 分区向导中的目标文件系统。  
/// **注意**：`diskutil partitionDisk` 不能直接创建 NTFS；选 NTFS 时单分区下会先建 ExFAT 占位卷再调用 `mkntfs`（与依赖中的 ntfs-3g 一致）。
enum PartitionDiskFilesystem: String, CaseIterable, Identifiable {
    case ntfs
    case exfat
    case fat32
    case apfs
    case jhfs
    
    var id: String { rawValue }
    
    /// 传给 `diskutil partitionDisk` 的 personality。NTFS 在磁盘阶段用 ExFAT 占位，再 `mkntfs`。
    var diskutilPersonality: String {
        switch self {
        case .ntfs: return "ExFAT"
        case .exfat: return "ExFAT"
        case .fat32: return "MS-DOS FAT32"
        case .apfs: return "APFS"
        case .jhfs: return "JHFS+"
        }
    }
    
    var menuTitle: String {
        switch self {
        case .ntfs: return "NTFS（Windows，需 mkntfs）"
        case .exfat: return "ExFAT（跨平台）"
        case .fat32: return "MS-DOS FAT32"
        case .apfs: return "APFS（仅 macOS）"
        case .jhfs: return "Mac OS 扩展（日志式）"
        }
    }
    
    /// NTFS 仅支持单分区（`diskutil` 无法对多卷直接写 NTFS）
    var requiresSinglePartitionPreset: Bool {
        self == .ntfs
    }
}
