import Foundation

/// Versioned, platform-neutral configuration model for Flux (design spec §9).
///
/// The model is pure value data with no AppKit, CoreGraphics, or
/// ApplicationServices dependency, so it stays unit-testable without macOS
/// permissions. `sanitized()` is the single normalization pass applied when
/// loading v1 files and before every save.
public struct FluxConfiguration: Codable, Sendable, Equatable {
    /// Current on-disk schema version. v1 is the first released schema.
    public static let currentSchemaVersion = 1

    /// Schema version of the encoded document.
    public var schemaVersion: Int
    /// Master switch; when false Flux leaves the keyboard untouched.
    public var enabled: Bool
    /// Bundle identifiers for the eight direct-launch targets.
    public var applications: Applications
    /// Per-mapping switches.
    public var mappings: Mappings
    /// Pointer fallback speed multiplier, clamped to 0.5...2.0.
    public var pointerSpeedMultiplier: Double

    public init(
        schemaVersion: Int = FluxConfiguration.currentSchemaVersion,
        enabled: Bool = true,
        applications: Applications = Applications(),
        mappings: Mappings = Mappings(),
        pointerSpeedMultiplier: Double = 1.0
    ) {
        self.schemaVersion = schemaVersion
        self.enabled = enabled
        self.applications = applications
        self.mappings = mappings
        self.pointerSpeedMultiplier = pointerSpeedMultiplier
    }

    /// Out-of-the-box configuration (design spec §9: 默认配置开箱即用).
    public static let `default` = FluxConfiguration()

    /// Normalized copy: schema rewritten to the current version, bundle IDs
    /// trimmed and validated, pointer speed clamped. Explicit nil application
    /// entries stay nil; only `default` and v0 migration fill missing values.
    public func sanitized() -> FluxConfiguration {
        FluxConfiguration(
            schemaVersion: FluxConfiguration.currentSchemaVersion,
            enabled: enabled,
            applications: Applications(
                ares: Self.sanitizedBundleID(applications.ares),
                codex: Self.sanitizedBundleID(applications.codex),
                chrome: Self.sanitizedBundleID(applications.chrome),
                wechat: Self.sanitizedBundleID(applications.wechat),
                lark: Self.sanitizedBundleID(applications.lark),
                wps: Self.sanitizedBundleID(applications.wps),
                hermes: Self.sanitizedBundleID(applications.hermes),
                finder: Self.sanitizedBundleID(applications.finder)
            ),
            mappings: mappings,
            pointerSpeedMultiplier: Self.sanitizedPointerSpeed(pointerSpeedMultiplier)
        )
    }
}

extension FluxConfiguration {
    /// Bundle identifiers for the eight `Caps + Command + letter` targets.
    /// Defaults mirror the frozen `AppBundleIdentifier` raw values.
    public struct Applications: Codable, Sendable, Equatable {
        public var ares: String?
        public var codex: String?
        public var chrome: String?
        public var wechat: String?
        public var lark: String?
        public var wps: String?
        public var hermes: String?
        public var finder: String?

        public init(
            ares: String? = AppBundleIdentifier.ares.rawValue,
            codex: String? = AppBundleIdentifier.codex.rawValue,
            chrome: String? = AppBundleIdentifier.chrome.rawValue,
            wechat: String? = AppBundleIdentifier.wechat.rawValue,
            lark: String? = AppBundleIdentifier.lark.rawValue,
            wps: String? = AppBundleIdentifier.wps.rawValue,
            hermes: String? = AppBundleIdentifier.hermes.rawValue,
            finder: String? = AppBundleIdentifier.finder.rawValue
        ) {
            self.ares = ares
            self.codex = codex
            self.chrome = chrome
            self.wechat = wechat
            self.lark = lark
            self.wps = wps
            self.hermes = hermes
            self.finder = finder
        }

        public static let `default` = Applications()
    }

    /// Per-mapping switches (design spec §3.3). All default to enabled.
    public struct Mappings: Codable, Sendable, Equatable {
        public var capsTextNavigationEnabled: Bool
        public var capsEditingEnabled: Bool
        public var capsInputSourceEnabled: Bool
        public var chromeTabEnabled: Bool
        public var leftControlAsCommandEnabled: Bool
        public var leftControlMAsReturnEnabled: Bool
        public var commandEToCommandMEnabled: Bool
        public var legacyTerminalCopyEnabled: Bool

        public init(
            capsTextNavigationEnabled: Bool = true,
            capsEditingEnabled: Bool = true,
            capsInputSourceEnabled: Bool = true,
            chromeTabEnabled: Bool = true,
            leftControlAsCommandEnabled: Bool = true,
            leftControlMAsReturnEnabled: Bool = true,
            commandEToCommandMEnabled: Bool = true,
            legacyTerminalCopyEnabled: Bool = true
        ) {
            self.capsTextNavigationEnabled = capsTextNavigationEnabled
            self.capsEditingEnabled = capsEditingEnabled
            self.capsInputSourceEnabled = capsInputSourceEnabled
            self.chromeTabEnabled = chromeTabEnabled
            self.leftControlAsCommandEnabled = leftControlAsCommandEnabled
            self.leftControlMAsReturnEnabled = leftControlMAsReturnEnabled
            self.commandEToCommandMEnabled = commandEToCommandMEnabled
            self.legacyTerminalCopyEnabled = legacyTerminalCopyEnabled
        }

        public static let `default` = Mappings()
    }
}

extension FluxConfiguration {
    /// Trims whitespace/newlines; empty values become nil. Values that are not
    /// plain bundle IDs (ASCII letters, digits, `.`, `-`, `_`) are rejected so
    /// the configuration can never smuggle macros, shell commands, or other
    /// executable payloads.
    static func sanitizedBundleID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")
        }) else { return nil }
        return trimmed
    }

    /// Non-finite values fall back to the default; finite values clamp to the
    /// supported 0.5...2.0 range.
    static func sanitizedPointerSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0.5), 2.0)
    }
}
