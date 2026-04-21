import Foundation
import os.log

/// 挂载管理 — 负责 NTFS 磁盘的读写挂载、推出卷、安全移除磁盘等
/// 读写挂载使用 ntfs-3g 常用安全选项：remove_hiberfile、noatime 等。
class MountManager {
    private static let logger = Logger(subsystem: VolFerryApp.subsystem, category: "MountManager")
    
    /// 在部分系统上优先使用 Data 卷下的可执行路径。
    private static func preferDataVolumeExecutable(_ path: String) -> String {
        let dataPath = "/System/Volumes/Data" + path
        if FileManager.default.isExecutableFile(atPath: dataPath) {
            return dataPath
        }
        return path
    }
    
    /// GUI 应用默认 PATH 往往不含 Homebrew，需在查找命令时前置 `/opt/homebrew/bin` 等。
    private static let homebrewPathPrefix = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin"
    
    private static func which(_ name: String, prependHomebrewToPATH: Bool) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [name]
        if prependHomebrewToPATH {
            var env = ProcessInfo.processInfo.environment
            let base = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = homebrewPathPrefix + ":" + base
            task.environment = env
        }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
    
    /// 与终端一致：登录 shell 的 PATH（含 `eval "$(brew shellenv)"` 等）里解析命令。
    private static func commandVLoginShell(_ name: String) -> String? {
        guard name.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
    
    /// Homebrew Cellar 内真实路径（未正确链到 `bin/` 时仍能找到）。
    private static func findInHomebrewCellar(package: String, binary: String) -> String? {
        let roots = ["/opt/homebrew/Cellar", "/usr/local/Cellar"]
        for root in roots {
            let pkg = "\(root)/\(package)"
            guard let versions = try? FileManager.default.contentsOfDirectory(atPath: pkg) else { continue }
            for ver in versions.sorted(by: >) {
                let binPath = "\(pkg)/\(ver)/bin/\(binary)"
                if FileManager.default.isExecutableFile(atPath: binPath) {
                    return binPath
                }
                let sbinPath = "\(pkg)/\(ver)/sbin/\(binary)"
                if FileManager.default.isExecutableFile(atPath: sbinPath) {
                    return sbinPath
                }
            }
        }
        return nil
    }
    
    /// Shell 单引号包裹（用于 `bash -c` 内嵌路径）。
    private static func shellSingleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    
    /// 卷名用于 `/Volumes/...` 时避免非法路径字符（与常见 NTFS 卷标规则一致）。
    private static func safeVolumeFolderName(_ volumeName: String) -> String {
        let t = volumeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "UNTITLED" }
        return t.replacingOccurrences(of: "/", with: "-")
    }
    
    /// 查找 ntfs-3g（常见 Homebrew 路径 + Cellar + 带 PATH 的 `which` + 登录 shell）
    static func findNTFS3G() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ntfs-3g",
            "/opt/homebrew/sbin/ntfs-3g",
            "/opt/homebrew/opt/ntfs-3g-mac/bin/ntfs-3g",
            "/usr/local/bin/ntfs-3g",
            "/usr/local/sbin/ntfs-3g",
            "/usr/local/opt/ntfs-3g-mac/bin/ntfs-3g"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return preferDataVolumeExecutable(path)
        }
        if let p = findInHomebrewCellar(package: "ntfs-3g-mac", binary: "ntfs-3g") {
            return preferDataVolumeExecutable(p)
        }
        if let w = which("ntfs-3g", prependHomebrewToPATH: true) {
            return preferDataVolumeExecutable(w)
        }
        if let w = commandVLoginShell("ntfs-3g") {
            return preferDataVolumeExecutable(w)
        }
        return nil
    }
    
    /// macOS 上 `/dev/disk*` 为**块设备**，`/dev/rdisk*` 为 raw **字符设备**。Homebrew 的 `mkntfs` 会校验块设备（报错「not a block device」），故必须传 `/dev/diskXsY`，不能传 `rdisk`。
    private static func mkntfsBlockDevicePath(_ devicePath: String) -> String {
        let p = devicePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.hasPrefix("/dev/rdisk") else { return p }
        let block = p.replacingOccurrences(of: "/dev/rdisk", with: "/dev/disk")
        return FileManager.default.fileExists(atPath: block) ? block : p
    }
    
    /// 格式化前尽量卸载分区：与读写挂载类似，顺序 `diskutil unmount force` → `umount -f`，避免仍挂载时 mkntfs 失败。
    private static func unmountPartitionBeforeMkntfs(partitionIdentifier: String, devicePath: String, password: String) async throws {
        let qId = shellSingleQuoted(partitionIdentifier)
        let qDev = shellSingleQuoted(devicePath)
        let script = """
        set +e
        diskutil unmount force \(qId) 2>/dev/null
        sleep 0.4
        umount -f \(qDev) 2>/dev/null
        sleep 0.4
        exit 0
        """
        try await runSudo(["/bin/bash", "-c", script], password: password, timeout: 60)
    }
    
    /// 查找 mkntfs（与 `findNTFS3G` 相同策略；gromgit 公式偶发未链到 `bin/`）
    static func findMkntfs() -> String? {
        let paths = [
            "/opt/homebrew/bin/mkntfs",
            "/opt/homebrew/sbin/mkntfs",
            "/opt/homebrew/opt/ntfs-3g-mac/bin/mkntfs",
            "/usr/local/bin/mkntfs",
            "/usr/local/sbin/mkntfs",
            "/usr/local/opt/ntfs-3g-mac/bin/mkntfs"
        ]
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            return preferDataVolumeExecutable(path)
        }
        if let p = findInHomebrewCellar(package: "ntfs-3g-mac", binary: "mkntfs") {
            return preferDataVolumeExecutable(p)
        }
        if let w = which("mkntfs", prependHomebrewToPATH: true) {
            return preferDataVolumeExecutable(w)
        }
        if let w = commandVLoginShell("mkntfs") {
            return preferDataVolumeExecutable(w)
        }
        return nil
    }
    
    /// 列表里的 `PartitionInfo` 可能只来自 `diskutil list -plist`，文件系字段不全；用 `diskutil info -plist` 再核一次是否与所选格式一致（与 DriveDetector NTFS 判定对齐）。
    static func partitionMatchesFormatViaDiskutilInfo(partitionIdentifier: String, format: DiskFormatKind) async -> Bool {
        do {
            let output = try await ProcessExecutor.run("diskutil", arguments: ["info", "-plist", partitionIdentifier])
            guard let data = output.data(using: .utf8),
                  let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                return false
            }
            switch format {
            case .ntfs:
                return NTFSDetection.plistIndicatesNTFS(plist)
            case .exfat, .apfs, .hfsJournaled, .fat32:
                let fs = [
                    plist["FilesystemType"] as? String ?? "",
                    plist["FilesystemName"] as? String ?? "",
                    plist["FilesystemUserVisibleName"] as? String ?? "",
                    plist["Filesystem"] as? String ?? "",
                    plist["FileSystem"] as? String ?? ""
                ].joined(separator: " ")
                let content = (plist["Content"] as? String) ?? ""
                return DiskFormatKind.volumeMatchesExpected(fileSystem: fs, partitionContent: content, expected: format)
            }
        } catch {
            return false
        }
    }
    
    /// 先 `diskutil mount`；若失败（常见为卷需只读或轻微损坏），按系统提示再试 `diskutil mount readOnly`。
    private static func diskutilMountWithReadOnlyFallback(partitionIdentifier: String, timeout: TimeInterval = 120) async throws -> String {
        logger.info("diskutil mount \(partitionIdentifier)")
        do {
            let out = try await ProcessExecutor.run("diskutil", arguments: ["mount", partitionIdentifier], timeout: timeout)
            let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "已挂载：\(partitionIdentifier)" : t
        } catch let error as ProcessError {
            guard case .failed(let code, _) = error, code == 1 else { throw error }
            logger.info("diskutil mount 失败 (exit 1)，重试 readOnly: \(partitionIdentifier)")
            let out2 = try await ProcessExecutor.run("diskutil", arguments: ["mount", "readOnly", partitionIdentifier], timeout: timeout)
            let t2 = out2.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = t2.isEmpty ? "已以只读方式挂载：\(partitionIdentifier)" : t2
            return "\(detail)\n（标准挂载未成功，已改用系统只读挂载。）"
        }
    }
    
    /// 使用系统 `diskutil mount` 挂载卷（NTFS 一般为只读；ExFAT、APFS 等由系统决定）。通常**无需管理员密码**。
    static func mountVolumeSystem(partitionIdentifier: String) async throws -> String {
        try await diskutilMountWithReadOnlyFallback(partitionIdentifier: partitionIdentifier, timeout: 120)
    }
    
    /// 挂载 NTFS 为读写模式（ntfs-3g：local、allow_other、auto_xattr、remove_hiberfile、noatime）
    static func mountReadWrite(drive: DriveInfo, ntfs3gPath: String, password: String) async throws -> String {
        let devicePath = drive.devicePath
        let folder = safeVolumeFolderName(drive.volumeName)
        let mountPoint = "/Volumes/\(folder)"
        
        /// 单次 `sudo` 内顺序执行 `umount` → `mkdir` → `ntfs-3g`，避免连续两次 `sudo` 进程各自认证（用户会感觉要输两次密码）。
        let qDev = shellSingleQuoted(devicePath)
        let qMp = shellSingleQuoted(mountPoint)
        let qBin = shellSingleQuoted(ntfs3gPath)
        let qVol = shellSingleQuoted(folder)
        let script = """
        set +e
        umount -f \(qDev) 2>/dev/null
        sleep 0.5
        mkdir -p \(qMp)
        set -e
        exec \(qBin) \(qDev) \(qMp) -o local -o allow_other -o auto_xattr -o remove_hiberfile -o noatime -o volname=\(qVol)
        """
        logger.info("单次 sudo：卸载只读挂载后执行 ntfs-3g: \(devicePath) -> \(mountPoint)")
        try await runSudo(["/bin/bash", "-c", script], password: password, timeout: 45)
        
        try? await ProcessExecutor.run("killall", arguments: ["Finder"])
        
        return "已挂载为读写模式: \(folder)"
    }
    
    /// 推出卷（diskutil / umount）
    static func unmount(drive: DriveInfo, password: String) async throws -> String {
        let devicePath = drive.devicePath
        let partId = drive.partitionIdentifier
        logger.info("卸载设备: \(devicePath)")
        
        let qId = shellSingleQuoted(partId)
        let qDev = shellSingleQuoted(devicePath)
        let script = """
        if diskutil unmount force \(qId) 2>/dev/null; then exit 0; fi
        if umount -f \(qDev) 2>/dev/null; then exit 0; fi
        exit 1
        """
        try await runSudo(["/bin/bash", "-c", script], password: password)
        
        let folder = safeVolumeFolderName(drive.volumeName)
        let mountPoint = "/Volumes/\(folder)"
        try? FileManager.default.removeItem(atPath: mountPoint)
        
        return "已推出: \(drive.volumeName)"
    }
    
    /// 推出设备（完全断开）
    static func eject(drive: DriveInfo, password: String) async throws -> String {
        try? await unmount(drive: drive, password: password)
        try await Task.sleep(nanoseconds: 500_000_000)
        
        try await ProcessExecutor.run("diskutil", arguments: ["eject", drive.diskIdentifier])
        return "已安全移除: \(drive.volumeName)"
    }
    
    /// 将分区格式化为 NTFS（会清除全部数据）
    static func formatPartitionAsNTFS(partitionIdentifier: String, devicePath: String, volumeLabel: String, password: String) async throws -> String {
        guard let mkntfs = findMkntfs() else {
            throw ProcessError.notFound("mkntfs")
        }
        let label = volumeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            throw ProcessError.failed(1, "卷标不能为空")
        }
        logger.info("卸载分区以格式化: \(partitionIdentifier)")
        let blockDev = mkntfsBlockDevicePath(devicePath)
        try await unmountPartitionBeforeMkntfs(partitionIdentifier: partitionIdentifier, devicePath: blockDev, password: password)
        let args = [mkntfs, "-f", "-Q", "-L", label, blockDev]
        logger.info("执行 mkntfs: \(blockDev)")
        try await runSudo(args, password: password, timeout: 600)
        return "已格式化为 NTFS，卷标：\(label)"
    }
    
    /// 将分区格式化为指定主流格式（NTFS 使用 mkntfs，其余使用 `diskutil eraseVolume`）
    static func formatPartition(partitionIdentifier: String, devicePath: String, format: DiskFormatKind, volumeName: String, password: String) async throws -> String {
        let name = DiskFormatKind.sanitizedVolumeName(volumeName)
        switch format {
        case .ntfs:
            return try await formatPartitionAsNTFS(partitionIdentifier: partitionIdentifier, devicePath: devicePath, volumeLabel: name, password: password)
        default:
            let personality = format.diskutilPersonality
            guard !personality.isEmpty else {
                throw ProcessError.failed(1, "内部错误：未指定 diskutil 格式")
            }
            logger.info("diskutil eraseVolume \(personality) → \(partitionIdentifier)")
            try? await runSudo(["diskutil", "unmount", "force", partitionIdentifier], password: password)
            try await Task.sleep(nanoseconds: 500_000_000)
            try await runSudo(["diskutil", "eraseVolume", personality, name, partitionIdentifier], password: password, timeout: 600)
            return "已格式化为 \(format.shortName)，名称：\(name)"
        }
    }
    
    /// 整盘格式化为指定类型（NTFS 为既有 MBR+mkntfs 流程；其余为 `diskutil eraseDisk` + GPT）
    static func formatWholeDisk(diskIdentifier: String, format: DiskFormatKind, volumeName: String, password: String) async throws -> String {
        let name = DiskFormatKind.sanitizedVolumeName(volumeName)
        switch format {
        case .ntfs:
            return try await formatWholeDiskAsNTFS(diskIdentifier: diskIdentifier, volumeLabel: name, password: password)
        default:
            guard diskIdentifier.range(of: #"^disk\d+$"#, options: .regularExpression) != nil else {
                throw ProcessError.failed(1, "整盘格式化请使用磁盘标识（如 disk4），不能使用分区标识")
            }
            let personality = format.diskutilPersonality
            guard !personality.isEmpty else {
                throw ProcessError.failed(1, "内部错误：未指定 diskutil 格式")
            }
            logger.info("diskutil eraseDisk \(personality) GPT \(diskIdentifier)")
            try? await runSudo(["diskutil", "unmountDisk", "force", diskIdentifier], password: password)
            try await Task.sleep(nanoseconds: 500_000_000)
            try await runSudo(["diskutil", "eraseDisk", personality, name, "GPTFormat", diskIdentifier], password: password, timeout: 600)
            return "已将整盘格式化为 \(format.shortName)，名称：\(name)"
        }
    }
    
    /// 使用 `diskutil partitionDisk` 重新划分整块磁盘（**清除盘上全部数据**）。  
    /// NTFS 仅支持单分区：`diskutil` 先建 ExFAT 占位卷，再对该分区执行 `mkntfs`。
    static func repartitionWholeDisk(
        diskIdentifier: String,
        scheme: PartitionDiskScheme,
        preset: PartitionDiskPreset,
        filesystem: PartitionDiskFilesystem,
        volumeNameBase: String,
        password: String
    ) async throws -> String {
        guard diskIdentifier.range(of: #"^disk\d+$"#, options: .regularExpression) != nil else {
            throw ProcessError.failed(1, "分区请使用整块磁盘标识（如 disk4）")
        }
        if filesystem == .ntfs, preset != .single {
            throw ProcessError.failed(1, "NTFS 仅支持「单分区」布局。多分区请先选 ExFAT/FAT32 等，再对各分区使用「格式化」选 NTFS。")
        }
        let baseRaw = volumeNameBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBase = DiskFormatKind.sanitizedVolumeName(baseRaw)
        let names: [String] = (0..<preset.partitionCount).map { i in
            if preset.partitionCount == 1 { return safeBase }
            return i == 0 ? safeBase : "\(safeBase)\(i + 1)"
        }
        let triplets = preset.partitionTriplets(filesystemPersonality: filesystem.diskutilPersonality, volumeNames: names)
        var args: [String] = ["diskutil", "partitionDisk", diskIdentifier, scheme.rawValue]
        for t in triplets {
            args.append(t.0)
            args.append(t.1)
            args.append(t.2)
        }
        let fsLog = filesystem == .ntfs ? "NTFS(via ExFAT+mkntfs)" : filesystem.diskutilPersonality
        logger.info("partitionDisk \(diskIdentifier) scheme=\(scheme.rawValue) count=\(preset.partitionCount) fs=\(fsLog)")
        try? await runSudo(["diskutil", "unmountDisk", "force", diskIdentifier], password: password)
        try await Task.sleep(nanoseconds: 500_000_000)
        try await runSudo(args, password: password, timeout: 1800)
        
        if filesystem == .ntfs {
            guard let mkntfs = findMkntfs() else {
                throw ProcessError.notFound("mkntfs")
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let sliceId = try await primaryDataPartitionIdentifier(forWholeDisk: diskIdentifier)
            let blockPath = mkntfsBlockDevicePath("/dev/\(sliceId)")
            logger.info("分区占位完成后 mkntfs: \(blockPath)")
            try await unmountPartitionBeforeMkntfs(partitionIdentifier: sliceId, devicePath: blockPath, password: password)
            try await runSudo([mkntfs, "-f", "-Q", "-L", safeBase, blockPath], password: password, timeout: 600)
            return "已对 \(diskIdentifier) 分区并写入 NTFS，卷标：\(safeBase)（\(sliceId)）。"
        }
        
        return "已对 \(diskIdentifier) 重新分区，共 \(preset.partitionCount) 个卷。"
    }
    
    /// 整盘重新分区后，从 `diskutil list -plist` 中取用于格式化的主数据分区（跳过 EFI 等）。
    private static func plistInt64(_ value: Any?) -> Int64? {
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
    
    /// 整块磁盘格式化为 **单分区 NTFS**：先 `diskutil eraseDisk` 建立 MBR + FAT32 占位分区，再对该分区执行 `mkntfs`。
    /// - Note: `diskutil` 不允许抹掉启动磁盘；标识须为整块盘（如 `disk4`，不能是 `disk4s2`）。
    static func formatWholeDiskAsNTFS(diskIdentifier: String, volumeLabel: String, password: String) async throws -> String {
        guard diskIdentifier.range(of: #"^disk\d+$"#, options: .regularExpression) != nil else {
            throw ProcessError.failed(1, "整盘格式化请使用磁盘标识（如 disk4），不能使用分区标识（如 disk4s1）")
        }
        guard let mkntfs = findMkntfs() else {
            throw ProcessError.notFound("mkntfs")
        }
        let label = volumeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            throw ProcessError.failed(1, "卷标不能为空")
        }
        logger.info("整盘抹掉并重建分区表: \(diskIdentifier)")
        try? await runSudo(["diskutil", "unmountDisk", "force", diskIdentifier], password: password)
        try await Task.sleep(nanoseconds: 500_000_000)
        let tempVolName = "NTFSPREP"
        try await runSudo(
            ["diskutil", "eraseDisk", "FAT32", tempVolName, "MBRFormat", diskIdentifier],
            password: password,
            timeout: 600
        )
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let sliceId = try await primaryDataPartitionIdentifier(forWholeDisk: diskIdentifier)
        logger.info("对重建后的分区执行 mkntfs: \(sliceId)")
        let blockPath = mkntfsBlockDevicePath("/dev/\(sliceId)")
        try await unmountPartitionBeforeMkntfs(partitionIdentifier: sliceId, devicePath: blockPath, password: password)
        try await runSudo([mkntfs, "-f", "-Q", "-L", label, blockPath], password: password, timeout: 600)
        return "已整盘格式化为 NTFS，卷标：\(label)（分区 \(sliceId)）"
    }
    
    private static func primaryDataPartitionIdentifier(forWholeDisk diskIdentifier: String) async throws -> String {
        let output = try await ProcessExecutor.run("diskutil", arguments: ["list", "-plist"])
        guard let data = output.data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let all = plist["AllDisksAndPartitions"] as? [[String: Any]],
              let diskEntry = all.first(where: { ($0["DeviceIdentifier"] as? String) == diskIdentifier }) else {
            throw ProcessError.failed(1, "无法在 list 中找到磁盘 \(diskIdentifier)")
        }
        let parts = diskEntry["Partitions"] as? [[String: Any]] ?? []
        let candidates = parts.filter { part in
            let content = (part["Content"] as? String ?? "").lowercased()
            if content.contains("efi") { return false }
            if content.contains("apple_efi") { return false }
            return true
        }
        guard let best = candidates.max(by: { a, b in
            (plistInt64(a["Size"]) ?? 0) < (plistInt64(b["Size"]) ?? 0)
        }), let pid = best["DeviceIdentifier"] as? String else {
            throw ProcessError.failed(1, "未找到可格式化的数据分区（\(diskIdentifier)）")
        }
        return pid
    }
    
    /// 系统启动卷所在整块磁盘（`diskutil info /` 的 `ParentWholeDisk`），用于隐藏整盘格式化入口。
    static func bootParentWholeDiskIdentifier() async -> String? {
        do {
            let output = try await ProcessExecutor.run("diskutil", arguments: ["info", "-plist", "/"])
            guard let data = output.data(using: .utf8),
                  let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                return nil
            }
            return plist["ParentWholeDisk"] as? String
        } catch {
            return nil
        }
    }
    
    /// 还原为系统只读挂载
    static func restoreReadOnly(drive: DriveInfo, password: String) async throws -> String {
        try? await runSudo(["umount", "-f", drive.devicePath], password: password)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        try await ProcessExecutor.run("diskutil", arguments: ["mount", "readOnly", drive.partitionIdentifier], timeout: 120)
        
        return "已还原为只读模式: \(drive.volumeName)"
    }
    
    // MARK: - sudo
    
    /// 控制台 / Console.app 用：避免过长 bash -c 脚本撑爆日志
    private static func truncatedForLog(_ s: String, maxLen: Int = 2000) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= maxLen { return t }
        return String(t.prefix(maxLen)) + "…(共\(t.count)字符)"
    }
    
    private static func sudoArgsSummary(_ args: [String]) -> String {
        let j = args.joined(separator: " ")
        if j.count <= 1200 { return j }
        return String(j.prefix(1200)) + "…(truncated, \(j.count) chars)"
    }
    
    /// mkntfs 常把 CHS/几何与「Windows 无法从此设备启动」等信息打到 stderr，在 GPT + mac 上属正常提示，退出码仍为 0。
    private static func stderrIsBenignMkntfsSuccessNoise(_ stderr: String) -> Bool {
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if lines.isEmpty { return true }
        for line in lines {
            let l = line.lowercased()
            let benign =
                l.contains("partition start sector was not specified")
                || l.contains("sectors per track was not specified")
                || l.contains("number of heads was not specified")
                || l.contains("it has been set to 0")
                || l.contains("to boot from a device, windows needs")
                || l.contains("windows will not be able to boot from this device")
            if !benign { return false }
        }
        return true
    }
    
    private static func runSudo(_ args: [String], password: String, timeout: TimeInterval? = nil) async throws -> String {
        let task = Process()
        task.launchPath = "/usr/bin/sudo"
        task.arguments = ["-S"] + args
        
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardInput = inPipe
        task.standardOutput = outPipe
        task.standardError = errPipe
        
        var timeoutWork: DispatchWorkItem?
        if let seconds = timeout {
            let work = DispatchWorkItem {
                if task.isRunning {
                    task.terminate()
                }
            }
            timeoutWork = work
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds, execute: work)
        }
        
        do {
            try task.run()
        } catch {
            logger.error("sudo 无法启动进程 args=\(sudoArgsSummary(args), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
        
        if let data = (password + "\n").data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
            inPipe.fileHandleForWriting.closeFile()
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            task.terminationHandler = { process in
                timeoutWork?.cancel()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                
                if process.terminationStatus == 0 {
                    let out = String(data: outData, encoding: .utf8) ?? ""
                    let errTrim = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !errTrim.isEmpty {
                        let el = errTrim.lowercased()
                        // 个别工具在失败时仍返回 0；mkntfs 等若 stderr 已明确拒绝则视为失败
                        if el.contains("refusing to make") || el.contains("not a block device") {
                            logger.error("sudo 退出码 0 但 stderr 表明失败 args=\(sudoArgsSummary(args), privacy: .public) stderr=\(truncatedForLog(errTrim), privacy: .public)")
                            continuation.resume(throwing: ProcessError.failed(1, errTrim))
                            return
                        }
                        if !stderrIsBenignMkntfsSuccessNoise(errTrim) {
                            logger.warning("sudo 退出码 0 但 stderr 非空 args=\(sudoArgsSummary(args), privacy: .public) stderr=\(truncatedForLog(errTrim), privacy: .public)")
                        }
                    }
                    continuation.resume(returning: out)
                } else {
                    if process.terminationStatus == 15 || process.terminationStatus == 9 {
                        logger.error("sudo 超时（进程被终止）exit=\(process.terminationStatus) args=\(sudoArgsSummary(args), privacy: .public)")
                        continuation.resume(throwing: ProcessError.timeout)
                    } else if stderr.contains("password") || stderr.contains("Sorry") {
                        logger.error("sudo 密码或授权失败 exit=\(process.terminationStatus) args=\(sudoArgsSummary(args), privacy: .public) stderr=\(truncatedForLog(stderr), privacy: .public)")
                        continuation.resume(throwing: ProcessError.authorizationFailed)
                    } else {
                        let stdout = String(data: outData, encoding: .utf8) ?? ""
                        let merged = [stderr, stdout]
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n")
                        let detail = merged.isEmpty ? stderr : merged
                        logger.error("sudo 命令失败 exit=\(process.terminationStatus) args=\(sudoArgsSummary(args), privacy: .public) output=\(truncatedForLog(detail), privacy: .public)")
                        continuation.resume(throwing: ProcessError.failed(process.terminationStatus, detail))
                    }
                }
            }
        }
    }
}
