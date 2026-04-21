import Foundation
import os.log

/// 磁盘检测服务 — 解析 diskutil 输出，识别 NTFS 和外置磁盘
class DriveDetector: ObservableObject {
    static let shared = DriveDetector()
    
    @Published var drives: [DriveInfo] = []
    @Published var allDisks: [DiskInfo] = []
    @Published var isLoading = false
    @Published var statusMessage: String = ""
    
    private let logger = Logger(subsystem: VolFerryApp.subsystem, category: "DriveDetector")
    
    private init() {}
    
    /// 合并短时间内的多次刷新请求（卷挂载 / 外部工具改读写等）
    private var scheduledRefreshTask: Task<Void, Never>?
    
    /// plist 里整数可能是 Int / Int64 / NSNumber / Double，统一转换避免整盘被 guard 跳过
    private func plistInt64(_ value: Any?) -> Int64? {
        switch value {
        case let v as Int64: return v
        case let v as Int: return Int64(v)
        case let v as UInt: return Int64(v)
        case let v as UInt64: return Int64(v)
        case let v as Double: return Int64(v)
        case let v as Float: return Int64(v)
        case let v as NSNumber: return v.int64Value
        case let v as Decimal: return NSDecimalNumber(decimal: v).int64Value
        default: return nil
        }
    }
    
    /// 新系统用 OSInternal；旧版或部分磁盘只有 Internal；缺省按外置处理
    private func plistIsInternal(_ disk: [String: Any]) -> Bool {
        if let b = disk["OSInternal"] as? Bool { return b }
        if let b = disk["Internal"] as? Bool { return b }
        return false
    }
    
    /// `diskutil info -plist` 是否表明为 NTFS（排除 exFAT 等误标 Basic Data）
    private func plistIndicatesNTFS(_ info: [String: Any]) -> Bool {
        NTFSDetection.plistIndicatesNTFS(info)
    }
    
    /// 从 `diskutil list` 文本中抓取疑似 NTFS 的分区 id（plist 漏项时备用）
    private func ntfsPartitionHintsFromDiskUtilListText(_ text: String) -> [String] {
        var ids: [String] = []
        for line in text.split(separator: "\n") {
            let s = String(line)
            let lower = s.lowercased()
            let looksLikeNtfsLine =
                lower.contains("microsoft basic data")
                || lower.contains("windows_ntfs")
                || lower.contains("hpfs_ntfs")
                || lower.contains("ntfs")
            guard looksLikeNtfsLine else { continue }
            guard !lower.contains("guid_partition_scheme") else { continue }
            guard !lower.contains("apple_apfs") else { continue }
            if let r = s.range(of: #"(disk\d+s\d+)\s*$"#, options: .regularExpression) {
                ids.append(String(s[r]))
            }
        }
        return ids
    }
    
    /// 与「磁盘工具」侧栏设备名对齐：优先 **IORegistryEntryName**（如 `TOSHIBA External USB 3.0 Media`），
    /// 再 **MediaName**（常为泛称如 `External USB 3.0`）。`diskutil list -plist` 对整块盘通常不给 VolumeName。
    private func fetchWholeDiskDisplayName(_ diskIdentifier: String) async -> String? {
        do {
            let output = try await ProcessExecutor.run("diskutil", arguments: ["info", "-plist", diskIdentifier])
            guard let data = output.data(using: .utf8),
                  let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                return nil
            }
            if let m = plist["IORegistryEntryName"] as? String {
                let t = m.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
            if let m = plist["MediaName"] as? String {
                let t = m.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
            return nil
        } catch {
            return nil
        }
    }
    
    /// 整块磁盘容量（`diskutil info` 父盘）
    private func fetchWholeDiskSizeBytes(_ diskIdentifier: String) async -> Int64? {
        do {
            let output = try await ProcessExecutor.run("diskutil", arguments: ["info", "-plist", diskIdentifier])
            guard let data = output.data(using: .utf8),
                  let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                return nil
            }
            return plistInt64(plist["TotalSize"]) ?? plistInt64(plist["Size"]) ?? plistInt64(plist["IOKitSize"])
        } catch {
            return nil
        }
    }
    
    /// 行末形如 `disk4s2` 的标识，且属于整块盘 `disk4`（不含父盘自身）
    private func partitionIdentifiersFromDiskutilListText(_ text: String, parentDisk: String) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            guard let r = s.range(of: #"(disk\d+s\d+)\s*$"#, options: .regularExpression) else { continue }
            let id = String(s[r])
            guard id != parentDisk, id.hasPrefix(parentDisk) else { continue }
            if seen.insert(id).inserted {
                ordered.append(id)
            }
        }
        return ordered
    }
    
    /// plist 主列表未带子分区时（整盘格式化后偶发），用 `diskutil list <disk>` + `info -plist` 补全
    private func fallbackPartitionsForWholeDisk(
        parentDisk: String,
        wholeDiskSize: Int64,
        isExternal: Bool,
        isEjectable: Bool,
        isInternal: Bool,
        readWriteByDevice: [String: Bool]
    ) async -> (partitions: [PartitionInfo], extraDrives: [DriveInfo]) {
        let listText = (try? await ProcessExecutor.run("diskutil", arguments: ["list", parentDisk])) ?? ""
        let candidateIds = partitionIdentifiersFromDiskutilListText(listText, parentDisk: parentDisk)
        guard !candidateIds.isEmpty else { return ([], []) }
        
        var parts: [PartitionInfo] = []
        var drives: [DriveInfo] = []
        
        for partId in candidateIds {
            guard let built = await partitionInfoFromDiskutilInfoPlist(
                partitionId: partId,
                parentWholeDisk: parentDisk,
                wholeDiskCapacityBytes: wholeDiskSize,
                isExternal: isExternal,
                isEjectable: isEjectable,
                isInternal: isInternal,
                readWriteByDevice: readWriteByDevice
            ) else {
                continue
            }
            parts.append(built.partition)
            if let d = built.drive {
                drives.append(d)
            }
        }
        return (parts, drives)
    }
    
    /// `diskutil list -plist` 中 APFS 容器合成盘（如 `disk3`）仅有 `APFSVolumes`，与「磁盘工具」侧栏展开的卷一致。
    private func partitionInfosFromAPFSVolumesEntry(_ apfsVols: [[String: Any]]) async -> [PartitionInfo] {
        var out: [PartitionInfo] = []
        for vol in apfsVols {
            guard let partId = vol["DeviceIdentifier"] as? String,
                  let partSize = plistInt64(vol["Size"]), partSize > 0 else { continue }
            let partName = (vol["VolumeName"] as? String) ?? ""
            let volumePath = vol["MountPoint"] as? String
            let isMounted = volumePath != nil
            let capUse = plistInt64(vol["CapacityInUse"])
            let usedBytes: Int64?
            let freeBytes: Int64?
            if let u = capUse {
                let used = min(max(0, u), partSize)
                usedBytes = used
                freeBytes = max(0, partSize - used)
            } else if let mp = volumePath, !mp.isEmpty, let space = await volumeSpaceBytes(mountPoint: mp) {
                usedBytes = space.used
                freeBytes = space.free
            } else {
                usedBytes = nil
                freeBytes = nil
            }
            let partition = PartitionInfo(
                identifier: partId,
                name: partName.isEmpty ? "(未命名)" : partName,
                type: "Apple_APFS_Volume",
                fileSystem: "apfs",
                size: partSize,
                volumePath: volumePath,
                isMounted: isMounted,
                usedBytes: usedBytes,
                freeBytes: freeBytes
            )
            out.append(partition)
        }
        return out
    }
    
    /// 由 `diskutil info -plist` 构造分区；若为 NTFS 则同时给出 DriveInfo
    private func partitionInfoFromDiskutilInfoPlist(
        partitionId: String,
        parentWholeDisk: String,
        wholeDiskCapacityBytes: Int64,
        isExternal: Bool,
        isEjectable: Bool,
        isInternal: Bool,
        readWriteByDevice: [String: Bool]
    ) async -> (partition: PartitionInfo, drive: DriveInfo?)? {
        do {
            let output = try await ProcessExecutor.run("diskutil", arguments: ["info", "-plist", partitionId])
            guard let data = output.data(using: .utf8),
                  let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                return nil
            }
            guard let partId = plist["DeviceIdentifier"] as? String, partId == partitionId else { return nil }
            let parent = (plist["ParentWholeDisk"] as? String) ?? ""
            if !parent.isEmpty, parent != parentWholeDisk {
                return nil
            }
            let contentRaw = (plist["Content"] as? String) ?? ""
            let contentLower = contentRaw.lowercased()
            if contentLower.contains("partition_scheme")
                || contentLower.contains("partition_map")
                || contentLower == "apple_partition_map" {
                return nil
            }
            let partSize = plistInt64(plist["Size"])
                ?? plistInt64(plist["TotalSize"])
                ?? plistInt64(plist["VolumeSize"])
                ?? plistInt64(plist["Total Disk Space"])
                ?? 0
            guard partSize > 0 else { return nil }
            
            let partName = (plist["VolumeName"] as? String) ?? ""
            let partType = contentRaw
            let fsRaw = (plist["Filesystem"] as? String)
                ?? (plist["FileSystem"] as? String)
                ?? (plist["FilesystemType"] as? String)
                ?? ""
            let fs = fsRaw.lowercased()
            let volumePath = plist["MountPoint"] as? String
            let isMounted = volumePath != nil
            let space = await volumeSpaceBytes(mountPoint: volumePath)
            let devicePath = "/dev/\(partId)"
            
            let partition = PartitionInfo(
                identifier: partId,
                name: partName.isEmpty ? "(未命名)" : partName,
                type: partType,
                fileSystem: fs,
                size: partSize,
                volumePath: volumePath,
                isMounted: isMounted,
                usedBytes: space?.used,
                freeBytes: space?.free
            )
            
            var drive: DriveInfo?
            if NTFSDetection.isLikelyNTFS(fileSystem: fs, partitionContent: partType) {
                let used = space?.used ?? 0
                let isReadWrite = readWriteByDevice[devicePath] ?? false
                drive = DriveInfo(
                    diskIdentifier: parentWholeDisk,
                    partitionIdentifier: partId,
                    volumeName: partName.isEmpty ? "(未命名)" : partName,
                    volumePath: volumePath ?? "",
                    devicePath: devicePath,
                    size: partSize,
                    wholeDiskCapacityBytes: wholeDiskCapacityBytes,
                    partitionContent: partType,
                    used: used,
                    isNTFS: true,
                    isMounted: isMounted,
                    isReadWrite: isReadWrite,
                    isExternal: isExternal,
                    isEjectable: isEjectable,
                    fileSystem: "NTFS",
                    volumeUUID: plist["VolumeUUID"] as? String,
                    diskUUID: plist["DiskUUID"] as? String
                )
            }
            return (partition, drive)
        } catch {
            return nil
        }
    }
    
    /// 用 `diskutil info -plist` 构造 DriveInfo（补充枚举；仅跳过已在 drives 列表中的分区）
    private func driveFromDiskUtilInfoPlist(partitionId: String, alreadyListed: Set<String>, readWriteByDevice: [String: Bool]) async -> DriveInfo? {
        guard !alreadyListed.contains(partitionId) else { return nil }
        do {
            let output = try await ProcessExecutor.run("diskutil", arguments: ["info", "-plist", partitionId])
            guard let data = output.data(using: .utf8),
                  let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  plistIndicatesNTFS(plist) else { return nil }
            
            guard let partId = plist["DeviceIdentifier"] as? String,
                  let parentDisk = plist["ParentWholeDisk"] as? String else { return nil }
            let partSize = plistInt64(plist["Size"])
                ?? plistInt64(plist["TotalSize"])
                ?? plistInt64(plist["VolumeSize"])
                ?? plistInt64(plist["IOKitSize"])
                ?? 0
            guard partSize > 0 else { return nil }
            
            let volName = (plist["VolumeName"] as? String) ?? ""
            let mountPoint = plist["MountPoint"] as? String
            let isMounted = mountPoint != nil
            let isInternal = (plist["OSInternal"] as? Bool)
                ?? (plist["Internal"] as? Bool)
                ?? (plist["OSInternalMedia"] as? Bool)
                ?? false
            let isEjectable = (plist["Ejectable"] as? Bool)
                ?? (plist["EjectableMedia"] as? Bool)
                ?? (plist["RemovableMediaOrExternalDevice"] as? Bool)
                ?? false
            
            let used = (await volumeSpaceBytes(mountPoint: mountPoint))?.used ?? 0
            let devicePath = "/dev/\(partId)"
            let isReadWrite = readWriteByDevice[devicePath] ?? false
            
            let content = (plist["Content"] as? String) ?? ""
            let wholeDisk = await fetchWholeDiskSizeBytes(parentDisk)
            return DriveInfo(
                diskIdentifier: parentDisk,
                partitionIdentifier: partId,
                volumeName: volName.isEmpty ? "(未命名)" : volName,
                volumePath: mountPoint ?? "",
                devicePath: "/dev/\(partId)",
                size: partSize,
                wholeDiskCapacityBytes: wholeDisk,
                partitionContent: content,
                used: used,
                isNTFS: true,
                isMounted: isMounted,
                isReadWrite: isReadWrite,
                isExternal: !isInternal,
                isEjectable: isEjectable,
                fileSystem: "NTFS",
                volumeUUID: plist["VolumeUUID"] as? String,
                diskUUID: plist["DiskUUID"] as? String
            )
        } catch {
            return nil
        }
    }
    
    /// 防抖后静默刷新（不显示顶栏「正在扫描」），用于卷变化与定时同步
    func scheduleRefresh() {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard let self = self, !Task.isCancelled else { return }
            await self.refresh(showLoading: false)
        }
    }
    
    /// 解析 `mount` 输出，建立 `/dev/diskXsY` → 是否读写的映射（整份输出只解析一次，避免对每个分区重复执行 `mount`）
    private static func readWriteByDevicePath(from mountOutput: String) -> [String: Bool] {
        var map: [String: Bool] = [:]
        for line in mountOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            guard let onRange = s.range(of: " on ") else { continue }
            let device = s[..<onRange.lowerBound].trimmingCharacters(in: .whitespaces)
            guard device.hasPrefix("/dev/") else { continue }
            let opts = s[onRange.upperBound...].lowercased()
            let readOnly = opts.contains("read-only") || opts.contains("rdonly")
            map[device] = !readOnly
        }
        return map
    }
    
    /// 刷新所有磁盘信息
    /// - Parameter showLoading: 为 `true` 时显示顶栏加载态（用户手动刷新）；后台同步用 `false` 避免闪烁
    func refresh(showLoading: Bool = true) async {
        if showLoading {
            await MainActor.run {
                isLoading = true
                statusMessage = "正在读取磁盘列表…"
            }
        }
        
        do {
            let output = try await ProcessExecutor.run("diskutil", arguments: ["list", "-plist"])
            
            guard let data = output.data(using: .utf8),
                  let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let allDisksAndPartitions = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
                throw NSError(domain: "DriveDetector", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法解析 diskutil 输出"])
            }
            
            /// plist 成功后再并行拉取 `mount` 与文本 `list`（二者互不依赖，且失败时可降级为空）
            async let mountTask = ProcessExecutor.run("mount", arguments: [])
            async let listTextTask = ProcessExecutor.run("diskutil", arguments: ["list"])
            let mountOutput = (try? await mountTask) ?? ""
            let listText = ((try? await listTextTask) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let readWriteByDevice = Self.readWriteByDevicePath(from: mountOutput)
            
            if showLoading {
                await MainActor.run { statusMessage = "正在检测分区与读写状态…" }
            }
            
            let diskIdsForHardwareNames = allDisksAndPartitions.compactMap { $0["DeviceIdentifier"] as? String }
            var wholeDiskDisplayNameById: [String: String] = [:]
            await withTaskGroup(of: (String, String?).self) { group in
                for id in diskIdsForHardwareNames {
                    group.addTask { [self] in
                        (id, await self.fetchWholeDiskDisplayName(id))
                    }
                }
                for await (id, name) in group {
                    if let n = name, !n.isEmpty {
                        wholeDiskDisplayNameById[id] = n
                    }
                }
            }
            
            var foundDrives: [DriveInfo] = []
            var allDiskInfos: [DiskInfo] = []
            
            for diskEntry in allDisksAndPartitions {
                guard let deviceIdentifier = diskEntry["DeviceIdentifier"] as? String,
                      let size = plistInt64(diskEntry["Size"]) else {
                    continue
                }
                let partitions = diskEntry["Partitions"] as? [[String: Any]] ?? []
                
                let isInternal = plistIsInternal(diskEntry)
                let isEjectable = (diskEntry["EjectableMedia"] as? Bool)
                    ?? (diskEntry["Ejectable"] as? Bool)
                    ?? false
                let isExternal = !isInternal
                var diskPartitions: [PartitionInfo] = []
                
                for part in partitions {
                    guard let partId = part["DeviceIdentifier"] as? String,
                          let partSize = plistInt64(part["Size"]) else {
                        continue
                    }
                    let partName = (part["VolumeName"] as? String) ?? ""
                    let partType = (part["Content"] as? String) ?? ""
                    
                    let fsRaw = (part["Filesystem"] as? String)
                        ?? (part["FileSystem"] as? String)
                        ?? (part["FilesystemType"] as? String)
                        ?? ""
                    let fs = fsRaw.lowercased()
                    let volumePath = part["MountPoint"] as? String
                    let isMounted = volumePath != nil
                    let space = await volumeSpaceBytes(mountPoint: volumePath)
                    let devicePath = "/dev/\(partId)"
                    
                    let partition = PartitionInfo(
                        identifier: partId,
                        name: partName.isEmpty ? "(未命名)" : partName,
                        type: partType,
                        fileSystem: fs,
                        size: partSize,
                        volumePath: volumePath,
                        isMounted: isMounted,
                        usedBytes: space?.used,
                        freeBytes: space?.free
                    )
                    diskPartitions.append(partition)
                    
                    // NTFS 分区加入 drives 列表
                    if NTFSDetection.isLikelyNTFS(fileSystem: fs, partitionContent: partType) {
                        let used = space?.used ?? 0
                        let isReadWrite = readWriteByDevice[devicePath] ?? false
                        
                        let drive = DriveInfo(
                            diskIdentifier: deviceIdentifier,
                            partitionIdentifier: partId,
                            volumeName: partName.isEmpty ? "(未命名)" : partName,
                            volumePath: volumePath ?? "",
                            devicePath: devicePath,
                            size: partSize,
                            wholeDiskCapacityBytes: size,
                            partitionContent: partType,
                            used: used,
                            isNTFS: true,
                            isMounted: isMounted,
                            isReadWrite: isReadWrite,
                            isExternal: isExternal,
                            isEjectable: isEjectable,
                            fileSystem: "NTFS",
                            volumeUUID: part["VolumeUUID"] as? String,
                            diskUUID: part["DiskUUID"] as? String
                        )
                        foundDrives.append(drive)
                    }
                }
                
                if diskPartitions.isEmpty, let apfsVols = diskEntry["APFSVolumes"] as? [[String: Any]], !apfsVols.isEmpty {
                    diskPartitions = await partitionInfosFromAPFSVolumesEntry(apfsVols)
                }
                
                /// `list -plist` 有时在整盘抹掉后暂不列出 `Partitions`，用 `diskutil list <disk>` + `info` 补全
                if diskPartitions.isEmpty {
                    let fb = await fallbackPartitionsForWholeDisk(
                        parentDisk: deviceIdentifier,
                        wholeDiskSize: size,
                        isExternal: isExternal,
                        isEjectable: isEjectable,
                        isInternal: isInternal,
                        readWriteByDevice: readWriteByDevice
                    )
                    if !fb.partitions.isEmpty {
                        diskPartitions = fb.partitions
                        var listedIds = Set(foundDrives.map(\.partitionIdentifier))
                        for d in fb.extraDrives {
                            guard !listedIds.contains(d.partitionIdentifier) else { continue }
                            foundDrives.append(d)
                            listedIds.insert(d.partitionIdentifier)
                        }
                    }
                }
                
                let diskNameFromList = (diskEntry["VolumeName"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let hardwareName = wholeDiskDisplayNameById[deviceIdentifier]
                let resolvedDiskName: String
                if let h = hardwareName, !h.isEmpty {
                    resolvedDiskName = h
                } else if !diskNameFromList.isEmpty {
                    resolvedDiskName = diskNameFromList
                } else {
                    resolvedDiskName = deviceIdentifier
                }
                allDiskInfos.append(DiskInfo(
                    identifier: deviceIdentifier,
                    name: resolvedDiskName,
                    size: size,
                    isExternal: isExternal,
                    isEjectable: isEjectable,
                    isInternal: isInternal,
                    partitions: diskPartitions
                ))
            }
            
            // plist 未列出、或 Content 未识别时，用已并行取得的 list 文本 + info -plist 再扫一遍
            let hints = ntfsPartitionHintsFromDiskUtilListText(listText)
            if !hints.isEmpty {
                var listed = Set(foundDrives.map(\.partitionIdentifier))
                for hint in hints {
                    if let extra = await driveFromDiskUtilInfoPlist(partitionId: hint, alreadyListed: listed, readWriteByDevice: readWriteByDevice) {
                        foundDrives.append(extra)
                        listed.insert(extra.partitionIdentifier)
                    }
                }
            }
            
            let finalDrives = foundDrives
            let finalDisks = allDiskInfos
            await MainActor.run {
                self.drives = finalDrives
                self.allDisks = finalDisks
                if showLoading {
                    self.isLoading = false
                }
                let diskCount = finalDisks.count
                let partitionCount = finalDisks.reduce(0) { $0 + $1.partitions.count }
                let ntfsCount = finalDrives.count
                self.statusMessage = "\(diskCount) 个磁盘 · \(partitionCount) 个分区 · \(ntfsCount) 个 NTFS 分区"
            }
            Task {
                await AutoMountManager.shared.processDetectedNTFSDrives(finalDrives)
            }
            
        } catch {
            logger.error("刷新磁盘失败: \(error.localizedDescription)")
            await MainActor.run {
                self.statusMessage = "刷新失败: \(error.localizedDescription)"
                if showLoading {
                    self.isLoading = false
                }
            }
        }
    }
    
    /// 已挂载卷的已用、可用（与访达「显示简介」同一套 `attributesOfFileSystem`）
    private func volumeSpaceBytes(mountPoint: String?) async -> (used: Int64, free: Int64)? {
        guard let path = mountPoint, !path.isEmpty else { return nil }
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: path)
            let total = attrs[.systemSize] as? Int64 ?? 0
            let free = attrs[.systemFreeSize] as? Int64 ?? 0
            let used = max(0, total - free)
            return (used, free)
        } catch {
            return nil
        }
    }
    
}
