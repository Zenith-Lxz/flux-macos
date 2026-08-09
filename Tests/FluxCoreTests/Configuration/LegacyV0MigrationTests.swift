import Foundation
import Testing
@testable import FluxCore

// MARK: - v0 migration

struct LegacyV0MigrationTests {
    private func decodeV0(_ json: String) throws -> LegacyV0Configuration {
        try JSONDecoder().decode(LegacyV0Configuration.self, from: Data(json.utf8))
    }

    @Test func fullV0MigratesToV1() throws {
        let json = """
        {
          "version": 0,
          "enabled": false,
          "apps": {
            "a": "com.example.ares",
            "c": "com.example.codex",
            "g": "com.example.chrome",
            "x": "com.example.wechat",
            "l": "com.example.lark",
            "w": "com.example.wps",
            "h": "com.example.hermes",
            "f": "com.example.finder"
          },
          "pointerSpeed": 1.5
        }
        """
        let config = try decodeV0(json).migrated()
        #expect(config.schemaVersion == FluxConfiguration.currentSchemaVersion)
        #expect(!config.enabled)
        #expect(config.applications.ares == "com.example.ares")
        #expect(config.applications.codex == "com.example.codex")
        #expect(config.applications.chrome == "com.example.chrome")
        #expect(config.applications.wechat == "com.example.wechat")
        #expect(config.applications.lark == "com.example.lark")
        #expect(config.applications.wps == "com.example.wps")
        #expect(config.applications.hermes == "com.example.hermes")
        #expect(config.applications.finder == "com.example.finder")
        #expect(config.pointerSpeedMultiplier == 1.5)
        // v0 has no mapping switches; every mapping default stays true.
        #expect(config.mappings == FluxConfiguration.Mappings.default)
    }

    @Test func partialV0UsesCurrentDefaults() throws {
        let json = """
        {
          "version": 0,
          "apps": { "a": "com.example.only" },
          "pointerSpeed": 9.9
        }
        """
        let config = try decodeV0(json).migrated()
        #expect(config.enabled) // missing -> current default true
        #expect(config.applications.ares == "com.example.only")
        #expect(config.applications.codex == AppBundleIdentifier.codex.rawValue)
        #expect(config.applications.chrome == AppBundleIdentifier.chrome.rawValue)
        #expect(config.applications.wechat == AppBundleIdentifier.wechat.rawValue)
        #expect(config.applications.lark == AppBundleIdentifier.lark.rawValue)
        #expect(config.applications.wps == AppBundleIdentifier.wps.rawValue)
        #expect(config.applications.hermes == AppBundleIdentifier.hermes.rawValue)
        #expect(config.applications.finder == AppBundleIdentifier.finder.rawValue)
        #expect(config.pointerSpeedMultiplier == 2.0) // out-of-range clamps
    }

    @Test func minimalV0MigratesToAllDefaults() throws {
        let config = try decodeV0(#"{"version": 0}"#).migrated()
        #expect(config == FluxConfiguration.default)
    }

    @Test func v0MissingAppsAndPointerSpeedUseDefaults() throws {
        let config = try decodeV0(#"{"version": 0, "enabled": true}"#).migrated()
        #expect(config == FluxConfiguration.default)
    }

    @Test func nullEmptyAndScriptLikeV0AppsUseDefaults() throws {
        let json = """
        {
          "version": 0,
          "apps": { "a": null, "c": "", "g": "  ", "x": "$(rm -rf /)" },
          "enabled": null,
          "pointerSpeed": 0.1
        }
        """
        let config = try decodeV0(json).migrated()
        #expect(config.enabled) // null -> current default true
        #expect(config.applications.ares == AppBundleIdentifier.ares.rawValue)
        #expect(config.applications.codex == AppBundleIdentifier.codex.rawValue)
        #expect(config.applications.chrome == AppBundleIdentifier.chrome.rawValue)
        #expect(config.applications.wechat == AppBundleIdentifier.wechat.rawValue)
        #expect(config.applications.lark == AppBundleIdentifier.lark.rawValue)
        #expect(config.applications.wps == AppBundleIdentifier.wps.rawValue)
        #expect(config.applications.hermes == AppBundleIdentifier.hermes.rawValue)
        #expect(config.applications.finder == AppBundleIdentifier.finder.rawValue)
        #expect(config.pointerSpeedMultiplier == 0.5) // low clamp
    }

    @Test func v0AppIDsAreTrimmed() throws {
        let json = #"{"version": 0, "apps": {"a": "  com.example.trimmed  \n"}}"#
        let config = try decodeV0(json).migrated()
        #expect(config.applications.ares == "com.example.trimmed")
    }
}
