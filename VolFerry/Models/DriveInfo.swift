import Foundation

/// 列表中每一项表示 **一个 NTFS 分区上的卷**（如 `disk4s2`），不是整块物理硬盘。
/// `diskIdentifier` 为所属整块磁盘（如 `disk4`）；挂载/格式化等操作针对该分区。
struct DriveInfo: Identifiable, Equatable {
    var id: String { partitionIdentifier }
    /// 所属物理磁盘（整块盘）的 `diskutil` 标识，如 disk4
    let diskIdentifier: String
    /// 该 NTFS 所在 **分区** 标识，如 disk4s2
    let partitionIdentifier: String
    let volumeName: String
    let volumePath: String
    let devicePath: String
    /// 该分区容量（字节）
    let size: Int64
    /// 所属整块磁盘总容量；若未知则为 nil
    let wholeDiskCapacityBytes: Int64?
    /// GPT 分区 Content，如 Microsoft Basic Data
    let partitionContent: String
    let used: Int64
    let isNTFS: Bool
    let isMounted: Bool
    let isReadWrite: Bool
    let isExternal: Bool
    let isEjectable: Bool
    let fileSystem: String
    /// 文件系统卷 UUID（最优先，重格式化会变）
    let volumeUUID: String?
    /// 分区/容器 UUID（用于 VolumeUUID 缺失时回退）
    let diskUUID: String?
    
    var displayName: String {
        volumeName.isEmpty ? partitionIdentifier : volumeName
    }
    
    var wholeDiskCapacityFormatted: String? {
        guard let b = wholeDiskCapacityBytes, b > 0 else { return nil }
        return ByteCountFormatting.fileString(fromByteCount: b)
    }
    
    var sizeFormatted: String {
        ByteCountFormatting.fileString(fromByteCount: size)
    }
    
    var usedFormatted: String {
        ByteCountFormatting.fileString(fromByteCount: used)
    }
    
    /// 分区上剩余可用空间（与 `size`、`used` 一致时，与系统「可用」一致）
    var freeBytes: Int64 {
        max(0, size - used)
    }
    
    var freeFormatted: String {
        ByteCountFormatting.fileString(fromByteCount: freeBytes)
    }
    
    var usedPercent: Double {
        guard size > 0 else { return 0 }
        return min(1.0, Double(used) / Double(size))
    }
    
    static func == (lhs: DriveInfo, rhs: DriveInfo) -> Bool {
        lhs.partitionIdentifier == rhs.partitionIdentifier &&
        lhs.volumeName == rhs.volumeName &&
        lhs.isMounted == rhs.isMounted &&
        lhs.isReadWrite == rhs.isReadWrite &&
        lhs.used == rhs.used &&
        lhs.size == rhs.size &&
        lhs.wholeDiskCapacityBytes == rhs.wholeDiskCapacityBytes &&
        lhs.partitionContent == rhs.partitionContent &&
        lhs.volumeUUID == rhs.volumeUUID &&
        lhs.diskUUID == rhs.diskUUID
    }
}
