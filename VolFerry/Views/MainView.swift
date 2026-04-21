import AppKit
import os.log
import SwiftUI

private enum MainViewLog {
    static let logger = Logger(subsystem: VolFerryApp.subsystem, category: "MainView")
}

private enum MainTab: String, CaseIterable, Identifiable, Hashable {
    case devices
    case deps
    case options
    
    var id: String { rawValue }
    
    var shortLabel: String {
        switch self {
        case .devices: return "设备"
        case .deps: return "依赖"
        case .options: return "选项"
        }
    }
    
    var icon: String {
        switch self {
        case .devices: return "externaldrive.fill"
        case .deps: return "cube.box.fill"
        case .options: return "slider.horizontal.3"
        }
    }
}

private struct FormatSheetTarget: Identifiable, Hashable {
    let tag: String
    var id: String { tag }
}

private struct PartitionSheetTarget: Identifiable, Hashable {
    let diskIdentifier: String
    var id: String { diskIdentifier }
}

/// 待输入管理员密码后执行的设备操作（挂载 / 推出卷 / 安全移除等）
private struct PendingSudoOperation: Identifiable {
    let id = UUID()
    let action: DriveAction
    let drive: DriveInfo
}

/// 设备操作反馈：与「读写」等共用同一浮层，先 loading 再就地切换为结果
private enum DeviceOperationOverlayState: Equatable {
    case loading(String)
    case finished(message: String, success: Bool)
}

private enum AutoMountConfirmAlert: Identifiable {
    case enable
    case disable
    
    var id: String {
        switch self {
        case .enable: return "enable"
        case .disable: return "disable"
        }
    }
}

struct MainView: View {
    @ObservedObject private var detector = DriveDetector.shared
    @ObservedObject private var auth = AuthManager.shared
    
    @AppStorage(VolFerryUserDefaults.Key.appearanceMode) private var appearanceRaw = "system"
    /// 默认仅列出含 NTFS 分区的磁盘；关闭后显示全部磁盘树
    @AppStorage(VolFerryUserDefaults.Key.showOnlyNTFSDisks) private var showOnlyNTFSDisks = true
    /// 在密码面板点「好」时是否写入钥匙串（可在「选项」中关闭）
    @AppStorage(VolFerryUserDefaults.Key.saveAdminPasswordToKeychain) private var saveAdminPasswordToKeychain = true
    /// 「依赖」一键修复：`true` 用系统为 `.command` 关联的默认应用；`false` 强制用「终端」
    @AppStorage(VolFerryUserDefaults.Key.brewScriptOpenWithWorkspaceDefault) private var brewScriptOpenWithWorkspaceDefault = true
    /// 总开关：关闭后清空所有分区自动读写勾选并停止后台挂载
    @AppStorage(VolFerryUserDefaults.Key.autoMountReadWriteGloballyEnabled) private var autoMountReadWriteGloballyEnabled = true
    
    /// 打开格式化面板时的固定目标：`p:` 分区 id 或 `d:` 整块磁盘 id（仅由设备树上的「格式化」设置）
    @State private var formatSheetTarget: FormatSheetTarget?
    @State private var partitionSheetTarget: PartitionSheetTarget?
    /// 与 `diskutil info /` 的 `ParentWholeDisk` 一致，用于隐藏系统盘「整盘格式化」按钮
    @State private var bootParentWholeDiskID: String?
    @State private var toastMessage: String?
    /// 挂载 / 推出卷 / 安全移除 / 只读还原：同一居中浮层内从加载切换为成功或失败，再自动消失
    @State private var deviceOperationOverlay: DeviceOperationOverlayState?
    @State private var deviceOverlayDismissTask: Task<Void, Never>?
    @State private var depStatus = NTFSDependencyChecker.currentStatus()
    @State private var launchAtLoginEnabled = LaunchAtLoginManager.isEnabled()
    @State private var selectedTab: MainTab = .devices
    /// 设备树中各磁盘折叠区块是否展开（刷新后新出现的盘默认展开）
    @State private var expandedDiskIDs: Set<String> = []
    /// 挂载 / 读写 / 只读 / 推出卷 / 安全移除 等需要 sudo 时弹出
    @State private var pendingSudoOperation: PendingSudoOperation?
    @State private var sudoSheetPassword = ""
    /// 系统外观变化时递增，使 `dark` 在「跟随系统」模式下与菜单栏亮/暗同步刷新。
    @State private var systemAppearanceRevision = 0
    /// 启用/关闭「全局自动读写」前的二次确认
    @State private var autoMountConfirmAlert: AutoMountConfirmAlert?
    
    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }
    
    private var dark: Bool {
        _ = systemAppearanceRevision
        return appearanceMode.resolvedIsDark()
    }
    
    private var appearanceQuickToggleIconName: String {
        switch appearanceMode {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        }
    }
    
    private var appearanceQuickToggleHelp: String {
        switch appearanceMode {
        case .system: return "外观：跟随系统。点击依次切换为浅色、深色，再回跟随系统"
        case .light: return "外观：浅色。点击切换为深色"
        case .dark: return "外观：深色。点击切换为跟随系统"
        }
    }
    
    /// 读写挂载（ntfs-3g + MacFUSE）是否已就绪
    private var readWriteDependenciesReady: Bool {
        depStatus.readyForReadWrite
    }
    
    /// NTFS 格式化（mkntfs）是否可用
    private var formatMkDependenciesReady: Bool {
        depStatus.readyForNTFSFormat
    }
    
    /// 设备页实际展示的磁盘（受顶栏「仅 NTFS」开关过滤）
    private var disksForDevicesList: [DiskInfo] {
        guard showOnlyNTFSDisks else { return detector.allDisks }
        return detector.allDisks.filter { disk in
            if detector.drives.contains(where: { $0.diskIdentifier == disk.identifier }) {
                return true
            }
            if disk.partitions.contains(where: { $0.isNTFS }) {
                return true
            }
            // 整盘格式化后 diskutil 可能短暂无子分区；外置/可弹出盘仍应显示，避免从列表消失
            if disk.partitions.isEmpty, disk.size > 0, disk.isExternal || disk.isEjectable {
                return true
            }
            return false
        }
    }
    
    private var autoMountGlobalToggleBinding: Binding<Bool> {
        Binding(
            get: { autoMountReadWriteGloballyEnabled },
            set: { newValue in
                if newValue && !autoMountReadWriteGloballyEnabled {
                    autoMountConfirmAlert = .enable
                } else if !newValue && autoMountReadWriteGloballyEnabled {
                    autoMountConfirmAlert = .disable
                } else {
                    autoMountReadWriteGloballyEnabled = newValue
                }
            }
        )
    }
    
    var body: some View {
        ZStack {
            VolFerryTheme.bgPrimary(dark)
                .ignoresSafeArea()
            
            WindowAppearanceBridge(mode: appearanceMode)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            
            VStack(alignment: .leading, spacing: 0) {
                topChrome
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                    .overlay(VolFerryTheme.border(dark).opacity(0.6))
                
                Group {
                    switch selectedTab {
                    case .devices:
                        devicesPanel
                    case .deps:
                        depsPanel
                    case .options:
                        optionsPanel
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            /// 顶栏「设备 / 依赖 / 选项」分段与各页系统控件，与 `VolFerryTheme` 亮暗一致，避免浅色时字色发灰。
            .environment(\.colorScheme, dark ? .dark : .light)
        }
        .id(appearanceRaw)
        .frame(minWidth: 680, minHeight: 480)
        .task {
            async let boot = MountManager.bootParentWholeDiskIdentifier()
            /// 与状态栏共用 `DriveDetector.shared`：若 Popover 或其它路径已拉取过列表，此处不再用全屏 loading 再扫一遍。
            let hasCachedList = !detector.allDisks.isEmpty
            await detector.refresh(showLoading: !hasCachedList)
            bootParentWholeDiskID = await boot
        }
        .onAppear {
            depStatus = NTFSDependencyChecker.currentStatus()
            launchAtLoginEnabled = LaunchAtLoginManager.isEnabled()
        }
        .onChange(of: appearanceRaw) { _, _ in
            systemAppearanceRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .systemEffectiveAppearanceChanged)) { _ in
            systemAppearanceRevision += 1
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .deps || tab == .devices {
                depStatus = NTFSDependencyChecker.currentStatus()
            }
        }
        .onChange(of: launchAtLoginEnabled) { oldValue, newValue in
            do {
                try LaunchAtLoginManager.setEnabled(newValue)
                let current = LaunchAtLoginManager.isEnabled()
                if current != newValue {
                    launchAtLoginEnabled = current
                }
                toastMessage = current ? "已启用开机自启" : "已关闭开机自启"
            } catch {
                launchAtLoginEnabled = oldValue
                toastMessage = "设置开机自启失败：\(error.localizedDescription)"
            }
        }
        .onChange(of: autoMountReadWriteGloballyEnabled) { _, newValue in
            if !newValue {
                Task { await AutoMountManager.shared.clearAllReadWriteTargets() }
            }
        }
        .sheet(item: $autoMountConfirmAlert) { kind in
            AutoMountConfirmSheet(
                kind: kind,
                dark: dark,
                onCancel: { autoMountConfirmAlert = nil },
                onConfirm: {
                    switch kind {
                    case .enable:
                        autoMountReadWriteGloballyEnabled = true
                    case .disable:
                        autoMountReadWriteGloballyEnabled = false
                    }
                    autoMountConfirmAlert = nil
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .drivesNeedRefresh)) { notification in
            let showLoading = (notification.userInfo?["showLoading"] as? Bool) ?? false
            Task { await detector.refresh(showLoading: showLoading) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusDevicesTab)) { _ in
            selectedTab = .devices
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusDepsTab)) { _ in
            selectedTab = .deps
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFormatSheetWithTargetTag)) { note in
            guard let tag = note.userInfo?["tag"] as? String, !tag.isEmpty else { return }
            formatSheetTarget = FormatSheetTarget(tag: tag)
            selectedTab = .devices
        }
        /// 系统或其它 App 挂载、推出、重命名卷时同步列表与读写状态
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didMountNotification)) { _ in
            detector.scheduleRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            detector.scheduleRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didRenameVolumeNotification)) { _ in
            detector.scheduleRefresh()
        }
        /// 从其它应用切回本应用时再拉一次（外部改读写/只读后常需切回才看到）
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            detector.scheduleRefresh()
        }
        /// 定时静默同步：纯改 mount 选项时未必触发 Workspace 通知
        .onReceive(Timer.publish(every: 8, on: .main, in: .common).autoconnect()) { _ in
            guard selectedTab == .devices else { return }
            detector.scheduleRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showFormatSheet)) { _ in
            toastMessage = "格式化须指定具体磁盘或分区。请在「设备」列表中展开磁盘，并对整块磁盘或分区点击「格式化」。菜单无法单独打开格式化面板。"
        }
        .sheet(item: $formatSheetTarget) { target in
            FormatSheetView(
                isPresented: Binding(
                    get: { formatSheetTarget != nil },
                    set: { if !$0 { formatSheetTarget = nil } }
                ),
                formatTargetTag: target.tag
            )
            .environmentObject(detector)
            .environmentObject(auth)
        }
        .sheet(item: $partitionSheetTarget) { target in
            PartitionSheetView(
                isPresented: Binding(
                    get: { partitionSheetTarget != nil },
                    set: { if !$0 { partitionSheetTarget = nil } }
                ),
                diskIdentifier: target.diskIdentifier,
                ntfsRepartitioningReady: formatMkDependenciesReady
            )
            .environmentObject(detector)
            .environmentObject(auth)
        }
        .sheet(item: $pendingSudoOperation) { pending in
            SudoPasswordPromptSheet(
                pending: pending,
                password: $sudoSheetPassword,
                dark: dark,
                auth: auth,
                saveToKeychainOnConfirm: saveAdminPasswordToKeychain,
                onCancel: {
                    pendingSudoOperation = nil
                    sudoSheetPassword = ""
                },
                onConfirm: { pw in
                    pendingSudoOperation = nil
                    sudoSheetPassword = ""
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
            if let op = deviceOperationOverlay {
                deviceOperationOverlayContent(op)
            }
        }
        .volFerryToast(message: $toastMessage, dark: dark)
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: deviceOperationOverlay)
    }
    
    /// 设备操作结果态自动关闭前等待时长（成功略短，失败或长文案略长）
    private func deviceOverlayFinishedDismissDelay(message: String, success: Bool) -> Double {
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
    
    private func cancelDeviceOverlayDismissSchedule() {
        deviceOverlayDismissTask?.cancel()
        deviceOverlayDismissTask = nil
    }
    
    private func scheduleDeviceOverlayAutoDismiss(message: String, success: Bool) {
        cancelDeviceOverlayDismissSchedule()
        let delay = deviceOverlayFinishedDismissDelay(message: message, success: success)
        deviceOverlayDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            deviceOperationOverlay = nil
            deviceOverlayDismissTask = nil
        }
    }
    
    @ViewBuilder
    private func deviceOperationOverlayContent(_ op: DeviceOperationOverlayState) -> some View {
        ZStack {
            Color.black.opacity(dark ? 0.42 : 0.24)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    if case .finished = op {
                        cancelDeviceOverlayDismissSchedule()
                        deviceOperationOverlay = nil
                    }
                }
            
            VStack(spacing: 14) {
                switch op {
                case .loading(let msg):
                    ProgressView()
                        .controlSize(.large)
                        .scaleEffect(1.05)
                    Text(msg)
                        .font(.body.weight(.medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(VolFerryTheme.textPrimary(dark))
                        .textSelectable()
                case .finished(let msg, let success):
                    Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(success ? VolFerryTheme.success : VolFerryTheme.warning)
                        .accessibilityHidden(true)
                    Text(msg)
                        .font(.body.weight(.medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(VolFerryTheme.textPrimary(dark))
                        .textSelectable()
                }
            }
            .padding(26)
            .frame(minWidth: 280, maxWidth: 420)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(VolFerryTheme.bgSecondary(dark))
                    .shadow(color: .black.opacity(dark ? 0.35 : 0.18), radius: 28, y: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(VolFerryTheme.border(dark).opacity(0.45), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
    }
    
    // MARK: - 顶栏（与系统红绿灯、缩放同一行区域对齐）
    
    /// 左右内边距与右侧一致为 12；若与系统红绿灯重叠可再略增左侧。
    /// 标题区左对齐、右侧操作区右对齐，中间分段控件保持固有宽度，三者两端顶满可用宽度。
    private var topChrome: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(AppBrand.displayName)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(VolFerryTheme.textPrimary(dark))
                            .textSelectable()
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        statusPill
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Text(detector.statusMessage)
                        .font(.callout)
                        .foregroundStyle(VolFerryTheme.textSecondary(dark))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .truncationMode(.tail)
                        .textSelectable()
                }
                .frame(minWidth: 120, maxWidth: 420, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Picker("", selection: $selectedTab) {
                ForEach(MainTab.allCases) { tab in
                    Text(tab.shortLabel)
                        .textSelectable()
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .font(.body)
            .controlSize(.regular)
            .contentShape(Rectangle())
            .pointingHandOnHover()
            .fixedSize(horizontal: true, vertical: false)
            
            HStack(spacing: 8) {
                if selectedTab == .devices {
                    Toggle(isOn: $showOnlyNTFSDisks) {
                        Text("仅 NTFS")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(VolFerryTheme.textSecondary(dark))
                            .textSelectable()
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(VolFerryTheme.accent)
                    .help("开启时只显示含 NTFS 分区的磁盘；关闭后显示全部磁盘与分区结构")
                }
                Button {
                    Task { await detector.refresh() }
                } label: {
                    ZStack {
                        if detector.isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 28, height: 28)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(VolFerryTheme.accent)
                                .frame(width: 28, height: 28)
                                .background(VolFerryTheme.bgSecondary(dark), in: Circle())
                                .contentShape(Circle())
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(detector.isLoading)
                .keyboardShortcut("r", modifiers: .command)
                .pointingHandOnHover(enabled: !detector.isLoading)
                Button {
                    switch appearanceMode {
                    case .system: appearanceRaw = AppearanceMode.light.rawValue
                    case .light: appearanceRaw = AppearanceMode.dark.rawValue
                    case .dark: appearanceRaw = AppearanceMode.system.rawValue
                    }
                } label: {
                    Image(systemName: appearanceQuickToggleIconName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(VolFerryTheme.textSecondary(dark))
                        .frame(width: 28, height: 28)
                        .background(VolFerryTheme.bgSecondary(dark), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(appearanceQuickToggleHelp)
                .pointingHandOnHover()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .background(VolFerryTheme.bgPrimary(dark))
    }
    
    private var statusPill: some View {
        let rwReady = depStatus.readyForReadWrite
        let loading = detector.isLoading
        let dotColor: Color = {
            if loading { return VolFerryTheme.accent }
            if rwReady { return VolFerryTheme.success }
            return VolFerryTheme.warning
        }()
        let labelText = loading ? "扫描中" : (rwReady ? "就绪" : "需配置依赖")
        return HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(labelText)
                .font(.callout.weight(.medium))
                .foregroundStyle(VolFerryTheme.textSecondary(dark))
                .textSelectable()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(VolFerryTheme.bgSecondary(dark), in: Capsule())
    }
    
    // MARK: - 设备
    
    /// 已有列表数据时再次刷新：顶栏提示 + 保留下方列表，避免整页只剩一个小转圈「看不出在刷列表」。
    private var devicesRefreshingBanner: some View {
        let msg = detector.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .center, spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(msg.isEmpty ? "正在刷新磁盘列表…" : msg)
                .font(.callout.weight(.medium))
                .foregroundStyle(VolFerryTheme.textPrimary(dark))
                .textSelectable()
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VolFerryTheme.accent.opacity(dark ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(VolFerryTheme.accent.opacity(0.35), lineWidth: 1)
        )
    }
    
    private var devicesPanel: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if detector.isLoading && detector.allDisks.isEmpty {
                    ProgressView()
                        .scaleEffect(1.1)
                        .tint(VolFerryTheme.accent)
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity)
                } else if detector.allDisks.isEmpty {
                    emptyDevices
                } else {
                    if detector.isLoading {
                        devicesRefreshingBanner
                    }
                    if disksForDevicesList.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.system(size: 36, weight: .light))
                                .foregroundStyle(VolFerryTheme.textSecondary(dark).opacity(0.7))
                            Text("当前列表下没有可显示的磁盘")
                                .font(.headline)
                                .foregroundStyle(VolFerryTheme.textPrimary(dark))
                                .textSelectable()
                            Text(showOnlyNTFSDisks
                                 ? "已开启顶栏「仅 NTFS」，本机可能没有 NTFS 分区。请关闭该开关以查看全部磁盘。"
                                 : "请尝试刷新或检查磁盘连接。")
                                .font(.body)
                                .foregroundStyle(VolFerryTheme.textSecondary(dark))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 400)
                                .textSelectable()
                        }
                        .padding(.top, 36)
                        .frame(maxWidth: .infinity)
                    } else {
                        if detector.drives.isEmpty && !showOnlyNTFSDisks {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(VolFerryTheme.warning)
                                Text("未发现 NTFS 分区，下方仍可查看磁盘与分区结构。")
                                    .font(.body)
                                    .foregroundStyle(VolFerryTheme.textSecondary(dark))
                                    .textSelectable()
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(VolFerryTheme.bgTertiary(dark), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        ForEach(disksForDevicesList) { disk in
                            DiskDeviceSection(
                                disk: disk,
                                dark: dark,
                                drives: detector.drives,
                                bootParentWholeDisk: bootParentWholeDiskID,
                                isExpanded: diskExpansionBinding(for: disk.identifier),
                                rwDepsReady: readWriteDependenciesReady,
                                formatMkReady: formatMkDependenciesReady,
                                autoMountReadWriteGloballyEnabled: $autoMountReadWriteGloballyEnabled,
                                onOpenDependencyTab: {
                                    selectedTab = .deps
                                    depStatus = NTFSDependencyChecker.currentStatus()
                                },
                                onOpenOptionsTab: {
                                    selectedTab = .options
                                },
                                onFormatWholeDisk: { d in
                                    formatSheetTarget = FormatSheetTarget(tag: "d:\(d.identifier)")
                                },
                                onPartitionWholeDisk: { d in
                                    partitionSheetTarget = PartitionSheetTarget(diskIdentifier: d.identifier)
                                },
                                onFormatPartition: { part in
                                    formatSheetTarget = FormatSheetTarget(tag: "p:\(part.identifier)")
                                },
                                onMountPartition: { part in
                                    Task {
                                        let name = part.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                            ? part.identifier
                                            : part.name
                                        await mountVolumeSystemOverlay(partitionIdentifier: part.identifier, displayName: name)
                                    }
                                },
                                onDriveAction: { action, drive in
                                    if action == .format {
                                        formatSheetTarget = FormatSheetTarget(tag: "p:\(drive.partitionIdentifier)")
                                    } else {
                                        Task { await prepareDriveAction(action, drive: drive) }
                                    }
                                }
                            )
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(VolFerryTheme.bgPrimary(dark))
        .onAppear {
            syncExpandedDiskIDs()
        }
        .onChange(of: detector.isLoading) { _, loading in
            if !loading {
                syncExpandedDiskIDs()
            }
        }
        .onChange(of: showOnlyNTFSDisks) { _, _ in
            syncExpandedDiskIDs()
        }
    }
    
    private func diskExpansionBinding(for diskId: String) -> Binding<Bool> {
        Binding(
            get: { expandedDiskIDs.contains(diskId) },
            set: { newValue in
                if newValue {
                    expandedDiskIDs.insert(diskId)
                } else {
                    expandedDiskIDs.remove(diskId)
                }
            }
        )
    }
    
    /// 刷新完成后：去掉已不存在的盘 id；新出现的盘默认展开
    private func syncExpandedDiskIDs() {
        let ids = Set(disksForDevicesList.map(\.identifier))
        guard !ids.isEmpty else {
            expandedDiskIDs = []
            return
        }
        let previous = expandedDiskIDs
        expandedDiskIDs = previous.intersection(ids)
        for id in ids where !previous.contains(id) {
            expandedDiskIDs.insert(id)
        }
    }
    
    private var emptyDevices: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(VolFerryTheme.textSecondary(dark).opacity(0.6))
            Text("未发现 NTFS 分区")
                .font(.headline)
                .foregroundStyle(VolFerryTheme.textPrimary(dark))
                .textSelectable()
            Text("未发现可用磁盘数据。接入磁盘后点击右上角刷新，或前往「依赖」检查 ntfs-3g / MacFUSE。")
                .font(.body)
                .foregroundStyle(VolFerryTheme.textSecondary(dark))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .textSelectable()
        }
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - 依赖
    
    /// 一级：总览 · 二级：读写 / 格式化 / 手动安装 · 三级：具体依赖项
    private var depsPanel: some View {
        ScrollView {
            dependencyCard {
                VStack(alignment: .leading, spacing: 14) {
                    depsHeadingLevel1("总览")
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: NTFSDependencyChecker.isFullyReady(depStatus) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(NTFSDependencyChecker.isFullyReady(depStatus) ? VolFerryTheme.success : VolFerryTheme.warning)
                            .frame(width: 28, alignment: .center)
                        Text(NTFSDependencyChecker.isFullyReady(depStatus) ? "依赖已就绪" : "依赖未完全就绪")
                            .font(.headline)
                            .foregroundStyle(VolFerryTheme.textPrimary(dark))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelectable()
                        HStack(spacing: 8) {
                            if !NTFSDependencyChecker.isFullyReady(depStatus) {
                                Button {
                                    if NTFSDependencyChecker.launchTerminalHomebrewInstall(useWorkspaceDefault: brewScriptOpenWithWorkspaceDefault) {
                                        toastMessage = brewScriptOpenWithWorkspaceDefault
                                            ? "已按系统为 .command 关联的默认应用打开安装命令。请在终端内按提示完成安装；MacFUSE 首次安装一般需在「系统设置 → 隐私与安全性」允许系统扩展，并可能需要重启。完成后回到此处点「重新检测」。"
                                            : "已使用「终端」(Terminal.app) 打开安装命令。请在终端内按提示完成安装；MacFUSE 首次安装一般需在「系统设置 → 隐私与安全性」允许系统扩展，并可能需要重启。完成后回到此处点「重新检测」。"
                                    } else {
                                        toastMessage = "无法打开临时安装脚本。请手动复制下方安装命令到终端执行。"
                                    }
                                } label: {
                                    Text("一键修复").textSelectable()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(VolFerryTheme.warning)
                                .controlSize(.regular)
                                .help("运行 Homebrew 安装命令（可在「选项」中设置用默认应用或「终端」打开脚本）")
                                .pointingHandOnHover()
                            }
                            Button {
                                depStatus = NTFSDependencyChecker.currentStatus()
                            } label: {
                                Text("重新检测").textSelectable()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(VolFerryTheme.accent)
                            .controlSize(.regular)
                            .pointingHandOnHover()
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    
                    Divider()
                        .overlay(VolFerryTheme.border(dark).opacity(0.45))
                    
                    depsHeadingLevel2("读写")
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(depsReadWriteCheckItems) { item in
                            dependencyCheckRow(item: item, dark: dark)
                        }
                    }
                    .padding(.leading, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    depsHeadingLevel2("格式化")
                    VStack(alignment: .leading, spacing: 10) {
                        if let mk = depStatus.items.first(where: { $0.key == "mkntfs" }) {
                            dependencyCheckRow(item: mk, dark: dark)
                        }
                        Text("若仅缺 mkntfs，可尝试：`brew reinstall ntfs-3g-mac`，并确认 PATH 中含 Homebrew 的 bin。")
                            .font(.callout)
                            .foregroundStyle(VolFerryTheme.textSecondary(dark))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelectable()
                    }
                    .padding(.leading, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Divider()
                        .overlay(VolFerryTheme.border(dark).opacity(0.45))
                    
                    depsHeadingLevel2("手动安装")
                    VStack(alignment: .leading, spacing: 10) {
                        Text("首次安装 MacFUSE 后需在「系统设置 → 隐私与安全性」允许系统扩展，必要时重启。仅缺 mkntfs 时可执行 `brew reinstall ntfs-3g-mac`。")
                            .font(.callout)
                            .foregroundStyle(VolFerryTheme.textSecondary(dark))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelectable()
                        HStack(alignment: .top, spacing: 10) {
                            Text(NTFSDependencyChecker.brewInstallReadWrite)
                                .font(.callout.monospaced())
                                .foregroundStyle(VolFerryTheme.textPrimary(dark))
                                .textSelectable()
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(VolFerryTheme.bgTertiary(dark), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(NTFSDependencyChecker.brewInstallReadWrite, forType: .string)
                            } label: {
                                Text("复制").textSelectable()
                            }
                            .buttonStyle(.bordered)
                            .tint(VolFerryTheme.accent)
                            .controlSize(.small)
                            .pointingHandOnHover()
                        }
                        Text("无 Homebrew 时：从 MacFUSE 官网安装 .pkg，再单独安装 `ntfs-3g-mac`。")
                            .font(.callout)
                            .foregroundStyle(VolFerryTheme.textSecondary(dark))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelectable()
                    }
                    .padding(.leading, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .background(VolFerryTheme.bgPrimary(dark))
    }
    
    private func depsHeadingLevel1(_ text: String) -> some View {
        Text(text)
            .font(.title2.weight(.bold))
            .foregroundStyle(VolFerryTheme.textPrimary(dark))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelectable()
    }
    
    private func depsHeadingLevel2(_ text: String) -> some View {
        Text(text)
            .font(.headline.weight(.semibold))
            .foregroundStyle(VolFerryTheme.textPrimary(dark))
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelectable()
    }
    
    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(VolFerryTheme.textPrimary(dark))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelectable()
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(VolFerryTheme.textSecondary(dark))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelectable()
        }
    }
    
    private var depsReadWriteCheckItems: [NTFSDependencyChecker.CheckItem] {
        depStatus.items.filter { $0.key == "macfuse" || $0.key == "ntfs3g" }
    }
    
    private func dependencyCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(VolFerryTheme.bgSecondary(dark))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(VolFerryTheme.border(dark).opacity(0.65), lineWidth: 1)
                )
        )
    }
    
    private func dependencyCheckRow(item: NTFSDependencyChecker.CheckItem, dark: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.isOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(item.isOK ? VolFerryTheme.success : VolFerryTheme.warning)
                .font(.body)
                .frame(width: 24, height: 24, alignment: .center)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(VolFerryTheme.textPrimary(dark))
                    .textSelectable()
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(VolFerryTheme.textSecondary(dark))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelectable()
            }
            Spacer(minLength: 0)
        }
    }
    
    // MARK: - 选项
    
    private var optionsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader("外观", subtitle: "窗口与面板配色；可与 macOS 外观一致，或固定浅色 / 深色")
                    Picker("外观模式", selection: $appearanceRaw) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(VolFerryTheme.accent)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardShape)
                
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader("启动", subtitle: "开机登录后自动启动 \(AppBrand.displayName)")
                    toggleRow(
                        title: "开机自启",
                        subtitle: "启用后会将 \(AppBrand.displayName) 注册到登录项；首次开启可能需要系统确认",
                        isOn: $launchAtLoginEnabled
                    )
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardShape)
                
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader("NTFS 自动读写", subtitle: "总开关开启后，方可在各 NTFS 分区卡片上勾选自动读写；后台检测到分区时会尝试读写挂载（需依赖与管理员密码）")
                    toggleRow(
                        title: "启用全局自动读写",
                        subtitle: "关闭后将清空所有分区的自动读写勾选，并不再后台执行；需重新开启后逐盘勾选",
                        isOn: autoMountGlobalToggleBinding
                    )
                    Label {
                        Text("已启用并保存管理员密码到钥匙串时，系统在自动读写阶段可能出现“想要使用钥匙链中的机密信息”授权提示。")
                            .font(.callout)
                            .foregroundStyle(VolFerryTheme.textSecondary(dark))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelectable()
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(VolFerryTheme.warning)
                    }
                    .labelStyle(.titleAndIcon)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardShape)
                
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader("管理员密码", subtitle: "sudo 挂载、推出卷与格式化；保存在系统钥匙串")
                    toggleRow(
                        title: "保存管理员密码到钥匙串",
                        subtitle: "在密码面板中确认后写入钥匙串；关闭则仅临时使用、不保存",
                        isOn: $saveAdminPasswordToKeychain
                    )
                    Button(role: .destructive) {
                        auth.deletePassword()
                        toastMessage = "已删除钥匙串中的管理员密码"
                    } label: {
                        Label {
                            Text("删除已保存的密码")
                                .textSelectable()
                        } icon: {
                            Image(systemName: "trash")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .tint(VolFerryTheme.danger)
                    .disabled(!auth.hasSavedPassword)
                    .contentShape(Rectangle())
                    .pointingHandOnHover(enabled: auth.hasSavedPassword)
                    if auth.hasSavedPassword {
                        Label {
                            Text("当前已保存密码，将不再弹出应用内密码窗口")
                                .textSelectable()
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        .font(.callout)
                        .foregroundStyle(VolFerryTheme.success)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardShape)
                
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader("默认打开", subtitle: "依赖页「一键修复」如何打开安装脚本")
                    toggleRow(
                        title: "使用系统默认应用",
                        subtitle: "按访达中对「.command」的「打开方式」打开（如 Terminal、iTerm）。关闭则始终用「终端」(Terminal.app)",
                        isOn: $brewScriptOpenWithWorkspaceDefault
                    )
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardShape)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(VolFerryTheme.bgPrimary(dark))
    }
    
    private var cardShape: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(VolFerryTheme.bgSecondary(dark))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(VolFerryTheme.border(dark).opacity(0.65), lineWidth: 1)
            )
    }
    
    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(VolFerryTheme.textPrimary(dark))
                    .textSelectable()
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(VolFerryTheme.textSecondary(dark))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelectable()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { isOn.wrappedValue.toggle() }
            
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(VolFerryTheme.accent)
                .padding(.top, 1)
        }
        .contentShape(Rectangle())
        .pointingHandOnHover()
    }
    
    private func resolvedPassword() -> String? {
        auth.loadPassword()
    }
    
    /// 设备工具栏入口：钥匙串已有密码则直接执行；否则弹出密码面板
    private func prepareDriveAction(_ action: DriveAction, drive: DriveInfo) async {
        guard action != .format else { return }
        
        if action == .mountSystem {
            await mountVolumeSystemOverlay(partitionIdentifier: drive.partitionIdentifier, displayName: drive.displayName)
            return
        }
        
        if action == .mountReadWrite, MountManager.findNTFS3G() == nil {
            await MainActor.run {
                toastMessage = "未找到 ntfs-3g。请在「依赖」中按提示安装。"
                selectedTab = .deps
            }
            return
        }
        
        if let pw = resolvedPassword(), !pw.isEmpty {
            await performDriveAction(action, drive: drive, password: pw, savePasswordToKeychainAfterSuccess: false)
            return
        }
        
        await MainActor.run {
            sudoSheetPassword = ""
            pendingSudoOperation = PendingSudoOperation(action: action, drive: drive)
        }
    }
    
    /// 系统 `diskutil mount`，与 sudo 类操作共用同一浮层反馈
    private func mountVolumeSystemOverlay(partitionIdentifier: String, displayName: String) async {
        await MainActor.run {
            cancelDeviceOverlayDismissSchedule()
            deviceOperationOverlay = .loading("正在挂载 \(displayName)…")
        }
        do {
            let msg = try await MountManager.mountVolumeSystem(partitionIdentifier: partitionIdentifier)
            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                    deviceOperationOverlay = .finished(message: msg, success: true)
                }
                detector.scheduleRefresh()
                scheduleDeviceOverlayAutoDismiss(message: msg, success: true)
            }
        } catch let error as ProcessError {
            let errText = error.localizedDescription
            MainViewLog.logger.error("系统挂载失败 partition=\(partitionIdentifier, privacy: .public) \(errText, privacy: .public)")
            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                    deviceOperationOverlay = .finished(message: errText, success: false)
                }
                scheduleDeviceOverlayAutoDismiss(message: errText, success: false)
            }
        } catch {
            let errText = error.localizedDescription
            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                    deviceOperationOverlay = .finished(message: errText, success: false)
                }
                scheduleDeviceOverlayAutoDismiss(message: errText, success: false)
            }
        }
    }
    
    /// 使用已解析的管理员密码执行挂载 / 推出卷 / 安全移除 / 只读还原（格式化由独立面板处理）
    /// - Parameter savePasswordToKeychainAfterSuccess: 仅在操作**成功**后写入钥匙串，避免与 `sudo` 同时进行时触发两次系统授权感。
    private func performDriveAction(
        _ action: DriveAction,
        drive: DriveInfo,
        password: String,
        savePasswordToKeychainAfterSuccess: Bool
    ) async {
        guard action != .format else { return }
        guard action != .mountSystem else { return }
        
        let pw = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pw.isEmpty else {
            await MainActor.run {
                toastMessage = "需要管理员密码。"
            }
            return
        }
        
        await MainActor.run {
            cancelDeviceOverlayDismissSchedule()
            deviceOperationOverlay = .loading(action.progressMessage(for: drive.displayName))
        }
        do {
            let msg: String
            switch action {
            case .mountSystem:
                return
            case .mountReadWrite:
                guard let ntfs3g = MountManager.findNTFS3G() else {
                    await MainActor.run {
                        deviceOperationOverlay = nil
                        cancelDeviceOverlayDismissSchedule()
                        toastMessage = "未找到 ntfs-3g。请在「依赖」中按提示安装。"
                        selectedTab = .deps
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
                    deviceOperationOverlay = .finished(message: msg, success: true)
                }
                detector.scheduleRefresh()
                scheduleDeviceOverlayAutoDismiss(message: msg, success: true)
            }
        } catch let error as ProcessError {
            let errText: String
            if case .timeout = error {
                errText = "挂载超时（常见于 Windows 快速启动或脏卷）。请在 Windows 完全关机后再试。"
            } else {
                errText = error.localizedDescription
            }
            MainViewLog.logger.error("设备操作失败 action=\(String(describing: action), privacy: .public) partition=\(drive.partitionIdentifier, privacy: .public) ProcessError: \(errText, privacy: .public)")
            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                    deviceOperationOverlay = .finished(message: errText, success: false)
                }
                scheduleDeviceOverlayAutoDismiss(message: errText, success: false)
            }
        } catch {
            let errText = error.localizedDescription
            MainViewLog.logger.error("设备操作失败 action=\(String(describing: action), privacy: .public) partition=\(drive.partitionIdentifier, privacy: .public) \(errText, privacy: .public)")
            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                    deviceOperationOverlay = .finished(message: errText, success: false)
                }
                scheduleDeviceOverlayAutoDismiss(message: errText, success: false)
            }
        }
    }
}

// MARK: - 管理员密码弹窗（sudo）

private struct SudoPasswordPromptSheet: View {
    let pending: PendingSudoOperation
    @Binding var password: String
    let dark: Bool
    @ObservedObject var auth: AuthManager
    /// 与「选项」中开关一致，用于提示本次确认后是否会写入钥匙串
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
                .textSelectable()
            Text(promptDetail)
                .font(.body)
                .foregroundStyle(VolFerryTheme.textSecondary(dark))
                .fixedSize(horizontal: false, vertical: true)
                .textSelectable()
            SecureField("管理员密码", text: $password)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(10)
                .background(VolFerryTheme.bgTertiary(dark), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(VolFerryTheme.textPrimary(dark))
            Text(saveToKeychainOnConfirm ? "点「好」后先执行操作；成功后将密码保存到钥匙串（避免与授权步骤重叠）。" : "点「好」后仅本次使用，不会写入钥匙串。可在「选项」中开启保存。")
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
        case .format:
            return ""
        case .mountSystem:
            return ""
        }
    }
}

private struct AutoMountConfirmSheet: View {
    let kind: AutoMountConfirmAlert
    let dark: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    
    private var title: String {
        switch kind {
        case .enable:
            return "确认启用全局自动读写？"
        case .disable:
            return "确认关闭全局自动读写？"
        }
    }
    
    private var message: String {
        switch kind {
        case .enable:
            return "启用后可在各 NTFS 分区上勾选自动读写；后台尝试自动读写时，系统可能出现“想要使用钥匙链中的机密信息”授权提示。"
        case .disable:
            return "关闭后将清空所有分区的自动读写勾选，并停止后台自动挂载。确定要继续吗？"
        }
    }
    
    private var confirmTitle: String {
        switch kind {
        case .enable:
            return "启用"
        case .disable:
            return "关闭"
        }
    }
    
    private var confirmTint: Color {
        switch kind {
        case .enable:
            return VolFerryTheme.accent
        case .disable:
            return VolFerryTheme.danger
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(VolFerryTheme.textPrimary(dark))
                .textSelectable()
            Text(message)
                .font(.body)
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
                Button(action: onConfirm) {
                    Text(confirmTitle).textSelectable()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(confirmTint)
                .pointingHandOnHover()
            }
        }
        .padding(24)
        .frame(minWidth: 460)
        .background(VolFerryTheme.bgPrimary(dark))
        .preferredColorScheme(dark ? .dark : .light)
    }
}

// MARK: - 磁盘树（整块盘 → 分区）

private struct DiskDeviceSection: View {
    let disk: DiskInfo
    let dark: Bool
    let drives: [DriveInfo]
    let bootParentWholeDisk: String?
    @Binding var isExpanded: Bool
    /// 读写 / 只读按钮依赖 MacFUSE + ntfs-3g
    let rwDepsReady: Bool
    /// 格式化（含整盘）为 NTFS 依赖 mkntfs
    let formatMkReady: Bool
    /// 「选项」中 NTFS 自动读写总开关（勾选分区前须为 true）
    @Binding var autoMountReadWriteGloballyEnabled: Bool
    let onOpenDependencyTab: () -> Void
    let onOpenOptionsTab: () -> Void
    let onFormatWholeDisk: (DiskInfo) -> Void
    let onPartitionWholeDisk: (DiskInfo) -> Void
    let onFormatPartition: (PartitionInfo) -> Void
    let onMountPartition: (PartitionInfo) -> Void
    let onDriveAction: (DriveAction, DriveInfo) -> Void
    
    /// 是否与 `diskutil info /` 的启动卷同属一块物理盘（用于隐藏危险操作，与 Popover 过滤一致）
    private static func diskIsSystemBootDisk(_ diskId: String, _ bootParent: String?) -> Bool {
        guard let b = bootParent else { return false }
        return diskId == b
    }
    
    /// 是否允许整盘格式化（系统盘所在父盘不显示）
    private var showWholeDiskFormatButton: Bool {
        guard let boot = bootParentWholeDisk else { return false }
        return disk.identifier != boot
    }
    
    @ViewBuilder
    private func partitionLegendSwatchLine(color: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 4, height: 11)
            Text(text)
                .foregroundStyle(VolFerryTheme.textSecondary(dark).opacity(0.95))
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .multilineTextAlignment(.leading)
                .textSelectable()
        }
    }
    
    /// 容量条下方整行：仅分区与未划分；图例色块 + 文案，与条同色；各段均分可用宽度
    @ViewBuilder
    private var partitionSpaceSummaryRow: some View {
        if disk.partitions.isEmpty {
            Text("暂无分区")
                .font(.callout)
                .foregroundStyle(VolFerryTheme.textSecondary(dark).opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelectable()
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ForEach(Array(disk.partitions.enumerated()), id: \.element.id) { idx, part in
                    partitionLegendSwatchLine(
                        color: partitionSegmentColor(idx),
                        text: "\(part.identifier) \(ByteCountFormatting.compactLetter(fromByteCount: part.size))"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if disk.unallocatedBytes > 0, disk.partitionsTotalBytes <= disk.size {
                    partitionLegendSwatchLine(
                        color: unallocatedBarColor,
                        text: "未划分/分区表间隙等 \(ByteCountFormatting.compactLetter(fromByteCount: disk.unallocatedBytes))"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
    
    private func partitionSegmentColor(_ index: Int) -> Color {
        let colors: [Color] = [
            VolFerryTheme.accent,
            VolFerryTheme.accent.opacity(0.65),
            VolFerryTheme.success.opacity(0.85),
            VolFerryTheme.warning.opacity(0.9)
        ]
        return colors[index % colors.count]
    }
    
    /// 仅分区容量占比条（图例摘要在其下方单独一行）
    @ViewBuilder
    private var partitionCapacityBar: some View {
        if !disk.partitions.isEmpty, disk.size > 0 {
            GeometryReader { geo in
                let w = geo.size.width
                let denom = max(Double(disk.partitionsTotalBytes), Double(disk.size), 1)
                HStack(spacing: 0) {
                    ForEach(Array(disk.partitions.enumerated()), id: \.element.id) { idx, part in
                        let frac = Double(part.size) / denom
                        Rectangle()
                            .fill(partitionSegmentColor(idx))
                            .frame(width: max(1, w * CGFloat(frac)))
                    }
                    if disk.unallocatedBytes > 0, disk.partitionsTotalBytes <= disk.size {
                        let uFrac = Double(disk.unallocatedBytes) / Double(disk.size)
                        Rectangle()
                            .fill(unallocatedBarColor)
                            .frame(width: max(0, w * CGFloat(uFrac)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(VolFerryTheme.border(dark).opacity(0.55), lineWidth: 0.5)
                )
            }
            .frame(height: 16)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("分区空间占比条")
        }
    }
    
    private var unallocatedBarColor: Color {
        VolFerryTheme.textSecondary(dark).opacity(0.32)
    }
    
    private func toggleDiskExpansion() {
        isExpanded.toggle()
    }
    
    /// 副标题 + 容量条 + 图例：可点击展开/折叠（避免与标题选字、整盘格式化按钮抢手势）
    private var diskHeaderExpandableMetrics: some View {
        Group {
            Text("\(disk.identifier) · \(disk.isExternal ? "外置" : "内置") · \(disk.sizeFormatted)")
                .font(.callout)
                .foregroundStyle(VolFerryTheme.textSecondary(dark))
                .textSelectable()
            partitionCapacityBar
            partitionSpaceSummaryRow
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                /// 系统 DisclosureGroup 仅小 chevron 可点；此处给足约 44pt 最小热区（HIG）
                Button(action: toggleDiskExpansion) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(VolFerryTheme.accent)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Image(systemName: disk.isExternal ? "externaldrive.fill" : "internaldrive")
                            .font(.title3)
                            .foregroundStyle(VolFerryTheme.accent)
                    }
                    .frame(minWidth: 56, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "折叠磁盘详情" : "展开磁盘详情")
                .accessibilityLabel(isExpanded ? "折叠" : "展开")
                .pointingHandOnHover()
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 10) {
                        Text(disk.name.isEmpty ? disk.identifier : disk.name)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(VolFerryTheme.textPrimary(dark))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .textSelectable()
                        Spacer(minLength: 8)
                        if showWholeDiskFormatButton {
                            Button {
                                onPartitionWholeDisk(disk)
                            } label: {
                                Text("磁盘分区")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(VolFerryTheme.accent)
                                    .textSelectable()
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(VolFerryTheme.bgTertiary(dark), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("使用 diskutil 重新划分整块磁盘（将删除该盘全部数据）")
                            .pointingHandOnHover()
                            if formatMkReady {
                                Button {
                                    onFormatWholeDisk(disk)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: VolFerryTheme.DeviceToolbar.systemImage(.format))
                                            .font(.callout.weight(.semibold))
                                        Text("整盘格式化")
                                            .font(.callout.weight(.semibold))
                                            .textSelectable()
                                    }
                                    .foregroundStyle(VolFerryTheme.DeviceToolbar.tint(.format))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(VolFerryTheme.bgTertiary(dark), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .help("打开格式化面板并预选整块磁盘（将清空全部数据）")
                                .pointingHandOnHover()
                            } else {
                                Button {
                                    onOpenDependencyTab()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: VolFerryTheme.DeviceToolbar.systemImage(.installDeps))
                                            .font(.callout.weight(.semibold))
                                        Text("安装依赖")
                                            .font(.callout.weight(.semibold))
                                            .textSelectable()
                                    }
                                    .foregroundStyle(VolFerryTheme.DeviceToolbar.tint(.installDeps))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(VolFerryTheme.bgTertiary(dark), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .help("整盘格式化为 NTFS 前需安装 MacFUSE、ntfs-3g 与 mkntfs。点此前往「依赖」页。")
                                .pointingHandOnHover()
                            }
                        }
                    }
                    diskHeaderExpandableMetrics
                        .contentShape(Rectangle())
                        .onTapGesture(perform: toggleDiskExpansion)
                        .pointingHandOnHover()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    let rows = disk.operablePartitions
                    if disk.partitions.isEmpty {
                        Text("暂无分区。若刚整盘格式化过，请点顶栏「刷新」或稍后重试；仍无显示可重新插拔磁盘。")
                            .font(.callout)
                            .foregroundStyle(VolFerryTheme.textSecondary(dark))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelectable()
                    } else if rows.isEmpty {
                        Text("本盘仅含 EFI、Microsoft 保留分区等系统保留切片，\(AppBrand.displayName) 不提供挂载或格式化；容量条上仍可看到完整分区几何。")
                            .font(.callout)
                            .foregroundStyle(VolFerryTheme.textSecondary(dark))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelectable()
                    } else {
                        ForEach(rows) { part in
                            if let drive = drives.first(where: { $0.partitionIdentifier == part.identifier }) {
                                DriveCardView(
                                    drive: drive,
                                    dark: dark,
                                    bootParentWholeDisk: bootParentWholeDisk,
                                    rwDepsReady: rwDepsReady,
                                    formatMkReady: formatMkReady,
                                    autoMountReadWriteGloballyEnabled: $autoMountReadWriteGloballyEnabled,
                                    onOpenDependencyTab: onOpenDependencyTab,
                                    onOpenOptionsTab: onOpenOptionsTab
                                ) { action in
                                    onDriveAction(action, drive)
                                }
                            } else {
                                NonNTFSPartitionRow(
                                    partition: part,
                                    dark: dark,
                                    isOnSystemBootDisk: Self.diskIsSystemBootDisk(disk.identifier, bootParentWholeDisk),
                                    formatMkReady: formatMkReady,
                                    onOpenDependencyTab: onOpenDependencyTab,
                                    onMount: { onMountPartition(part) },
                                    onFormat: { onFormatPartition(part) }
                                )
                            }
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(VolFerryTheme.bgSecondary(dark))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(VolFerryTheme.border(dark), lineWidth: 1)
                )
        )
    }
}

/// 分区容量 / 已使用 / 未使用分栏大字展示，并带占用比例条（分区卡片与磁盘图例共用）
private struct PartitionSpaceHighlight: View {
    let dark: Bool
    let capacityText: String
    let usedText: String?
    let freeText: String?
    let usedPercent: Double
    /// 首列标题：一般为「分区容量」；未划分条可用「空间」等
    var capacityTitle: String = "分区容量"
    /// 数字字号：卡片 21pt，磁盘折叠下图例 17pt
    var valuePointSize: CGFloat = 21
    
    private var showUsageBreakdown: Bool {
        guard let u = usedText, let f = freeText else { return false }
        return !u.isEmpty && !f.isEmpty
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                spaceColumn(title: capacityTitle, value: capacityText, valueColor: VolFerryTheme.textPrimary(dark))
                if showUsageBreakdown, let u = usedText, let f = freeText {
                    spaceColumn(title: "已使用", value: u, valueColor: VolFerryTheme.warning)
                    spaceColumn(title: "未使用", value: f, valueColor: VolFerryTheme.success)
                }
            }
            if showUsageBreakdown {
                ProgressView(value: min(1, max(0, usedPercent)))
                    .tint(VolFerryTheme.accent)
                    .scaleEffect(x: 1, y: 1.4, anchor: .center)
            }
        }
    }
    
    private func spaceColumn(title: String, value: String, valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(VolFerryTheme.textSecondary(dark))
                .textSelectable()
            Text(value)
                .font(.system(size: valuePointSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .textSelectable()
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

/// GPT `Content`（diskutil），与「NTFS 分区」同风格的胶囊徽标
private struct PartitionTypeBadge: View {
    let content: String
    let dark: Bool
    
    var body: some View {
        Text(displayText)
            .font(.callout.weight(.semibold))
            .foregroundStyle(VolFerryTheme.accent.opacity(0.95))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(VolFerryTheme.accent.opacity(dark ? 0.2 : 0.12), in: Capsule())
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .textSelectable()
            .help(helpText)
    }
    
    private var displayText: String {
        PartitionContentLabel.display(from: content)
    }
    
    private var helpText: String {
        let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "分区类型未知" }
        let friendly = PartitionContentLabel.display(from: content)
        if t == friendly { return "分区类型：\(friendly)" }
        return "分区类型：\(friendly)\ndiskutil Content：\(t)"
    }
}

private struct NonNTFSPartitionRow: View {
    let partition: PartitionInfo
    let dark: Bool
    let isOnSystemBootDisk: Bool
    let formatMkReady: Bool
    let onOpenDependencyTab: () -> Void
    let onMount: () -> Void
    let onFormat: () -> Void
    
    /// 卷名非空时另起一行显示分区 id（卷名为空时标题已含 identifier，不再重复）
    private var hasNamedVolume: Bool {
        !partition.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isOnSystemBootDisk {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(VolFerryTheme.warning)
                    Text("系统启动磁盘上的分区：已隐藏格式化，避免误操作。")
                        .font(.callout)
                        .foregroundStyle(VolFerryTheme.textSecondary(dark))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelectable()
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VolFerryTheme.warning.opacity(dark ? 0.14 : 0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(partition.name.isEmpty ? partition.identifier : partition.name)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(VolFerryTheme.textPrimary(dark))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .textSelectable()
                        PartitionTypeBadge(content: partition.type, dark: dark)
                    }
                    if hasNamedVolume {
                        Text(partition.identifier)
                            .font(.callout)
                            .foregroundStyle(VolFerryTheme.textSecondary(dark))
                            .lineLimit(2)
                            .textSelectable()
                    }
                }
                Spacer(minLength: 8)
                nonNTFSStatusBadge
            }
            PartitionSpaceHighlight(
                dark: dark,
                capacityText: partition.sizeFormatted,
                usedText: partition.hasSpaceStats ? partition.usedFormatted : nil,
                freeText: partition.hasSpaceStats ? partition.freeFormatted : nil,
                usedPercent: partition.usedPercentOfCapacity
            )
            HStack(spacing: 8) {
                if !partition.isMounted {
                    DriveCardToolbarButton(
                        title: "挂载",
                        systemImage: VolFerryTheme.DeviceToolbar.systemImage(.mount),
                        dark: dark,
                        tint: VolFerryTheme.DeviceToolbar.tint(.mount),
                        disabled: false,
                        exclusiveActiveTint: nil,
                        helpText: "使用系统方式挂载该卷（diskutil mount，无需管理员密码）",
                        action: onMount
                    )
                }
                if !isOnSystemBootDisk {
                    if formatMkReady {
                        DriveCardToolbarButton(
                            title: "格式化",
                            systemImage: VolFerryTheme.DeviceToolbar.systemImage(.format),
                            dark: dark,
                            tint: VolFerryTheme.DeviceToolbar.tint(.format),
                            disabled: false,
                            exclusiveActiveTint: nil,
                            helpText: "打开格式化面板并预选该分区（将清空数据）",
                            action: onFormat
                        )
                    } else {
                        DriveCardToolbarButton(
                            title: "安装依赖",
                            systemImage: VolFerryTheme.DeviceToolbar.systemImage(.installDeps),
                            dark: dark,
                            tint: VolFerryTheme.DeviceToolbar.tint(.installDeps),
                            disabled: false,
                            exclusiveActiveTint: nil,
                            helpText: "格式化前需安装 MacFUSE、ntfs-3g 与 mkntfs。点此前往「依赖」页。",
                            action: onOpenDependencyTab
                        )
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(VolFerryTheme.bgSecondary(dark))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [VolFerryTheme.border(dark).opacity(0.9), VolFerryTheme.border(dark).opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(dark ? 0.35 : 0.08), radius: 12, y: 4)
        )
    }
    
    /// 与 NTFS 卡片 `statusBadge` 对齐：右侧胶囊展示挂载状态
    @ViewBuilder
    private var nonNTFSStatusBadge: some View {
        if partition.isMounted, partition.volumePath?.isEmpty == false {
            Text("已挂载")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(VolFerryTheme.success)
                .background(VolFerryTheme.success.opacity(0.18), in: Capsule())
                .textSelectable()
        } else {
            Text("未挂载")
                .font(.callout.weight(.medium))
                .foregroundStyle(VolFerryTheme.textSecondary(dark))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(VolFerryTheme.bgTertiary(dark), in: Capsule())
                .textSelectable()
        }
    }
}

// MARK: - 设备卡片（devices.styl 风格的圆角容器）

private struct DriveCardView: View {
    let drive: DriveInfo
    let dark: Bool
    /// `diskutil info /` 的 `ParentWholeDisk`，与 `drive.diskIdentifier` 比较
    let bootParentWholeDisk: String?
    let rwDepsReady: Bool
    let formatMkReady: Bool
    @Binding var autoMountReadWriteGloballyEnabled: Bool
    let onOpenDependencyTab: () -> Void
    let onOpenOptionsTab: () -> Void
    let onAction: (DriveAction) -> Void
    @State private var autoReadWriteEnabled = false
    @State private var autoReadWriteSupported = true
    @State private var showNeedGlobalAutoMountAlert = false
    
    private var isOnSystemBootDisk: Bool {
        guard let b = bootParentWholeDisk else { return false }
        return drive.diskIdentifier == b
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isOnSystemBootDisk {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(VolFerryTheme.warning)
                    Text("此分区位于系统启动磁盘。已隐藏格式化、推出与安全移除，避免误操作。")
                        .font(.callout)
                        .foregroundStyle(VolFerryTheme.textSecondary(dark))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelectable()
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VolFerryTheme.warning.opacity(dark ? 0.14 : 0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(drive.displayName)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(VolFerryTheme.textPrimary(dark))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .textSelectable()
                        Text("NTFS 分区")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(VolFerryTheme.accent.opacity(0.95))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(VolFerryTheme.accent.opacity(dark ? 0.2 : 0.12), in: Capsule())
                            .textSelectable()
                        PartitionTypeBadge(content: drive.partitionContent, dark: dark)
                        Spacer(minLength: 8)
                        statusBadge
                        if rwDepsReady {
                            Toggle("NTFS 自动读写", isOn: Binding(
                                get: { autoMountReadWriteGloballyEnabled && autoReadWriteEnabled },
                                set: { newValue in
                                    guard autoReadWriteSupported else { return }
                                    if newValue {
                                        if !autoMountReadWriteGloballyEnabled {
                                            showNeedGlobalAutoMountAlert = true
                                            return
                                        }
                                        autoReadWriteEnabled = true
                                        Task { await AutoMountManager.shared.setReadWriteTarget(drive, enabled: true) }
                                    } else {
                                        autoReadWriteEnabled = false
                                        Task { await AutoMountManager.shared.setReadWriteTarget(drive, enabled: false) }
                                    }
                                }
                            ))
                            .font(.caption.weight(.semibold))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .tint(VolFerryTheme.accent)
                            .disabled(!autoReadWriteSupported)
                            .help(autoReadWriteHelp)
                        }
                    }
                    PartitionSpaceHighlight(
                        dark: dark,
                        capacityText: drive.sizeFormatted,
                        usedText: (drive.isMounted && !drive.volumePath.isEmpty) ? drive.usedFormatted : nil,
                        freeText: (drive.isMounted && !drive.volumePath.isEmpty) ? drive.freeFormatted : nil,
                        usedPercent: drive.usedPercent
                    )
                }
            }
            HStack(spacing: 8) {
                if !drive.isMounted {
                    DriveCardToolbarButton(
                        title: "挂载",
                        systemImage: VolFerryTheme.DeviceToolbar.systemImage(.mount),
                        dark: dark,
                        tint: VolFerryTheme.DeviceToolbar.tint(.mount),
                        disabled: false,
                        exclusiveActiveTint: nil,
                        helpText: "使用系统方式挂载（diskutil mount；NTFS 多为只读）。挂载后可点「读写」切换读写。",
                        action: { onAction(.mountSystem) }
                    )
                } else {
                    /// 读写 / 只读：仅已挂载时显示，与「挂载」互斥；依赖 MacFUSE + ntfs-3g
                    Group {
                        if rwDepsReady {
                            if drive.isReadWrite {
                                DriveCardToolbarButton(
                                    title: "只读",
                                    systemImage: VolFerryTheme.DeviceToolbar.systemImage(.readOnly),
                                    dark: dark,
                                    tint: VolFerryTheme.DeviceToolbar.tint(.readOnly),
                                    disabled: false,
                                    exclusiveActiveTint: nil,
                                    helpText: "还原为系统只读挂载",
                                    action: { onAction(.restoreReadOnly) }
                                )
                            } else {
                                DriveCardToolbarButton(
                                    title: "读写",
                                    systemImage: VolFerryTheme.DeviceToolbar.systemImage(.readWrite),
                                    dark: dark,
                                    tint: VolFerryTheme.DeviceToolbar.tint(.readWrite),
                                    disabled: false,
                                    exclusiveActiveTint: nil,
                                    helpText: "以读写方式挂载此卷",
                                    action: { onAction(.mountReadWrite) }
                                )
                            }
                        } else {
                            DriveCardToolbarButton(
                                title: "安装依赖",
                                systemImage: VolFerryTheme.DeviceToolbar.systemImage(.installDeps),
                                dark: dark,
                                tint: VolFerryTheme.DeviceToolbar.tint(.installDeps),
                                disabled: false,
                                exclusiveActiveTint: nil,
                                helpText: "读写挂载需 MacFUSE 与 ntfs-3g。点此前往「依赖」完成安装。",
                                action: { onOpenDependencyTab() }
                            )
                        }
                    }
                    if !isOnSystemBootDisk {
                        DriveCardToolbarButton(
                            title: "推出",
                            systemImage: VolFerryTheme.DeviceToolbar.systemImage(.unmount),
                            dark: dark,
                            tint: VolFerryTheme.DeviceToolbar.tint(.unmount),
                            disabled: false,
                            exclusiveActiveTint: nil,
                            helpText: "推出此卷（移除挂载点；外置设备未断电时可再次挂载）",
                            action: { onAction(.unmount) }
                        )
                    }
                }
                if !isOnSystemBootDisk {
                    if formatMkReady {
                        DriveCardToolbarButton(
                            title: "格式化",
                            systemImage: VolFerryTheme.DeviceToolbar.systemImage(.format),
                            dark: dark,
                            tint: VolFerryTheme.DeviceToolbar.tint(.format),
                            disabled: false,
                            exclusiveActiveTint: nil,
                            helpText: "打开格式化面板并预选当前分区（将清空数据）",
                            action: { onAction(.format) }
                        )
                    } else {
                        DriveCardToolbarButton(
                            title: "安装依赖",
                            systemImage: VolFerryTheme.DeviceToolbar.systemImage(.installDeps),
                            dark: dark,
                            tint: VolFerryTheme.DeviceToolbar.tint(.installDeps),
                            disabled: false,
                            exclusiveActiveTint: nil,
                            helpText: "格式化为 NTFS 需 mkntfs（随 ntfs-3g-mac）。点此前往「依赖」完成安装。",
                            action: { onOpenDependencyTab() }
                        )
                    }
                }
                if drive.isEjectable && !isOnSystemBootDisk {
                    DriveCardToolbarButton(
                        title: "安全移除",
                        systemImage: VolFerryTheme.DeviceToolbar.systemImage(.eject),
                        dark: dark,
                        tint: VolFerryTheme.DeviceToolbar.tint(.eject),
                        disabled: false,
                        exclusiveActiveTint: nil,
                        helpText: "推出卷后断开整个磁盘，可安全拔掉外置设备",
                        action: { onAction(.eject) }
                    )
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(VolFerryTheme.bgSecondary(dark))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [VolFerryTheme.border(dark).opacity(0.9), VolFerryTheme.border(dark).opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(dark ? 0.35 : 0.08), radius: 12, y: 4)
        )
        .task(id: drive.partitionIdentifier) {
            autoReadWriteSupported = AutoMountManager.stableID(for: drive) != nil
            guard autoReadWriteSupported else {
                autoReadWriteEnabled = false
                return
            }
            autoReadWriteEnabled = await AutoMountManager.shared.isReadWriteTarget(drive)
        }
        .onChange(of: autoMountReadWriteGloballyEnabled) { _, globalOn in
            if !globalOn {
                autoReadWriteEnabled = false
            } else {
                Task {
                    guard autoReadWriteSupported else { return }
                    autoReadWriteEnabled = await AutoMountManager.shared.isReadWriteTarget(drive)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .autoMountTargetsChanged)) { _ in
            Task {
                guard autoReadWriteSupported else { return }
                autoReadWriteEnabled = await AutoMountManager.shared.isReadWriteTarget(drive)
            }
        }
        .alert("需要先开启全局自动读写", isPresented: $showNeedGlobalAutoMountAlert) {
            Button("开启并勾选此分区") {
                autoMountReadWriteGloballyEnabled = true
                autoReadWriteEnabled = true
                Task { await AutoMountManager.shared.setReadWriteTarget(drive, enabled: true) }
            }
            Button("前往选项") {
                onOpenOptionsTab()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该功能由「选项 → NTFS 自动读写」中的总开关控制。可前往选项手动开启，或一键同时为当前分区开启全局与勾选。")
        }
    }
    
    private var autoReadWriteHelp: String {
        if !autoReadWriteSupported {
            return "该分区缺少稳定 UUID，暂不支持 NTFS 自动读写"
        }
        if !autoMountReadWriteGloballyEnabled {
            return "全局自动读写未开启：打开开关时将提示前往选项或一键开启全局并勾选此分区"
        }
        return "NTFS 自动读写：检测到该分区时自动以读写挂载（依赖全局总开关）"
    }
    
    @ViewBuilder
    private var statusBadge: some View {
        if drive.isMounted {
            Text(drive.isReadWrite ? "读写" : "只读")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(drive.isReadWrite ? VolFerryTheme.success : VolFerryTheme.warning)
                .background(
                    (drive.isReadWrite ? VolFerryTheme.success : VolFerryTheme.warning).opacity(0.18),
                    in: Capsule()
                )
                .textSelectable()
        } else {
            Text("未挂载")
                .font(.callout.weight(.medium))
                .foregroundStyle(VolFerryTheme.textSecondary(dark))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(VolFerryTheme.bgTertiary(dark), in: Capsule())
                .textSelectable()
        }
    }
    
}

/// 设备卡片工具栏按钮：悬停高亮边框与背景，按下缩放与加深
private struct DriveCardToolbarButton: View {
    let title: String
    let systemImage: String
    let dark: Bool
    let tint: Color
    let disabled: Bool
    /// 非 nil 时表示因「已是该模式」而禁用，用此色做实心高亮（与读写/只读另一侧互斥）
    let exclusiveActiveTint: Color?
    let helpText: String
    let action: () -> Void
    
    @State private var hovered = false
    
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .frame(minHeight: 26)
                .foregroundStyle(foregroundTint)
                .textSelectable()
        }
        .buttonStyle(
            DriveCardToolbarButtonStyle(
                hovered: hovered,
                dark: dark,
                tint: tint,
                disabled: disabled,
                exclusiveActiveTint: exclusiveActiveTint
            )
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .disabled(disabled)
        .help(helpText)
        .onHover { if !disabled { hovered = $0 } }
        .pointingHandOnHover(enabled: !disabled)
        .onChange(of: disabled) { _, nowDisabled in
            if nowDisabled { hovered = false }
        }
    }
    
    private var foregroundTint: Color {
        if let c = exclusiveActiveTint {
            return c
        }
        if disabled {
            return VolFerryTheme.textSecondary(dark).opacity(0.45)
        }
        return tint
    }
}

private struct DriveCardToolbarButtonStyle: ButtonStyle {
    var hovered: Bool
    var dark: Bool
    var tint: Color
    var disabled: Bool
    var exclusiveActiveTint: Color?
    
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fillColor(pressed: pressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(borderColor(pressed: pressed), lineWidth: borderWidth(pressed: pressed))
            )
            .scaleEffect(pressed && !disabled ? 0.96 : 1)
            .opacity(disabled && exclusiveActiveTint == nil ? 0.85 : 1)
            .animation(.easeOut(duration: 0.14), value: pressed)
            .animation(.easeOut(duration: 0.16), value: hovered)
    }
    
    private func fillColor(pressed: Bool) -> Color {
        if let mode = exclusiveActiveTint {
            return mode.opacity(dark ? 0.3 : 0.22)
        }
        guard !disabled else {
            return VolFerryTheme.bgTertiary(dark).opacity(0.5)
        }
        if pressed {
            return tint.opacity(dark ? 0.38 : 0.26)
        }
        if hovered {
            return tint.opacity(dark ? 0.2 : 0.14)
        }
        return tint.opacity(dark ? 0.1 : 0.07)
    }
    
    private func borderColor(pressed: Bool) -> Color {
        if let mode = exclusiveActiveTint {
            return mode.opacity(0.55)
        }
        guard !disabled else {
            return VolFerryTheme.border(dark).opacity(0.35)
        }
        if pressed {
            return tint.opacity(0.95)
        }
        if hovered {
            return tint.opacity(0.72)
        }
        return tint.opacity(0.32)
    }
    
    private func borderWidth(pressed: Bool) -> CGFloat {
        if disabled && exclusiveActiveTint == nil { return 0.5 }
        if pressed { return 1.35 }
        if hovered { return 1.15 }
        return 0.75
    }
}

enum DriveAction {
    /// 系统 `diskutil mount`（多为只读 NTFS / 普通卷），无需 sudo
    case mountSystem
    case mountReadWrite
    case unmount
    case eject
    case restoreReadOnly
    /// 打开格式化面板（由卡片处理，不经过 perform）
    case format
    
    func progressMessage(for name: String) -> String {
        switch self {
        case .mountSystem: return "正在挂载 \(name)…"
        case .mountReadWrite: return "正在以读写挂载 \(name)…"
        case .unmount: return "正在推出 \(name)…"
        case .eject: return "正在安全移除 \(name)…"
        case .restoreReadOnly: return "正在还原只读 \(name)…"
        case .format: return ""
        }
    }
}

#Preview {
    MainView()
}
