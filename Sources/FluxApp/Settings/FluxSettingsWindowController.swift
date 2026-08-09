import AppKit
import FluxCore

/// Settings-facing launch-at-login state. Keeping the presentation model
/// separate from ServiceManagement makes the window independent of the
/// system mutation API and easy to refresh after an explicit toggle.
enum SettingsLaunchAtLoginState: Sendable, Equatable {
    case off
    case on
    case pendingApproval
}

/// Restrained native settings window for Flux v1 (design spec §9).
///
/// The window is created lazily and appears only when the user chooses
/// Settings. It contains no global overlay, key-hint layer, macro editor, or
/// script field. Application bindings are selected from real `.app` bundles;
/// arbitrary executable text is never accepted.
@MainActor
final class FluxSettingsWindowController: NSWindowController {
    typealias ApplyConfiguration = (FluxConfiguration) -> Result<FluxConfiguration, Error>
    typealias ToggleLaunchAtLogin = () -> Result<SettingsLaunchAtLoginState, Error>

    private enum AppBinding: Int, CaseIterable {
        case ares, codex, chrome, wechat, lark, wps, hermes, finder

        var title: String {
            switch self {
            case .ares: "⌘ A  ARES"
            case .codex: "⌘ C  Codex"
            case .chrome: "⌘ G  Chrome"
            case .wechat: "⌘ X  微信"
            case .lark: "⌘ L  飞书"
            case .wps: "⌘ W  WPS"
            case .hermes: "⌘ H  Hermes"
            case .finder: "⌘ F  Finder"
            }
        }
    }

    private enum Mapping: Int, CaseIterable {
        case capsTextNavigation
        case capsEditing
        case capsInputSource
        case chromeTab
        case leftControlAsCommand
        case leftControlMAsReturn
        case commandEToCommandM
        case legacyTerminalCopy

        var title: String {
            switch self {
            case .capsTextNavigation: "Caps + B/N/P/F  文本光标移动"
            case .capsEditing: "Caps + H/O  退格与回车"
            case .capsInputSource: "Caps + Space  输入法切换"
            case .chromeTab: "Chrome 中 Caps + Tab  切换标签"
            case .leftControlAsCommand: "Left Control  作为 Left Command"
            case .leftControlMAsReturn: "Left Control + M  回车"
            case .commandEToCommandM: "Command + E  映射为 Command + M"
            case .legacyTerminalCopy: "旧终端 Command + C  映射为 Control + C"
            }
        }
    }

    private let onApplyConfiguration: ApplyConfiguration
    private let onOpenPermissions: () -> Void
    private let onToggleLaunchAtLogin: ToggleLaunchAtLogin

    private var configuration = FluxConfiguration.default
    private var permissionSnapshot = PermissionSnapshot(
        accessibilityTrusted: false,
        inputMonitoring: .unknown
    )
    private var launchAtLoginState: SettingsLaunchAtLoginState = .off
    private var rememberedBundleIdentifiers: [AppBinding: String] = [:]

    private let enabledButton = NSButton(
        checkboxWithTitle: "启用 Flux",
        target: nil,
        action: nil
    )
    private let permissionLabel = NSTextField(labelWithString: "")
    private let launchAtLoginButton = NSButton(
        checkboxWithTitle: "开机启动",
        target: nil,
        action: nil
    )
    private let launchAtLoginDetailLabel = NSTextField(labelWithString: "")
    private let speedSlider = NSSlider(value: 1, minValue: 0.5, maxValue: 2, target: nil, action: nil)
    private let speedValueLabel = NSTextField(labelWithString: "1.0×")
    private var appEnabledButtons: [AppBinding: NSButton] = [:]
    private var appIdentifierLabels: [AppBinding: NSTextField] = [:]
    private var mappingButtons: [Mapping: NSButton] = [:]

    init(
        onApplyConfiguration: @escaping ApplyConfiguration,
        onOpenPermissions: @escaping () -> Void,
        onToggleLaunchAtLogin: @escaping ToggleLaunchAtLogin
    ) {
        self.onApplyConfiguration = onApplyConfiguration
        self.onOpenPermissions = onOpenPermissions
        self.onToggleLaunchAtLogin = onToggleLaunchAtLogin

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Flux 设置"
        window.minSize = NSSize(width: 660, height: 560)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildInterface()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Refreshes every external state before presenting the single retained
    /// window. No setting is written merely by opening it.
    func present(
        configuration: FluxConfiguration,
        permissionSnapshot: PermissionSnapshot,
        launchAtLoginState: SettingsLaunchAtLoginState
    ) {
        self.configuration = configuration.sanitized()
        self.permissionSnapshot = permissionSnapshot
        self.launchAtLoginState = launchAtLoginState
        rememberCurrentBundleIdentifiers()
        refreshControls()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Updates an already-visible window after a keyboard/menu pause change,
    /// permission refresh, or launch-at-login change.
    func refresh(
        configuration: FluxConfiguration,
        permissionSnapshot: PermissionSnapshot,
        launchAtLoginState: SettingsLaunchAtLoginState
    ) {
        self.configuration = configuration.sanitized()
        self.permissionSnapshot = permissionSnapshot
        self.launchAtLoginState = launchAtLoginState
        rememberCurrentBundleIdentifiers()
        refreshControls()
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        contentView.addSubview(scrollView)

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        documentView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24),
        ])

        let heading = NSTextField(labelWithString: "键盘优先，不打断当前工作流")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(heading)

        let subheading = NSTextField(
            wrappingLabelWithString: "Flux 只处理这里列出的导航和编辑映射。所有更改保存在本机并立即生效。"
        )
        subheading.textColor = .secondaryLabelColor
        stack.addArrangedSubview(subheading)

        stack.addArrangedSubview(makeGeneralSection())
        stack.addArrangedSubview(makeApplicationsSection())
        stack.addArrangedSubview(makeMappingsSection())
        stack.addArrangedSubview(makePointerSection())
        stack.addArrangedSubview(makeFooter())

        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func makeGeneralSection() -> NSView {
        enabledButton.target = self
        enabledButton.action = #selector(enabledChanged(_:))
        enabledButton.font = .systemFont(ofSize: 14, weight: .medium)

        permissionLabel.textColor = .secondaryLabelColor
        permissionLabel.lineBreakMode = .byTruncatingTail

        let permissionButton = NSButton(title: "打开权限设置", target: self, action: #selector(openPermissions))
        permissionButton.bezelStyle = .rounded

        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(launchAtLoginChanged(_:))
        launchAtLoginButton.allowsMixedState = true
        launchAtLoginDetailLabel.textColor = .secondaryLabelColor

        let permissionRow = horizontalRow([permissionLabel, flexibleSpacer(), permissionButton])
        return section(
            title: "运行",
            views: [enabledButton, permissionRow, launchAtLoginButton, launchAtLoginDetailLabel]
        )
    }

    private func makeApplicationsSection() -> NSView {
        var rows: [NSView] = []
        for binding in AppBinding.allCases {
            let enabled = NSButton(checkboxWithTitle: binding.title, target: self, action: #selector(appEnabledChanged(_:)))
            enabled.tag = binding.rawValue
            enabled.widthAnchor.constraint(equalToConstant: 150).isActive = true

            let identifier = NSTextField(labelWithString: "未绑定")
            identifier.textColor = .secondaryLabelColor
            identifier.lineBreakMode = .byTruncatingMiddle
            identifier.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let choose = NSButton(title: "选择应用…", target: self, action: #selector(selectApplication(_:)))
            choose.tag = binding.rawValue
            choose.bezelStyle = .rounded

            appEnabledButtons[binding] = enabled
            appIdentifierLabels[binding] = identifier
            rows.append(horizontalRow([enabled, identifier, choose]))
        }
        return section(title: "应用直达（Caps + Command）", views: rows)
    }

    private func makeMappingsSection() -> NSView {
        var rows: [NSView] = []
        for mapping in Mapping.allCases {
            let button = NSButton(checkboxWithTitle: mapping.title, target: self, action: #selector(mappingChanged(_:)))
            button.tag = mapping.rawValue
            mappingButtons[mapping] = button
            rows.append(button)
        }
        return section(title: "编辑映射", views: rows)
    }

    private func makePointerSection() -> NSView {
        speedSlider.target = self
        speedSlider.action = #selector(pointerSpeedChanged(_:))
        speedSlider.isContinuous = false
        speedSlider.numberOfTickMarks = 7
        speedSlider.allowsTickMarkValuesOnly = false
        speedSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        speedValueLabel.alignment = .right
        speedValueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        speedValueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        return section(
            title: "指针兜底速度",
            views: [horizontalRow([NSTextField(labelWithString: "移动倍率"), speedSlider, speedValueLabel])]
        )
    }

    private func makeFooter() -> NSView {
        let reset = NSButton(title: "恢复默认值…", target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .rounded
        let note = NSTextField(labelWithString: "不包含宏、脚本、联网或云同步")
        note.textColor = .tertiaryLabelColor
        return horizontalRow([note, flexibleSpacer(), reset])
    }

    private func section(title: String, views: [NSView]) -> NSView {
        let box = NSBox()
        box.title = title
        box.titlePosition = .atTop
        box.boxType = .primary
        guard let content = box.contentView else { return box }

        let stack = NSStackView(views: views)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return box
    }

    private func horizontalRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func refreshControls() {
        enabledButton.state = configuration.enabled ? .on : .off
        refreshPermissionControls()
        refreshLaunchAtLoginControls()

        for binding in AppBinding.allCases {
            let identifier = bundleIdentifier(for: binding)
            appEnabledButtons[binding]?.state = identifier == nil ? .off : .on
            appIdentifierLabels[binding]?.stringValue = identifier ?? "未绑定"
        }

        for mapping in Mapping.allCases {
            mappingButtons[mapping]?.state = mappingEnabled(mapping) ? .on : .off
        }
        speedSlider.doubleValue = configuration.pointerSpeedMultiplier
        speedValueLabel.stringValue = String(format: "%.1f×", configuration.pointerSpeedMultiplier)
    }

    private func refreshPermissionControls() {
        let accessibility = permissionSnapshot.accessibilityTrusted ? "辅助功能：已授权" : "辅助功能：未授权"
        let input: String
        switch permissionSnapshot.inputMonitoring {
        case .granted: input = "输入监控：已授权"
        case .denied: input = "输入监控：未授权"
        case .unknown: input = "输入监控：状态未知"
        }
        permissionLabel.stringValue = "\(accessibility) · \(input)"
        permissionLabel.textColor = permissionSnapshot.isReady ? .secondaryLabelColor : .systemOrange
    }

    private func refreshLaunchAtLoginControls() {
        switch launchAtLoginState {
        case .off:
            launchAtLoginButton.state = .off
            launchAtLoginDetailLabel.stringValue = ""
        case .on:
            launchAtLoginButton.state = .on
            launchAtLoginDetailLabel.stringValue = ""
        case .pendingApproval:
            launchAtLoginButton.state = .mixed
            launchAtLoginDetailLabel.stringValue = "已注册，等待在系统设置中批准"
        }
    }

    private func rememberCurrentBundleIdentifiers() {
        for binding in AppBinding.allCases {
            if let identifier = bundleIdentifier(for: binding) {
                rememberedBundleIdentifiers[binding] = identifier
            }
        }
    }

    private func commit(_ mutation: (inout FluxConfiguration) -> Void) {
        let previous = configuration
        mutation(&configuration)
        switch onApplyConfiguration(configuration.sanitized()) {
        case .success(let applied):
            configuration = applied.sanitized()
            rememberCurrentBundleIdentifiers()
        case .failure:
            configuration = previous
            showWarning(title: "设置未保存", message: "Flux 无法写入本地配置，请检查文件权限后重试。")
        }
        refreshControls()
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        commit { $0.enabled = sender.state == .on }
    }

    @objc private func appEnabledChanged(_ sender: NSButton) {
        guard let binding = AppBinding(rawValue: sender.tag) else { return }
        commit { configuration in
            if sender.state == .on {
                let identifier = rememberedBundleIdentifiers[binding]
                    ?? defaultBundleIdentifier(for: binding)
                setBundleIdentifier(identifier, for: binding, in: &configuration)
            } else {
                setBundleIdentifier(nil, for: binding, in: &configuration)
            }
        }
    }

    @objc private func selectApplication(_ sender: NSButton) {
        guard let binding = AppBinding(rawValue: sender.tag) else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要绑定到 \(binding.title) 的应用"
        panel.prompt = "选择"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK,
              let url = panel.url,
              url.pathExtension.lowercased() == "app",
              let identifier = Bundle(url: url)?.bundleIdentifier else {
            if panel.url != nil {
                showWarning(title: "无法绑定应用", message: "所选项目不是带 bundle identifier 的 macOS 应用。")
            }
            return
        }
        rememberedBundleIdentifiers[binding] = identifier
        commit { setBundleIdentifier(identifier, for: binding, in: &$0) }
    }

    @objc private func mappingChanged(_ sender: NSButton) {
        guard let mapping = Mapping(rawValue: sender.tag) else { return }
        commit { setMapping(mapping, enabled: sender.state == .on, in: &$0) }
    }

    @objc private func pointerSpeedChanged(_ sender: NSSlider) {
        commit { $0.pointerSpeedMultiplier = sender.doubleValue }
    }

    @objc private func openPermissions() {
        onOpenPermissions()
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        switch onToggleLaunchAtLogin() {
        case .success(let state):
            launchAtLoginState = state
        case .failure:
            showWarning(title: "开机启动设置失败", message: "无法更新开机启动状态，请稍后重试。")
        }
        refreshLaunchAtLoginControls()
    }

    @objc private func resetDefaults() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "恢复 Flux 默认设置？"
        alert.informativeText = "应用绑定、编辑映射和指针速度将恢复默认值。"
        alert.addButton(withTitle: "恢复默认值")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        commit { $0 = .default }
    }

    private func showWarning(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func bundleIdentifier(for binding: AppBinding) -> String? {
        switch binding {
        case .ares: configuration.applications.ares
        case .codex: configuration.applications.codex
        case .chrome: configuration.applications.chrome
        case .wechat: configuration.applications.wechat
        case .lark: configuration.applications.lark
        case .wps: configuration.applications.wps
        case .hermes: configuration.applications.hermes
        case .finder: configuration.applications.finder
        }
    }

    private func defaultBundleIdentifier(for binding: AppBinding) -> String? {
        let defaults = FluxConfiguration.default.applications
        return switch binding {
        case .ares: defaults.ares
        case .codex: defaults.codex
        case .chrome: defaults.chrome
        case .wechat: defaults.wechat
        case .lark: defaults.lark
        case .wps: defaults.wps
        case .hermes: defaults.hermes
        case .finder: defaults.finder
        }
    }

    private func setBundleIdentifier(
        _ identifier: String?,
        for binding: AppBinding,
        in configuration: inout FluxConfiguration
    ) {
        switch binding {
        case .ares: configuration.applications.ares = identifier
        case .codex: configuration.applications.codex = identifier
        case .chrome: configuration.applications.chrome = identifier
        case .wechat: configuration.applications.wechat = identifier
        case .lark: configuration.applications.lark = identifier
        case .wps: configuration.applications.wps = identifier
        case .hermes: configuration.applications.hermes = identifier
        case .finder: configuration.applications.finder = identifier
        }
    }

    private func mappingEnabled(_ mapping: Mapping) -> Bool {
        let mappings = configuration.mappings
        return switch mapping {
        case .capsTextNavigation: mappings.capsTextNavigationEnabled
        case .capsEditing: mappings.capsEditingEnabled
        case .capsInputSource: mappings.capsInputSourceEnabled
        case .chromeTab: mappings.chromeTabEnabled
        case .leftControlAsCommand: mappings.leftControlAsCommandEnabled
        case .leftControlMAsReturn: mappings.leftControlMAsReturnEnabled
        case .commandEToCommandM: mappings.commandEToCommandMEnabled
        case .legacyTerminalCopy: mappings.legacyTerminalCopyEnabled
        }
    }

    private func setMapping(
        _ mapping: Mapping,
        enabled: Bool,
        in configuration: inout FluxConfiguration
    ) {
        switch mapping {
        case .capsTextNavigation: configuration.mappings.capsTextNavigationEnabled = enabled
        case .capsEditing: configuration.mappings.capsEditingEnabled = enabled
        case .capsInputSource: configuration.mappings.capsInputSourceEnabled = enabled
        case .chromeTab: configuration.mappings.chromeTabEnabled = enabled
        case .leftControlAsCommand: configuration.mappings.leftControlAsCommandEnabled = enabled
        case .leftControlMAsReturn: configuration.mappings.leftControlMAsReturnEnabled = enabled
        case .commandEToCommandM: configuration.mappings.commandEToCommandMEnabled = enabled
        case .legacyTerminalCopy: configuration.mappings.legacyTerminalCopyEnabled = enabled
        }
    }
}
