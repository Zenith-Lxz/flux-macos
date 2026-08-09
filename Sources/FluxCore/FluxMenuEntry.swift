/// Entries shown in the menu bar status menu, in display order.
///
/// Contract (design spec §8): the menu bar provides “暂停 Flux”, “打开权限设置”,
/// “开机启动”, “显示快捷键”, and “退出”. Order, titles, and raw identifiers are
/// frozen; `FluxMenuEntryTests` pins the contract and the AppKit menu is built
/// from this model.
public enum FluxMenuEntry: String, CaseIterable, Sendable, Equatable {
    case pause
    case permissions
    case launchAtLogin
    case showShortcuts
    case quit

    public var title: String {
        switch self {
        case .pause:
            return "暂停 Flux"
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
