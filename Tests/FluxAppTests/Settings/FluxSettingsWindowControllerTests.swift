import AppKit
import FluxCore
import Testing
@testable import FluxApp

/// Construction-only tests: no window is shown, no permission API is called,
/// and no configuration/login mutation closure may run merely because the
/// controller exists.
struct FluxSettingsWindowControllerTests {
    @Test @MainActor func constructionIsSideEffectFreeAndUsesNativeWindow() {
        var applyCalls = 0
        var permissionCalls = 0
        var loginCalls = 0

        let controller = FluxSettingsWindowController(
            onApplyConfiguration: { configuration in
                applyCalls += 1
                return .success(configuration)
            },
            onOpenPermissions: { permissionCalls += 1 },
            onToggleLaunchAtLogin: {
                loginCalls += 1
                return .success(.off)
            }
        )

        #expect(controller.window?.title == "Flux 设置")
        #expect(controller.window?.styleMask.contains(.titled) == true)
        #expect(applyCalls == 0)
        #expect(permissionCalls == 0)
        #expect(loginCalls == 0)
    }

    @Test func launchAtLoginPresentationStatesAreDistinct() {
        #expect(SettingsLaunchAtLoginState.off != .on)
        #expect(SettingsLaunchAtLoginState.on != .pendingApproval)
        #expect(SettingsLaunchAtLoginState.pendingApproval != .off)
    }
}
