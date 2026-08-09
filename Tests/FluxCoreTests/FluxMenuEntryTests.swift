import Testing
@testable import FluxCore

/// Contract tests for the status menu entries (design spec §8).
/// Order and titles are frozen; the AppKit menu is built from this model.
struct FluxMenuEntryTests {
    @Test func displayOrderMatchesFrozenDesign() {
        #expect(FluxMenuEntry.allCases.map(\.title) == [
            "暂停 Flux",
            "设置…",
            "打开权限设置",
            "开机启动",
            "显示快捷键",
            "退出",
        ])
    }

    @Test func quitIsLastEntry() {
        #expect(FluxMenuEntry.allCases.last == FluxMenuEntry.quit)
    }

    @Test func rawValuesAreStableIdentifiers() {
        // String raw-value enums default to the case name; AppDelegate uses
        // these identifiers to wire menu items, so they must stay stable.
        #expect(FluxMenuEntry.allCases.map(\.rawValue) == [
            "pause",
            "settings",
            "permissions",
            "launchAtLogin",
            "showShortcuts",
            "quit",
        ])
    }
}
