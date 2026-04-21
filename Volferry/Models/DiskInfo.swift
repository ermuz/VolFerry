import Foundation

/// 与 `DriveDetector` 一致的 NTFS / Microsoft Basic Data 识别，供列表过滤与 `PartitionInfo` 共用。
enum NTFSDetection {
    static func isLikelyNTFS(fileSystem: String, partitionContent: String) -> Bool {
        let fs = fileSystem.lowercased()
        let c = partitionContent.lowercased()
        if fs.contains("ntfs") { return true }
        if c.contains("ntfs") { return true }
        if c.contains("microsoft"), c.contains("basic"), c.contains("data") { return true }
        if c.replacingOccurrences(of: " ", with: "_").contains("microsoft_basic_data") { return true }
        if c.contains("windows"), c.contains("ntfs") { return true }
        if c.contains("hpfs"), c.contains("ntfs") { return true }
        return false
    }
    
    /// 与 `diskutil info -plist` 根字典对照，是否与 DriveDetector 中 NTFS 识别一致（含 FilesystemType / Name / Filesystem 等）
    static func plistIndicatesNTFS(_ info: [String: Any]) -> Bool {
        let fsType = (info["FilesystemType"] as? String ?? "").lowercased()
        let fsName = (info["FilesystemName"] as? String ?? "").lowercased()
        let visible = (info["FilesystemUserVisibleName"] as? String ?? "").lowercased()
        let fsLegacy = ((info["Filesystem"] as? String ?? "") + " " + (info["FileSystem"] as? String ?? "")).lowercased()
        if fsType == "exfat" || fsName.contains("exfat") || visible.contains("exfat") || fsLegacy.contains("exfat") { return false }
        if fsType == "ntfs" || fsName.contains("ntfs") || visible.contains("ntfs") || fsLegacy.contains("ntfs") { return true }
        let content = (info["Content"] as? String ?? "")
        let comboFs = [fsType, fsName, visible, fsLegacy].joined(separator: " ")
        return isLikelyNTFS(fileSystem: comboFs, partitionContent: content)
    }
}

/// 将 `diskutil` 的 GPT/MBR `Content` 转为界面简短名称（徽标用）；原始字符串仍可通过悬停提示查看。
enum PartitionContentLabel {
    static func display(from raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "—" }
        let key = t.uppercased().replacingOccurrences(of: " ", with: "_")
        if let name = known[key] { return name }
        let lower = t.lowercased()
        if lower.contains("microsoft"), lower.contains("basic"), lower.contains("data") {
            return "Microsoft 基本数据"
        }
        if lower.hasPrefix("efi") || (lower.contains("efi") && lower.contains("system")) {
            return "EFI 系统分区"
        }
        return t.replacingOccurrences(of: "_", with: " ")
    }
    
    private static let known: [String: String] = [
        "DOS_FAT_32": "FAT32",
        "WINDOWS_FAT_32": "FAT32",
        "DOS_FAT_16": "FAT16",
        "WINDOWS_FAT_16": "FAT16",
        "DOS_FAT_12": "FAT12",
        "EXFAT": "exFAT",
        "APPLE_APFS": "APFS",
        "APPLE_APFS_ISC": "APFS",
        "APPLE_APFS_CONTAINER": "APFS 容器",
        "APPLE_APFS_VOLUME": "APFS 卷",
        "APPLE_CORE_STORAGE": "Core Storage",
        "APPLE_HFS": "Mac OS 扩展",
        "APPLE_BLANK": "未使用",
        "LINUX": "Linux",
        "LINUX_LVM": "Linux LVM",
        "LINUX_SWAP": "Linux Swap",
        "WINDOWS_NTFS": "NTFS",
        "HPFS_NTFS": "NTFS",
        "APPLE_BOOT": "Boot 分区",
        "APPLE_RAID": "RAID",
        "APPLE_RAID_OFFLINE": "RAID（离线）",
    ]
}

struct DiskInfo: Identifiable {
    var id: String { identifier }
    let identifier: String
    /// 整块磁盘展示名：优先 `diskutil info` 的 **IORegistryEntryName**（与「磁盘工具」一致，常含 `… Media` 后缀），其次 MediaName，再 list 的 VolumeName，最后 `disk0` 等标识
    let name: String
    let size: Int64
    let isExternal: Bool
    let isEjectable: Bool
    let isInternal: Bool
    let partitions: [PartitionInfo]
    
    var sizeFormatted: String {
        ByteCountFormatting.fileString(fromByteCount: size)
    }
    
    /// 各分区容量之和（来自 `diskutil list`）
    var partitionsTotalBytes: Int64 {
        partitions.reduce(0) { $0 + $1.size }
    }
    
    /// 整盘标称容量与已列出分区合计的差（分区表、对齐、未分配等）
    var unallocatedBytes: Int64 {
        max(0, size - partitionsTotalBytes)
    }
    
    var partitionsTotalFormatted: String {
        ByteCountFormatting.fileString(fromByteCount: partitionsTotalBytes)
    }
    
    var unallocatedFormatted: String {
        ByteCountFormatting.fileString(fromByteCount: unallocatedBytes)
    }
}

struct PartitionInfo: Identifiable {
    var id: String { identifier }
    let identifier: String
    let name: String
    let type: String
    let fileSystem: String
    let size: Int64
    let volumePath: String?
    let isMounted: Bool
    /// 已挂载时由文件系统统计的已用/可用（字节）；未挂载为 nil
    let usedBytes: Int64?
    let freeBytes: Int64?
    
    var isNTFS: Bool {
        NTFSDetection.isLikelyNTFS(fileSystem: fileSystem, partitionContent: type)
    }
    
    var sizeFormatted: String {
        ByteCountFormatting.fileString(fromByteCount: size)
    }
    
    /// 是否已从挂载卷读到用量（用于展示已用/可用）
    var hasSpaceStats: Bool {
        usedBytes != nil && freeBytes != nil
    }
    
    var usedFormatted: String? {
        guard let u = usedBytes else { return nil }
        return ByteCountFormatting.fileString(fromByteCount: u)
    }
    
    var freeFormatted: String? {
        guard let f = freeBytes else { return nil }
        return ByteCountFormatting.fileString(fromByteCount: f)
    }
    
    /// 已用占分区标称容量比例（用于进度条）
    var usedPercentOfCapacity: Double {
        guard let u = usedBytes, size > 0 else { return 0 }
        return min(1.0, Double(u) / Double(size))
    }
}
