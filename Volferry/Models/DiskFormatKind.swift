import Foundation

/// 主流磁盘/卷格式（与「磁盘工具」可抹掉格式对应）；NTFS 走 mkntfs，其余走 `diskutil eraseVolume` / `eraseDisk`
enum DiskFormatKind: String, CaseIterable, Identifiable {
    case ntfs
    case exfat
    case fat32
    case apfs
    case hfsJournaled
    
    var id: String { rawValue }
    
    /// 结果提示等用的短名称
    var shortName: String {
        switch self {
        case .ntfs: return "NTFS"
        case .exfat: return "exFAT"
        case .fat32: return "FAT32"
        case .apfs: return "APFS"
        case .hfsJournaled: return "Mac OS 扩展（日志式）"
        }
    }
    
    /// 菜单/列表中的短标题
    var menuTitle: String {
        switch self {
        case .ntfs: return "NTFS（Windows / 大文件）"
        case .exfat: return "exFAT（跨平台 U 盘）"
        case .fat32: return "FAT32（兼容性最广）"
        case .apfs: return "APFS（仅 macOS 固态）"
        case .hfsJournaled: return "Mac OS 扩展（日志式）"
        }
    }
    
    /// `diskutil eraseVolume` / `eraseDisk` 使用的 personality（NTFS 不使用）
    var diskutilPersonality: String {
        switch self {
        case .ntfs: return ""
        case .exfat: return "ExFAT"
        case .fat32: return "MS-DOS FAT32"
        case .apfs: return "APFS"
        case .hfsJournaled: return "Journaled HFS+"
        }
    }
    
    var scenario: String {
        switch self {
        case .ntfs:
            return "适用场景：Windows 系统盘、内置硬盘、大容量移动硬盘（主要在 Windows 与 Mac 间以大文件为主时）。"
        case .exfat:
            return "适用场景：U 盘、移动硬盘、需要在 Windows 与 Mac 之间频繁跨平台读写。"
        case .fat32:
            return "适用场景：老旧电脑、游戏机、老款车载音响、轻量级 U 盘。"
        case .apfs:
            return "适用场景：macOS 10.13 及更高版本使用的固态硬盘（SSD）及苹果生态外置盘。"
        case .hfsJournaled:
            return "适用场景：旧版 macOS 使用的机械盘/移动硬盘（日志式 HFS+）。"
        }
    }
    
    var pros: String {
        switch self {
        case .ntfs:
            return "优点：安全性较高，支持大于 4GB 的单个文件，顺序读写表现通常较好。"
        case .exfat:
            return "优点：兼容性强（常见 Windows / Mac / 部分嵌入式设备），支持大于 4GB 的单个文件，空间利用率较好。"
        case .fat32:
            return "优点：兼容性极广，几乎所有消费类设备都能识别。"
        case .apfs:
            return "优点：为闪存优化，支持快照、加密与空间共享等现代特性。"
        case .hfsJournaled:
            return "优点：在旧版 macOS 上成熟稳定，日志式有助于异常断电后的恢复。"
        }
    }
    
    var cons: String {
        switch self {
        case .ntfs:
            return "缺点：macOS 默认只读挂载（本应用可配合 ntfs-3g 读写）；在极老旧设备上兼容性一般。"
        case .exfat:
            return "缺点：无日志机制，异常断电时数据损坏风险相对 APFS/HFS+ 更高。"
        case .fat32:
            return "缺点：不支持大于 4GB 的单个文件；单卷容量上限较低。"
        case .apfs:
            return "缺点：Windows 无法原生挂载读写；不适合需要与旧版 Windows 直接换盘使用的场景。"
        case .hfsJournaled:
            return "缺点：Windows 无法原生读写；新设备上逐步被 APFS 取代。"
        }
    }
    
    /// 根据 `diskutil` 报告的文件系统与 GPT `Content` 推断面板默认格式（与当前卷一致）
    static func inferredDefault(fileSystem: String, partitionContent: String) -> DiskFormatKind {
        if NTFSDetection.isLikelyNTFS(fileSystem: fileSystem, partitionContent: partitionContent) {
            return .ntfs
        }
        let fs = fileSystem.lowercased()
        let c = partitionContent.lowercased()
        if fs.contains("exfat") || c.contains("exfat") { return .exfat }
        if fs.contains("apfs") || c.contains("apple_apfs") { return .apfs }
        if fs.contains("hfs") || c.contains("apple_hfs") || c.contains("hfsx") { return .hfsJournaled }
        if fs.contains("msdos")
            || c.contains("dos_fat")
            || c.contains("fat32")
            || c.contains("fat16")
            || c.contains("windows_fat") {
            return .fat32
        }
        return .ntfs
    }
    
    /// 格式化完成后核对：`diskutil` 报告的文件系统 / GPT 类型是否与所选格式一致（避免命令返回成功但实际未变）
    static func volumeMatchesExpected(_ part: PartitionInfo, _ expected: DiskFormatKind) -> Bool {
        volumeMatchesExpected(fileSystem: part.fileSystem, partitionContent: part.type, expected: expected)
    }
    
    static func volumeMatchesExpected(fileSystem: String, partitionContent: String, expected: DiskFormatKind) -> Bool {
        switch expected {
        case .ntfs:
            return NTFSDetection.isLikelyNTFS(fileSystem: fileSystem, partitionContent: partitionContent)
        case .exfat:
            let fs = fileSystem.lowercased()
            let c = partitionContent.lowercased()
            return fs.contains("exfat") || c.contains("exfat")
        case .apfs:
            let fs = fileSystem.lowercased()
            let c = partitionContent.lowercased()
            return fs.contains("apfs") || c.contains("apple_apfs")
        case .hfsJournaled:
            let fs = fileSystem.lowercased()
            let c = partitionContent.lowercased()
            return fs.contains("hfs") || c.contains("apple_hfs") || c.contains("hfsx")
        case .fat32:
            let fs = fileSystem.lowercased()
            let c = partitionContent.lowercased()
            return fs.contains("msdos")
                || c.contains("dos_fat")
                || c.contains("fat32")
                || c.contains("fat16")
                || c.contains("windows_fat")
        }
    }
    
    /// 整盘：用容量最大的「数据」分区推断（跳过 EFI、分区表等）
    static func inferredDefaultForPartitions(_ parts: [PartitionInfo]) -> DiskFormatKind {
        let data = parts.filter { p in
            let t = p.type.lowercased()
            if t.contains("partition_scheme") || t.contains("partition_map") { return false }
            if t.contains("efi") && t.contains("system") { return false }
            if t == "efi" { return false }
            return p.size > 0
        }
        guard let best = data.max(by: { $0.size < $1.size }) else { return .ntfs }
        return inferredDefault(fileSystem: best.fileSystem, partitionContent: best.type)
    }
    
    /// 卷名中的非法字符替换（与 MountManager 一致思路）
    static func sanitizedVolumeName(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        if t.isEmpty { t = "UNTITLED" }
        return t
    }
}
