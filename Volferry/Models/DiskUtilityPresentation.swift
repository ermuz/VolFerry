import Foundation

/// 设备树中**可挂载/格式化**的分区集合：EFI、Microsoft 保留分区、GPT 上的 APFS 引导切片等仅作系统用途，不在此提供操作入口。
///
/// **关于 `diskNs1`（如 disk4s1）**：GPT 外接盘上第一个分区常为 **EFI**，用于固件引导，不是数据卷。
enum DiskUtilityPresentation {
    /// 是否属于不应在应用内挂载、格式化、读写的系统/保留分区。
    static func isAuxiliaryNonOperablePartition(partitionTypeContent: String) -> Bool {
        let u = partitionTypeContent.uppercased().replacingOccurrences(of: " ", with: "_")
        if u == "EFI" { return true }
        if u.contains("MICROSOFT_RESERVED") { return true }
        if u == "APPLE_APFS_ISC" || u == "APPLE_APFS_RECOVERY" { return true }
        return false
    }
}

extension DiskInfo {
    /// 可供用户操作的分区行（排除 EFI、保留分区等）；容量条与 `partitions` 仍为 diskutil 全量枚举。
    var operablePartitions: [PartitionInfo] {
        partitions.filter { !DiskUtilityPresentation.isAuxiliaryNonOperablePartition(partitionTypeContent: $0.type) }
    }
}
