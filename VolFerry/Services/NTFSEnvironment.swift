import AppKit
import Foundation

/// NTFS 读写相关依赖检测与环境探测。
enum NTFSDependencyChecker {

    /// 单项检测结果（用于依赖页分行展示）
    struct CheckItem: Identifiable, Equatable {
        var id: String { key }
        let key: String
        let title: String
        let isOK: Bool
        /// 简短说明：路径或原因
        let detail: String
    }

    struct Status: Equatable {
        var items: [CheckItem]
        var ntfs3gPath: String?
        var macFUSEInstalled: Bool
        var macFUSEDetail: String
        var mkntfsPath: String?

        var readyForReadWrite: Bool {
            ntfs3gPath != nil && macFUSEInstalled
        }

        /// 抹盘 / 格式化为 NTFS 时是否需要 mkntfs
        var readyForNTFSFormat: Bool {
            mkntfsPath != nil
        }

        /// 顶栏等处的简短摘要（单行不适合时用多行）
        var summary: String {
            let n = ntfs3gPath ?? "未找到"
            let f = macFUSEInstalled ? "已检测到" : "未检测到"
            let m = mkntfsPath ?? "未找到"
            return "ntfs-3g: \(n)\n\(macFUSEDetail)\nMacFUSE: \(f)\nmkntfs: \(m)"
        }
    }

    /// Homebrew 一键安装：先 `tap`，再仅在未安装时执行 `install`，避免已装最新版时出现 `Not upgrading macfuse`、`already installed and up-to-date` 等提示。
    /// `ntfs-3g-mac` 在 brew 中可能以短名或 `gromgit/fuse/ntfs-3g-mac` 登记，需一并检测。
    static let brewInstallReadWrite = "brew tap gromgit/homebrew-fuse && (brew list --cask macfuse &>/dev/null || brew install --cask macfuse) && ((brew list --formula ntfs-3g-mac &>/dev/null || brew list --formula gromgit/fuse/ntfs-3g-mac &>/dev/null) || brew install ntfs-3g-mac)"

    /// 依赖是否已全部检测到（读写 + mkntfs）
    static func isFullyReady(_ status: Status) -> Bool {
        status.readyForReadWrite && status.readyForNTFSFormat
    }

    /// 使用终端执行 `brewInstallReadWrite`。
    /// - Parameter useWorkspaceDefault: `true` 时用 **系统为 `.command` 配置的默认应用**（访达「显示简介 → 打开方式」）；`false` 时强制用 **终端 (Terminal.app)**。
    /// 用户仍需在终端内确认密码、按提示授权 MacFUSE 等。
    /// - Returns: 是否成功启动打开流程（不代表 brew 已装完）
    @discardableResult
    static func launchTerminalHomebrewInstall(useWorkspaceDefault: Bool = true) -> Bool {
        // bash 单引号字符串内若出现 `'` 需写成 `'\''`
        let escaped = brewInstallReadWrite.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/bash
        exec /bin/bash -lc '\(escaped)'
        """
        let name = "volferry-brew-install-\(UUID().uuidString.prefix(8)).command"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            guard let data = script.data(using: .utf8) else { return false }
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            if useWorkspaceDefault {
                return NSWorkspace.shared.open(url)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", "Terminal", url.path]
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// MacFUSE 常见安装位置（任一存在即视为已安装核心组件）
    private static let macFUSEProbePaths: [String] = [
        "/Library/Filesystems/macfuse.fs",
        "/Library/Filesystems/fusefs.fs",
        "/usr/local/lib/libfuse.dylib",
        "/opt/homebrew/opt/macfuse/lib/libfuse.dylib",
        "/opt/homebrew/lib/libfuse.dylib",
        "/Library/PreferencePanes/macfuse.prefPane"
    ]

    static func currentStatus() -> Status {
        let ntfs = MountManager.findNTFS3G()
        let mk = MountManager.findMkntfs()

        var fuseOK = false
        var fuseDetail = "未在常见路径发现 MacFUSE（需安装 .pkg 或 Homebrew cask）"
        for p in macFUSEProbePaths where FileManager.default.fileExists(atPath: p) {
            fuseOK = true
            fuseDetail = "已找到：\(p)"
            break
        }

        let items: [CheckItem] = [
            CheckItem(
                key: "macfuse",
                title: "MacFUSE",
                isOK: fuseOK,
                detail: fuseDetail
            ),
            CheckItem(
                key: "ntfs3g",
                title: "ntfs-3g",
                isOK: ntfs != nil,
                detail: ntfs.map { "可执行：\($0)" } ?? "未找到（需 brew install ntfs-3g-mac 等）"
            ),
            CheckItem(
                key: "mkntfs",
                title: "mkntfs（NTFS 格式化）",
                isOK: mk != nil,
                detail: mk.map { "可执行：\($0)" } ?? "未找到（通常随 ntfs-3g-mac 提供）"
            )
        ]

        return Status(
            items: items,
            ntfs3gPath: ntfs,
            macFUSEInstalled: fuseOK,
            macFUSEDetail: fuseDetail,
            mkntfsPath: mk
        )
    }
}
