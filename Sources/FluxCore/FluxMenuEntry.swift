/// Entries shown in the menu bar status menu, in display order.
///
/// Contract (design spec §8, §9): the menu bar provides the runtime controls,
/// the native settings window, permission/login shortcuts, shortcut help, and
/// Quit. Order, titles, and raw identifiers are pinned by tests.
public enum FluxMenuEntry: String, CaseIterable, Sendable, Equatable {
    case pause
    case settings
    case permissions
    case launchAtLogin
    case showShortcuts
    case quit

    public var title: String {
        switch self {
        case .pause:
            return "暂停 Flux"
        case .settings:
            return "设置…"
        case .permissions:
            return "打开权限设置"
        case .launchAtLogin:
            return "开机启动"
        case .showShortcuts:
            return "显示快捷键"
        case .quit:
            return "退出"
        }
    }
}
