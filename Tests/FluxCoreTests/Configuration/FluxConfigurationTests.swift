import Foundation
import Testing
@testable import FluxCore

// MARK: - Defaults

struct FluxConfigurationDefaultsTests {
    @Test func defaultValuesMatchDesign() {
        let config = FluxConfiguration.default
        #expect(config.schemaVersion == FluxConfiguration.currentSchemaVersion)
        #expect(config.schemaVersion == 1)
        #expect(config.enabled)
        #expect(config.pointerSpeedMultiplier == 1.0)

        // Application defaults mirror the frozen AppBundleIdentifier raw values.
        #expect(config.applications.ares == AppBundleIdentifier.ares.rawValue)
        #expect(config.applications.codex == AppBundleIdentifier.codex.rawValue)
        #expect(config.applications.chrome == AppBundleIdentifier.chrome.rawValue)
        #expect(config.applications.wechat == AppBundleIdentifier.wechat.rawValue)
        #expect(config.applications.lark == AppBundleIdentifier.lark.rawValue)
        #expect(config.applications.wps == AppBundleIdentifier.wps.rawValue)
        #expect(config.applications.hermes == AppBundleIdentifier.hermes.rawValue)
        #expect(config.applications.finder == AppBundleIdentifier.finder.rawValue)

        // Mapping switches default on.
        let mappings = config.mappings
        #expect(mappings.capsTextNavigationEnabled)
        #expect(mappings.capsEditingEnabled)
        #expect(mappings.capsInputSourceEnabled)
        #expect(mappings.chromeTabEnabled)
        #expect(mappings.leftControlAsCommandEnabled)
        #expect(mappings.leftControlMAsReturnEnabled)
        #expect(mappings.commandEToCommandMEnabled)
        #expect(mappings.legacyTerminalCopyEnabled)
    }
}

// MARK: - Codable

struct FluxConfigurationCodableTests {
    @Test func defaultRoundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(FluxConfiguration.default)
        let decoded = try JSONDecoder().decode(FluxConfiguration.self, from: data)
        #expect(decoded == FluxConfiguration.default)
    }

    @Test func customizedRoundTripsThroughCodable() throws {
        let custom = FluxConfiguration(
            enabled: false,
            applications: .init(ares: nil, codex: "com.example.codex", wechat: "com.example.wechat"),
            mappings: .init(capsTextNavigationEnabled: false, legacyTerminalCopyEnabled: false),
            pointerSpeedMultiplier: 1.75
        )
        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(FluxConfiguration.self, from: data)
        #expect(decoded == custom)
        #expect(decoded.applications.ares == nil)
        #expect(decoded.applications.codex == "com.example.codex")
        #expect(!decoded.mappings.capsTextNavigationEnabled)
        #expect(!decoded.mappings.legacyTerminalCopyEnabled)
        #expect(decoded.pointerSpeedMultiplier == 1.75)
    }
}

// MARK: - Sanitization

struct FluxConfigurationSanitizationTests {
    @Test func trimsWhitespaceAndNewlinesFromBundleIDs() {
        let clean = FluxConfiguration(
            applications: .init(
                ares: "  com.ares.terminal  ",
                codex: "\ncom.openai.codex\t",
                chrome: " com.google.Chrome\n"
            )
        ).sanitized()
        #expect(clean.applications.ares == "com.ares.terminal")
        #expect(clean.applications.codex == "com.openai.codex")
        #expect(clean.applications.chrome == "com.google.Chrome")
    }

    @Test func emptyAndWhitespaceOnlyBundleIDsBecomeNil() {
        let clean = FluxConfiguration(
            applications: .init(
                ares: "",
                codex: "   \n\t  ",
                chrome: nil
            )
        ).sanitized()
        #expect(clean.applications.ares == nil)
        #expect(clean.applications.codex == nil)
        #expect(clean.applications.chrome == nil)
    }

    @Test func scriptLikeBundleIDsAreRejected() {
        let clean = FluxConfiguration(
            applications: .init(
                ares: "$(rm -rf ~)",
                codex: "com.x; echo pwned",
                chrome: "com.x`touch /tmp/pwned`",
                wechat: "com.x | sh",
                lark: "com.x&&id"
            )
        ).sanitized()
        #expect(clean.applications.ares == nil)
        #expect(clean.applications.codex == nil)
        #expect(clean.applications.chrome == nil)
        #expect(clean.applications.wechat == nil)
        #expect(clean.applications.lark == nil)
    }

    @Test func validBundleIDsSurviveSanitization() {
        let clean = FluxConfiguration(
            applications: .init(
                ares: "com.apple.Safari",
                codex: "com.example.my_app-2",
                chrome: "org.openai.codex"
            )
        ).sanitized()
        #expect(clean.applications.ares == "com.apple.Safari")
        #expect(clean.applications.codex == "com.example.my_app-2")
        #expect(clean.applications.chrome == "org.openai.codex")
    }

    @Test func pointerSpeedIsClampedAndNonFiniteFallsBackToDefault() {
        #expect(FluxConfiguration(pointerSpeedMultiplier: .nan).sanitized().pointerSpeedMultiplier == 1.0)
        #expect(FluxConfiguration(pointerSpeedMultiplier: .infinity).sanitized().pointerSpeedMultiplier == 1.0)
        #expect(FluxConfiguration(pointerSpeedMultiplier: -.infinity).sanitized().pointerSpeedMultiplier == 1.0)
        #expect(FluxConfiguration(pointerSpeedMultiplier: 0.1).sanitized().pointerSpeedMultiplier == 0.5)
        #expect(FluxConfiguration(pointerSpeedMultiplier: 0.5).sanitized().pointerSpeedMultiplier == 0.5)
        #expect(FluxConfiguration(pointerSpeedMultiplier: 1.5).sanitized().pointerSpeedMultiplier == 1.5)
        #expect(FluxConfiguration(pointerSpeedMultiplier: 2.0).sanitized().pointerSpeedMultiplier == 2.0)
        #expect(FluxConfiguration(pointerSpeedMultiplier: 9.9).sanitized().pointerSpeedMultiplier == 2.0)
    }

    @Test func sanitizationRewritesSchemaVersionToCurrent() {
        let clean = FluxConfiguration(schemaVersion: 99, enabled: false).sanitized()
        #expect(clean.schemaVersion == FluxConfiguration.currentSchemaVersion)
        #expect(clean.schemaVersion == 1)
    }
}

// MARK: - Equality

struct FluxConfigurationEqualityTests {
    @Test func equalConfigurationsAreEqual() {
        #expect(FluxConfiguration.default == FluxConfiguration.default)
        #expect(FluxConfiguration() == FluxConfiguration.default)
    }

    @Test func differingFieldsBreakEquality() {
        #expect(FluxConfiguration(enabled: false) != FluxConfiguration.default)
        #expect(FluxConfiguration(pointerSpeedMultiplier: 2.0) != FluxConfiguration.default)
        #expect(FluxConfiguration(applications: .init(ares: nil)) != FluxConfiguration.default)
        #expect(FluxConfiguration(mappings: .init(chromeTabEnabled: false)) != FluxConfiguration.default)
        #expect(FluxConfiguration(schemaVersion: 2) != FluxConfiguration.default)
    }
}

// MARK: - Sendable

struct FluxConfigurationSendableTests {
    // Compile-time proof: a @Sendable closure can only capture Sendable values.
    private let sendableClosure: @Sendable () -> FluxConfiguration = { .default }

    @Test func canCrossSendableBoundary() async {
        let value = await Task.detached { FluxConfiguration.default }.value
        #expect(value == FluxConfiguration.default)
    }
}
