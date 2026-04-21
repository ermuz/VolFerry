import AppKit
import os.log
import SwiftUI

private enum StatusBarPopoverLog {
    static let logger = Logger(subsystem: VolFerryApp.subsystem, category: "StatusBarPopover")
}

private struct PopoverPendingSudo: Identifiable {
    let id = UUID()
    let action: DriveAction
    let drive: DriveInfo
}

private enum PopoverOperationOverlay: Equatable {
    case loading(String)
    case finished(message: String, success: Bool)
}

/// 状态栏图标点击时展示：与主窗口设备卡一致的 NTFS 快捷操作（挂载 / 读写 / 推出 / 格式化 / 安全移除等）。
struct StatusBarPopoverView: View {
    @ObservedObject private var detector = DriveDetector.shared
    @ObservedObject private var auth = AuthManager.shared
    
    @AppStorage(VolFerryUserDefaults.Key.appearanceMode) private var appearanceRaw = "system"
    @AppStorage(VolFerryUserDefaults.Key.saveAdminPasswordToKeychain) private var saveAdminPasswordToKeychain = true
    @AppStorage(VolFerryUserDefaults.Key.autoMountReadWriteGloballyEnabled) private var autoMountReadWriteGloballyEnabled = true
    
    @State private var systemAppearanceRevision = 0
    @State private var pendingSudo: PopoverPendingSudo?
    @State private var sudoPassword = ""
    @State private var operationOverlay: PopoverOperationOverlay?
    @State private var overlayDismissTask: Task<Void, Never>?
    @State private var toastMessage: String?
    @State private var showNTFSHintPopover = false
    @State private var autoReadWriteEnabledByPartition: [String: Bool] = [:]
    @State private var needEnableGlobalAutoMountAlert = false
    @State private var pendingGlobalEnableDrive: DriveInfo?
    /// 与主窗口一致：`diskutil info /` 的 `ParentWholeDisk`，用于不展示启动盘上的 NTFS 卷。
    @State private var bootParentWholeDiskID: String?
    
    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }
    
    private var dark: Bool {
        _ = systemAppearanceRevision
        return appearanceMode.resolvedIsDark()
    }
    
    private var rwDepsReady: Bool {
        NTFSDependencyChecker.currentStatus().readyForReadWrite
    }
    
    private var formatMkReady: Bool {
        NTFSDependencyChecker.currentStatus().readyForNTFSFormat
    }
    
    /// 弹窗仅列出可在菜单栏操作的 NTFS 分区（排除启动盘上的 NTFS）。
    private var popoverVisibleDrives: [DriveInfo] {
        let ntfs = detector.drives.filter(\.isNTFS)
        guard let boot = bootParentWholeDiskID else { return ntfs }
        return ntfs.filter { $0.diskIdentifier != boot }
    }
    
    /// 仅与 NTFS 相关的简短说明（不展示全盘「磁盘/分区总数」）。
    private var popoverNTFSOnlyCaption: String {
        let s = detector.statusMessage
        if s.hasPrefix("刷新失败") { return s }
        if detector.isLoading { return "正在检测 NTFS 分区…" }
        let n = popoverVisibleDrives.count
        if n == 0 {
            if !detector.drives.filter(\.isNTFS).isEmpty {
                return "NTFS 均在启动盘，请使用主窗口「设备」"
            }
            return "未发现 NTFS 分区"
        }
        return "\(n) 个 NTFS 分区"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .background(VolFerryTheme.border(dark))
            content
            Divider()
                .background(VolFerryTheme.border(dark))
            footer
        }
        .frame(width: 380, height: 440)
        .background(VolFerryTheme.bgPrimary(dark))
        .environment(\.colorScheme, dark ? .dark : .light)
        .task {
            bootParentWholeDiskID = await MountManager.bootParentWholeDiskIdentifier()
        }
        .onAppear {
            NotificationCenter.default.post(name: .drivesNeedRefresh, object: nil)
            refreshAutoReadWriteState()
        }
        .onChange(of: detector.drives) { _, _ in
            refreshAutoReadWriteState()
        }
        .onChange(of: autoMountReadWriteGloballyEnabled) { _, enabled in
            if !enabled {
                autoReadWriteEnabledByPartition = autoReadWriteEnabledByPartition.mapValues { _ in false }
            }
            refreshAutoReadWriteState()
        }
        .onChange(of: appearanceRaw) { _, _ in
            systemAppearanceRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .systemEffectiveAppearanceChanged)) { _ in
            systemAppearanceRevision += 1
        }
        .sheet(item: $pendingSudo) { pending in
            PopoverSudoPasswordSheet(
                pending: pending,
                password: $sudoPassword,
                dark: dark,
                saveToKeychainOnConfirm: saveAdminPasswordToKeychain,
                onCancel: {
                    pendingSudo = nil
                    sudoPassword = ""
                },
                onConfirm: { pw in
                    pendingSudo = nil
                    sudoPassword = ""
                    let action = pending.action
                    let drive = pending.drive
                    Task {
                        await performDriveAction(
                            action,
                            drive: drive,
                            password: pw,
                            savePasswordToKeychainAfterSuccess: saveAdminPasswordToKeychain
                        )
                    }
                }
            )
        }
        .overlay {
            if let op = operationOverlay {
                popoverOperationOverlayContent(op)
            }
        }
        .alert("需要先开启全局自动读写", isPresented: $needEnableGlobalAutoMountAlert) {
            Button("开启并勾选此分区") {
                guard let drive = pendingGlobalEnableDrive else { return }
                autoMountReadWriteGloballyEnabled = true
                autoReadWriteEnabledByPartition[drive.partitionIdentifier] = true
                Task { await AutoMountManager.shared.setReadWriteTarget(drive, enabled: true) }
                pendingGlobalEnableDrive = nil
            }
            Button("取消", role: .cancel) {
                pendingGlobalEnableDrive = nil
            }
        } message: {
            Text("该功能受「选项 → NTFS 自动读写」总开关控制。可一键开启全局并勾选当前分区。")
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: operationOverlay)
        .volFerryToast(message: $toastMessage, dark: dark)
    }
    
    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(AppBrand.displayName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(VolFerryTheme.textPrimary(dark))
                    Button {
                        showNTFSHintPopover = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundStyle(VolFerryTheme.textSecondary(dark))
                    }
                    .buttonStyle(.plain)
                    .help("仅展示 NTFS 分区")
                    .pointingHandOnHover()
                    .popover(isPresented: $showNTFSHintPopover, arrowEdge: .top) {
                        Text("仅展示 NTFS 分区")
                            .font(.callout)
                            .foregroundStyle(VolFerryTheme.textPrimary(dark))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                }
                Text(popoverNTFSOnlyCaption)
                    .font(.caption)
                    .foregroundStyle(VolFerryTheme.textSecondary(dark))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if detector.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                Task { await detector.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新并检测 NTFS 分区")
            .pointingHandOnHover()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
    
    @ViewBuilder
    private var content: some View {
        if detector.drives.isEmpty, detector.isLoading {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("正在检测 NTFS 分区…")
                    .font(.callout)
                    .foregroundStyle(VolFerryTheme.textSecondary(dark))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if detector.drives.isEmpty {
            if detector.statusMessage.hasPrefix("刷新失败") {
                Text(detector.statusMessage)
                    .font(.callout)
                    .foregroundStyle(VolFerryTheme.warning)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                VStack(spacing: 10) {
                    Text("未发现 NTFS 卷")
                        .font(.body.weight(.medium))
                        .foregroundStyle(VolFerryTheme.textPrimary(dark))
                    Text("可尝试重新插拔磁盘后点右上角刷新。")
                        .font(.callout)
                        .foregroundStyle(VolFerryTheme.textSecondary(dark))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        } else if popoverVisibleDrives.isEmpty {
            VStack(spacing: 10) {
                Text("无可用外置 NTFS")
                    .font(.body.weight(.medium))
                    .foregroundStyle(VolFerryTheme.textPrimary(dark))
                Text("启动盘上的 NTFS（如 Boot Camp）不在此列出。请在主窗口「设备」中查看与管理。")
                    .font(.callout)
                    .foregroundStyle(VolFerryTheme.textSecondary(dark))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(popoverVisibleDrives) { drive in
                        popoverDriveRow(drive)
                    }
                }
                .padding(12)
            }
        }
    }
    
    private var footer: some View {
        HStack(spacing: 12) {
            Button("打开完整窗口…") {
                NotificationCenter.default.post(name: .closeStatusBarPopover, object: nil)
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .focusDevicesTab, object: nil)
                DispatchQueue.main.async {
                    for window in NSApp.windows where window.canBecomeKey {
                        window.deminiaturize(nil)
                        window.makeKeyAndOrderFront(nil)
                        break
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointingHandOnHover()
            Spacer()
            Button("退出") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
            .pointingHandOnHover()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
    
    private func popoverDriveRow(_ drive: DriveInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(drive.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VolFerryTheme.textPrimary(dark))
                    .lineLimit(1)
                Spacer(minLength: 8)
                statusBadge(for: drive)
                if rwDepsReady {
                    Toggle("自动读写", isOn: Binding(
                        get: { autoMountReadWriteGloballyEnabled && (autoReadWriteEnabledByPartition[drive.partitionIdentifier] ?? false) },
                        set: { newValue in
                            guard AutoMountManager.stableID(for: drive) != nil else { return }
                            if newValue {
                                if !autoMountReadWriteGloballyEnabled {
                                    pendingGlobalEnableDrive = drive
                                    needEnableGlobalAutoMountAlert = true
                                    return
                                }
                                autoReadWriteEnabledByPartition[drive.partitionIdentifier] = true
                                Task { await AutoMountManager.shared.setReadWriteTarget(drive, enabled: true) }
                            } else {
                                autoReadWriteEnabledByPartition[drive.partitionIdentifier] = false
                                Task { await AutoMountManager.shared.setReadWriteTarget(drive, enabled: false) }
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(VolFerryTheme.accent)
                    .disabled(AutoMountManager.stableID(for: drive) == nil)
                    .help("NTFS 自动读写")
                }
            }
            Text("\(drive.partitionIdentifier) · \(drive.sizeFormatted)")
                .font(.caption)
                .foregroundStyle(VolFerryTheme.textSecondary(dark))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if !drive.isMounted {
                        compactAction("挂载", VolFerryTheme.DeviceToolbar.systemImage(.mount), VolFerryTheme.DeviceToolbar.tint(.mount)) {
                            Task { await mountVolumeSystemOverlay(partitionIdentifier: drive.partitionIdentifier, displayName: drive.displayName) }
                        }
                    } else {
                        Group {
                            if rwDepsReady {
                                if drive.isReadWrite {
                                    compactAction("只读", VolFerryTheme.DeviceToolbar.systemImage(.readOnly), VolFerryTheme.DeviceToolbar.tint(.readOnly)) {
                                        Task { await prepareDriveAction(.restoreReadOnly, drive: drive) }
                                    }
                                } else {
                                    compactAction("读写", VolFerryTheme.DeviceToolbar.systemImage(.readWrite), VolFerryTheme.DeviceToolbar.tint(.readWrite)) {
                                        Task { await prepareDriveAction(.mountReadWrite, drive: drive) }
                                    }
                                }
                            } else {
                                compactAction("依赖", VolFerryTheme.DeviceToolbar.systemImage(.installDeps), VolFerryTheme.DeviceToolbar.tint(.installDeps)) {
                                    toastMessage = "读写需 MacFUSE 与 ntfs-3g。已切换到「依赖」页，请按提示安装。"
                                    NotificationCenter.default.post(name: .closeStatusBarPopover, object: nil)
                                    NSApp.activate(ignoringOtherApps: true)
                                    NotificationCenter.default.post(name: .focusDepsTab, object: nil)
                                    DispatchQueue.main.async {
                                        for window in NSApp.windows where window.canBecomeKey {
                                            window.makeKeyAndOrderFront(nil)
                                            break
                                        }
                                    }
                                }
                            }
                        }
                        compactAction("推出", VolFerryTheme.DeviceToolbar.systemImage(.unmount), VolFerryTheme.DeviceToolbar.tint(.unmount)) {
                            Task { await prepareDriveAction(.unmount, drive: drive) }
                        }
                    }
                    if formatMkReady {
                        compactAction("格式化", VolFerryTheme.DeviceToolbar.systemImage(.format), VolFerryTheme.DeviceToolbar.tint(.format)) {
                            openFormatSheetForCurrentPartition(drive)
                        }
                    } else {
                        compactAction("安装依赖", VolFerryTheme.DeviceToolbar.systemImage(.installDeps), VolFerryTheme.DeviceToolbar.tint(.installDeps)) {
                            toastMessage = "格式化为 NTFS 需 mkntfs（随 ntfs-3g-mac）。已切换到「依赖」页，请按提示安装。"
                            NotificationCenter.default.post(name: .closeStatusBarPopover, object: nil)
                            NSApp.activate(ignoringOtherApps: true)
                            NotificationCenter.default.post(name: .focusDepsTab, object: nil)
                            DispatchQueue.main.async {
                                for window in NSApp.windows where window.canBecomeKey {
                                    window.makeKeyAndOrderFront(nil)
                                    break
                                }
                            }
                        }
                    }
                    if drive.isEjectable {
                        compactAction("安全移除", VolFerryTheme.DeviceToolbar.systemImage(.eject), VolFerryTheme.DeviceToolbar.tint(.eject)) {
                            Task { await prepareDriveAction(.eject, drive: drive) }
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(VolFerryTheme.bgSecondary(dark))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(VolFerryTheme.border(dark), lineWidth: 1)
                )
        )
    }
    
    private func refreshAutoReadWriteState() {
        let visible = popoverVisibleDrives
        let visibleIDs = Set(visible.map(\.partitionIdentifier))
        autoReadWriteEnabledByPartition = autoReadWriteEnabledByPartition.filter { visibleIDs.contains($0.key) }
        
        Task {
            var latest: [String: Bool] = [:]
            for drive in visible {
                guard AutoMountManager.stableID(for: drive) != nil else {
                    latest[drive.partitionIdentifier] = false
                    continue
                }
                let enabled = await AutoMountManager.shared.isReadWriteTarget(drive)
                latest[drive.partitionIdentifier] = enabled
            }
            await MainActor.run {
                for (k, v) in latest {
                    autoReadWriteEnabledByPartition[k] = v
                }
            }
        }
    }
    
    @ViewBuilder
    private func statusBadge(for drive: DriveInfo) -> some View {
        if drive.isMounted {
            Text(drive.isReadWrite ? "读写" : "只读")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(drive.isReadWrite ? VolFerryTheme.success : VolFerryTheme.warning)
                .background(
                    (drive.isReadWrite ? VolFerryTheme.success : VolFerryTheme.warning).opacity(0.18),
                    in: Capsule()
                )
        } else {
            Text("未挂载")
                .font(.caption.weight(.medium))
                .foregroundStyle(VolFerryTheme.textSecondary(dark))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(VolFerryTheme.bgTertiary(dark), in: Capsule())
        }
    }
    
    /// 与设备树「格式化」一致：预选当前 NTFS 分区，在主窗口弹出 `FormatSheetView`。
    private func openFormatSheetForCurrentPartition(_ drive: DriveInfo) {
        let tag = "p:\(drive.partitionIdentifier)"
        NotificationCenter.default.post(
            name: .openFormatSheetWithTargetTag,
            object: nil,
            userInfo: ["tag": tag]
        )
        NotificationCenter.default.post(name: .closeStatusBarPopover, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .focusDevicesTab, object: nil)
        DispatchQueue.main.async {
            for window in NSApp.windows where window.canBecomeKey {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
    }
    
    private func compactAction(
        _ title: String,
        _ systemImage: String,
        _ tint: Color,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .tint(tint)
        .disabled(disabled)
        .pointingHandOnHover(enabled: !disabled)
    }
    
    // MARK: - 操作逻辑（与 MainView 设备卡一致）
    
    private func prepareDriveAction(_ action: DriveAction, drive: DriveInfo) async {
        guard action != .format else { return }
        
        if action == .mountSystem {
            await mountVolumeSystemOverlay(partitionIdentifier: drive.partitionIdentifier, displayName: drive.displayName)
            return
        }
        
        if action == .mountReadWrite, MountManager.findNTFS3G() == nil {
            await MainActor.run {
                toastMessage = "未找到 ntfs-3g。请在主窗口「依赖」中安装。"
            }
            return
        }
        
        if let pw = auth.loadPassword(), !pw.isEmpty {
            await performDriveAction(action, drive: drive, password: pw, savePasswordToKeychainAfterSuccess: false)
            return
        }
        
        await MainActor.run {
            sudoPassword = ""
            pendingSudo = PopoverPendingSudo(action: action, drive: drive)
        }
    }
    
    private func mountVolumeSystemOverlay(partitionIdentifier: String, displayName: String) async {
        await MainActor.run {
            cancelOverlayDismissSchedule()
            operationOverlay = .loading("正在挂载 \(displayName)…")
        }
        do {
            let msg = try await MountManager.mountVolumeSystem(partitionIdentifier: partitionIdentifier)
            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                    operationOverlay = .finished(message: msg, success: true)
                }
                detector.scheduleRefresh()
                scheduleOverlayAutoDismiss(message: msg, success: true)
            }
        } catch let error as ProcessError {
            let errText = error.localizedDescription
            StatusBarPopoverLog.logger.error("系统挂载失败: \(errText, privacy: .public)")
            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                    operationOverlay = .finished(message: errText, success: false)
                }
                scheduleOverlayAutoDismiss(message: errText, success: false)
            }
        } catch {
            let errText = error.localizedDescription
            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                    operationOverlay = .finished(message: errText, success: false)
                }
                scheduleOverlayAutoDismiss(message: errText, success: false)
            }
        }
    }
    
    private func performDriveAction(
        _ action: DriveAction,
        drive: DriveInfo,
        password: String,
        savePasswordToKeychainAfterSuccess: Bool
    ) async {
        guard action != .format, action != .mountSystem else { return }
        
        let pw = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pw.isEmpty else {
            await MainActor.run { toastMessage = "需要管理员密码。" }
            return
        }
        
        await MainActor.run {
            cancelOverlayDismissSchedule()
            operationOverlay = .loading(action.progressMessage(for: drive.displayName))
        }
        do {
            let msg: String
            switch action {
            case .mountSystem:
                return
            case .mountReadWrite:
                guard let ntfs3g = MountManager.findNTFS3G() else {
                    await MainActor.run {
                        operationOverlay = nil
                        cancelOverlayDismissSchedule()
                        toastMessage = "未找到 ntfs-3g。请在主窗口「依赖」中安装。"
                    }
                    return
                }
                msg = try await MountManager.mountReadWrite(drive: drive, ntfs3gPath: ntfs3g, password: pw)
            case .unmount:
                msg = try await MountManager.unmount(drive: drive, password: pw)
            case .eject:
                msg = try await MountManager.eject(drive: drive, password: pw)
            case .restoreReadOnly:
                msg = try await MountManager.restoreReadOnly(drive: drive, password: pw)
            case .format:
                return
            }
            await MainActor.run {
                if savePasswordToKeychainAfterSuccess {
                    auth.savePassword(pw)
                }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                    operationOverlay = .finished(message: msg, success: true)
                }
                detector.scheduleRefresh()
                scheduleOverlayAutoDismiss(message: msg, success: true)
            }
        } catch let error as ProcessError {
            let errText: String
            if case .timeout = error {
                errText = "挂载超时（常见于 Windows 快速启动或脏卷）。请在 Windows 完全关机后再试。"
            } else {
                errText = error.localizedDescription
            }
            StatusBarPopoverLog.logger.error("设备操作失败: \(errText, privacy: .public)")
            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                    operationOverlay = .finished(message: errText, success: false)
                }
                scheduleOverlayAutoDismiss(message: errText, success: false)
            }
        } catch {
            let errText = error.localizedDescription
            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                    operationOverlay = .finished(message: errText, success: false)
                }
                scheduleOverlayAutoDismiss(message: errText, success: false)
            }
        }
    }
    
    private func overlayFinishedDismissDelay(message: String, success: Bool) -> Double {
        if !success {
            let n = message.count
            if n > 200 { return 8 }
            if n > 100 { return 5.5 }
            return 4.2
        }
        let n = message.count
        if n > 200 { return 8 }
        if n > 100 { return 5.5 }
        return 3.0
    }
    
    private func cancelOverlayDismissSchedule() {
        overlayDismissTask?.cancel()
        overlayDismissTask = nil
    }
    
    private func scheduleOverlayAutoDismiss(message: String, success: Bool) {
        cancelOverlayDismissSchedule()
        let delay = overlayFinishedDismissDelay(message: message, success: success)
        overlayDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            operationOverlay = nil
            overlayDismissTask = nil
        }
    }
    
    @ViewBuilder
    private func popoverOperationOverlayContent(_ op: PopoverOperationOverlay) -> some View {
        ZStack {
            Color.black.opacity(dark ? 0.42 : 0.24)
                .contentShape(Rectangle())
                .onTapGesture {
                    if case .finished = op {
                        cancelOverlayDismissSchedule()
                        operationOverlay = nil
                    }
                }
            VStack(spacing: 14) {
                switch op {
                case .loading(let msg):
                    ProgressView()
                        .controlSize(.regular)
                    Text(msg)
                        .font(.body)
                        .foregroundStyle(VolFerryTheme.textPrimary(dark))
                        .multilineTextAlignment(.center)
                case .finished(let message, let success):
                    Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(success ? VolFerryTheme.success : VolFerryTheme.danger)
                    Text(message)
                        .font(.body)
                        .foregroundStyle(VolFerryTheme.textPrimary(dark))
                        .multilineTextAlignment(.center)
                        .textSelectable()
                }
            }
            .padding(24)
            .frame(minWidth: 280)
            .background(VolFerryTheme.bgSecondary(dark), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(VolFerryTheme.border(dark), lineWidth: 1)
            )
        }
    }
}

// MARK: - 密码面板

private struct PopoverSudoPasswordSheet: View {
    let pending: PopoverPendingSudo
    @Binding var password: String
    let dark: Bool
    var saveToKeychainOnConfirm: Bool
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
            Text(promptDetail)
                .font(.body)
                .foregroundStyle(VolFerryTheme.textSecondary(dark))
                .fixedSize(horizontal: false, vertical: true)
            SecureField("管理员密码", text: $password)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(10)
                .background(VolFerryTheme.bgTertiary(dark), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(VolFerryTheme.textPrimary(dark))
            Text(saveToKeychainOnConfirm ? "成功后可保存到钥匙串（与主窗口「选项」一致）。" : "仅本次使用，不写入钥匙串。")
                .font(.callout)
                .foregroundStyle(VolFerryTheme.textSecondary(dark))
            HStack {
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Spacer()
                Button("好") {
                    onConfirm(trimmedPassword)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(VolFerryTheme.accent)
                .disabled(trimmedPassword.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 400)
        .background(VolFerryTheme.bgPrimary(dark))
        .preferredColorScheme(dark ? .dark : .light)
    }
    
    private var promptDetail: String {
        let name = pending.drive.displayName
        switch pending.action {
        case .mountReadWrite:
            return "即将对「\(name)」执行读写挂载（sudo）。"
        case .restoreReadOnly:
            return "即将对「\(name)」还原为系统只读挂载（sudo）。"
        case .unmount:
            return "即将推出「\(name)」（sudo）。"
        case .eject:
            return "即将安全移除「\(name)」所在磁盘（sudo）。"
        case .format, .mountSystem:
            return ""
        }
    }
}
