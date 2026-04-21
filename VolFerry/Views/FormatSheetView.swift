import os.log
import SwiftUI

private enum FormatSheetLog {
    static let logger = Logger(subsystem: VolFerryApp.subsystem, category: "FormatSheet")
}

struct FormatSheetView: View {
    @EnvironmentObject private var detector: DriveDetector
    @EnvironmentObject private var auth: AuthManager
    @Binding var isPresented: Bool
    /// 固定目标：`p:` + 分区 id，或 `d:` + 整块磁盘 id（由设备树传入，不可在面板内更改）
    let formatTargetTag: String
    
    @AppStorage(VolFerryUserDefaults.Key.appearanceMode) private var appearanceRaw = "system"
    /// 默认格式随**当前选中的磁盘/分区**推断，不记忆上一次在其它盘上的选择
    @State private var formatKindRaw: String = DiskFormatKind.ntfs.rawValue
    /// 抹掉后新卷名称（用户可编辑）。每次打开面板时默认填入**当前选中磁盘**的展示名（与设备树一致），不跨磁盘记忆。
    @State private var volumeNameChoice = ""
    @AppStorage(VolFerryUserDefaults.Key.saveAdminPasswordToKeychain) private var saveAdminPasswordToKeychain = true
    
    @State private var showAdminPasswordSheet = false
    @State private var adminPasswordSheetField = ""
    @State private var toastMessage: String?
    /// Toast 消失后是否关闭面板并刷新列表（仅格式化成功）
    @State private var toastSuccessClosesSheet = false
    @State private var isFormatting = false
    @State private var systemAppearanceRevision = 0
    
    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }
    
    private var dark: Bool {
        _ = systemAppearanceRevision
        return appearanceMode.resolvedIsDark()
    }
    
    private var selectedFormat: DiskFormatKind {
        DiskFormatKind(rawValue: formatKindRaw) ?? .ntfs
    }
    
    /// 提交给 diskutil / mkntfs 的名称；空或全空白时回退为 UNTITLED
    private var resolvedVolumeName: String {
        let t = volumeNameChoice.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "UNTITLED" : t
    }
    
    /// 与设备树、整盘格式化一致：用磁盘展示名（去掉常见「… Media」后缀）经 `sanitizedVolumeName` 得到默认卷标
    private func normalizedDiskVolumeNameLabel(for disk: DiskInfo) -> String {
        var n = disk.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.hasSuffix(" Media") {
            n = String(n.dropLast(" Media".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !n.isEmpty else { return "" }
        return DiskFormatKind.sanitizedVolumeName(n)
    }
    
    /// 从当前 `formatTargetTag` 解析出的默认卷标：**整盘与分区均优先用父磁盘名称**（无磁盘名时再回退分区卷名）
    private var suggestedVolumeNameForCurrentTarget: String {
        if formatTargetTag.hasPrefix("p:") {
            let partId = String(formatTargetTag.dropFirst(2))
            for disk in detector.allDisks {
                guard let p = disk.partitions.first(where: { $0.identifier == partId }) else { continue }
                let fromDisk = normalizedDiskVolumeNameLabel(for: disk)
                if !fromDisk.isEmpty { return fromDisk }
                let n = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if n.isEmpty || n == "(未命名)" { return "UNTITLED" }
                return DiskFormatKind.sanitizedVolumeName(n)
            }
        } else if formatTargetTag.hasPrefix("d:") {
            let diskId = String(formatTargetTag.dropFirst(2))
            if let disk = detector.allDisks.first(where: { $0.identifier == diskId }) {
                let n = normalizedDiskVolumeNameLabel(for: disk)
                return n.isEmpty ? "UNTITLED" : n
            }
        }
        return "UNTITLED"
    }
    
    /// 按当前 `formatTargetTag` 从 `detector` 解析分区/整盘，设置格式下拉为**该目标当前文件系统类型**
    private func applyInferredFormatKindFromCurrentTarget() {
        let kind: DiskFormatKind
        if formatTargetTag.hasPrefix("p:") {
            let partId = String(formatTargetTag.dropFirst(2))
            if let p = detector.allDisks.flatMap(\.partitions).first(where: { $0.identifier == partId }) {
                kind = DiskFormatKind.inferredDefault(fileSystem: p.fileSystem, partitionContent: p.type)
            } else {
                kind = .ntfs
            }
        } else if formatTargetTag.hasPrefix("d:") {
            let diskId = String(formatTargetTag.dropFirst(2))
            if let disk = detector.allDisks.first(where: { $0.identifier == diskId }) {
                kind = DiskFormatKind.inferredDefaultForPartitions(disk.partitions)
            } else {
                kind = .ntfs
            }
        } else {
            kind = .ntfs
        }
        formatKindRaw = kind.rawValue
    }
    
    /// 与设备树中选中项对应的只读说明行
    private var formatTargetDescription: String {
        if formatTargetTag.hasPrefix("d:") {
            let id = String(formatTargetTag.dropFirst(2))
            if let disk = detector.allDisks.first(where: { $0.identifier == id }) {
                return "整块磁盘 · \(disk.name)（\(disk.identifier)）· \(disk.sizeFormatted)"
            }
            return "整块磁盘（\(id)）"
        }
        if formatTargetTag.hasPrefix("p:") {
            let id = String(formatTargetTag.dropFirst(2))
            for disk in detector.allDisks {
                if let p = disk.partitions.first(where: { $0.identifier == id }) {
                    return "分区 · \(disk.name) — \(p.name)（\(p.identifier)）· \(p.sizeFormatted)"
                }
            }
            return "分区（\(id)）"
        }
        return formatTargetTag
    }
    
    private var isWholeDiskTarget: Bool {
        formatTargetTag.hasPrefix("d:")
    }
    
    /// 与「格式」「名称」左列同宽，保证两行 label 竖向对齐
    private let formatFormLabelColumnWidth: CGFloat = 96
    /// 「格式」弹出按钮与「名称」输入框同一行高（贴近系统偏好设置里的表单行，不宜过大）
    private let formatRowControlHeight: CGFloat = 28
    
    private func formRowLabel(_ title: String) -> some View {
        Text(title)
            .font(.title2.weight(.semibold))
            .foregroundStyle(VolFerryTheme.textPrimary(dark))
            .frame(width: formatFormLabelColumnWidth, alignment: .leading)
            .textSelectable()
    }
    
    private var adminPasswordHintRow: some View {
        Label {
            Text(auth.hasSavedPassword ? "已保存管理员密码，点击「开始格式化」将直接执行。" : "未保存密码时，将在下一步弹窗中输入管理员密码。")
                .font(.body)
                .foregroundStyle(VolFerryTheme.textSecondary(dark))
                .fixedSize(horizontal: false, vertical: true)
                .textSelectable()
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(VolFerryTheme.accent)
        }
        .labelStyle(.titleAndIcon)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VolFerryTheme.bgTertiary(dark), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    
    /// 醒目展示当前将格式化的目标（设备树传入，只读）
    @ViewBuilder
    private var formatTargetHero: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(VolFerryTheme.accent)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: isWholeDiskTarget ? "internaldrive.fill" : "externaldrive.fill")
                        .font(.title2)
                        .foregroundStyle(VolFerryTheme.accent)
                    Text("格式化目标")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(VolFerryTheme.textPrimary(dark))
                        .textSelectable()
                }
                Text(formatTargetDescription)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(VolFerryTheme.textPrimary(dark))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelectable()
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(VolFerryTheme.accent.opacity(dark ? 0.16 : 0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(VolFerryTheme.accent.opacity(dark ? 0.5 : 0.38), lineWidth: 1.5)
        )
    }
    
    var body: some View {
        ZStack {
            VolFerryTheme.bgPrimary(dark).ignoresSafeArea()
            WindowAppearanceBridge(mode: appearanceMode)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 16) {
                Text("卷与磁盘格式化")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(VolFerryTheme.textPrimary(dark))
                    .textSelectable()
                Text("目标由设备列表中的选择确定，不可更改。NTFS 需已安装 mkntfs；其余由系统 diskutil 执行。将清空所选范围内的数据。")
                    .font(.body)
                    .foregroundStyle(VolFerryTheme.textSecondary(dark))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelectable()
                
                formatTargetHero
                
                HStack(alignment: .center, spacing: 12) {
                    formRowLabel("格式")
                    FormatPopUpPicker(selectionRaw: $formatKindRaw, useDarkAppearance: dark)
                        .frame(maxWidth: .infinity)
                        .frame(height: formatRowControlHeight)
                        .accessibilityLabel("文件系统格式")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                formatDescriptionCard(kind: selectedFormat)
                
                HStack(alignment: .center, spacing: 12) {
                    formRowLabel("名称")
                    TextField("", text: $volumeNameChoice, prompt: Text("UNTITLED").foregroundStyle(VolFerryTheme.textSecondary(dark).opacity(0.75)))
                        .textFieldStyle(.plain)
                        .font(.body.weight(.medium))
                        .foregroundStyle(VolFerryTheme.textPrimary(dark))
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity)
                        .frame(height: formatRowControlHeight)
                        .background(VolFerryTheme.bgTertiary(dark), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityLabel("新卷名称")
                        .help(isWholeDiskTarget ? "整盘抹掉后，新卷将使用该名称作为默认卷名。" : "抹掉分区后新卷的显示名称。")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                adminPasswordHintRow
                HStack {
                    Button {
                        isPresented = false
                    } label: {
                        Text("取消").textSelectable()
                    }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .tint(VolFerryTheme.accent)
                    .pointingHandOnHover()
                    Spacer()
                    Button {
                        if let pw = auth.loadPassword(), !pw.isEmpty {
                            Task { await formatWithPassword(pw) }
                        } else {
                            adminPasswordSheetField = ""
                            showAdminPasswordSheet = true
                        }
                    } label: {
                        Text("开始格式化").textSelectable()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(VolFerryTheme.accent)
                    .disabled(formatTargetTag.isEmpty || isFormatting)
                    .pointingHandOnHover(enabled: !formatTargetTag.isEmpty && !isFormatting)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .frame(minWidth: 560)
        }
        .onReceive(NotificationCenter.default.publisher(for: .systemEffectiveAppearanceChanged)) { _ in
            systemAppearanceRevision += 1
        }
        .sheet(isPresented: $showAdminPasswordSheet) {
            FormatAdminPasswordSheet(
                password: $adminPasswordSheetField,
                dark: dark,
                saveToKeychainOnConfirm: saveAdminPasswordToKeychain,
                onCancel: {
                    showAdminPasswordSheet = false
                    adminPasswordSheetField = ""
                },
                onConfirm: { pw in
                    showAdminPasswordSheet = false
                    adminPasswordSheetField = ""
                    Task { await formatWithPassword(pw) }
                }
            )
        }
        .onAppear {
            applyInferredFormatKindFromCurrentTarget()
            volumeNameChoice = suggestedVolumeNameForCurrentTarget
        }
        .onChange(of: formatTargetTag) { _, _ in
            applyInferredFormatKindFromCurrentTarget()
            volumeNameChoice = suggestedVolumeNameForCurrentTarget
        }
        .volFerryToast(message: $toastMessage, dark: dark) {
            let close = toastSuccessClosesSheet
            toastSuccessClosesSheet = false
            if close {
                isPresented = false
                Task { await detector.refresh() }
            }
        }
        .overlay {
            if isFormatting {
                ZStack {
                    Color.black.opacity(dark ? 0.42 : 0.24)
                        .ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                            .scaleEffect(1.05)
                        Text("正在格式化…")
                            .font(.body.weight(.medium))
                            .foregroundStyle(VolFerryTheme.textPrimary(dark))
                            .textSelectable()
                    }
                    .padding(26)
                    .frame(minWidth: 260, maxWidth: 380)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(VolFerryTheme.bgSecondary(dark))
                            .shadow(color: .black.opacity(dark ? 0.35 : 0.18), radius: 28, y: 12)
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(true)
            }
        }
    }
    
    @ViewBuilder
    private func formatDescriptionCard(kind: DiskFormatKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                Text(kind.scenario)
                Text(kind.pros)
                Text(kind.cons)
            }
            .font(.callout)
            .foregroundStyle(VolFerryTheme.textSecondary(dark))
            .fixedSize(horizontal: false, vertical: true)
            .textSelectable()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VolFerryTheme.bgSecondary(dark), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(VolFerryTheme.border(dark).opacity(0.55), lineWidth: 1)
        )
    }
    
    /// 刷新 `detector` 后核对格式；列表项可能缺文件系字段，再调用 `diskutil info` 与 DriveDetector 的 NTFS 判定对齐。
    private func verifyFormattedVolumeMatchesExpected(expected: DiskFormatKind) async -> Bool {
        if formatTargetTag.hasPrefix("p:") {
            let partId = String(formatTargetTag.dropFirst(2))
            if let part = detector.allDisks.flatMap(\.partitions).first(where: { $0.identifier == partId }),
               DiskFormatKind.volumeMatchesExpected(part, expected) {
                return true
            }
            return await MountManager.partitionMatchesFormatViaDiskutilInfo(partitionIdentifier: partId, format: expected)
        }
        if formatTargetTag.hasPrefix("d:") {
            let diskId = String(formatTargetTag.dropFirst(2))
            guard let disk = detector.allDisks.first(where: { $0.identifier == diskId }),
                  let part = Self.largestNonEFIDataPartition(in: disk) else {
                return false
            }
            if DiskFormatKind.volumeMatchesExpected(part, expected) {
                return true
            }
            return await MountManager.partitionMatchesFormatViaDiskutilInfo(partitionIdentifier: part.identifier, format: expected)
        }
        return false
    }
    
    private static func largestNonEFIDataPartition(in disk: DiskInfo) -> PartitionInfo? {
        let data = disk.partitions.filter { p in
            let t = p.type.lowercased()
            if t.contains("partition_scheme") || t.contains("partition_map") { return false }
            if t.contains("efi") && t.contains("system") { return false }
            if t == "efi" { return false }
            return p.size > 0
        }
        return data.max(by: { $0.size < $1.size })
    }
    
    private func formatWithPassword(_ rawPassword: String) async {
        let pw = rawPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pw.isEmpty else {
            toastSuccessClosesSheet = false
            toastMessage = "需要管理员密码。"
            return
        }
        guard !formatTargetTag.isEmpty else {
            toastSuccessClosesSheet = false
            toastMessage = "未指定格式化目标"
            return
        }
        let kind = DiskFormatKind(rawValue: formatKindRaw) ?? .ntfs
        await MainActor.run { isFormatting = true }
        defer { Task { @MainActor in isFormatting = false } }
        do {
            let msg: String
            if formatTargetTag.hasPrefix("d:") {
                let diskId = String(formatTargetTag.dropFirst(2))
                msg = try await MountManager.formatWholeDisk(
                    diskIdentifier: diskId,
                    format: kind,
                    volumeName: resolvedVolumeName,
                    password: pw
                )
            } else if formatTargetTag.hasPrefix("p:") {
                let partId = String(formatTargetTag.dropFirst(2))
                guard let part = detector.allDisks.flatMap(\.partitions).first(where: { $0.identifier == partId }) else {
                    toastSuccessClosesSheet = false
                    toastMessage = "无效的分区"
                    return
                }
                msg = try await MountManager.formatPartition(
                    partitionIdentifier: part.identifier,
                    devicePath: "/dev/\(part.identifier)",
                    format: kind,
                    volumeName: resolvedVolumeName,
                    password: pw
                )
            } else {
                toastSuccessClosesSheet = false
                toastMessage = "无效的格式化目标"
                return
            }
            // 先重扫再核对：不能仅凭返回文案判断成功（曾出现 exit 0 / 文案含「已格式」但实际未变成目标文件系统）
            await detector.refresh(showLoading: false)
            var verified = await verifyFormattedVolumeMatchesExpected(expected: kind)
            if !verified {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await detector.refresh(showLoading: false)
                verified = await verifyFormattedVolumeMatchesExpected(expected: kind)
            }
            await MainActor.run {
                if saveAdminPasswordToKeychain {
                    auth.savePassword(pw)
                }
                if verified {
                    toastSuccessClosesSheet = true
                    toastMessage = msg
                } else {
                    toastSuccessClosesSheet = false
                    toastMessage = "命令已结束，但刷新后该分区仍不是「\(kind.shortName)」。请到「磁盘工具」核对；若卷仍挂载请先推出后再试。\n\(msg)"
                }
            }
        } catch let e as ProcessError {
            FormatSheetLog.logger.error("格式化失败 target=\(self.formatTargetTag, privacy: .public) format=\(kind.rawValue, privacy: .public) ProcessError: \(e.localizedDescription, privacy: .public)")
            await MainActor.run {
                toastSuccessClosesSheet = false
                toastMessage = e.localizedDescription
            }
        } catch {
            FormatSheetLog.logger.error("格式化失败 target=\(self.formatTargetTag, privacy: .public) format=\(kind.rawValue, privacy: .public) \(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                toastSuccessClosesSheet = false
                toastMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - 格式化：管理员密码二次确认

private struct FormatAdminPasswordSheet: View {
    @Binding var password: String
    let dark: Bool
    let saveToKeychainOnConfirm: Bool
    var onCancel: () -> Void
    var onConfirm: (String) -> Void
    
    private var trimmedPassword: String {
        password.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("需要管理员密码")
                .font(.title2.weight(.semibold))
                .foregroundStyle(VolFerryTheme.textPrimary(dark))
                .textSelectable()
            Text("即将对所选目标执行格式化（sudo），数据将被清空。")
                .font(.body)
                .foregroundStyle(VolFerryTheme.textSecondary(dark))
                .fixedSize(horizontal: false, vertical: true)
                .textSelectable()
            Text("请输入本机管理员密码以授权格式化（sudo）。")
                .font(.callout)
                .foregroundStyle(VolFerryTheme.textSecondary(dark))
                .fixedSize(horizontal: false, vertical: true)
                .textSelectable()
            SecureField("管理员密码", text: $password)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(10)
                .background(VolFerryTheme.bgTertiary(dark), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(VolFerryTheme.textPrimary(dark))
            Text(saveToKeychainOnConfirm ? "点「好」后先执行格式化；成功后将密码保存到钥匙串。" : "点「好」后仅本次使用，不会写入钥匙串。可在「选项」中开启保存。")
                .font(.callout)
                .foregroundStyle(VolFerryTheme.textSecondary(dark))
                .fixedSize(horizontal: false, vertical: true)
                .textSelectable()
            HStack {
                Button(action: onCancel) {
                    Text("取消").textSelectable()
                }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .tint(VolFerryTheme.accent)
                    .pointingHandOnHover()
                Spacer()
                Button {
                    onConfirm(trimmedPassword)
                } label: {
                    Text("好").textSelectable()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(VolFerryTheme.accent)
                .disabled(trimmedPassword.isEmpty)
                .pointingHandOnHover(enabled: !trimmedPassword.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
        .background(VolFerryTheme.bgPrimary(dark))
        .preferredColorScheme(dark ? .dark : .light)
    }
}
