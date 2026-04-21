import os.log
import SwiftUI

private enum PartitionSheetLog {
    static let logger = Logger(subsystem: VolFerryApp.subsystem, category: "PartitionSheet")
}

/// 整块磁盘重新分区（`diskutil partitionDisk`），与「整盘格式化」入口并列。
struct PartitionSheetView: View {
    @EnvironmentObject private var detector: DriveDetector
    @EnvironmentObject private var auth: AuthManager
    @Binding var isPresented: Bool
    let diskIdentifier: String
    /// 与「格式化 NTFS」相同：需 Homebrew `mkntfs`（ntfs-3g-mac）
    let ntfsRepartitioningReady: Bool
    
    @AppStorage(VolFerryUserDefaults.Key.appearanceMode) private var appearanceRaw = "system"
    @AppStorage(VolFerryUserDefaults.Key.saveAdminPasswordToKeychain) private var saveAdminPasswordToKeychain = true
    
    @State private var scheme: PartitionDiskScheme = .gpt
    @State private var preset: PartitionDiskPreset = .single
    @State private var filesystem: PartitionDiskFilesystem = .exfat
    @State private var volumeNameBase = "UNTITLED"
    @State private var showAdminPasswordSheet = false
    @State private var adminPasswordSheetField = ""
    @State private var toastMessage: String?
    @State private var toastSuccessClosesSheet = false
    @State private var isWorking = false
    @State private var systemAppearanceRevision = 0
    
    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }
    
    private var dark: Bool {
        _ = systemAppearanceRevision
        return appearanceMode.resolvedIsDark()
    }
    
    private var disk: DiskInfo? {
        detector.allDisks.first { $0.identifier == diskIdentifier }
    }
    
    /// NTFS 不能进多分区向导；未装 mkntfs 时隐藏 NTFS
    private var filesystemChoices: [PartitionDiskFilesystem] {
        var list = Array(PartitionDiskFilesystem.allCases)
        if preset != .single {
            list.removeAll { $0 == .ntfs }
        }
        if !ntfsRepartitioningReady {
            list.removeAll { $0 == .ntfs }
        }
        return list
    }
    
    private var canStartPartition: Bool {
        guard disk != nil, !diskIdentifier.isEmpty, !isWorking else { return false }
        guard filesystemChoices.contains(filesystem) else { return false }
        if filesystem == .ntfs, !ntfsRepartitioningReady { return false }
        return true
    }
    
    private let labelColumnWidth: CGFloat = 108
    private let rowControlHeight: CGFloat = 28
    
    private func formRowLabel(_ title: String) -> some View {
        Text(title)
            .font(.title2.weight(.semibold))
            .foregroundStyle(VolFerryTheme.textPrimary(dark))
            .frame(width: labelColumnWidth, alignment: .leading)
            .textSelectable()
    }
    
    var body: some View {
        ZStack {
            VolFerryTheme.bgPrimary(dark).ignoresSafeArea()
            WindowAppearanceBridge(mode: appearanceMode)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 16) {
                Text("磁盘分区")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(VolFerryTheme.textPrimary(dark))
                    .textSelectable()
                Text("使用系统 diskutil 重新划分整块磁盘，将删除该盘上所有数据。NTFS 仅支持「单分区」：先建 ExFAT 占位卷再写入（mkntfs）。多分区需先选 ExFAT/FAT32 等，再对各卷「格式化」选 NTFS。")
                    .font(.body)
                    .foregroundStyle(VolFerryTheme.textSecondary(dark))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelectable()
                
                partitionTargetHero
                
                HStack(alignment: .center, spacing: 12) {
                    formRowLabel("分区表")
                    Picker("", selection: $scheme) {
                        ForEach(PartitionDiskScheme.allCases) { s in
                            Text(s.menuTitle).tag(s)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .frame(height: rowControlHeight)
                }
                
                HStack(alignment: .center, spacing: 12) {
                    formRowLabel("布局")
                    Picker("", selection: $preset) {
                        ForEach(PartitionDiskPreset.allCases) { p in
                            Text(p.menuTitle).tag(p)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .frame(height: rowControlHeight)
                }
                
                HStack(alignment: .center, spacing: 12) {
                    formRowLabel("文件系统")
                    Picker("", selection: $filesystem) {
                        ForEach(filesystemChoices) { f in
                            Text(f.menuTitle).tag(f)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .frame(height: rowControlHeight)
                }
                
                if filesystem == .ntfs {
                    Text("单分区 + NTFS：分区完成后自动执行 mkntfs。请确认「依赖」中已检测到 mkntfs。")
                        .font(.callout)
                        .foregroundStyle(VolFerryTheme.textSecondary(dark))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelectable()
                }
                if !ntfsRepartitioningReady {
                    Text("未检测到 mkntfs，分区向导中已隐藏 NTFS。安装 ntfs-3g-mac 后可在「依赖」刷新。")
                        .font(.callout)
                        .foregroundStyle(VolFerryTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelectable()
                }
                
                if scheme == .mbr, filesystem == .apfs {
                    Text("提示：MBR 分区表通常不适合创建 APFS，若失败请改选 GPT 或 ExFAT / FAT32。")
                        .font(.callout)
                        .foregroundStyle(VolFerryTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelectable()
                }
                
                HStack(alignment: .center, spacing: 12) {
                    formRowLabel("卷名前缀")
                    TextField("", text: $volumeNameBase, prompt: Text("UNTITLED").foregroundStyle(VolFerryTheme.textSecondary(dark).opacity(0.75)))
                        .textFieldStyle(.plain)
                        .font(.body.weight(.medium))
                        .foregroundStyle(VolFerryTheme.textPrimary(dark))
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity)
                        .frame(height: rowControlHeight)
                        .background(VolFerryTheme.bgTertiary(dark), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Text("多个分区时名称依次为：前缀、前缀2、前缀3…（非法字符会自动替换）。")
                    .font(.callout)
                    .foregroundStyle(VolFerryTheme.textSecondary(dark))
                    .textSelectable()
                
                Label {
                    Text("请勿对系统启动盘或含 macOS 的系统容器盘执行此操作。")
                        .font(.callout)
                        .foregroundStyle(VolFerryTheme.danger.opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelectable()
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(VolFerryTheme.danger)
                }
                .labelStyle(.titleAndIcon)
                
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
                            Task { await runPartition(password: pw) }
                        } else {
                            adminPasswordSheetField = ""
                            showAdminPasswordSheet = true
                        }
                    } label: {
                        Text("开始分区").textSelectable()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(VolFerryTheme.accent)
                    .disabled(!canStartPartition)
                    .pointingHandOnHover(enabled: canStartPartition)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .frame(minWidth: 560)
        }
        .onAppear {
            if !filesystemChoices.contains(filesystem) {
                filesystem = .exfat
            }
        }
        .onChange(of: preset) { _, _ in
            if !filesystemChoices.contains(filesystem) {
                filesystem = .exfat
            }
        }
        .onChange(of: ntfsRepartitioningReady) { _, _ in
            if !filesystemChoices.contains(filesystem) {
                filesystem = .exfat
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .systemEffectiveAppearanceChanged)) { _ in
            systemAppearanceRevision += 1
        }
        .sheet(isPresented: $showAdminPasswordSheet) {
            PartitionAdminPasswordSheet(
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
                    Task { await runPartition(password: pw) }
                }
            )
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
            if isWorking {
                ZStack {
                    Color.black.opacity(dark ? 0.42 : 0.24)
                        .ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                            .scaleEffect(1.05)
                        Text(filesystem == .ntfs ? "正在分区并写入 NTFS…" : "正在分区…")
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
    private var partitionTargetHero: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(VolFerryTheme.accent)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "square.split.2x1")
                        .font(.title2)
                        .foregroundStyle(VolFerryTheme.accent)
                    Text("分区目标")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(VolFerryTheme.textPrimary(dark))
                        .textSelectable()
                }
                if let d = disk {
                    Text("\(d.name.isEmpty ? d.identifier : d.name)（\(d.identifier)）· \(d.sizeFormatted)")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(VolFerryTheme.textPrimary(dark))
                        .textSelectable()
                } else {
                    Text("未在列表中找到 \(diskIdentifier)，请关闭后刷新设备页再试。")
                        .font(.body)
                        .foregroundStyle(VolFerryTheme.warning)
                        .textSelectable()
                }
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
    
    private func runPartition(password: String) async {
        let pw = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pw.isEmpty else {
            toastSuccessClosesSheet = false
            toastMessage = "需要管理员密码。"
            return
        }
        guard disk != nil else {
            toastSuccessClosesSheet = false
            toastMessage = "无效磁盘"
            return
        }
        await MainActor.run { isWorking = true }
        defer { Task { @MainActor in isWorking = false } }
        do {
            let msg = try await MountManager.repartitionWholeDisk(
                diskIdentifier: diskIdentifier,
                scheme: scheme,
                preset: preset,
                filesystem: filesystem,
                volumeNameBase: volumeNameBase,
                password: pw
            )
            await MainActor.run {
                if saveAdminPasswordToKeychain {
                    auth.savePassword(pw)
                }
                toastSuccessClosesSheet = true
                toastMessage = msg
            }
            await detector.refresh(showLoading: false)
        } catch let e as ProcessError {
            PartitionSheetLog.logger.error("分区失败 disk=\(diskIdentifier, privacy: .public): \(e.localizedDescription, privacy: .public)")
            await MainActor.run {
                toastSuccessClosesSheet = false
                toastMessage = e.localizedDescription
            }
        } catch {
            PartitionSheetLog.logger.error("分区失败 disk=\(diskIdentifier, privacy: .public) \(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                toastSuccessClosesSheet = false
                toastMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - 分区：管理员密码

private struct PartitionAdminPasswordSheet: View {
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
            Text("即将对所选磁盘执行重新分区（sudo），该盘上所有数据将被清除。")
                .font(.body)
                .foregroundStyle(VolFerryTheme.textSecondary(dark))
                .fixedSize(horizontal: false, vertical: true)
                .textSelectable()
            Text("请输入本机管理员密码以授权分区（sudo）。")
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
            Text(saveToKeychainOnConfirm ? "点「好」后先执行分区；成功后将密码保存到钥匙串。" : "点「好」后仅本次使用，不会写入钥匙串。可在「选项」中开启保存。")
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
