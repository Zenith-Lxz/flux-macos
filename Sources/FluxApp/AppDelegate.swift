import AppKit
import FluxCore

/// Application delegate: owns the app lifecycle, the status menu, and the
/// permission/login wiring (design spec §8, §9).
///
/// Launch sequence: context observation starts first, then the status menu
/// is installed, the pause callback is wired, permission and login-item
/// status are refreshed, and the input engine starts only when the
/// permission snapshot is ready. Permission state is polled every two
/// seconds only while not ready and re-checked whenever the menu opens;
/// permission requests are never automatic — the one-time first-launch
/// explanatory alert only offers them through its authorization button.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // MARK: - Configuration

    private let configurationStore: FluxConfigurationStore
    private var configuration: FluxConfiguration
    private let configurationLoadSource: ConfigurationSource
    private let startupMode: FluxStartupMode
    private var isApplyingConfiguration = false

    // MARK: - Owned controllers

    private let contextRuntime = MacOSContextRuntime()
    private let focusController = MacOSFocusController()
    private let pointerController = MacOSPointerController()
    private let permissionController = MacOSPermissionController()
    private let loginItemController = MacOSLoginItemController()
    private var settingsWindowController: FluxSettingsWindowController?

    /// The input engine is created lazily: construction has no side
    /// effects, and `start()` is called only when permissions are ready.
    private lazy var inputEngine = MacOSGlobalInputEngine(
        contextRuntime: contextRuntime,
        focusController: focusController,
        pointerController: pointerController,
        configuration: configuration
    )

    // MARK: - Status / polling state

    private var statusItem: NSStatusItem?
    private var permissionPollTimer: Timer?
    private var contextReturnFailureTimer: Timer?
    private var isContextReturnFailureVisible = false
    private var pauseMenuItem: NSMenuItem?
    private var launchAtLoginMenuItem: NSMenuItem?

    /// True after a failed engine `start()` was logged, so the constant
    /// failure message is logged once per failure episode instead of on
    /// every ready refresh (for example on every menu open). Reset as soon
    /// as the engine runs again.
    private var startFailureLogged = false

    /// Poll interval while permissions are missing (design spec §8).
    private static let permissionPollInterval: TimeInterval = 2.0

    /// Brief enough to remain ambient, long enough for the menu-bar icon and
    /// tooltip to be noticed after an empty single-Caps Return.
    private static let contextReturnFailureDuration: TimeInterval = 0.8

    /// UserDefaults key for the one-time first-launch permission alert.
    private static let onboardingPermissionAlertKey = "FluxOnboardingPermissionAlertPresented"

    override init() {
        let store = FluxConfigurationStore(fileURL: FluxConfigurationStore.defaultFileURL())
        let loadResult = store.load()
        self.configurationStore = store
        self.configuration = loadResult.configuration
        self.configurationLoadSource = loadResult.source
        self.startupMode = FluxStartupMode(environment: ProcessInfo.processInfo.environment)
        super.init()
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        logConfigurationFallbackIfNeeded()
        contextRuntime.start()
        installStatusItem()
        inputEngine.onPauseStateChange = { [weak self] _ in
            self?.pauseStateDidChange()
        }
        inputEngine.onListeningFailure = { [weak self] in
            self?.inputEngineListeningDidFail()
        }
        inputEngine.onContextReturnFailure = { [weak self] in
            self?.showContextReturnFailure()
        }
        refreshPermissionState()
        refreshLoginItemState()
        presentOnboardingIfNeeded()
        finishStartupSmokeIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopPermissionPolling()
        contextReturnFailureTimer?.invalidate()
        inputEngine.stop()
        contextRuntime.stop()
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        for entry in FluxMenuEntry.allCases {
            let menuItem = NSMenuItem(
                title: entry.title,
                action: #selector(menuItemSelected(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = entry.rawValue
            switch entry {
            case .pause:
                pauseMenuItem = menuItem
            case .launchAtLogin:
                launchAtLoginMenuItem = menuItem
            default:
                break
            }
            menu.addItem(menuItem)
        }
        item.menu = menu
        statusItem = item
        updatePauseMenuItem()
        refreshLoginItemState()
        updateStatusItem(snapshot: currentPermissionSnapshot())
    }

    /// Makes the running / paused / listening-failed / permissions-needed
    /// state visible in the menu bar with minimal symbols; the app stays a
    /// menu-bar-only accessory (no Dock icon). Never shows an alert for
    /// missing permissions or a failed engine start here.
    private func updateStatusItem(snapshot: PermissionSnapshot) {
        guard let button = statusItem?.button else { return }
        let symbolName: String
        let fallbackTitle: String
        let toolTip: String
        let runtimeStatus = AppRuntimeStatus.resolve(
            permissionReady: snapshot.isReady,
            inputEngineRunning: inputEngine.isRunning,
            paused: inputEngine.isPaused,
            contextReturnFailed: isContextReturnFailureVisible
        )
        switch runtimeStatus {
        case .permissionsNeeded:
            symbolName = "exclamationmark.triangle.fill"
            fallbackTitle = "⚠ Flux"
            toolTip = "Flux — 需要权限"
        case .listeningFailed:
            // Permissions are granted but the engine failed to start (HID
            // manager or event tap); the next menu-open refresh retries.
            symbolName = "bolt.slash.fill"
            fallbackTitle = "✕ Flux"
            toolTip = "Flux — 监听失败"
        case .contextReturnFailed:
            symbolName = "exclamationmark.circle.fill"
            fallbackTitle = "! Flux"
            toolTip = "Flux — 没有可返回的位置"
        case .paused:
            symbolName = "pause.fill"
            fallbackTitle = "⏸ Flux"
            toolTip = "Flux — 已暂停"
        case .running:
            symbolName = "keyboard"
            fallbackTitle = "Flux"
            toolTip = "Flux — 运行中"
        }
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = fallbackTitle
        }
        button.toolTip = toolTip
    }

    // MARK: - Menu

    @objc private func menuItemSelected(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let entry = FluxMenuEntry(rawValue: rawValue) else {
            return
        }
        switch entry {
        case .pause:
            inputEngine.togglePaused()
        case .settings:
            showSettings()
        case .permissions:
            permissionController.requestAndOpenRelevantSettings()
            refreshPermissionState()
        case .launchAtLogin:
            toggleLaunchAtLogin()
        case .showShortcuts:
            showShortcuts()
        case .quit:
            NSApp.terminate(nil)
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        refreshPermissionState()
        refreshLoginItemState()
        updatePauseMenuItem()
    }

    // MARK: - Permissions

    /// Re-reads the permission snapshot, reconciles the input engine first
    /// (started only when ready, stopped and polled when not), then updates
    /// the status item and the Pause menu from the engine's actual state.
    /// A failed `start()` leaves the engine off: the menu bar shows the
    /// listening-failed state and the next menu-open refresh retries the
    /// start; no ready-state polling retries it in between. Never prompts.
    private func refreshPermissionState() {
        let snapshot = currentPermissionSnapshot()
        if snapshot.isReady {
            stopPermissionPolling()
            // start() is idempotent, so repeated ready refreshes (for
            // example on every menu open) never re-install the engine.
            if inputEngine.start() {
                startFailureLogged = false
            } else {
                logStartFailureIfNeeded()
            }
        } else {
            inputEngine.stop()
            startPermissionPolling()
        }
        updateStatusItem(snapshot: snapshot)
        updatePauseMenuItem()
        refreshSettingsWindow()
    }

    /// Logs the engine start failure exactly once per failure episode. The
    /// message is a constant string (privacy boundary, design spec §8) and
    /// the engine's own logs already carry the specific IOReturn/creation
    /// codes; no alert is shown and nothing repeats on every menu open.
    private func logStartFailureIfNeeded() {
        guard !startFailureLogged else { return }
        startFailureLogged = true
        NSLog("Flux: input engine failed to start; keyboard listening is unavailable")
    }

    private func inputEngineListeningDidFail() {
        updateStatusItem(snapshot: currentPermissionSnapshot())
        updatePauseMenuItem()
        refreshSettingsWindow()
    }

    /// Shows a transient status-only failure when Return has no valid target.
    /// Repeated empty Returns extend the same 0.8-second window; no alert,
    /// overlay, sound, or focus change is introduced.
    private func showContextReturnFailure() {
        contextReturnFailureTimer?.invalidate()
        isContextReturnFailureVisible = true
        updateStatusItem(snapshot: currentPermissionSnapshot())

        let timer = Timer(
            timeInterval: Self.contextReturnFailureDuration,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isContextReturnFailureVisible = false
                self.contextReturnFailureTimer = nil
                self.updateStatusItem(snapshot: self.currentPermissionSnapshot())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        contextReturnFailureTimer = timer
    }

    /// Polls the permission snapshot while it is not ready. The timer is
    /// scheduled on the main run loop, so the callback runs on the main
    /// thread; `MainActor.assumeIsolated` expresses that contract the same
    /// way the event-tap callback does.
    private func startPermissionPolling() {
        guard startupMode == .normal else { return }
        guard permissionPollTimer == nil else { return }
        let timer = Timer(
            timeInterval: Self.permissionPollInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPermissionState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    // MARK: - Pause

    private func pauseStateDidChange() {
        if !isApplyingConfiguration {
            configuration.enabled = !inputEngine.isPaused
            do {
                try configurationStore.save(configuration)
            } catch {
                logConfigurationSaveFailure(error)
            }
        }
        updatePauseMenuItem()
        updateStatusItem(snapshot: currentPermissionSnapshot())
        refreshSettingsWindow()
    }

    private func updatePauseMenuItem() {
        guard let item = pauseMenuItem else { return }
        // Pause is meaningful only while the engine is actually running: it
        // stays disabled when permissions are missing and when a ready
        // start() failed (listening-failed state).
        item.isEnabled = inputEngine.isRunning
        item.title = inputEngine.isPaused ? "恢复 Flux" : "暂停 Flux"
    }

    // MARK: - Launch at login

    private func refreshLoginItemState() {
        guard let item = launchAtLoginMenuItem else { return }
        // Every status the current SDK defines is mapped explicitly;
        // @unknown default stays only as a forward-compat safety net.
        switch loginItemController.status {
        case .enabled:
            item.state = .on
            item.title = FluxMenuEntry.launchAtLogin.title
        case .requiresApproval:
            // Mixed state plus a pending title so the user can see the
            // system approval is still outstanding (design spec §7.1).
            item.state = .mixed
            item.title = "开机启动（待批准）"
        case .notRegistered, .notFound:
            item.state = .off
            item.title = FluxMenuEntry.launchAtLogin.title
        @unknown default:
            item.state = .off
            item.title = FluxMenuEntry.launchAtLogin.title
        }
        refreshSettingsWindow()
    }

    private func toggleLaunchAtLogin() {
        switch performLaunchAtLoginToggle() {
        case .success:
            break
        case .failure:
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "开机启动设置失败"
            alert.informativeText = "无法更新开机启动状态，请稍后重试。"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    private func performLaunchAtLoginToggle() -> Result<SettingsLaunchAtLoginState, Error> {
        switch loginItemController.toggle() {
        case .success:
            refreshLoginItemState()
            return .success(settingsLaunchAtLoginState())
        case .failure(let error):
            logLaunchAtLoginFailure(error)
            return .failure(error)
        }
    }

    private func logLaunchAtLoginFailure(_ error: Error) {
        let nsError = error as NSError
        // Log only the error domain and code; the full error may embed local
        // paths or private metadata (design spec §8).
        NSLog(
            "Flux: launch at login toggle failed (domain: %@, code: %ld)",
            nsError.domain,
            nsError.code
        )
    }

    // MARK: - First-launch onboarding

    /// Presents the one-time explanatory alert when permissions are
    /// missing. This is the only automatic UI: the UserDefaults flag is set
    /// before presentation so the alert can never appear twice, and the
    /// permission request path runs only when the user picks the
    /// authorization button (design spec §8).
    private func presentOnboardingIfNeeded() {
        guard startupMode == .normal else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.onboardingPermissionAlertKey) else { return }
        guard !currentPermissionSnapshot().isReady else { return }
        defaults.set(true, forKey: Self.onboardingPermissionAlertKey)

        let alert = NSAlert()
        alert.messageText = "Flux 需要两项系统权限"
        alert.informativeText = "「辅助功能」权限让 Flux 读取界面焦点并恢复应用窗口；「输入监控」权限让 Flux 拦截 Caps 键并保留无鼠标逃生路径。\n\n你可以随时通过菜单栏的「打开权限设置」修改这些权限。"
        alert.addButton(withTitle: "打开权限设置")
        alert.addButton(withTitle: "稍后")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            permissionController.requestAndOpenRelevantSettings()
            refreshPermissionState()
        }
    }

    /// Ends the assembled-app startup smoke only after the same AppKit setup
    /// used by a real launch has completed. The forced denied snapshot kept
    /// the input engine stopped, onboarding was skipped without writing
    /// UserDefaults, and no permission prompt was issued.
    private func finishStartupSmokeIfNeeded() {
        guard startupMode.shouldExitAfterStartup else { return }
        print(FluxStartupMode.noPermissionSmokeSuccessLine)
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Shortcuts

    /// The frozen v1 shortcut list (design spec §3.1, §3.2, §3.3, §8).
    /// Shown in a restrained native alert; no overlay or custom panel.
    private static let shortcutList = """
        单击 Caps：返回上一个位置
        Caps + 方向键：移动界面焦点
        Caps + Option + 方向键：移动指针（长按加速，+ Shift 快速）
        Caps + Option + Return：单击；Caps + Option + Shift + Return：双击
        Caps + Command + 字母：直达应用（A ARES、C Codex、G Chrome、X 微信、L 飞书、W WPS、H Hermes、F Finder）
        Caps + Command + Escape：暂停 / 恢复
        Caps + B/N/P/F：文本光标移动；Caps + H：退格；Caps + O：回车
        Caps + Space：保留输入法切换
        其他 Caps + 键：透传为 Right Control + 键
        Left Control：作为 Left Command；Left Control + M：回车
        Command + E：Command + M
        """

    private func showShortcuts() {
        let alert = NSAlert()
        alert.messageText = "Flux 快捷键"
        alert.informativeText = Self.shortcutList
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - Settings and configuration persistence

    private func showSettings() {
        let controller: FluxSettingsWindowController
        if let existing = settingsWindowController {
            controller = existing
        } else {
            controller = FluxSettingsWindowController(
                onApplyConfiguration: { [weak self] configuration in
                    guard let self else {
                        return .failure(FluxSettingsError.applicationUnavailable)
                    }
                    return self.persistAndApplyConfiguration(configuration)
                },
                onOpenPermissions: { [weak self] in
                    guard let self else { return }
                    self.permissionController.requestAndOpenRelevantSettings()
                    self.refreshPermissionState()
                },
                onToggleLaunchAtLogin: { [weak self] in
                    guard let self else {
                        return .failure(FluxSettingsError.applicationUnavailable)
                    }
                    return self.performLaunchAtLoginToggle()
                }
            )
            settingsWindowController = controller
        }
        controller.present(
            configuration: configuration,
            permissionSnapshot: currentPermissionSnapshot(),
            launchAtLoginState: settingsLaunchAtLoginState()
        )
    }

    private func persistAndApplyConfiguration(
        _ proposed: FluxConfiguration
    ) -> Result<FluxConfiguration, Error> {
        let sanitized = proposed.sanitized()
        do {
            try configurationStore.save(sanitized)
        } catch {
            logConfigurationSaveFailure(error)
            return .failure(error)
        }

        configuration = sanitized
        isApplyingConfiguration = true
        inputEngine.applyConfiguration(sanitized)
        isApplyingConfiguration = false
        updatePauseMenuItem()
        updateStatusItem(snapshot: currentPermissionSnapshot())
        return .success(sanitized)
    }

    private func refreshSettingsWindow() {
        settingsWindowController?.refresh(
            configuration: configuration,
            permissionSnapshot: currentPermissionSnapshot(),
            launchAtLoginState: settingsLaunchAtLoginState()
        )
    }

    private func settingsLaunchAtLoginState() -> SettingsLaunchAtLoginState {
        switch loginItemController.status {
        case .enabled:
            return .on
        case .requiresApproval:
            return .pendingApproval
        case .notRegistered, .notFound:
            return .off
        @unknown default:
            return .off
        }
    }

    private func currentPermissionSnapshot() -> PermissionSnapshot {
        startupMode.effectivePermissionSnapshot(actual: permissionController.snapshot())
    }

    private func logConfigurationFallbackIfNeeded() {
        switch configurationLoadSource {
        case .currentFile, .migratedV0, .missingDefault:
            break
        case .corruptDefault:
            NSLog("Flux: configuration is corrupt; using built-in defaults")
        case .unsupportedFutureVersionDefault:
            NSLog("Flux: configuration version is unsupported; using built-in defaults")
        }
    }

    private func logConfigurationSaveFailure(_ error: Error) {
        let nsError = error as NSError
        NSLog(
            "Flux: configuration save failed (domain: %@, code: %ld)",
            nsError.domain,
            nsError.code
        )
    }
}

private enum FluxSettingsError: Error {
    case applicationUnavailable
}
